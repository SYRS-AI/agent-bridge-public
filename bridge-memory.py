#!/usr/bin/env python3
"""bridge-memory.py — bridge-native markdown memory wiki helpers."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path


USER_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
SEARCH_SCOPES = ("wiki", "all", "user", "daily", "shared", "project", "decision", "raw")
QUERY_SCOPES = ("all", "wiki", "user", "daily", "shared", "project", "decision", "raw")
INDEX_KIND = "bridge-wiki-fts-v1"
INDEX_KIND_WIKI_HYBRID_V2 = "bridge-wiki-hybrid-v2"
KNOWN_INDEX_KINDS = (INDEX_KIND, INDEX_KIND_WIKI_HYBRID_V2)


@dataclass
class UserSpec:
    user_id: str
    display_name: str


def die(message: str) -> None:
    raise SystemExit(message)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str, dry_run: bool) -> None:
    """Atomic + locked text write.

    Writes to a same-directory tempfile, fsyncs, and renames into place.
    Serializes concurrent writers by holding an exclusive flock on a
    sibling `<name>.lock` file — this prevents two summarize runs for the
    same week/month from clobbering each other.
    """
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    with lock_path.open("a") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
            tmp = tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8",
                dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp",
                delete=False,
            )
            try:
                tmp.write(text)
                tmp.flush()
                os.fsync(tmp.fileno())
            finally:
                tmp.close()
            os.replace(tmp.name, path)
        finally:
            try:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass


def append_text(path: Path, text: str, dry_run: bool) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            handle.write(text)
            handle.flush()
        finally:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass


def _safe_excerpt(path: Path, limit: int) -> str | None:
    """Read first `limit` chars from `path`. Returns None on any OSError or decode issue."""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    return text[:limit]


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


ENVELOPE_SCHEMA_VERSIONS = {"1"}


def _sniff_envelope(text: str) -> dict | None:
    """Return parsed envelope dict if `text` carries a structured capture.

    Two accepted shapes (both produced by hooks/pre-compact.py):
        1) Pure JSON body whose top-level `schema_version` is known.
        2) A short head line (e.g. `schema_version=1 | excerpt=...`)
           followed by a blank line, then a JSON object body.
    Anything else returns None and the caller falls back to text-only.
    """
    if not text:
        return None
    stripped = text.lstrip()
    if stripped.startswith("{"):
        try:
            data = json.loads(stripped)
        except (json.JSONDecodeError, ValueError):
            data = None
        if isinstance(data, dict) and str(data.get("schema_version") or "") in ENVELOPE_SCHEMA_VERSIONS:
            return data
    brace_idx = text.find("\n{")
    if brace_idx != -1:
        candidate = text[brace_idx + 1:].strip()
        try:
            data = json.loads(candidate)
        except (json.JSONDecodeError, ValueError):
            return None
        if isinstance(data, dict) and str(data.get("schema_version") or "") in ENVELOPE_SCHEMA_VERSIONS:
            return data
    return None


def capture_payload(args: argparse.Namespace) -> dict:
    now = datetime.now().astimezone()
    capture_id = now.strftime("%Y%m%dT%H%M%S%z")
    capture_id = f"{capture_id[:15]}-{slugify(args.title or args.source or args.agent)}"
    payload: dict = {
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
    envelope = _sniff_envelope(args.text or "")
    if envelope is not None:
        payload["envelope"] = envelope
        payload["schema_version"] = envelope.get("schema_version")
        for key in ("suggested_slug", "suggested_title", "session_type", "trigger"):
            value = envelope.get(key)
            if value and key not in payload:
                payload[key] = value
    return payload


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
    line = (
        f"- {created_at} kind=ingest target=`{daily_rel}` "
        f"source=`{capture['capture_id']}` summary=\"{capture.get('source') or 'capture'} -> daily memory\"\n"
    )
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


def build_agent_pref_block(
    created_at: str,
    title: str,
    summary: str,
    capture: dict | None,
) -> str:
    # Issue #162 Phase 2: agent-role rule format per
    # docs/agent-runtime/user-preference-injection.md §2. Each promotion is
    # a self-contained `## <title> (YYYY-MM-DD, scope: agent)` section.
    # Why / How-to-apply fall back to `(see source)` when the capture body
    # does not carry explicit keys — Phase 2 deliberately avoids new CLI
    # flags and keeps the Source attribution at the real capture id so it
    # traces back to the canonical raw/captures/* payload.
    date_str = created_at[:10]
    rule_body = summary.strip() or "(see source)"
    source_ref = "(inline)"
    if capture:
        source_ref = f"capture `{capture['capture_id']}`"
        if capture.get("source"):
            source_ref += f" ({capture['source']})"
    lines = [
        "",
        f"## {title} ({date_str}, scope: agent)",
        "",
        f"**Rule:** {rule_body}",
        "**Why:** (see source)",
        "**How to apply:** (see source)",
        f"**Source:** {source_ref}",
        "",
    ]
    return "\n".join(lines)


def ensure_active_preferences_page(path: Path, dry_run: bool) -> None:
    # Issue #162 Phase 2: file is created lazily on first promote only —
    # NOT at scaffold time. bridge-docs.py's Runtime Canon renderer keys
    # the CLAUDE pointer on file existence, so agents without promoted
    # role-specific preferences pay zero startup overhead.
    if path.exists():
        return
    intro = (
        "# Active Preferences\n\n"
        "이 파일은 이 에이전트 역할에만 적용되는 운영 규칙을 담는다.\n"
        "새 규칙은 `agent-bridge memory promote --kind agent-pref ...` 로 추가한다 — 직접 편집하지 말 것.\n"
    )
    write_text(path, intro, dry_run)


def append_agent_pref_block(path: Path, block: str, dry_run: bool) -> None:
    existing = read_text(path) if path.exists() else ""
    if existing and not existing.endswith("\n"):
        existing += "\n"
    write_text(path, existing + block, dry_run)


def _load_bridge_docs_module():
    # Hyphenated filename workaround mirroring bridge-migrate.py. Always
    # load the bridge-docs.py that lives alongside this script so we get
    # the current render_agent_bridge_block behaviour, not whatever old
    # copy might sit under BRIDGE_HOME.
    script = Path(__file__).resolve().parent / "bridge-docs.py"
    spec = importlib.util.spec_from_file_location("_bridge_docs_memory", str(script))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load bridge-docs.py from {script}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["_bridge_docs_memory"] = module
    spec.loader.exec_module(module)
    return module


def cmd_promote(args: argparse.Namespace) -> int:
    home = Path(args.home)
    template_root = Path(args.template_root)
    ensure_memory_layout(home, template_root, args.dry_run)

    capture = None
    if args.capture:
        capture = json.loads(read_text(resolve_any_capture_path(home, args.capture)))
    user_id = args.user or (capture.get("user") if capture else "default") or "default"
    user = UserSpec(user_id=user_id, display_name=user_id)
    if args.kind != "agent-pref":
        # Issue #162 Phase 2 (codex review finding): agent-pref is
        # user-agnostic and lives only in ACTIVE-PREFERENCES.md. Scaffolding
        # a users/<uid>/ partition for this kind produces unrelated state
        # churn — skip the partition ensure for that kind specifically.
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
    elif kind == "user-profile":
        # Issue #162 Phase 1: shared user profile is the canonical surface
        # for persistent user preferences. Writing through the agent's
        # symlinked `users/<uid>/USER.md` hits the canonical
        # `shared/users/<uid>/USER.md`, so every other agent linked to the
        # same user sees the preference at next session start without a
        # separate promotion chain. The "Stable Preferences" section is
        # intentionally distinct from the hand-edited "Stable preferences"
        # bullet in the Identity/Working Notes skeleton so promoted
        # entries do not fight the operator's manual edits.
        target_path = home / "users" / user.user_id / "USER.md"
        append_under_section(
            target_path, "Stable Preferences", block, args.dry_run
        )
    elif kind == "agent-pref":
        # Issue #162 Phase 2: agent-role-specific operating rules. Unlike
        # user-profile (cross-agent for a given user via shared symlink),
        # these stay scoped to this single agent's home. File is created
        # lazily on first promote and lives at the agent home root so
        # bridge-docs.py's Runtime Canon bullet is keyed on presence.
        target_path = home / "ACTIVE-PREFERENCES.md"
        ensure_active_preferences_page(target_path, args.dry_run)
        append_agent_pref_block(
            target_path,
            build_agent_pref_block(created_at, title, summary, capture),
            args.dry_run,
        )
        # Issue #162 Phase 2 (codex review finding): the Runtime Canon
        # pointer in CLAUDE.md is keyed on file existence, so the first
        # promote MUST trigger a managed-block re-render — otherwise the
        # rule does not auto-load until the next `agent-bridge upgrade`
        # or `setup agent` run, breaking the Phase 2 "auto-loaded once
        # promoted" contract.
        if not args.dry_run:
            bridge_docs = _load_bridge_docs_module()
            backup_root = home / "state" / "promote-backups"
            backup_root.mkdir(parents=True, exist_ok=True)
            bridge_docs.normalize_claude(home, args.dry_run, backup_root)
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

    log_line = (
        f"- {created_at} kind=promote target=`{target_path.relative_to(home)}` "
        f"summary=\"{summary.strip()}\""
    )
    if capture:
        log_line += f" source=`{capture['capture_id']}`"
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
                # Issue #162 Phase 2: agent-role rules (if any) are high-signal
                # for "what are my operating constraints" searches. File is
                # optional — iter loop below filters non-existent paths.
                ("agent-pref", home / "ACTIVE-PREFERENCES.md"),
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
        "agent-pref": 75,
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


def collect_index_documents(home: Path, shared_root: Path | None = None, include_cascade: bool = False) -> list[dict]:
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
    # Issue #162 Phase 2: add_markdown is a no-op when the file is absent,
    # so unused agents do not pollute the index and indexed agents surface
    # role-specific rules under `memory search` without further wiring.
    add_markdown(home / "ACTIVE-PREFERENCES.md", "agent-pref")
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

    if include_cascade:
        # v2 cascade sources — weekly + monthly summaries produced by the
        # `summarize` subcommands.
        #
        # Note: ingested captures are ALREADY collected by the base flow
        # above as kind="raw-ingested". We do NOT re-add them here because
        # `documents.path` is a PRIMARY KEY and the same file would cause a
        # UNIQUE constraint violation on rebuild. The v2 search path maps
        # both "raw-ingested" and "capture-ingested" via the consumer's
        # `--source` filter, so no content is lost by skipping the re-add.
        for cascade_dir, kind in (
            (home / "memory" / "weekly", "memory-weekly"),
            (home / "memory" / "monthly", "memory-monthly"),
        ):
            if cascade_dir.exists():
                for path in sorted(cascade_dir.glob("*.md")):
                    add_markdown(path, kind)

    if shared_root is not None:
        wiki_root = shared_root / "wiki"
        if wiki_root.exists():
            for path in sorted(wiki_root.rglob("*.md")):
                # Skip workspace + audit scratch areas — they are noisy
                # and change on every hygiene run.
                rel = path.relative_to(shared_root)
                if rel.parts[:2] in (("wiki", "_workspace"), ("wiki", "_audit")):
                    continue
                add_markdown(path, "wiki")

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
    index_kind = getattr(args, "index_kind", INDEX_KIND) or INDEX_KIND
    if index_kind not in KNOWN_INDEX_KINDS:
        die(f"unknown --index-kind: {index_kind!r}. known: {', '.join(KNOWN_INDEX_KINDS)}")
    shared_root = Path(args.shared_root) if getattr(args, "shared_root", None) else None
    include_cascade = index_kind == INDEX_KIND_WIKI_HYBRID_V2
    if include_cascade and shared_root is None:
        # v2 without shared wiki still works (memory-only), but we warn.
        print(
            "note: --index-kind bridge-wiki-hybrid-v2 without --shared-root ingests local "
            "agent home only; pass --shared-root <path> to include shared/wiki/*",
            file=sys.stderr,
        )
    db_path = Path(args.db_path) if args.db_path else default_index_db_path(bridge_home, args.agent)
    indexed_at = datetime.now().astimezone().isoformat()
    documents = collect_index_documents(home, shared_root=shared_root, include_cascade=include_cascade)

    chunk_count = 0
    if not args.dry_run:
        db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(db_path)
        try:
            # Drop stale content tables first so a DB built against an older
            # schema does not break the new FTS triggers (which reference
            # columns that may not have existed before).
            conn.executescript(
                """
                DROP TRIGGER IF EXISTS chunks_ai;
                DROP TRIGGER IF EXISTS chunks_ad;
                DROP TRIGGER IF EXISTS chunks_au;
                DROP TABLE IF EXISTS chunks_fts;
                DROP TABLE IF EXISTS chunks;
                DROP TABLE IF EXISTS documents;
                DROP TABLE IF EXISTS meta;
                """
            )
            ensure_index_schema(conn)
            recreate_index_fts(conn)
            for doc in documents:
                path = doc["path"]
                # Paths may live under `home` (legacy) or under `shared_root`
                # (v2 wiki cascade). Store a stable relative form anchored at
                # whichever root the file actually came from.
                try:
                    relpath = str(path.relative_to(home))
                except ValueError:
                    if shared_root is not None:
                        try:
                            # Tag shared paths with a `shared:` prefix so they
                            # don't collide with agent-local paths in the
                            # documents PRIMARY KEY.
                            relpath = "shared:" + str(path.relative_to(shared_root))
                        except ValueError:
                            relpath = str(path)
                    else:
                        relpath = str(path)
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
                    # v2 uses the same schema; differs only in source-kind
                    # diversity and the meta.index_kind value. Embeddings are
                    # left empty; if/when a Gemini-backed embedder runs, it
                    # can UPDATE embedding in-place. Search falls back to
                    # keyword-only until embeddings exist (see
                    # `_index_has_embeddings` in tools/memory-manager.py).
                    # `chunks.source` is set to `doc["kind"]` so memory-manager
                    # search can filter via `--source`.
                    conn.execute(
                        """
                        INSERT INTO chunks(path, source, model, kind, user_id, start_line, end_line, text, embedding)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, '[]')
                        """,
                        (relpath, doc["kind"], index_kind, doc["kind"], user_id, start_line, end_line, text),
                    )
                    chunk_count += 1

            conn.executemany(
                "INSERT INTO meta(key, value) VALUES (?, ?)",
                {
                    "index_kind": index_kind,
                    "agent": args.agent,
                    "home": str(home),
                    "shared_root": str(shared_root) if shared_root else "",
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
        "index_kind": index_kind,
        "shared_root": str(shared_root) if shared_root else "",
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
        print(f"index_kind: {index_kind}")
        if shared_root:
            print(f"shared_root: {shared_root}")
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
            # Issue #162 Phase 2 (codex review finding): agent-pref rows
            # are indexed with empty user_id (kind is user-agnostic), so a
            # naive `user_id = ?` filter drops them for any --user query.
            # cmd_search does not apply this clause and correctly returns
            # agent-pref; mirror that behaviour here by letting agent-pref
            # rows through regardless of the user filter.
            clauses.append("(chunks.user_id = ? OR chunks.kind = 'agent-pref')")
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


# ---------------------------------------------------------------------------
# summarize weekly / monthly (cascading summarizer)
# ---------------------------------------------------------------------------

def _parse_iso_week(value: str) -> tuple[int, int]:
    """Parse `YYYY-W##` into (year, week_number). Raise SystemExit on bad format."""
    match = re.fullmatch(r"(\d{4})-W(\d{2})", value.strip())
    if not match:
        die(f"invalid --week (expected YYYY-W##): {value}")
    return int(match.group(1)), int(match.group(2))


def _previous_iso_week() -> tuple[int, int]:
    today = datetime.now().astimezone().date()
    monday_this = today - timedelta(days=today.isoweekday() - 1)
    prev_any_day = monday_this - timedelta(days=3)  # safely inside last week
    year, week, _ = prev_any_day.isocalendar()
    return year, week


def _iso_week_range(year: int, week: int) -> tuple[datetime, datetime]:
    monday = datetime.fromisocalendar(year, week, 1)
    sunday = datetime.fromisocalendar(year, week, 7)
    return monday, sunday


def _daily_notes_base(home: Path, user: str) -> Path:
    """Resolve the daily-notes root for a user.

    Contract:
    - `default` (or empty) user → `<home>/memory` is the canonical root.
    - Non-default user → `<home>/users/<user>/memory` only. No silent fallback to
      the shared root; absent directory = zero notes.
    """
    if not user or user == "default":
        return home / "memory"
    return home / "users" / user / "memory"


def _collect_daily_notes(home: Path, user: str, start: datetime, end: datetime) -> list[Path]:
    base = _daily_notes_base(home, user)
    if not base.exists():
        return []
    out: list[Path] = []
    cur = start.date()
    while cur <= end.date():
        candidate = base / f"{cur.isoformat()}.md"
        if candidate.exists():
            out.append(candidate)
        cur = cur + timedelta(days=1)
    return out


def _collect_ingested_captures(home: Path, start: datetime, end: datetime) -> list[Path]:
    ingested = home / "raw" / "captures" / "ingested"
    if not ingested.exists():
        return []
    out: list[Path] = []
    for path in sorted(ingested.glob("*.json")):
        try:
            payload = json.loads(read_text(path))
        except (OSError, json.JSONDecodeError):
            continue
        created_raw = payload.get("created_at") or ""
        try:
            ts = datetime.fromisoformat(created_raw)
        except ValueError:
            continue
        if ts.tzinfo is not None:
            ts = ts.replace(tzinfo=None)
        if start <= ts <= end:
            out.append(path)
    return out


def _llm_summarize(prompt: str, model: str = "") -> str | None:
    """Best-effort LLM summarization via claude CLI. Returns None on any failure."""
    claude = shutil.which("claude")
    if not claude:
        return None
    command = [claude, "-p", "--no-session-persistence", "--dangerously-skip-permissions", "--output-format", "text"]
    if model:
        command.extend(["--model", model])
    command.append(prompt)
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=90, check=True)
        return completed.stdout.strip() or None
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None


def _fallback_merge(sources: list[Path]) -> str:
    """Heading-based fallback merge when no LLM is available."""
    chunks: list[str] = []
    for path in sources:
        try:
            text = read_text(path)
        except OSError:
            continue
        headings = [line for line in text.splitlines() if line.startswith("#")]
        if headings:
            chunks.append(f"### {path.name}\n" + "\n".join(headings[:10]))
    return "\n\n".join(chunks) if chunks else "(no source headings available)"


def cmd_summarize_weekly(args: argparse.Namespace) -> int:
    home = Path(args.home)
    user = args.user or "default"
    if args.week:
        year, week = _parse_iso_week(args.week)
    else:
        year, week = _previous_iso_week()
    start, end = _iso_week_range(year, week)

    daily_notes = _collect_daily_notes(home, user, start, end)
    ingested = _collect_ingested_captures(home, start, end)

    header = f"# {year}-W{week:02d} Weekly Summary\n\n"
    header += f"Range: {start.date().isoformat()} .. {end.date().isoformat()}\n"
    header += f"Agent: {args.agent}\n"
    header += f"User: {user}\n\n"

    if args.llm and daily_notes + ingested:
        chunks: list[str] = []
        for p in (daily_notes + ingested[:8]):
            excerpt = _safe_excerpt(p, 2000)
            if excerpt is not None:
                chunks.append(f"## {p.name}\n{excerpt}")
        excerpt_text = "\n\n".join(chunks)
        prompt = (
            "Summarize this agent's week. Extract: (1) major events, "
            "(2) explicit user/operator decisions, (3) numeric results "
            "that changed, (4) unresolved items carried to next week. "
            "Return plain markdown with these four sub-sections.\n\n"
            f"{excerpt_text}"
        )
        body = _llm_summarize(prompt, args.llm_model) or _fallback_merge(daily_notes + ingested)
    else:
        body = _fallback_merge(daily_notes + ingested)

    out_path = home / "memory" / "weekly" / f"{year}-W{week:02d}.md"
    write_text(out_path, header + body + "\n", args.dry_run)

    log_line = (
        f"- {datetime.now().astimezone().isoformat(timespec='seconds')} "
        f"kind=summarize-weekly target=`{out_path.relative_to(home)}` "
        f"sources={len(daily_notes)}+{len(ingested)}\n"
    )
    append_text(home / "memory" / "log.md", log_line, args.dry_run)

    payload = {
        "agent": args.agent,
        "user": user,
        "year": year,
        "week": week,
        "range": [start.date().isoformat(), end.date().isoformat()],
        "daily_note_count": len(daily_notes),
        "ingested_count": len(ingested),
        "output": str(out_path),
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"weekly: {out_path}")
        print(f"sources: daily={len(daily_notes)} ingested={len(ingested)}")
    return 0


def cmd_summarize_monthly(args: argparse.Namespace) -> int:
    home = Path(args.home)
    user = args.user or "default"
    if args.month:
        match = re.fullmatch(r"(\d{4})-(\d{2})", args.month.strip())
        if not match:
            die(f"invalid --month (expected YYYY-MM): {args.month}")
        year, month = int(match.group(1)), int(match.group(2))
    else:
        today = datetime.now().astimezone().date()
        first_this = today.replace(day=1)
        last_prev = first_this - timedelta(days=1)
        year, month = last_prev.year, last_prev.month

    month_start = datetime(year, month, 1).astimezone()
    if month == 12:
        month_end = datetime(year + 1, 1, 1).astimezone() - timedelta(seconds=1)
    else:
        month_end = datetime(year, month + 1, 1).astimezone() - timedelta(seconds=1)

    weekly_dir = home / "memory" / "weekly"
    weekly_notes: list[Path] = []
    if weekly_dir.exists():
        for path in sorted(weekly_dir.glob("*.md")):
            match = re.fullmatch(r"(\d{4})-W(\d{2})\.md", path.name)
            if not match:
                continue
            wy, ww = int(match.group(1)), int(match.group(2))
            try:
                week_start = datetime.fromisocalendar(wy, ww, 1).astimezone()
                week_end = (datetime.fromisocalendar(wy, ww, 7)
                            .astimezone() + timedelta(hours=23, minutes=59, seconds=59))
            except ValueError:
                continue
            # Include the week if *any* day of it falls inside the target month.
            if week_end < month_start or week_start > month_end:
                continue
            weekly_notes.append(path)

    daily_notes = _collect_daily_notes(home, user, month_start, month_end)

    header = f"# {year}-{month:02d} Monthly Summary\n\n"
    header += f"Agent: {args.agent}\nUser: {user}\n\n"

    if args.llm and (weekly_notes or daily_notes):
        chunks: list[str] = []
        for p in (weekly_notes + daily_notes[:10]):
            excerpt = _safe_excerpt(p, 2500)
            if excerpt is not None:
                chunks.append(f"## {p.name}\n{excerpt}")
        excerpt_text = "\n\n".join(chunks)
        prompt = (
            "Summarize this agent's month. Extract: (1) monthly trends, "
            "(2) major decisions, (3) recurring patterns, (4) in-flight "
            "long-running projects. Flag any daily notes older than 60 "
            "days as candidates for archive-only retention. Return plain "
            "markdown with these sub-sections.\n\n"
            f"{excerpt_text}"
        )
        body = _llm_summarize(prompt, args.llm_model) or _fallback_merge(weekly_notes + daily_notes)
    else:
        body = _fallback_merge(weekly_notes + daily_notes)

    out_path = home / "memory" / "monthly" / f"{year}-{month:02d}.md"
    write_text(out_path, header + body + "\n", args.dry_run)

    log_line = (
        f"- {datetime.now().astimezone().isoformat(timespec='seconds')} "
        f"kind=summarize-monthly target=`{out_path.relative_to(home)}` "
        f"sources={len(weekly_notes)}w+{len(daily_notes)}d\n"
    )
    append_text(home / "memory" / "log.md", log_line, args.dry_run)

    payload = {
        "agent": args.agent,
        "user": user,
        "year": year,
        "month": month,
        "weekly_count": len(weekly_notes),
        "daily_count": len(daily_notes),
        "output": str(out_path),
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"monthly: {out_path}")
        print(f"sources: weekly={len(weekly_notes)} daily={len(daily_notes)}")
    return 0


_RECONCILE_MARKERS = (
    # phrase must look like an explicit contradiction statement, not a bare word.
    "is no longer",
    "is incorrect",
    "is deprecated",
    "superseded by",
    "was wrong",
    "should be",
    "actually,",
)


def _unique_report_path(out_dir: Path, ts: str, suffix: str) -> Path:
    """Return a non-colliding report path under `out_dir`. Adds `-pid-N` as needed."""
    pid = os.getpid()
    candidate = out_dir / f"{ts}-{pid}-{suffix}.json"
    counter = 0
    while candidate.exists():
        counter += 1
        candidate = out_dir / f"{ts}-{pid}-{counter}-{suffix}.json"
    return candidate


def _resolve_bridge_bin() -> Path | None:
    """Resolve the `agent-bridge` CLI binary, honoring BRIDGE_HOME and install-relative layout."""
    candidates: list[Path] = []
    env_home = os.environ.get("BRIDGE_HOME")
    if env_home:
        candidates.append(Path(env_home) / "agent-bridge")
    script_dir = Path(__file__).resolve().parent
    candidates.append(script_dir / "agent-bridge")
    candidates.append(Path.home() / ".agent-bridge" / "agent-bridge")
    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return c
    return None


def _reconcile_task_exists(agent: str) -> bool:
    """Return True if there is an existing open reconcile task for `agent`."""
    binary = _resolve_bridge_bin()
    if binary is None:
        return False
    try:
        completed = subprocess.run(
            [str(binary), "inbox", "patch", "--json"],
            capture_output=True, text=True, timeout=10, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    try:
        rows = json.loads(completed.stdout or "[]")
    except json.JSONDecodeError:
        return False
    needle = f"[reconcile] {agent}"
    for row in rows if isinstance(rows, list) else []:
        title = (row.get("title") or "") if isinstance(row, dict) else ""
        status = (row.get("status") or "") if isinstance(row, dict) else ""
        if status in {"queued", "claimed", "blocked"} and title.startswith(needle):
            return True
    return False


def cmd_reconcile(args: argparse.Namespace) -> int:
    """Flag candidate memory/wiki contradictions (heuristic).

    Limitation (by design): this is a *candidate* flagger driven by explicit
    contradiction phrases in the agent's memory notes that are absent from the
    canonical wiki page. False positives are possible (editorial prose) and
    false negatives are common (semantic contradictions without marker words).
    Use output as input for human review, not as a final verdict.
    """
    home = Path(args.home)
    shared_root = Path(args.shared_root) if args.shared_root else None
    now = datetime.now().astimezone()
    ts = now.strftime("%Y%m%dT%H%M%S")
    out_dir = home / "raw" / "captures" / "conflicts"
    out_path = _unique_report_path(out_dir, ts, "reconcile")

    conflicts: list[dict] = []
    if shared_root and shared_root.exists():
        wiki_pages = list((shared_root / "wiki").rglob("*.md")) if (shared_root / "wiki").exists() else []
        mem_pages = list((home / "memory").rglob("*.md"))
        wiki_stems: dict[str, Path] = {}
        for p in wiki_pages:
            # Prefer the first occurrence; if a stem collides, don't stomp.
            wiki_stems.setdefault(p.stem, p)
        for mp in mem_pages:
            if mp.stem not in wiki_stems:
                continue
            try:
                mem_text = read_text(mp).lower()
                wiki_text = read_text(wiki_stems[mp.stem]).lower()
            except (OSError, UnicodeDecodeError):
                continue
            hits: list[str] = []
            for marker in _RECONCILE_MARKERS:
                if marker in mem_text and marker not in wiki_text:
                    hits.append(marker)
            if hits:
                conflicts.append({
                    "stem": mp.stem,
                    "memory_path": str(mp),
                    "wiki_path": str(wiki_stems[mp.stem]),
                    "markers": hits,
                })

    report = {
        "agent": args.agent,
        "timestamp": ts,
        "pid": os.getpid(),
        "shared_root": str(shared_root) if shared_root else None,
        "conflict_count": len(conflicts),
        "conflicts": conflicts,
        "caveat": "heuristic flagger; requires human review",
    }
    if not args.dry_run:
        out_dir.mkdir(parents=True, exist_ok=True)
        # Atomic write.
        tmp = tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8",
            dir=str(out_dir), prefix=f".{out_path.name}.", suffix=".tmp",
            delete=False,
        )
        try:
            tmp.write(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            tmp.flush()
            os.fsync(tmp.fileno())
        finally:
            tmp.close()
        os.replace(tmp.name, out_path)

    task_created = False
    task_skipped_reason: str | None = None
    if conflicts and args.create_task and not args.dry_run:
        if _reconcile_task_exists(args.agent):
            task_skipped_reason = "existing open reconcile task"
        else:
            binary = _resolve_bridge_bin()
            if binary is None:
                task_skipped_reason = "agent-bridge binary not found"
            else:
                try:
                    completed = subprocess.run(
                        [
                            str(binary),
                            "task", "create",
                            "--to", "patch",
                            "--priority", "normal",
                            "--title", f"[reconcile] {args.agent}: {len(conflicts)} memory/wiki conflict(s)",
                            "--body", f"Reconcile report: {out_path}\nConflicts: {len(conflicts)}",
                        ],
                        check=False,
                        timeout=15,
                        capture_output=True,
                        text=True,
                    )
                    if completed.returncode == 0:
                        task_created = True
                    else:
                        task_skipped_reason = (
                            f"task create exited with rc={completed.returncode}: "
                            f"{(completed.stderr or completed.stdout or '').strip()[:200]}"
                        )
                except (OSError, subprocess.TimeoutExpired) as exc:
                    task_skipped_reason = f"task create failed: {exc}"

    report["task_created"] = task_created
    if task_skipped_reason:
        report["task_skipped_reason"] = task_skipped_reason

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"conflicts: {len(conflicts)}")
        print(f"report: {out_path}")
        if task_skipped_reason:
            print(f"task: skipped ({task_skipped_reason})")
        elif task_created:
            print("task: created")
    return 0 if not conflicts else 2



DAILY_META_MARKER = "<!-- bridge-daily-meta: "
DAILY_META_END = " -->"
DAILY_META_RE = re.compile(
    r"^<!-- bridge-daily-meta: (?P<json>\{.*\}) -->\s*$",
    re.MULTILINE,
)
DAILY_SECTION_HEADER_RE = re.compile(
    r"^## Session (?P<session>[A-Za-z0-9_-]+)(?P<tail>.*)$",
    re.MULTILINE,
)


def _kst_now() -> datetime:
    """Current time in the Asia/Seoul zone, independent of host tz."""
    from datetime import timezone, timedelta
    try:
        from zoneinfo import ZoneInfo  # Python 3.9+
        return datetime.now(ZoneInfo("Asia/Seoul"))
    except Exception:
        # Fallback for interpreters without tzdata: KST is fixed +09:00,
        # no DST, so a hard offset is safe.
        return datetime.now(timezone(timedelta(hours=9)))


def _now_iso_kst() -> str:
    """ISO8601 timestamp in Asia/Seoul (+09:00), regardless of host tz."""
    return _kst_now().strftime("%Y-%m-%dT%H:%M:%S+09:00")


def _today_kst() -> str:
    return _kst_now().strftime("%Y-%m-%d")


def _daily_note_path(home: Path, date: str) -> Path:
    return Path(home) / "memory" / f"{date}.md"


def _read_meta_block(text: str) -> tuple[dict, str]:
    """Return (meta_dict, remainder_after_meta_line). Empty dict if no meta."""
    match = DAILY_META_RE.search(text)
    if not match:
        return {}, text
    try:
        meta = json.loads(match.group("json"))
    except json.JSONDecodeError:
        return {}, text
    if not isinstance(meta, dict):
        return {}, text
    start, end = match.span(0)
    # strip the meta line + trailing newline if any
    remainder = text[:start] + text[end:].lstrip("\n")
    return meta, remainder


def _render_meta_block(meta: dict) -> str:
    return DAILY_META_MARKER + json.dumps(meta, ensure_ascii=False, sort_keys=False) + DAILY_META_END


def _split_sections(body: str) -> list[tuple[str | None, str]]:
    """Return [(session_id or None, section_text)]. Preamble comes first as (None, text)."""
    parts: list[tuple[str | None, str]] = []
    last_idx = 0
    last_session: str | None = None
    for match in DAILY_SECTION_HEADER_RE.finditer(body):
        if match.start() > last_idx:
            parts.append((last_session, body[last_idx:match.start()]))
        last_session = match.group("session")
        last_idx = match.start()
    parts.append((last_session, body[last_idx:]))
    return parts


def _assemble_daily_note(title: str, meta: dict, sections: list[tuple[str | None, str]]) -> str:
    chunks: list[str] = [_render_meta_block(meta), "", title.rstrip(), ""]
    rendered_preamble = False
    for session_id, text in sections:
        text = text.rstrip("\n")
        if not text.strip():
            continue
        if session_id is None and not rendered_preamble:
            chunks.append(text)
            chunks.append("")
            rendered_preamble = True
        elif session_id is not None:
            chunks.append(text)
            chunks.append("")
    return "\n".join(chunks).rstrip() + "\n"


def _ensure_daily_note_skeleton(path: Path, date: str, agent: str) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    meta = {
        "schema_version": 1,
        "session_ids": [],
        "writer_mix": {},
        "last_reconciled_at": _now_iso_kst(),
    }
    text = (
        _render_meta_block(meta) + "\n"
        f"\n# {date} — {agent}\n\n"
    )
    path.write_text(text, encoding="utf-8")


def _parse_daily_note(text: str, date: str, agent: str) -> tuple[dict, str, list[tuple[str | None, str]]]:
    meta, body = _read_meta_block(text)
    # Extract title (first H1) if present.
    title_match = re.match(r"^\s*(#\s[^\n]+)\n?", body)
    if title_match:
        title = title_match.group(1)
        body = body[title_match.end():]
    else:
        title = f"# {date} — {agent}"
    if not meta:
        meta = {
            "schema_version": 1,
            "session_ids": [],
            "writer_mix": {},
            "last_reconciled_at": _now_iso_kst(),
        }
    sections = _split_sections(body.lstrip("\n"))
    return meta, title, sections


def _session_section_header(session_id: str, writer: str) -> str:
    return f"## Session {session_id} — {writer}"


def cmd_current_session_id(args: argparse.Namespace) -> int:
    """Best-effort session_id for the agent calling this script.

    Returns the UUID of the most recently modified JSONL under the
    Claude project directory that matches `--home`. Claude scopes
    transcripts by the git root of the session cwd, so `--home` here is
    the **session workdir** (the cwd the agent was spawned in), not the
    agent's bridge runtime home — those can differ when an agent is
    pointed at an external project checkout. The wrap-up slash command
    template passes `BRIDGE_AGENT_WORKDIR` for exactly that reason.
    Claude Code exposes the session id via hook stdin but has no
    documented env var for slash commands, so we read from disk.
    """
    import os as _os
    projects_dir = Path(args.claude_projects).expanduser()
    home = Path(args.home).expanduser().resolve()
    # Match Anthropic's ~/.claude/projects/ slug convention (see
    # bridge-agent.sh:bridge_ensure_auto_memory_isolation).
    project_slug = str(home).replace(_os.sep, "-").replace(".", "-")
    project_dir = projects_dir / project_slug
    if not project_dir.is_dir():
        sys.stderr.write(
            f"[bridge-memory] no Claude project dir at {project_dir}. "
            f"Is BRIDGE_AGENT_ID={args.agent} and --home={args.home} correct?\n"
        )
        return 1
    candidates: list[tuple[float, str]] = []
    for jsonl in project_dir.glob("*.jsonl"):
        try:
            candidates.append((jsonl.stat().st_mtime, jsonl.stem))
        except OSError:
            continue
    if not candidates:
        sys.stderr.write(
            f"[bridge-memory] no transcripts found in {project_dir}. "
            "Has any session run from this home yet?\n"
        )
        return 1
    candidates.sort(reverse=True)
    print(candidates[0][1])
    return 0


def cmd_daily_append(args: argparse.Namespace) -> int:
    """Append or replace a session section inside the agent's daily note.

    writer=session sections may replace an earlier section with the same
    session_id (re-runs). writer=cron sections never overwrite anything
    a session has already written.
    """
    home = Path(args.home).expanduser()
    date = args.date or _today_kst()
    note_path = _daily_note_path(home, date)

    if args.content_from_stdin:
        content = sys.stdin.read()
    elif args.content_file:
        content = Path(args.content_file).expanduser().read_text(encoding="utf-8")
    else:
        sys.stderr.write("daily-append requires --content-from-stdin or --content-file\n")
        return 2

    content = content.rstrip() + "\n"

    _ensure_daily_note_skeleton(note_path, date, args.agent)
    raw = note_path.read_text(encoding="utf-8")
    meta, title, sections = _parse_daily_note(raw, date, args.agent)

    header = _session_section_header(args.session_id, args.writer)
    section_text = f"{header}\n\n{content}"

    session_ids = list(meta.get("session_ids") or [])
    writer_mix = dict(meta.get("writer_mix") or {})

    existing_index: int | None = None
    existing_writer: str | None = None
    for idx, (sid, text) in enumerate(sections):
        if sid == args.session_id:
            existing_index = idx
            header_match = re.match(r"^## Session \S+\s+—\s+(\S+)", text)
            existing_writer = header_match.group(1) if header_match else None
            break

    # writer_mix counts *sections* per writer, so increments happen only
    # when a new section is materialised, not on re-runs that just
    # rewrite the body. A replace that also changes writer decrements
    # the previous writer before incrementing the new one; a same-writer
    # replace is a net no-op.
    applied = "appended"
    materialised_new_section = False
    if existing_index is not None:
        if args.writer == "cron" and existing_writer == "session":
            applied = "skipped (session writer already present)"
        else:
            old_session, _ = sections[existing_index]
            sections[existing_index] = (old_session, section_text)
            applied = "replaced"
            if existing_writer and existing_writer != args.writer:
                writer_mix[existing_writer] = max(0, writer_mix.get(existing_writer, 0) - 1)
                writer_mix[args.writer] = writer_mix.get(args.writer, 0) + 1
    else:
        sections.append((args.session_id, section_text))
        materialised_new_section = True

    if materialised_new_section:
        if args.session_id not in session_ids:
            session_ids.append(args.session_id)
        writer_mix[args.writer] = writer_mix.get(args.writer, 0) + 1

    meta["session_ids"] = session_ids
    meta["writer_mix"] = writer_mix
    meta["last_reconciled_at"] = _now_iso_kst()
    meta.setdefault("schema_version", 1)

    assembled = _assemble_daily_note(title, meta, sections)
    tmp = note_path.with_suffix(note_path.suffix + ".tmp")
    tmp.write_text(assembled, encoding="utf-8")
    import os as _os
    _os.replace(tmp, note_path)

    report = {
        "agent": args.agent,
        "date": date,
        "note_path": str(note_path),
        "session_id": args.session_id,
        "writer": args.writer,
        "applied": applied,
        "session_count": len(session_ids),
        "writer_mix": writer_mix,
    }
    if args.json:
        print(json.dumps(report, ensure_ascii=False))
    else:
        print(f"{applied} session {args.session_id[:12]} writer={args.writer} in {note_path}")
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
    promote_parser.add_argument(
        "--kind",
        choices=("user", "user-profile", "agent-pref", "shared", "project", "decision"),
        required=True,
        help=(
            "user = per-user memory bucket; "
            "user-profile = Stable Preferences section of shared/users/<uid>/USER.md "
            "(auto-loaded at every session start, cross-agent via canonical USER.md); "
            "agent-pref = agent-role rules in this agent's ACTIVE-PREFERENCES.md "
            "(file-exists-only load, zero overhead when unused); "
            "shared|project|decision = agent-local wiki pages"
        ),
    )
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
    rebuild_parser.add_argument(
        "--index-kind",
        choices=list(KNOWN_INDEX_KINDS),
        default=INDEX_KIND,
        help="index kind to build (default: bridge-wiki-fts-v1)",
    )
    rebuild_parser.add_argument(
        "--shared-root",
        help="path to shared/ root; required for full v2 wiki cascade ingestion",
    )
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

    # -----------------------------------------------------------------
    # summarize — two-level subcommand: `summarize weekly` / `summarize monthly`.
    # -----------------------------------------------------------------
    summarize_parser = subparsers.add_parser("summarize")
    summarize_sub = summarize_parser.add_subparsers(dest="level", required=True)

    weekly_parser = summarize_sub.add_parser("weekly")
    weekly_parser.add_argument("--agent", required=True)
    weekly_parser.add_argument("--home", required=True)
    weekly_parser.add_argument("--user", default="default")
    weekly_parser.add_argument("--week", help="YYYY-W## (defaults to previous ISO week)")
    weekly_parser.add_argument("--llm", action="store_true", help="use claude CLI to generate summary")
    weekly_parser.add_argument("--llm-model", default="")
    weekly_parser.add_argument("--dry-run", action="store_true")
    weekly_parser.add_argument("--json", action="store_true")
    weekly_parser.set_defaults(func=cmd_summarize_weekly)

    monthly_parser = summarize_sub.add_parser("monthly")
    monthly_parser.add_argument("--agent", required=True)
    monthly_parser.add_argument("--home", required=True)
    monthly_parser.add_argument("--user", default="default")
    monthly_parser.add_argument("--month", help="YYYY-MM (defaults to previous month)")
    monthly_parser.add_argument("--llm", action="store_true")
    monthly_parser.add_argument("--llm-model", default="")
    monthly_parser.add_argument("--dry-run", action="store_true")
    monthly_parser.add_argument("--json", action="store_true")
    monthly_parser.set_defaults(func=cmd_summarize_monthly)

    reconcile_parser = subparsers.add_parser("reconcile")
    reconcile_parser.add_argument("--agent", required=True)
    reconcile_parser.add_argument("--home", required=True)
    reconcile_parser.add_argument("--shared-root", help="path to ~/.agent-bridge/shared (or test fixture)")
    reconcile_parser.add_argument("--create-task", action="store_true", help="file a patch task on conflict")
    reconcile_parser.add_argument("--dry-run", action="store_true")
    reconcile_parser.add_argument("--json", action="store_true")
    reconcile_parser.set_defaults(func=cmd_reconcile)

    csi_parser = subparsers.add_parser(
        "current-session-id",
        help="print the most recently active session id for the given agent",
    )
    csi_parser.add_argument("--agent", required=True)
    csi_parser.add_argument(
        "--home",
        required=True,
        help="real agent home path; the Claude project slug is derived from this",
    )
    csi_parser.add_argument(
        "--claude-projects",
        default=str(Path.home() / ".claude" / "projects"),
    )
    csi_parser.set_defaults(func=cmd_current_session_id)

    da_parser = subparsers.add_parser(
        "daily-append",
        help="append or replace a session section in today's daily note",
    )
    da_parser.add_argument("--agent", required=True)
    da_parser.add_argument("--home", required=True, help="agent home root, e.g. ~/.agent-bridge/agents/<agent>")
    da_parser.add_argument("--session-id", required=True)
    da_parser.add_argument("--writer", choices=("session", "cron"), default="session")
    da_parser.add_argument("--date", help="YYYY-MM-DD override; defaults to today (Asia/Seoul)")
    src = da_parser.add_mutually_exclusive_group()
    src.add_argument("--content-from-stdin", action="store_true")
    src.add_argument("--content-file")
    da_parser.add_argument("--json", action="store_true")
    da_parser.set_defaults(func=cmd_daily_append)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if getattr(args, "text_file", None):
        args.text = Path(args.text_file).read_text(encoding="utf-8")
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
