#!/usr/bin/env python3
"""bridge-memory.py — bridge-native markdown memory wiki helpers."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sqlite3
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


USER_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
SEARCH_SCOPES = ("wiki", "all", "user", "daily", "shared", "project", "decision", "raw")
QUERY_SCOPES = ("all", "wiki", "user", "daily", "shared", "project", "decision", "raw")
INDEX_KIND = "bridge-wiki-fts-v1"


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


def write_capture_payload(home: Path, payload: dict, dry_run: bool) -> Path:
    inbox_dir = home / "raw" / "captures" / "inbox"
    path = inbox_dir / f"{payload['capture_id']}.json"
    if not dry_run:
        inbox_dir.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path


def cmd_capture(args: argparse.Namespace) -> int:
    home = Path(args.home)
    ensure_memory_layout(home, Path(args.template_root), args.dry_run)
    payload = capture_payload(args)
    path = write_capture_payload(home, payload, args.dry_run)
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


def ingest_capture_payload(
    home: Path,
    template_root: Path,
    capture: dict,
    capture_path: Path,
    dry_run: bool,
) -> dict:
    user = UserSpec(user_id=capture.get("user") or "default", display_name=capture.get("user") or "default")
    ensure_user_partition(home, template_root, user, dry_run, [])
    created_at = datetime.fromisoformat(capture["created_at"])
    date_str = created_at.date().isoformat()
    daily_path = home / "users" / user.user_id / "memory" / f"{date_str}.md"
    ensure_daily_note(daily_path, date_str, dry_run)
    processed_dir = home / "raw" / "captures" / "ingested"
    processed_path = processed_dir / capture_path.name
    append_ingest_entry(daily_path, capture, processed_path, dry_run)
    append_memory_log(home / "memory" / "log.md", capture, str(daily_path.relative_to(home)), dry_run)
    if not dry_run:
        processed_dir.mkdir(parents=True, exist_ok=True)
        shutil.move(str(capture_path), str(processed_path))
    return {
        "capture_id": capture["capture_id"],
        "user": user.user_id,
        "daily_note": str(daily_path),
        "processed_path": str(processed_path),
    }


def cmd_ingest(args: argparse.Namespace) -> int:
    home = Path(args.home)
    template_root = Path(args.template_root)
    ensure_memory_layout(home, template_root, args.dry_run)
    capture_paths = resolve_capture_paths(home, args.capture, args.latest, args.all)
    ingested: list[dict] = []
    for path in capture_paths:
        capture = json.loads(read_text(path))
        ingested.append(ingest_capture_payload(home, template_root, capture, path, args.dry_run))
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


def build_page_promotion_block(
    created_at: str,
    title: str,
    summary: str,
    capture: dict | None,
) -> str:
    lines = [f"### {created_at} — {title}", "", summary]
    detail_text = (capture or {}).get("text", "").strip()
    if detail_text and detail_text != summary.strip():
        lines.extend(["", "#### Details", "", detail_text])
    if capture:
        lines.extend(["", "#### Source"])
        lines.append(f"- Capture: `{capture['capture_id']}`")
        if capture.get("source"):
            lines.append(f"- Source: {capture['source']}")
        if capture.get("author"):
            lines.append(f"- Author: {capture['author']}")
        if capture.get("channel"):
            lines.append(f"- Channel: {capture['channel']}")
    return "\n".join(lines).rstrip() + "\n"


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
        append_under_section(
            target_path,
            "Notes",
            build_page_promotion_block(created_at, title, summary, capture),
            args.dry_run,
        )

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


def promote_capture_or_summary(
    home: Path,
    template_root: Path,
    agent: str,
    kind: str,
    user_id: str,
    capture: dict | None,
    page: str,
    title: str,
    summary: str,
    dry_run: bool,
) -> dict:
    promote_args = argparse.Namespace(
        agent=agent,
        home=str(home),
        template_root=str(template_root),
        kind=kind,
        user=user_id,
        capture=capture["capture_id"] if capture else "",
        page=page,
        title=title,
        summary=summary,
        dry_run=dry_run,
        json=True,
    )
    from io import StringIO
    import contextlib

    buffer = StringIO()
    with contextlib.redirect_stdout(buffer):
        cmd_promote(promote_args)
    return json.loads(buffer.getvalue())


def cmd_remember(args: argparse.Namespace) -> int:
    home = Path(args.home)
    template_root = Path(args.template_root)
    ensure_memory_layout(home, template_root, args.dry_run)

    capture_args = argparse.Namespace(
        agent=args.agent,
        user=args.user,
        source=args.source,
        author=args.author,
        channel=args.channel,
        title=args.title,
        text=args.text,
    )
    capture = capture_payload(capture_args)
    capture_path = write_capture_payload(home, capture, args.dry_run)
    ingested = ingest_capture_payload(home, template_root, capture, capture_path, args.dry_run)

    promotion = None
    if args.kind != "none":
        promotion = promote_capture_or_summary(
            home=home,
            template_root=template_root,
            agent=args.agent,
            kind=args.kind,
            user_id=args.user,
            capture=capture,
            page=args.page,
            title=args.title,
            summary=args.summary or args.text,
            dry_run=args.dry_run,
        )

    payload = {
        "agent": args.agent,
        "capture_id": capture["capture_id"],
        "user": args.user,
        "source": args.source,
        "daily_note": ingested["daily_note"],
        "processed_path": ingested["processed_path"],
        "promotion": promotion or {},
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"capture_id: {capture['capture_id']}")
        print(f"user: {args.user}")
        print(f"daily_note: {ingested['daily_note']}")
        print(f"processed_path: {ingested['processed_path']}")
        if promotion:
            print(f"promotion: {promotion['kind']} -> {promotion['target']}")
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


def tokenize_query(text: str) -> list[str]:
    tokens = [item.lower() for item in re.findall(r"[A-Za-z0-9._-]+", text) if len(item) >= 2]
    if not tokens and text.strip():
        tokens = [text.strip().lower()]
    seen: set[str] = set()
    unique: list[str] = []
    for token in tokens:
        if token in seen:
            continue
        seen.add(token)
        unique.append(token)
    return unique


def user_daily_sort_key(path: Path) -> tuple[int, str]:
    try:
        date_str = path.stem
        return (0, date_str)
    except Exception:
        return (1, path.name)


def iter_search_candidates(home: Path, scope: str, user_id: str | None) -> list[tuple[str, Path]]:
    candidates: list[tuple[str, Path]] = []
    include_wiki = scope in ("wiki", "all")

    if include_wiki or scope == "user":
        if user_id:
            user_root = home / "users" / user_id
            if user_root.exists():
                candidates.extend(
                    [
                        ("user-profile", user_root / "USER.md"),
                        ("user-memory", user_root / "MEMORY.md"),
                    ]
                )
        else:
            users_root = home / "users"
            if users_root.exists():
                for user_root in sorted(path for path in users_root.iterdir() if path.is_dir()):
                    candidates.extend(
                        [
                            ("user-profile", user_root / "USER.md"),
                            ("user-memory", user_root / "MEMORY.md"),
                        ]
                    )

    if include_wiki or scope == "daily":
        if user_id:
            daily_root = home / "users" / user_id / "memory"
            if daily_root.exists():
                for path in sorted(daily_root.glob("*.md"), key=user_daily_sort_key, reverse=True):
                    candidates.append(("daily", path))
        else:
            users_root = home / "users"
            if users_root.exists():
                for user_root in sorted(path for path in users_root.iterdir() if path.is_dir()):
                    daily_root = user_root / "memory"
                    if not daily_root.exists():
                        continue
                    for path in sorted(daily_root.glob("*.md"), key=user_daily_sort_key, reverse=True):
                        candidates.append(("daily", path))

    if include_wiki:
        candidates.extend(
            [
                ("agent-memory", home / "MEMORY.md"),
                ("wiki-index", home / "memory" / "index.md"),
                ("wiki-log", home / "memory" / "log.md"),
            ]
        )

    if include_wiki or scope == "shared":
        shared_root = home / "memory" / "shared"
        if shared_root.exists():
            for path in sorted(shared_root.glob("*.md")):
                candidates.append(("shared", path))

    if include_wiki or scope == "project":
        project_root = home / "memory" / "projects"
        if project_root.exists():
            for path in sorted(project_root.glob("*.md")):
                candidates.append(("project", path))

    if include_wiki or scope == "decision":
        decision_root = home / "memory" / "decisions"
        if decision_root.exists():
            for path in sorted(decision_root.glob("*.md")):
                candidates.append(("decision", path))

    if scope in ("all", "raw"):
        for raw_dir in (
            home / "raw" / "captures" / "inbox",
            home / "raw" / "captures" / "ingested",
        ):
            if not raw_dir.exists():
                continue
            for path in sorted(raw_dir.glob("*.json"), reverse=True):
                candidates.append(("raw", path))

    filtered: list[tuple[str, Path]] = []
    seen_paths: set[Path] = set()
    for kind, path in candidates:
        if path in seen_paths or not path.exists():
            continue
        seen_paths.add(path)
        filtered.append((kind, path))
    return filtered


def search_score(kind: str, path: Path, text: str, tokens: list[str]) -> tuple[int, list[str]]:
    lower = text.lower()
    hits: list[str] = []
    score = 0
    for token in tokens:
        count = lower.count(token)
        if count <= 0:
            continue
        hits.append(token)
        score += count * 8
        if token in path.name.lower():
            score += 10
    base_scores = {
        "user-profile": 80,
        "user-memory": 70,
        "daily": 60,
        "agent-memory": 55,
        "shared": 50,
        "project": 45,
        "decision": 45,
        "wiki-index": 30,
        "wiki-log": 20,
        "raw": 10,
    }
    score += base_scores.get(kind, 0)
    return score, hits


def build_snippet(text: str, tokens: list[str]) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return ""
    for line in lines:
        lower = line.lower()
        if any(token in lower for token in tokens):
            return line[:240]
    return lines[0][:240]


def cmd_search(args: argparse.Namespace) -> int:
    home = Path(args.home)
    tokens = tokenize_query(args.query)
    if not tokens:
        die("search query is empty")

    results: list[dict] = []
    for kind, path in iter_search_candidates(home, args.scope, args.user):
        text = read_text(path)
        score, hits = search_score(kind, path, text, tokens)
        if score <= 0 or not hits:
            continue
        results.append(
            {
                "kind": kind,
                "path": str(path),
                "relative_path": str(path.relative_to(home)),
                "score": score,
                "hits": hits,
                "snippet": build_snippet(text, tokens),
            }
        )

    results.sort(key=lambda item: (-item["score"], item["relative_path"]))
    limited = results[: args.limit]
    payload = {
        "agent": args.agent,
        "query": args.query,
        "tokens": tokens,
        "scope": args.scope,
        "user": args.user or "",
        "count": len(limited),
        "total_matches": len(results),
        "results": limited,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"query: {args.query}")
        print(f"scope: {args.scope}")
        if args.user:
            print(f"user: {args.user}")
        print(f"matches: {len(limited)} / {len(results)}")
        for item in limited:
            print(f"- [{item['kind']}] {item['relative_path']} (score={item['score']})")
            if item["snippet"]:
                print(f"  {item['snippet']}")
    return 0


def collect_index_documents(home: Path) -> list[dict]:
    documents: list[dict] = []

    def add_markdown(path: Path, kind: str, user_id: str = "") -> None:
        if path.exists():
            documents.append({"path": path, "kind": kind, "user_id": user_id, "format": "markdown"})

    def add_json(path: Path, kind: str) -> None:
        if path.exists():
            documents.append({"path": path, "kind": kind, "user_id": "", "format": "json"})

    add_markdown(home / "SOUL.md", "agent-soul")
    add_markdown(home / "CLAUDE.md", "agent-contract")
    add_markdown(home / "MEMORY-SCHEMA.md", "memory-schema")
    add_markdown(home / "MEMORY.md", "agent-memory")
    add_markdown(home / "memory" / "index.md", "wiki-index")
    add_markdown(home / "memory" / "log.md", "wiki-log")

    for subdir, kind in (("shared", "shared"), ("projects", "project"), ("decisions", "decision")):
        root = home / "memory" / subdir
        if root.exists():
            for path in sorted(root.glob("*.md")):
                add_markdown(path, kind)

    users_root = home / "users"
    if users_root.exists():
        for user_root in sorted(path for path in users_root.iterdir() if path.is_dir()):
            user_id = user_root.name
            add_markdown(user_root / "USER.md", "user-profile", user_id=user_id)
            add_markdown(user_root / "MEMORY.md", "user-memory", user_id=user_id)
            daily_root = user_root / "memory"
            if daily_root.exists():
                for path in sorted(daily_root.glob("*.md")):
                    add_markdown(path, "daily", user_id=user_id)

    for raw_root, kind in (
        (home / "raw" / "captures" / "ingested", "raw-ingested"),
        (home / "raw" / "captures" / "inbox", "raw-inbox"),
    ):
        if raw_root.exists():
            for path in sorted(raw_root.glob("*.json")):
                add_json(path, kind)

    return documents


def chunk_markdown_text(text: str) -> list[tuple[int, int, str]]:
    lines = text.splitlines()
    chunks: list[tuple[int, int, str]] = []
    current: list[str] = []
    start_line = 1

    def flush(end_line: int) -> None:
        nonlocal current, start_line
        compact = "\n".join(line.rstrip() for line in current).strip()
        if compact:
            chunks.append((start_line, end_line, compact))
        current = []

    for lineno, line in enumerate(lines, start=1):
        if line.startswith("#"):
            if current:
                flush(lineno - 1)
            current = [line]
            start_line = lineno
            continue
        if line.strip() == "":
            if current:
                current.append(line)
                flush(lineno)
            else:
                start_line = lineno + 1
            continue
        if not current:
            current = [line]
            start_line = lineno
        else:
            current.append(line)
    if current:
        flush(len(lines) if lines else start_line)
    return chunks


def chunk_json_capture(path: Path) -> tuple[int, int, str, str]:
    payload = json.loads(read_text(path))
    lines = [
        f"capture_id: {payload.get('capture_id', '')}",
        f"user: {payload.get('user', '')}",
        f"source: {payload.get('source', '')}",
        f"author: {payload.get('author', '')}",
        f"channel: {payload.get('channel', '')}",
        f"title: {payload.get('title', '')}",
        f"text: {payload.get('text', '')}",
        f"created_at: {payload.get('created_at', '')}",
    ]
    return 1, len(lines), "\n".join(lines).strip(), payload.get("user", "") or ""


def ensure_index_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS documents (
            path TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            user_id TEXT NOT NULL DEFAULT '',
            format TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            indexed_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL,
            source TEXT NOT NULL,
            model TEXT NOT NULL DEFAULT 'bridge-wiki-fts-v1',
            kind TEXT NOT NULL,
            user_id TEXT NOT NULL DEFAULT '',
            start_line INTEGER NOT NULL,
            end_line INTEGER NOT NULL,
            text TEXT NOT NULL,
            embedding TEXT NOT NULL DEFAULT '[]'
        );
        """
    )


def recreate_index_fts(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        DROP TRIGGER IF EXISTS chunks_ai;
        DROP TRIGGER IF EXISTS chunks_ad;
        DROP TRIGGER IF EXISTS chunks_au;
        DROP TABLE IF EXISTS chunks_fts;
        CREATE VIRTUAL TABLE chunks_fts USING fts5(
            text,
            path UNINDEXED,
            source UNINDEXED,
            model UNINDEXED,
            kind UNINDEXED,
            user_id UNINDEXED,
            content='chunks',
            content_rowid='id'
        );
        CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
          INSERT INTO chunks_fts(rowid, text, path, source, model, kind, user_id)
          VALUES (new.id, new.text, new.path, new.source, new.model, new.kind, new.user_id);
        END;
        CREATE TRIGGER chunks_ad AFTER DELETE ON chunks BEGIN
          INSERT INTO chunks_fts(chunks_fts, rowid, text, path, source, model, kind, user_id)
          VALUES ('delete', old.id, old.text, old.path, old.source, old.model, old.kind, old.user_id);
        END;
        CREATE TRIGGER chunks_au AFTER UPDATE ON chunks BEGIN
          INSERT INTO chunks_fts(chunks_fts, rowid, text, path, source, model, kind, user_id)
          VALUES ('delete', old.id, old.text, old.path, old.source, old.model, old.kind, old.user_id);
          INSERT INTO chunks_fts(rowid, text, path, source, model, kind, user_id)
          VALUES (new.id, new.text, new.path, new.source, new.model, new.kind, new.user_id);
        END;
        """
    )


def build_fts_query(raw: str) -> str | None:
    tokens = re.findall(r"\w+", raw, flags=re.UNICODE)
    tokens = [token.strip() for token in tokens if token.strip()]
    if not tokens:
        return None
    return " AND ".join(f'"{token.replace(chr(34), "")}"' for token in tokens)


def default_index_db_path(bridge_home: Path, agent: str) -> Path:
    return bridge_home / "runtime" / "memory" / f"{agent}.sqlite"


def cmd_rebuild_index(args: argparse.Namespace) -> int:
    home = Path(args.home)
    bridge_home = Path(args.bridge_home)
    db_path = Path(args.db_path) if args.db_path else default_index_db_path(bridge_home, args.agent)
    indexed_at = datetime.now().astimezone().isoformat()
    documents = collect_index_documents(home)

    chunk_count = 0
    if not args.dry_run:
        db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(db_path)
        try:
            ensure_index_schema(conn)
            recreate_index_fts(conn)
            conn.execute("DELETE FROM chunks")
            conn.execute("DELETE FROM documents")
            conn.execute("DELETE FROM meta")
            for doc in documents:
                path = doc["path"]
                relpath = str(path.relative_to(home))
                if doc["format"] == "markdown":
                    text = read_text(path)
                    chunks = chunk_markdown_text(text)
                    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
                    size_bytes = len(text.encode("utf-8"))
                    user_id = doc["user_id"]
                else:
                    start_line, end_line, text, capture_user = chunk_json_capture(path)
                    chunks = [(start_line, end_line, text)]
                    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
                    size_bytes = len(text.encode("utf-8"))
                    user_id = capture_user or doc["user_id"]

                conn.execute(
                    """
                    INSERT INTO documents(path, kind, user_id, format, sha256, size_bytes, indexed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (relpath, doc["kind"], user_id, doc["format"], digest, size_bytes, indexed_at),
                )
                for start_line, end_line, text in chunks:
                    if not text.strip():
                        continue
                    conn.execute(
                        """
                        INSERT INTO chunks(path, source, model, kind, user_id, start_line, end_line, text, embedding)
                        VALUES (?, ?, 'bridge-wiki-fts-v1', ?, ?, ?, ?, ?, '[]')
                        """,
                        (relpath, doc["kind"], doc["kind"], user_id, start_line, end_line, text),
                    )
                    chunk_count += 1

            conn.executemany(
                "INSERT INTO meta(key, value) VALUES (?, ?)",
                {
                    "index_kind": INDEX_KIND,
                    "agent": args.agent,
                    "home": str(home),
                    "indexed_at": indexed_at,
                    "document_count": str(len(documents)),
                    "chunk_count": str(chunk_count),
                }.items(),
            )
            conn.commit()
        finally:
            conn.close()
    else:
        for doc in documents:
            if doc["format"] == "markdown":
                chunk_count += len(chunk_markdown_text(read_text(doc["path"])))
            else:
                chunk_count += 1

    payload = {
        "agent": args.agent,
        "db_path": str(db_path),
        "document_count": len(documents),
        "chunk_count": chunk_count,
        "indexed_at": indexed_at,
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"db_path: {db_path}")
        print(f"document_count: {len(documents)}")
        print(f"chunk_count: {chunk_count}")
        print(f"dry_run: {'yes' if args.dry_run else 'no'}")
    return 0


def cmd_query(args: argparse.Namespace) -> int:
    home = Path(args.home)
    bridge_home = Path(args.bridge_home)
    db_path = Path(args.db_path) if args.db_path else default_index_db_path(bridge_home, args.agent)
    if not db_path.exists():
        fallback = argparse.Namespace(**vars(args))
        fallback.scope = "all" if args.scope == "all" else args.scope
        return cmd_search(fallback)

    fts_query = build_fts_query(args.query)
    if not fts_query:
        die("query is empty")

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        clauses = ["chunks_fts MATCH ?"]
        params: list[object] = [fts_query]
        if args.user:
            clauses.append("chunks.user_id = ?")
            params.append(args.user)
        if args.scope != "all":
            if args.scope == "wiki":
                clauses.append("chunks.kind NOT LIKE 'raw-%'")
            elif args.scope == "raw":
                clauses.append("chunks.kind LIKE 'raw-%'")
            elif args.scope == "user":
                clauses.append("chunks.kind IN ('user-profile', 'user-memory')")
            elif args.scope == "daily":
                clauses.append("chunks.kind = 'daily'")
            elif args.scope == "shared":
                clauses.append("chunks.kind = 'shared'")
            elif args.scope == "project":
                clauses.append("chunks.kind = 'project'")
            elif args.scope == "decision":
                clauses.append("chunks.kind = 'decision'")
        params.append(int(args.limit))
        rows = conn.execute(
            f"""
            SELECT
              chunks.kind,
              chunks.user_id,
              chunks.path,
              chunks.start_line,
              chunks.end_line,
              bm25(chunks_fts) AS rank,
              snippet(chunks_fts, 0, '', '', ' ... ', 20) AS snippet
            FROM chunks_fts
            JOIN chunks ON chunks.id = chunks_fts.rowid
            WHERE {' AND '.join(clauses)}
            ORDER BY rank ASC
            LIMIT ?
            """,
            params,
        ).fetchall()
    finally:
        conn.close()

    results = []
    for row in rows:
        rank = row["rank"]
        if isinstance(rank, (int, float)):
            score = (-float(rank) / (1 + -float(rank))) if float(rank) < 0 else 1 / (1 + float(rank))
        else:
            score = 0.0
        results.append(
            {
                "kind": row["kind"],
                "user_id": row["user_id"],
                "path": str(home / row["path"]),
                "relative_path": row["path"],
                "start_line": row["start_line"],
                "end_line": row["end_line"],
                "score": score,
                "snippet": (row["snippet"] or "").strip(),
            }
        )

    payload = {
        "agent": args.agent,
        "query": args.query,
        "scope": args.scope,
        "user": args.user or "",
        "backend": "index",
        "db_path": str(db_path),
        "count": len(results),
        "results": results,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"agent: {args.agent}")
        print(f"query: {args.query}")
        print(f"scope: {args.scope}")
        print("backend: index")
        print(f"matches: {len(results)}")
        for item in results:
            print(f"- [{item['kind']}] {item['relative_path']}:{item['start_line']}-{item['end_line']} (score={item['score']:.4f})")
            if item["snippet"]:
                print(f"  {item['snippet']}")
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

    remember_parser = subparsers.add_parser("remember")
    remember_parser.add_argument("--agent", required=True)
    remember_parser.add_argument("--home", required=True)
    remember_parser.add_argument("--template-root", required=True)
    remember_parser.add_argument("--user", default="default")
    remember_parser.add_argument("--source", required=True)
    remember_parser.add_argument("--author")
    remember_parser.add_argument("--channel")
    remember_parser.add_argument("--title")
    remember_parser.add_argument("--text", required=True)
    remember_parser.add_argument("--kind", choices=("none", "user", "shared", "project", "decision"), default="user")
    remember_parser.add_argument("--page", default="")
    remember_parser.add_argument("--summary", default="")
    remember_parser.add_argument("--dry-run", action="store_true")
    remember_parser.add_argument("--json", action="store_true")
    remember_parser.set_defaults(func=cmd_remember)

    lint_parser = subparsers.add_parser("lint")
    lint_parser.add_argument("--agent", required=True)
    lint_parser.add_argument("--home", required=True)
    lint_parser.add_argument("--json", action="store_true")
    lint_parser.set_defaults(func=cmd_lint)

    rebuild_parser = subparsers.add_parser("rebuild-index")
    rebuild_parser.add_argument("--agent", required=True)
    rebuild_parser.add_argument("--home", required=True)
    rebuild_parser.add_argument("--bridge-home", required=True)
    rebuild_parser.add_argument("--db-path")
    rebuild_parser.add_argument("--dry-run", action="store_true")
    rebuild_parser.add_argument("--json", action="store_true")
    rebuild_parser.set_defaults(func=cmd_rebuild_index)

    search_parser = subparsers.add_parser("search")
    search_parser.add_argument("--agent", required=True)
    search_parser.add_argument("--home", required=True)
    search_parser.add_argument("--query", required=True)
    search_parser.add_argument("--user")
    search_parser.add_argument("--scope", choices=SEARCH_SCOPES, default="wiki")
    search_parser.add_argument("--limit", type=int, default=10)
    search_parser.add_argument("--json", action="store_true")
    search_parser.set_defaults(func=cmd_search)

    query_parser = subparsers.add_parser("query")
    query_parser.add_argument("--agent", required=True)
    query_parser.add_argument("--home", required=True)
    query_parser.add_argument("--bridge-home", required=True)
    query_parser.add_argument("--db-path")
    query_parser.add_argument("--query", required=True)
    query_parser.add_argument("--user")
    query_parser.add_argument("--scope", choices=QUERY_SCOPES, default="all")
    query_parser.add_argument("--limit", type=int, default=10)
    query_parser.add_argument("--json", action="store_true")
    query_parser.set_defaults(func=cmd_query)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if getattr(args, "text_file", None):
        args.text = Path(args.text_file).read_text(encoding="utf-8")
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
