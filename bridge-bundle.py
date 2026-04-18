#!/usr/bin/env python3
"""bridge-bundle.py — queue-first structured handoff bundle helpers."""

from __future__ import annotations

import argparse
import json
import re
import shutil
from datetime import datetime
from pathlib import Path


def die(message: str) -> None:
    raise SystemExit(message)


def now() -> datetime:
    return datetime.now().astimezone()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str, dry_run: bool = False) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def slugify(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-").lower()
    return slug or "handoff"


def bundle_root(shared_root: Path) -> Path:
    return shared_root / "a2a-files"


def bundle_dir(shared_root: Path, bundle_id: str) -> Path:
    return bundle_root(shared_root) / bundle_id


def bundle_json_path(shared_root: Path, bundle_id: str) -> Path:
    return bundle_dir(shared_root, bundle_id) / "bundle.json"


def bundle_markdown_path(shared_root: Path, bundle_id: str) -> Path:
    return bundle_dir(shared_root, bundle_id) / "handoff.md"


def artifact_relpath(path: Path, shared_root: Path) -> str:
    try:
        return str(path.relative_to(shared_root))
    except ValueError:
        return ""


def parse_artifact_spec(raw: str, shared_root: Path, dry_run: bool) -> dict[str, str]:
    if "::" in raw:
        path_text, purpose = raw.split("::", 1)
    else:
        path_text, purpose = raw, ""
    path = Path(path_text).expanduser()
    if not path.is_absolute():
        path = path.resolve()
    if not dry_run and not path.exists():
        die(f"artifact path not found: {path}")
    relative_path = artifact_relpath(path, shared_root)
    return {
        "path": str(path),
        "relative_path": relative_path,
        "purpose": purpose.strip(),
        "scope": "shared" if relative_path else "external",
    }


def default_task_title(title: str) -> str:
    return f"[handoff] {title}"


def render_bundle_markdown(payload: dict[str, object]) -> str:
    artifacts = payload["artifacts"]
    lines = [
        f"# Handoff Bundle {payload['bundle_id']}",
        "",
        f"- Created at: {payload['created_at']}",
        f"- From: {payload['from_agent']}",
        f"- To: {payload['to_agent']}",
        f"- Queue title: {payload['task']['title']}",
        f"- Queue task: #{payload['task']['id']}" if payload["task"]["id"] else "- Queue task: pending",
        f"- Priority: {payload['task']['priority']}",
        "",
        "## Summary",
        "",
        str(payload["summary"]).strip(),
        "",
        "## Required Action",
        "",
        str(payload["required_action"]).strip(),
        "",
        "## Expected Output",
        "",
        str(payload["expected_output"]).strip() or "_No explicit expected output._",
        "",
        "## Artifact Manifest",
        "",
    ]
    if artifacts:
        for artifact in artifacts:
            purpose = f" — {artifact['purpose']}" if artifact["purpose"] else ""
            rel = f" ({artifact['relative_path']})" if artifact["relative_path"] else ""
            lines.append(f"- `{artifact['path']}`{rel}{purpose}")
    else:
        lines.append("- _No artifacts attached._")
    lines.extend(
        [
            "",
            "## Human Follow-up Draft",
            "",
            str(payload["human_followup"]).strip() or "_No human follow-up draft._",
            "",
            "## Bundle Files",
            "",
            f"- JSON: `{payload['paths']['bundle_json']}`",
            f"- Task body: `{payload['paths']['task_body']}`",
            f"- Artifact staging dir: `{payload['paths']['artifact_dir']}`",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def write_bundle(payload: dict[str, object], dry_run: bool) -> None:
    bundle_dir_path = Path(payload["paths"]["bundle_dir"])
    artifact_dir_path = Path(payload["paths"]["artifact_dir"])
    if not dry_run:
        bundle_dir_path.mkdir(parents=True, exist_ok=True)
        artifact_dir_path.mkdir(parents=True, exist_ok=True)
        bundle_dir_path.chmod(0o755)
        artifact_dir_path.chmod(0o755)
        (artifact_dir_path / ".gitkeep").write_text("", encoding="utf-8")
    write_text(Path(payload["paths"]["bundle_json"]), json.dumps(payload, ensure_ascii=False, indent=2) + "\n", dry_run)
    write_text(Path(payload["paths"]["task_body"]), render_bundle_markdown(payload), dry_run)


def stage_artifacts(artifacts: list[dict[str, str]], artifact_dir: Path, shared_root: Path, dry_run: bool) -> None:
    used_names: set[str] = set()
    for artifact in artifacts:
        src = Path(artifact["path"])
        base = src.name
        name = base
        index = 1
        while name in used_names:
            name = f"{src.stem}-{index}{src.suffix}"
            index += 1
        used_names.add(name)
        dst = artifact_dir / name
        artifact["staged_path"] = str(dst)
        try:
            artifact["staged_relative_path"] = str(dst.relative_to(shared_root))
        except ValueError:
            artifact["staged_relative_path"] = ""
        if dry_run or not src.exists():
            continue
        shutil.copy2(src, dst)
        dst.chmod(0o644)


def cmd_create(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    created_at = now().isoformat(timespec="seconds")
    bundle_id = args.bundle_id or f"{now().strftime('%Y%m%dT%H%M%S%z')}-{slugify(args.title)}"
    artifacts = [parse_artifact_spec(item, shared_root, args.dry_run) for item in args.artifact]
    task_title = args.task_title or default_task_title(args.title)
    payload = {
        "bundle_id": bundle_id,
        "created_at": created_at,
        "from_agent": args.from_agent,
        "to_agent": args.to_agent,
        "title": args.title,
        "summary": args.summary,
        "required_action": args.required_action,
        "expected_output": args.expected_output,
        "human_followup": args.human_followup,
        "artifacts": artifacts,
        "task": {
            "id": None,
            "title": task_title,
            "priority": args.priority,
        },
        "paths": {
            "bundle_dir": str(bundle_dir(shared_root, bundle_id)),
            "bundle_json": str(bundle_json_path(shared_root, bundle_id)),
            "task_body": str(bundle_markdown_path(shared_root, bundle_id)),
            "artifact_dir": str(bundle_dir(shared_root, bundle_id) / "artifacts"),
        },
        "relative_paths": {
            "bundle_dir": str(bundle_dir(shared_root, bundle_id).relative_to(shared_root)),
            "bundle_json": str(bundle_json_path(shared_root, bundle_id).relative_to(shared_root)),
            "task_body": str(bundle_markdown_path(shared_root, bundle_id).relative_to(shared_root)),
            "artifact_dir": str((bundle_dir(shared_root, bundle_id) / "artifacts").relative_to(shared_root)),
        },
    }
    write_bundle(payload, args.dry_run)
    stage_artifacts(artifacts, Path(payload["paths"]["artifact_dir"]), shared_root, args.dry_run)
    if not args.dry_run:
        write_text(Path(payload["paths"]["bundle_json"]), json.dumps(payload, ensure_ascii=False, indent=2) + "\n", args.dry_run)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_attach_task(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    path = bundle_json_path(shared_root, args.bundle_id)
    if not path.exists():
        die(f"bundle not found: {args.bundle_id}")
    payload = json.loads(read_text(path))
    payload["task"]["id"] = args.task_id
    payload["task"]["title"] = args.task_title
    payload["task"]["priority"] = args.task_priority
    payload["task"]["updated_at"] = now().isoformat(timespec="seconds")
    write_bundle(payload, args.dry_run)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    path = bundle_json_path(shared_root, args.bundle_id)
    if not path.exists():
        die(f"bundle not found: {args.bundle_id}")
    print(json.dumps(json.loads(read_text(path)), ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--shared-root", required=True)
    create_parser.add_argument("--bundle-id", default="")
    create_parser.add_argument("--from-agent", required=True)
    create_parser.add_argument("--to-agent", required=True)
    create_parser.add_argument("--title", required=True)
    create_parser.add_argument("--task-title", default="")
    create_parser.add_argument("--summary", required=True)
    create_parser.add_argument("--required-action", required=True)
    create_parser.add_argument("--artifact", action="append", default=[])
    create_parser.add_argument("--expected-output", default="")
    create_parser.add_argument("--human-followup", default="")
    create_parser.add_argument("--priority", default="normal")
    create_parser.add_argument("--dry-run", action="store_true")
    create_parser.set_defaults(func=cmd_create)

    attach_parser = subparsers.add_parser("attach-task")
    attach_parser.add_argument("--shared-root", required=True)
    attach_parser.add_argument("--bundle-id", required=True)
    attach_parser.add_argument("--task-id", type=int, required=True)
    attach_parser.add_argument("--task-title", required=True)
    attach_parser.add_argument("--task-priority", required=True)
    attach_parser.add_argument("--dry-run", action="store_true")
    attach_parser.set_defaults(func=cmd_attach_task)

    show_parser = subparsers.add_parser("show")
    show_parser.add_argument("--shared-root", required=True)
    show_parser.add_argument("--bundle-id", required=True)
    show_parser.set_defaults(func=cmd_show)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
