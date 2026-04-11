#!/usr/bin/env python3
"""bridge-intake.py — structured external intake triage helpers."""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from pathlib import Path


PRIORITIES = ("low", "normal", "high", "urgent")


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


def raw_root(shared_root: Path) -> Path:
    return shared_root / "raw"


def resolve_capture(shared_root: Path, capture_id: str) -> tuple[Path, dict[str, str]]:
    for folder in ("inbox", "promoted"):
        path = raw_root(shared_root) / "captures" / folder / f"{capture_id}.json"
        if path.exists():
            return path, json.loads(read_text(path))
    die(f"capture not found: {capture_id}")


def triage_root(shared_root: Path) -> Path:
    return raw_root(shared_root) / "intake"


def triage_json_path(shared_root: Path, capture_id: str) -> Path:
    return triage_root(shared_root) / f"{capture_id}.json"


def triage_markdown_path(shared_root: Path, capture_id: str) -> Path:
    return triage_root(shared_root) / f"{capture_id}.md"


def parse_field(raw: str) -> tuple[str, str]:
    if "=" not in raw:
        die(f"invalid extracted field (expected key=value): {raw}")
    key, value = raw.split("=", 1)
    key = key.strip()
    value = value.strip()
    if not key:
        die(f"invalid extracted field key: {raw}")
    return key, value


def render_triage_markdown(payload: dict[str, object]) -> str:
    capture = payload["capture"]
    task = payload["task"]
    lines = [
        f"# Intake Triage {payload['capture_id']}",
        "",
        f"- Triage created at: {payload['triage_created_at']}",
        f"- Source: {capture.get('source', '')}",
        f"- Author: {capture.get('author', '')}",
        f"- Channel: {capture.get('channel', '')}",
        f"- Title: {payload['title']}",
        f"- Category: {payload['category']}",
        f"- Importance: {payload['importance']}",
        f"- Reply needed: {'yes' if payload['reply_needed'] else 'no'}",
        f"- Suggested owner: {payload['suggested_owner']}",
        f"- Confidence: {payload['confidence']}",
        f"- Queue task: #{task['id']}" if task["id"] else "- Queue task: pending",
        "",
        "## Summary",
        "",
        str(payload["summary"]).strip(),
        "",
        "## Extracted Fields",
        "",
    ]
    extracted_fields = payload["extracted_fields"]
    if extracted_fields:
        for key, value in extracted_fields.items():
            lines.append(f"- {key}: {value}")
    else:
        lines.append("- _No structured fields._")
    lines.extend(
        [
            "",
            "## Human Follow-up Draft",
            "",
            str(payload["followup_draft"]).strip() or "_No human follow-up draft._",
            "",
            "## Raw Source Detail",
            "",
            str(capture.get("text", "")).strip() or "_No raw source detail._",
            "",
            "## Files",
            "",
            f"- Raw capture: `{payload['paths']['capture']}`",
            f"- Triage JSON: `{payload['paths']['triage_json']}`",
            f"- Queue body: `{payload['paths']['triage_markdown']}`",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def write_triage(payload: dict[str, object], dry_run: bool) -> None:
    write_text(Path(payload["paths"]["triage_json"]), json.dumps(payload, ensure_ascii=False, indent=2) + "\n", dry_run)
    write_text(Path(payload["paths"]["triage_markdown"]), render_triage_markdown(payload), dry_run)


def cmd_triage(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    capture_path, capture = resolve_capture(shared_root, args.capture)
    extracted_fields = dict(parse_field(item) for item in args.field)
    reply_needed = args.reply_needed == "yes"
    payload = {
        "capture_id": args.capture,
        "triage_created_at": now().isoformat(timespec="seconds"),
        "title": args.title or capture.get("title", "") or args.capture,
        "summary": args.summary,
        "category": args.category,
        "importance": args.importance,
        "reply_needed": reply_needed,
        "needs_human_followup": reply_needed or bool(args.followup),
        "suggested_owner": args.owner,
        "confidence": args.confidence,
        "extracted_fields": extracted_fields,
        "followup_draft": args.followup,
        "capture": capture,
        "task": {
            "id": None,
            "title": f"[intake] {args.summary}",
            "priority": args.importance,
        },
        "paths": {
            "capture": str(capture_path),
            "triage_json": str(triage_json_path(shared_root, args.capture)),
            "triage_markdown": str(triage_markdown_path(shared_root, args.capture)),
        },
        "relative_paths": {
            "capture": str(capture_path.relative_to(shared_root)),
            "triage_json": str(triage_json_path(shared_root, args.capture).relative_to(shared_root)),
            "triage_markdown": str(triage_markdown_path(shared_root, args.capture).relative_to(shared_root)),
        },
    }
    write_triage(payload, args.dry_run)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_attach_task(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    path = triage_json_path(shared_root, args.capture)
    if not path.exists():
        die(f"triage record not found: {args.capture}")
    payload = json.loads(read_text(path))
    payload["task"]["id"] = args.task_id
    payload["task"]["title"] = args.task_title
    payload["task"]["priority"] = args.task_priority
    payload["task"]["updated_at"] = now().isoformat(timespec="seconds")
    write_triage(payload, args.dry_run)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    path = triage_json_path(shared_root, args.capture)
    if not path.exists():
        die(f"triage record not found: {args.capture}")
    print(json.dumps(json.loads(read_text(path)), ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    triage_parser = subparsers.add_parser("triage")
    triage_parser.add_argument("--shared-root", required=True)
    triage_parser.add_argument("--capture", required=True)
    triage_parser.add_argument("--title", default="")
    triage_parser.add_argument("--summary", required=True)
    triage_parser.add_argument("--category", required=True)
    triage_parser.add_argument("--importance", choices=PRIORITIES, default="normal")
    triage_parser.add_argument("--reply-needed", choices=("yes", "no"), default="no")
    triage_parser.add_argument("--owner", required=True)
    triage_parser.add_argument("--confidence", default="")
    triage_parser.add_argument("--field", action="append", default=[])
    triage_parser.add_argument("--followup", default="")
    triage_parser.add_argument("--dry-run", action="store_true")
    triage_parser.set_defaults(func=cmd_triage)

    attach_parser = subparsers.add_parser("attach-task")
    attach_parser.add_argument("--shared-root", required=True)
    attach_parser.add_argument("--capture", required=True)
    attach_parser.add_argument("--task-id", type=int, required=True)
    attach_parser.add_argument("--task-title", required=True)
    attach_parser.add_argument("--task-priority", required=True)
    attach_parser.add_argument("--dry-run", action="store_true")
    attach_parser.set_defaults(func=cmd_attach_task)

    show_parser = subparsers.add_parser("show")
    show_parser.add_argument("--shared-root", required=True)
    show_parser.add_argument("--capture", required=True)
    show_parser.set_defaults(func=cmd_show)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
