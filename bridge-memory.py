#!/usr/bin/env python3
"""bridge-memory.py — bridge-native markdown memory wiki helpers."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


USER_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")


@dataclass
class UserSpec:
    user_id: str
    display_name: str


def die(message: str) -> None:
    raise SystemExit(message)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str, dry_run: bool) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def append_text(path: Path, text: str, dry_run: bool) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(text)


def load_template_files(template_root: Path) -> dict[str, str]:
    files: dict[str, str] = {}
    for item in template_root.rglob("*"):
        if item.is_file():
            files[str(item.relative_to(template_root))] = read_text(item)
    return files


def parse_user_spec(raw: str) -> UserSpec:
    if ":" in raw:
        user_id, display_name = raw.split(":", 1)
    else:
        user_id, display_name = raw, raw
    user_id = user_id.strip()
    display_name = display_name.strip() or user_id
    if not user_id:
        die("empty user id is not allowed")
    if not USER_ID_RE.match(user_id):
        die(f"invalid user id: {user_id}")
    return UserSpec(user_id=user_id, display_name=display_name)


def normalize_user_specs(values: list[str]) -> list[UserSpec]:
    if not values:
        return [UserSpec(user_id="default", display_name="default")]
    seen: set[str] = set()
    result: list[UserSpec] = []
    for raw in values:
        spec = parse_user_spec(raw)
        if spec.user_id in seen:
            continue
        seen.add(spec.user_id)
        result.append(spec)
    return result


def ensure_file_from_template(
    home: Path,
    relpath: str,
    template_files: dict[str, str],
    dry_run: bool,
    created: list[str],
) -> None:
    target = home / relpath
    if target.exists():
        return
    content = template_files.get(relpath)
    if content is None:
        return
    write_text(target, content, dry_run)
    created.append(relpath)


def patch_user_profile(path: Path, display_name: str, dry_run: bool) -> None:
    if not path.exists():
        return
    text = read_text(path)
    text = text.replace("- Name:\n", f"- Name: {display_name}\n")
    text = text.replace("- Preferred name:\n", f"- Preferred name: {display_name}\n")
    write_text(path, text, dry_run)


def ensure_memory_layout(home: Path, template_root: Path, dry_run: bool) -> list[str]:
    template_files = load_template_files(template_root)
    created: list[str] = []
    for relpath in (
        "MEMORY-SCHEMA.md",
        "MEMORY.md",
        "SOUL.md",
        "CLAUDE.md",
        "TOOLS.md",
        "SKILLS.md",
        "memory/index.md",
        "memory/log.md",
    ):
        ensure_file_from_template(home, relpath, template_files, dry_run, created)

    for relpath in (
        "memory/shared/.gitkeep",
        "memory/projects/.gitkeep",
        "memory/decisions/.gitkeep",
        "raw/captures/inbox/.gitkeep",
        "raw/captures/ingested/.gitkeep",
    ):
        target = home / relpath
        if target.exists():
            continue
        if not dry_run:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("", encoding="utf-8")
        created.append(relpath)

    return created


def ensure_user_partition(
    home: Path,
    template_root: Path,
    user: UserSpec,
    dry_run: bool,
    created: list[str],
) -> None:
    users_root = home / "users"
    default_root = template_root / "users" / "default"
    target_root = users_root / user.user_id
    if target_root.exists():
        patch_user_profile(target_root / "USER.md", user.display_name, dry_run)
        return
    if not default_root.exists():
        die(f"missing template user skeleton: {default_root}")
    if not dry_run:
        shutil.copytree(default_root, target_root)
    created.append(f"users/{user.user_id}/")
    patch_user_profile(target_root / "USER.md", user.display_name, dry_run)


def remove_default_partition_if_needed(home: Path, users: list[UserSpec], dry_run: bool) -> None:
    if any(user.user_id == "default" for user in users):
        return
    default_root = home / "users" / "default"
    if not default_root.exists():
        return
    if not dry_run:
        shutil.rmtree(default_root)


def update_memory_index(home: Path, users: list[UserSpec], dry_run: bool) -> None:
    path = home / "memory" / "index.md"
    if not path.exists():
        return
    lines = read_text(path).splitlines()
    out: list[str] = []
    inserted = False
    for line in lines:
        if line.strip().startswith("- `../users/") and line.strip() != "- `../users/`":
            continue
        out.append(line)
        if line.strip() == "- `../users/`":
            for user in users:
                out.append(f"- `../users/{user.user_id}/`")
            inserted = True
    if not inserted and "- `../users/`" not in lines:
        out.extend(["", "## Users", "- `../users/`"])
        for user in users:
            out.append(f"- `../users/{user.user_id}/`")
    write_text(path, "\n".join(out).rstrip() + "\n", dry_run)


def cmd_init(args: argparse.Namespace) -> int:
    home = Path(args.home)
    template_root = Path(args.template_root)
    users = normalize_user_specs(args.user or [])
    created = ensure_memory_layout(home, template_root, args.dry_run)
    for user in users:
        ensure_user_partition(home, template_root, user, args.dry_run, created)
    remove_default_partition_if_needed(home, users, args.dry_run)
    update_memory_index(home, users, args.dry_run)
    payload = {
        "agent": args.agent,
        "home": str(home),
        "dry_run": args.dry_run,
        "users": [user.__dict__ for user in users],
        "created": created,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"home: {home}")
        print(f"dry_run: {'yes' if args.dry_run else 'no'}")
        print(f"users: {json.dumps([user.__dict__ for user in users], ensure_ascii=False)}")
        print(f"created: {len(created)}")
    return 0


def slugify(text: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-").lower()
    return slug or "capture"


def capture_payload(args: argparse.Namespace) -> dict:
    now = datetime.now().astimezone()
    capture_id = now.strftime("%Y%m%dT%H%M%S%z")
    capture_id = f"{capture_id[:15]}-{slugify(args.title or args.source or args.agent)}"
    return {
        "capture_id": capture_id,
        "agent": args.agent,
        "user": args.user,
        "source": args.source,
        "author": args.author,
        "channel": args.channel,
        "title": args.title,
        "text": args.text,
        "created_at": now.isoformat(),
    }


def cmd_capture(args: argparse.Namespace) -> int:
    home = Path(args.home)
    ensure_memory_layout(home, Path(args.template_root), args.dry_run)
    payload = capture_payload(args)
    inbox_dir = home / "raw" / "captures" / "inbox"
    path = inbox_dir / f"{payload['capture_id']}.json"
    if not args.dry_run:
        inbox_dir.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    result = {
        "capture_id": payload["capture_id"],
        "agent": args.agent,
        "user": args.user,
        "path": str(path),
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"capture_id: {payload['capture_id']}")
        print(f"path: {path}")
        print(f"user: {args.user}")
    return 0


def resolve_capture_paths(home: Path, capture_id: str | None, latest: bool, all_items: bool) -> list[Path]:
    inbox_dir = home / "raw" / "captures" / "inbox"
    candidates = sorted(inbox_dir.glob("*.json"))
    if capture_id:
        path = inbox_dir / f"{capture_id}.json"
        if not path.exists():
            die(f"capture not found: {capture_id}")
        return [path]
    if latest:
        if not candidates:
            return []
        return [candidates[-1]]
    if all_items:
        return candidates
    die("specify --capture, --latest, or --all")


def resolve_any_capture_path(home: Path, capture_id: str) -> Path:
    for directory in (
        home / "raw" / "captures" / "inbox",
        home / "raw" / "captures" / "ingested",
    ):
        path = directory / f"{capture_id}.json"
        if path.exists():
            return path
    die(f"capture not found: {capture_id}")


def ensure_daily_note(path: Path, date_str: str, dry_run: bool) -> None:
    if path.exists():
        return
    write_text(path, f"# {date_str}\n\n## Captures\n", dry_run)


def relative_link(from_path: Path, to_path: Path) -> str:
    return str(Path(shutil.os.path.relpath(to_path, from_path.parent)))


def append_ingest_entry(
    daily_path: Path,
    capture: dict,
    processed_path: Path,
    dry_run: bool,
) -> None:
    created_at = datetime.fromisoformat(capture["created_at"])
    date_label = created_at.strftime("%Y-%m-%d %H:%M %Z").strip()
    raw_link = relative_link(daily_path, processed_path)
    block = (
        f"\n### {date_label} — {capture.get('author') or 'unknown'}\n"
        f"- Source: {capture.get('source') or 'unknown'}\n"
        f"- Channel: {capture.get('channel') or '-'}\n"
        f"- Raw capture: `{raw_link}`\n"
        f"- Note: {capture.get('text') or ''}\n"
    )
    append_text(daily_path, block, dry_run)


def append_memory_log(path: Path, capture: dict, daily_rel: str, dry_run: bool) -> None:
    created_at = datetime.now().astimezone().isoformat()
    line = f"- {created_at} ingested `{capture['capture_id']}` into `{daily_rel}`\n"
    append_text(path, line, dry_run)


def append_memory_event(path: Path, line: str, dry_run: bool) -> None:
    append_text(path, line.rstrip() + "\n", dry_run)


def cmd_ingest(args: argparse.Namespace) -> int:
    home = Path(args.home)
    template_root = Path(args.template_root)
    ensure_memory_layout(home, template_root, args.dry_run)
    capture_paths = resolve_capture_paths(home, args.capture, args.latest, args.all)
    ingested: list[dict] = []
    for path in capture_paths:
        capture = json.loads(read_text(path))
        user = UserSpec(user_id=capture.get("user") or "default", display_name=capture.get("user") or "default")
        ensure_user_partition(home, template_root, user, args.dry_run, [])
        created_at = datetime.fromisoformat(capture["created_at"])
        date_str = created_at.date().isoformat()
        daily_path = home / "users" / user.user_id / "memory" / f"{date_str}.md"
        ensure_daily_note(daily_path, date_str, args.dry_run)
        processed_dir = home / "raw" / "captures" / "ingested"
        processed_path = processed_dir / path.name
        append_ingest_entry(daily_path, capture, processed_path, args.dry_run)
        append_memory_log(home / "memory" / "log.md", capture, str(daily_path.relative_to(home)), args.dry_run)
        if not args.dry_run:
            processed_dir.mkdir(parents=True, exist_ok=True)
            shutil.move(str(path), str(processed_path))
        ingested.append(
            {
                "capture_id": capture["capture_id"],
                "user": user.user_id,
                "daily_note": str(daily_path),
                "processed_path": str(processed_path),
            }
        )
    payload = {
        "agent": args.agent,
        "count": len(ingested),
        "items": ingested,
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"ingested: {len(ingested)}")
        for item in ingested:
            print(f"- {item['capture_id']} -> {item['daily_note']}")
    return 0


def ensure_section(path: Path, section: str, dry_run: bool) -> None:
    if path.exists():
        text = read_text(path)
    else:
        text = f"# {section}\n"
    if f"## {section}\n" in text or text.startswith(f"# {section}\n"):
        if not path.exists():
            write_text(path, text, dry_run)
        return
    if not text.endswith("\n"):
        text += "\n"
    text += f"\n## {section}\n"
    write_text(path, text, dry_run)


def append_under_section(path: Path, section: str, block: str, dry_run: bool) -> None:
    if path.exists():
        text = read_text(path)
    else:
        text = ""
    marker = f"\n## {section}\n"
    if text.startswith(f"# {section}\n"):
        text = text.rstrip() + "\n\n" + block
    elif marker in text:
        text = text.rstrip() + "\n" + block
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        if text:
            text += "\n"
        text += f"## {section}\n{block}"
    write_text(path, text.rstrip() + "\n", dry_run)


def page_title_from_slug(slug: str) -> str:
    return slug.replace("-", " ").replace("_", " ").strip().title() or "Memory Page"


def ensure_page(path: Path, title: str, dry_run: bool) -> None:
    if path.exists():
        return
    write_text(path, f"# {title}\n\n## Notes\n", dry_run)


def cmd_promote(args: argparse.Namespace) -> int:
    home = Path(args.home)
    template_root = Path(args.template_root)
    ensure_memory_layout(home, template_root, args.dry_run)

    capture = None
    if args.capture:
        capture = json.loads(read_text(resolve_any_capture_path(home, args.capture)))
    user_id = args.user or (capture.get("user") if capture else "default") or "default"
    user = UserSpec(user_id=user_id, display_name=user_id)
    ensure_user_partition(home, template_root, user, args.dry_run, [])

    summary = args.summary or (capture.get("text") if capture else "")
    if not summary:
        die("promotion summary is required")

    created_at = datetime.now().astimezone().isoformat()
    kind = args.kind
    title = args.title or args.page or (capture.get("title") if capture else "") or kind
    block_lines = [
        f"- {created_at}: {summary}",
    ]
    if capture:
        block_lines.append(f"  - source capture: `{capture['capture_id']}`")
        if capture.get("source"):
            block_lines.append(f"  - source: {capture['source']}")
    block = "\n".join(block_lines) + "\n"

    target_path: Path
    if kind == "user":
        target_path = home / "users" / user.user_id / "MEMORY.md"
        append_under_section(target_path, "Promotions", block, args.dry_run)
    else:
        page_slug = slugify(args.page or title)
        if kind == "shared":
            target_path = home / "memory" / "shared" / f"{page_slug}.md"
        elif kind == "project":
            target_path = home / "memory" / "projects" / f"{page_slug}.md"
        elif kind == "decision":
            target_path = home / "memory" / "decisions" / f"{page_slug}.md"
        else:
            die(f"unsupported promote kind: {kind}")
        ensure_page(target_path, page_title_from_slug(page_slug), args.dry_run)
        append_under_section(target_path, "Notes", block, args.dry_run)

    log_line = f"- {created_at} promoted `{kind}` -> `{target_path.relative_to(home)}`"
    if capture:
        log_line += f" from `{capture['capture_id']}`"
    append_memory_event(home / "memory" / "log.md", log_line, args.dry_run)

    payload = {
        "agent": args.agent,
        "kind": kind,
        "user": user.user_id,
        "target": str(target_path),
        "capture": capture["capture_id"] if capture else "",
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"kind: {kind}")
        print(f"user: {user.user_id}")
        print(f"target: {target_path}")
        if capture:
            print(f"capture: {capture['capture_id']}")
    return 0


def cmd_lint(args: argparse.Namespace) -> int:
    home = Path(args.home)
    problems: list[str] = []
    warnings: list[str] = []

    for relpath in (
        "SOUL.md",
        "CLAUDE.md",
        "MEMORY-SCHEMA.md",
        "MEMORY.md",
        "memory/index.md",
        "memory/log.md",
    ):
        if not (home / relpath).exists():
            problems.append(f"missing: {relpath}")

    users_root = home / "users"
    user_dirs = sorted(path for path in users_root.iterdir() if path.is_dir()) if users_root.exists() else []
    if not user_dirs:
        problems.append("missing: users/<user-id> partitions")
    for user_dir in user_dirs:
        if not (user_dir / "USER.md").exists():
            problems.append(f"missing: {user_dir.relative_to(home)}/USER.md")
        if not (user_dir / "MEMORY.md").exists():
            problems.append(f"missing: {user_dir.relative_to(home)}/MEMORY.md")
        if not (user_dir / "memory").exists():
            problems.append(f"missing: {user_dir.relative_to(home)}/memory/")

    index_path = home / "memory" / "index.md"
    if index_path.exists():
        index_text = read_text(index_path)
        for user_dir in user_dirs:
            expected = f"../users/{user_dir.name}/"
            if expected not in index_text:
                warnings.append(f"index_missing_user_ref: {expected}")

    inbox_dir = home / "raw" / "captures" / "inbox"
    pending_captures = sorted(path.name for path in inbox_dir.glob("*.json")) if inbox_dir.exists() else []
    if pending_captures:
        warnings.append(f"pending_captures: {len(pending_captures)}")

    payload = {
        "agent": args.agent,
        "ok": len(problems) == 0,
        "problems": problems,
        "warnings": warnings,
        "pending_captures": pending_captures,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"ok: {'yes' if not problems else 'no'}")
        if problems:
            for item in problems:
                print(f"- {item}")
        else:
            print("- no problems")
        if warnings:
            print("warnings:")
            for item in warnings:
                print(f"- {item}")
        print(f"pending_captures: {len(pending_captures)}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init")
    init_parser.add_argument("--agent", required=True)
    init_parser.add_argument("--home", required=True)
    init_parser.add_argument("--template-root", required=True)
    init_parser.add_argument("--user", action="append")
    init_parser.add_argument("--dry-run", action="store_true")
    init_parser.add_argument("--json", action="store_true")
    init_parser.set_defaults(func=cmd_init)

    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--agent", required=True)
    capture_parser.add_argument("--home", required=True)
    capture_parser.add_argument("--template-root", required=True)
    capture_parser.add_argument("--user", default="default")
    capture_parser.add_argument("--source", required=True)
    capture_parser.add_argument("--author")
    capture_parser.add_argument("--channel")
    capture_parser.add_argument("--title")
    group = capture_parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--text")
    group.add_argument("--text-file")
    capture_parser.add_argument("--dry-run", action="store_true")
    capture_parser.add_argument("--json", action="store_true")
    capture_parser.set_defaults(func=cmd_capture)

    ingest_parser = subparsers.add_parser("ingest")
    ingest_parser.add_argument("--agent", required=True)
    ingest_parser.add_argument("--home", required=True)
    ingest_parser.add_argument("--template-root", required=True)
    selector = ingest_parser.add_mutually_exclusive_group(required=True)
    selector.add_argument("--capture")
    selector.add_argument("--latest", action="store_true")
    selector.add_argument("--all", action="store_true")
    ingest_parser.add_argument("--dry-run", action="store_true")
    ingest_parser.add_argument("--json", action="store_true")
    ingest_parser.set_defaults(func=cmd_ingest)

    promote_parser = subparsers.add_parser("promote")
    promote_parser.add_argument("--agent", required=True)
    promote_parser.add_argument("--home", required=True)
    promote_parser.add_argument("--template-root", required=True)
    promote_parser.add_argument("--kind", choices=("user", "shared", "project", "decision"), required=True)
    promote_parser.add_argument("--user")
    promote_parser.add_argument("--capture")
    promote_parser.add_argument("--page")
    promote_parser.add_argument("--title")
    promote_parser.add_argument("--summary")
    promote_parser.add_argument("--dry-run", action="store_true")
    promote_parser.add_argument("--json", action="store_true")
    promote_parser.set_defaults(func=cmd_promote)

    lint_parser = subparsers.add_parser("lint")
    lint_parser.add_argument("--agent", required=True)
    lint_parser.add_argument("--home", required=True)
    lint_parser.add_argument("--json", action="store_true")
    lint_parser.set_defaults(func=cmd_lint)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if getattr(args, "text_file", None):
        args.text = Path(args.text_file).read_text(encoding="utf-8")
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
