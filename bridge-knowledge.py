#!/usr/bin/env python3
"""bridge-knowledge.py — bridge-level team knowledge wiki helpers."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path


WIKI_FILES = (
    "index.md",
    "people.md",
    "agents.md",
    "operating-rules.md",
    "data-sources.md",
    "tools.md",
)
WIKI_DIRS = (
    "decisions",
    "projects",
    "playbooks",
)
RAW_DIRS = (
    "raw/captures/inbox",
    "raw/captures/promoted",
    "raw/channel-events",
    "raw/cron-results",
    "indexes",
)
SEARCH_SCOPES = ("wiki", "raw", "all")
PRIMARY_OPERATOR_HEADING = "## Primary Operator"
PRIMARY_OPERATOR_START = "<!-- BEGIN PRIMARY OPERATOR -->"
PRIMARY_OPERATOR_END = "<!-- END PRIMARY OPERATOR -->"
KIND_ALIASES = {
    "people": "people",
    "person": "people",
    "agents": "agents",
    "agent": "agents",
    "rules": "operating-rules",
    "operating-rules": "operating-rules",
    "data-source": "data-sources",
    "data-sources": "data-sources",
    "tools": "tools",
    "tool": "tools",
    "decision": "decision",
    "project": "project",
    "playbook": "playbook",
}


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


def append_text(path: Path, text: str, dry_run: bool = False) -> None:
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(text)


def slugify(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-").lower()
    return slug or "note"


def template_path(template_root: Path, relpath: str) -> Path:
    return template_root / "shared" / "wiki" / relpath


def read_template(template_root: Path, relpath: str, team_name: str) -> str:
    path = template_path(template_root, relpath)
    if path.exists():
        return read_text(path).replace("{{TEAM_NAME}}", team_name)
    title = relpath[:-3].replace("-", " ").replace("_", " ").title()
    return f"# {title}\n\n## Notes\n"


def wiki_root(shared_root: Path) -> Path:
    return shared_root / "wiki"


def raw_root(shared_root: Path) -> Path:
    return shared_root / "raw"


def ensure_layout(shared_root: Path, template_root: Path, team_name: str, dry_run: bool) -> list[str]:
    created: list[str] = []
    root = wiki_root(shared_root)
    for relpath in WIKI_FILES:
        target = root / relpath
        if not target.exists():
            write_text(target, read_template(template_root, relpath, team_name), dry_run)
            created.append(str(target.relative_to(shared_root)))
    for dirname in WIKI_DIRS:
        keep = root / dirname / ".gitkeep"
        if not keep.exists():
            write_text(keep, "", dry_run)
            created.append(str(keep.relative_to(shared_root)))
    for dirname in RAW_DIRS:
        keep = shared_root / dirname / ".gitkeep"
        if not keep.exists():
            write_text(keep, "", dry_run)
            created.append(str(keep.relative_to(shared_root)))
    return created


def cmd_init(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    template_root = Path(args.template_root)
    created = ensure_layout(shared_root, template_root, args.team_name, args.dry_run)
    payload = {
        "shared_root": str(shared_root),
        "wiki_root": str(wiki_root(shared_root)),
        "team_name": args.team_name,
        "created": created,
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"wiki_root: {payload['wiki_root']}")
        print(f"team_name: {args.team_name}")
        print(f"created: {len(created)}")
    return 0


def capture_payload(args: argparse.Namespace) -> dict[str, str]:
    stamp = now()
    base = slugify(args.title or args.source or "capture")
    capture_id = f"{stamp.strftime('%Y%m%dT%H%M%S%z')}-{base}"
    return {
        "capture_id": capture_id,
        "source": args.source,
        "author": args.author or "",
        "channel": args.channel or "",
        "title": args.title or "",
        "text": args.text,
        "created_at": stamp.isoformat(),
    }


def write_capture(shared_root: Path, payload: dict[str, str], dry_run: bool) -> Path:
    path = raw_root(shared_root) / "captures" / "inbox" / f"{payload['capture_id']}.json"
    write_text(path, json.dumps(payload, ensure_ascii=False, indent=2) + "\n", dry_run)
    return path


def cmd_capture(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    ensure_layout(shared_root, Path(args.template_root), args.team_name, args.dry_run)
    payload = capture_payload(args)
    path = write_capture(shared_root, payload, args.dry_run)
    result = {
        "capture_id": payload["capture_id"],
        "path": str(path),
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"capture_id: {payload['capture_id']}")
        print(f"path: {path}")
    return 0


def resolve_capture(shared_root: Path, capture_id: str) -> tuple[Path, dict[str, str]]:
    for folder in ("inbox", "promoted"):
        path = raw_root(shared_root) / "captures" / folder / f"{capture_id}.json"
        if path.exists():
            return path, json.loads(read_text(path))
    die(f"capture not found: {capture_id}")


def normalize_kind(kind: str) -> str:
    normalized = KIND_ALIASES.get(kind)
    if not normalized:
        die(f"unsupported knowledge kind: {kind}")
    return normalized


def page_title(slug: str) -> str:
    return slug.replace("-", " ").replace("_", " ").strip().title() or "Knowledge Page"


def target_for_kind(shared_root: Path, kind: str, page: str, title: str) -> Path:
    root = wiki_root(shared_root)
    if kind in {"people", "agents", "operating-rules", "data-sources", "tools"}:
        return root / f"{kind}.md"
    slug = slugify(page or title or kind)
    if kind == "decision":
        return root / "decisions" / f"{slug}.md"
    if kind == "project":
        return root / "projects" / f"{slug}.md"
    if kind == "playbook":
        return root / "playbooks" / f"{slug}.md"
    die(f"unsupported knowledge kind: {kind}")


def ensure_page(path: Path, title: str, dry_run: bool) -> None:
    if path.exists():
        return
    write_text(path, f"# {title}\n\n## Notes\n", dry_run)


def append_note(path: Path, block: str, dry_run: bool) -> None:
    if path.exists():
        text = read_text(path).rstrip()
    else:
        text = ""
    if "## Notes" not in text:
        text = text.rstrip() + "\n\n## Notes"
    text = text.rstrip() + "\n\n" + block.rstrip() + "\n"
    write_text(path, text, dry_run)


def build_note(args: argparse.Namespace, capture: dict[str, str] | None, summary: str) -> str:
    title = args.title or args.page or (capture or {}).get("title") or args.kind
    lines = [f"### {now().isoformat(timespec='seconds')} — {title}", "", summary.strip()]
    details = (capture or {}).get("text", "").strip()
    if details and details != summary.strip():
        lines.extend(["", "#### Source Detail", "", details])
    if capture:
        lines.extend(["", "#### Source"])
        lines.append(f"- Capture: {capture['capture_id']}")
        if capture.get("source"):
            lines.append(f"- Source: {capture['source']}")
        if capture.get("author"):
            lines.append(f"- Author: {capture['author']}")
        if capture.get("channel"):
            lines.append(f"- Channel: {capture['channel']}")
    return "\n".join(lines)


def append_log(shared_root: Path, line: str, dry_run: bool) -> None:
    log_path = wiki_root(shared_root) / "log.md"
    if not log_path.exists():
        write_text(log_path, "# Knowledge Log\n\n", dry_run)
    append_text(log_path, line.rstrip() + "\n", dry_run)


def iter_wiki_markdown_files(shared_root: Path) -> list[Path]:
    root = wiki_root(shared_root)
    if not root.exists():
        return []
    return sorted(path for path in root.rglob("*.md") if path.is_file())


def markdown_title(path: Path) -> str:
    for raw in read_text(path).splitlines():
        line = raw.strip()
        if line.startswith("# "):
            return line[2:].strip()
    return page_title(path.stem)


def normalize_title(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip().lower())


def markdown_links(text: str) -> list[str]:
    targets: list[str] = []
    for match in re.finditer(r"\[[^\]]+\]\(([^)]+)\)", text):
        target = match.group(1).strip()
        if not target:
            continue
        targets.append(target)
    return targets


def is_external_link(target: str) -> bool:
    lower = target.lower()
    return (
        lower.startswith("http://")
        or lower.startswith("https://")
        or lower.startswith("mailto:")
        or lower.startswith("tel:")
        or lower.startswith("#")
    )


def resolve_markdown_link(base: Path, target: str) -> Path | None:
    if is_external_link(target):
        return None
    raw_target = target.split("#", 1)[0].strip()
    if not raw_target:
        return None
    candidate = (base.parent / raw_target).resolve()
    return candidate


def first_paragraph(path: Path) -> str:
    lines = read_text(path).splitlines()
    paragraphs: list[str] = []
    current: list[str] = []
    for raw in lines:
        line = raw.strip()
        if not line:
            if current:
                paragraphs.append(" ".join(current).strip())
                current = []
            continue
        if line.startswith("#"):
            continue
        current.append(line)
    if current:
        paragraphs.append(" ".join(current).strip())
    return paragraphs[0] if paragraphs else ""


def lint_wiki(shared_root: Path, stale_days: int) -> dict[str, object]:
    root = wiki_root(shared_root)
    wiki_files = iter_wiki_markdown_files(shared_root)
    file_set = {path.resolve() for path in wiki_files}
    broken_links: list[dict[str, str]] = []
    orphan_pages: list[str] = []
    stale_pages: list[dict[str, object]] = []
    duplicate_titles: list[dict[str, object]] = []
    inbound_links: dict[Path, set[Path]] = {}
    now_ts = now()

    title_map: dict[str, list[Path]] = {}
    for path in wiki_files:
        title_map.setdefault(normalize_title(markdown_title(path)), []).append(path)

    for normalized_title, paths in sorted(title_map.items()):
        if len(paths) <= 1:
            continue
        duplicate_titles.append(
            {
                "title": markdown_title(paths[0]),
                "files": [str(path.relative_to(shared_root)) for path in paths],
            }
        )

    for path in wiki_files:
        try:
            text = read_text(path)
        except UnicodeDecodeError:
            continue
        for target in markdown_links(text):
            resolved = resolve_markdown_link(path, target)
            if resolved is None:
                continue
            if not resolved.exists():
                broken_links.append(
                    {
                        "source": str(path.relative_to(shared_root)),
                        "target": target,
                    }
                )
                continue
            if resolved.suffix == ".md" and resolved in file_set:
                inbound_links.setdefault(resolved, set()).add(path.resolve())

        age = now_ts - datetime.fromtimestamp(path.stat().st_mtime).astimezone()
        if age > timedelta(days=stale_days):
            stale_pages.append(
                {
                    "path": str(path.relative_to(shared_root)),
                    "days_old": int(age.total_seconds() // 86400),
                }
            )

    for path in wiki_files:
        if path.parent == root:
            continue
        if path.name == "log.md":
            continue
        if not inbound_links.get(path.resolve()):
            orphan_pages.append(str(path.relative_to(shared_root)))

    return {
        "broken_links": broken_links,
        "orphan_pages": orphan_pages,
        "duplicate_titles": duplicate_titles,
        "stale_pages": sorted(stale_pages, key=lambda item: item["path"]),
        "wiki_files": [str(path.relative_to(shared_root)) for path in wiki_files],
    }


def maybe_run_llm_review(shared_root: Path, requested: bool, model: str) -> dict[str, object]:
    if not requested:
        return {"requested": False, "status": "disabled", "findings": []}

    claude = shutil.which("claude")
    if not claude:
        return {
            "requested": True,
            "status": "unavailable",
            "findings": [],
            "message": "claude CLI is not installed",
        }

    sections: list[str] = []
    budget = 12000
    for path in iter_wiki_markdown_files(shared_root):
        title = markdown_title(path)
        body = first_paragraph(path)
        snippet = body[:400]
        block = f"## {path.relative_to(shared_root)}\nTitle: {title}\nSummary: {snippet}\n"
        if budget - len(block) < 0:
            break
        sections.append(block)
        budget -= len(block)

    prompt = (
        "Review this team knowledge wiki summary for contradictions or materially conflicting facts.\n"
        "Return strict JSON with shape {\"findings\": [{\"summary\": str, \"files\": [str]}]}.\n"
        "If you find no contradictions, return {\"findings\": []}.\n\n"
        + "\n".join(sections)
    )
    command = [claude, "-p", "--no-session-persistence", "--dangerously-skip-permissions", "--output-format", "text"]
    if model:
        command.extend(["--model", model])
    command.append(prompt)

    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        return {
            "requested": True,
            "status": "error",
            "findings": [],
            "message": str(exc),
        }

    stdout = completed.stdout.strip()
    try:
        payload = json.loads(stdout)
        findings = payload.get("findings") if isinstance(payload, dict) else []
        if not isinstance(findings, list):
            findings = []
        return {
            "requested": True,
            "status": "ok",
            "findings": findings,
            "raw": stdout,
        }
    except json.JSONDecodeError:
        return {
            "requested": True,
            "status": "parse-error",
            "findings": [],
            "raw": stdout,
        }


def maybe_move_capture(shared_root: Path, capture_path: Path, dry_run: bool) -> Path:
    inbox_dir = raw_root(shared_root) / "captures" / "inbox"
    promoted_dir = raw_root(shared_root) / "captures" / "promoted"
    if capture_path.parent != inbox_dir:
        return capture_path
    target = promoted_dir / capture_path.name
    if not dry_run:
        promoted_dir.mkdir(parents=True, exist_ok=True)
        shutil.move(str(capture_path), str(target))
    return target


def extract_managed_block(text: str, start: str, end: str) -> str:
    pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.DOTALL)
    match = pattern.search(text)
    return match.group(0) if match else ""


def parse_csv_field(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_handles_field(value: str) -> dict[str, str]:
    handles: dict[str, str] = {}
    for raw_item in value.split(";"):
        item = raw_item.strip()
        if not item:
            continue
        if "=" in item:
            surface, handle = item.split("=", 1)
        elif ":" in item:
            surface, handle = item.split(":", 1)
        else:
            continue
        surface = surface.strip().lower()
        handle = handle.strip()
        if surface and handle:
            handles[surface] = handle
    return handles


def serialize_handles(handles: dict[str, str]) -> str:
    if not handles:
        return ""
    return "; ".join(f"{surface}={handle}" for surface, handle in sorted(handles.items()))


def parse_operator_profile(text: str) -> dict[str, object]:
    block = extract_managed_block(text, PRIMARY_OPERATOR_START, PRIMARY_OPERATOR_END)
    if not block:
        return {
            "configured": False,
            "role": "primary operator",
            "user_id": "",
            "display_name": "",
            "preferred_address": "",
            "aliases": [],
            "channel_handles": {},
            "communication_preferences": "",
            "decision_scope": "",
            "escalation_relevance": "",
            "updated_at": "",
        }
    fields: dict[str, str] = {}
    for line in block.splitlines():
        match = re.match(r"^- ([^:]+):\s*(.*)$", line.strip())
        if match:
            fields[match.group(1).strip()] = match.group(2).strip()
    display_name = fields.get("Display name", "")
    return {
        "configured": bool(display_name),
        "role": fields.get("Role", "primary operator"),
        "user_id": fields.get("User ID", ""),
        "display_name": display_name,
        "preferred_address": fields.get("Preferred address", ""),
        "aliases": parse_csv_field(fields.get("Aliases", "")),
        "channel_handles": parse_handles_field(fields.get("Channel handles", "")),
        "communication_preferences": fields.get("Communication preferences", ""),
        "decision_scope": fields.get("Decision scope", ""),
        "escalation_relevance": fields.get("Escalation relevance", ""),
        "updated_at": fields.get("Updated at", ""),
    }


def render_operator_profile(payload: dict[str, object]) -> str:
    lines = [
        PRIMARY_OPERATOR_START,
        "- Role: primary operator",
        f"- User ID: {payload['user_id']}",
        f"- Display name: {payload['display_name']}",
        f"- Preferred address: {payload['preferred_address']}",
        f"- Aliases: {', '.join(payload['aliases'])}",
        f"- Channel handles: {serialize_handles(payload['channel_handles'])}",
        f"- Communication preferences: {payload['communication_preferences']}",
        f"- Decision scope: {payload['decision_scope']}",
        f"- Escalation relevance: {payload['escalation_relevance']}",
        f"- Updated at: {payload['updated_at']}",
        PRIMARY_OPERATOR_END,
    ]
    return "\n".join(lines)


def upsert_operator_profile(path: Path, payload: dict[str, object], dry_run: bool) -> None:
    block = render_operator_profile(payload)
    text = read_text(path) if path.exists() else "# People\n"
    pattern = re.compile(
        re.escape(PRIMARY_OPERATOR_START) + r".*?" + re.escape(PRIMARY_OPERATOR_END),
        re.DOTALL,
    )
    if pattern.search(text):
        updated = pattern.sub(block, text, count=1)
    elif PRIMARY_OPERATOR_HEADING in text:
        updated = text.replace(PRIMARY_OPERATOR_HEADING, f"{PRIMARY_OPERATOR_HEADING}\n\n{block}", 1)
    elif "## Notes" in text:
        updated = text.replace("## Notes", f"{PRIMARY_OPERATOR_HEADING}\n\n{block}\n\n## Notes", 1)
    else:
        updated = text.rstrip() + f"\n\n{PRIMARY_OPERATOR_HEADING}\n\n{block}\n"
    write_text(path, updated.rstrip() + "\n", dry_run)


def normalize_handle(raw: str) -> tuple[str, str]:
    if "=" not in raw:
        die(f"invalid handle format (expected surface=value): {raw}")
    surface, handle = raw.split("=", 1)
    surface = surface.strip().lower()
    handle = handle.strip()
    if not surface or not handle:
        die(f"invalid handle format (expected surface=value): {raw}")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", surface):
        die(f"invalid handle surface: {surface}")
    return surface, handle


def cmd_operator_set(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    ensure_layout(shared_root, Path(args.template_root), args.team_name, args.dry_run)
    target = wiki_root(shared_root) / "people.md"
    ensure_page(target, "People", args.dry_run)
    existing = parse_operator_profile(read_text(target) if target.exists() else "")
    handles = dict(existing["channel_handles"])
    if args.handle:
        handles = {}
        for raw_handle in args.handle:
            surface, handle = normalize_handle(raw_handle)
            handles[surface] = handle
    aliases = args.alias if args.alias else list(existing["aliases"])
    payload: dict[str, object] = {
        "configured": True,
        "role": "primary operator",
        "user_id": args.user or str(existing["user_id"]) or "owner",
        "display_name": args.name.strip(),
        "preferred_address": (
            args.preferred_address.strip()
            if args.preferred_address
            else str(existing["preferred_address"]) or args.name.strip()
        ),
        "aliases": aliases,
        "channel_handles": handles,
        "communication_preferences": (
            args.communication_preferences.strip()
            if args.communication_preferences
            else str(existing["communication_preferences"])
        ),
        "decision_scope": (
            args.decision_scope.strip()
            if args.decision_scope
            else str(existing["decision_scope"])
        ),
        "escalation_relevance": (
            args.escalation_relevance.strip()
            if args.escalation_relevance
            else str(existing["escalation_relevance"])
        ),
        "updated_at": now().isoformat(timespec="seconds"),
    }
    upsert_operator_profile(target, payload, args.dry_run)
    append_log(
        shared_root,
        f"- {now().isoformat(timespec='seconds')} updated primary operator -> {target.relative_to(shared_root)}",
        args.dry_run,
    )
    result = {
        **payload,
        "path": str(target),
        "relative_path": str(target.relative_to(shared_root)),
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print("role: primary operator")
        print(f"user_id: {payload['user_id']}")
        print(f"display_name: {payload['display_name']}")
        print(f"relative_path: {target.relative_to(shared_root)}")
    return 0


def cmd_operator_show(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    target = wiki_root(shared_root) / "people.md"
    payload = parse_operator_profile(read_text(target) if target.exists() else "")
    result = {
        **payload,
        "path": str(target),
        "relative_path": str(target.relative_to(shared_root)),
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"configured: {'true' if payload['configured'] else 'false'}")
        if payload["configured"]:
            print("role: primary operator")
            print(f"user_id: {payload['user_id']}")
            print(f"display_name: {payload['display_name']}")
            print(f"preferred_address: {payload['preferred_address']}")
            if payload["channel_handles"]:
                print(f"channel_handles: {serialize_handles(payload['channel_handles'])}")
        print(f"path: {target}")
    return 0


def cmd_promote(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    ensure_layout(shared_root, Path(args.template_root), args.team_name, args.dry_run)
    kind = normalize_kind(args.kind)
    capture = None
    capture_path = None
    if args.capture:
        capture_path, capture = resolve_capture(shared_root, args.capture)
    summary = args.summary or (capture or {}).get("text", "")
    if not summary.strip():
        die("--summary is required when --capture is not provided")
    target = target_for_kind(shared_root, kind, args.page, args.title or (capture or {}).get("title", ""))
    ensure_page(target, page_title(target.stem), args.dry_run)
    append_note(target, build_note(args, capture, summary), args.dry_run)
    promoted_capture_path = ""
    if capture_path:
        promoted_capture_path = str(maybe_move_capture(shared_root, capture_path, args.dry_run))
    append_log(
        shared_root,
        f"- {now().isoformat(timespec='seconds')} promoted {kind} -> {target.relative_to(shared_root)}",
        args.dry_run,
    )
    payload = {
        "kind": kind,
        "target": str(target),
        "relative_path": str(target.relative_to(shared_root)),
        "capture": args.capture or "",
        "promoted_capture_path": promoted_capture_path,
        "dry_run": args.dry_run,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"kind: {kind}")
        print(f"target: {target}")
        if args.capture:
            print(f"capture: {args.capture}")
    return 0


def iter_search_files(shared_root: Path, scope: str) -> list[Path]:
    files: list[Path] = []
    if scope in {"wiki", "all"}:
        files.extend(sorted(wiki_root(shared_root).rglob("*.md")))
    if scope in {"raw", "all"}:
        files.extend(sorted(raw_root(shared_root).rglob("*.json")))
        files.extend(sorted(raw_root(shared_root).rglob("*.md")))
    return [path for path in files if path.is_file()]


def line_matches(line: str, query: str, tokens: list[str]) -> bool:
    lower = line.lower()
    query_lower = query.lower()
    if query_lower in lower:
        return True
    return bool(tokens) and all(token in lower for token in tokens)


def cmd_search(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    tokens = [token for token in re.split(r"\s+", args.query.lower().strip()) if token]
    results: list[dict[str, object]] = []
    for path in iter_search_files(shared_root, args.scope):
        try:
            lines = read_text(path).splitlines()
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(lines, start=1):
            if line_matches(line, args.query, tokens):
                results.append(
                    {
                        "path": str(path),
                        "relative_path": str(path.relative_to(shared_root)),
                        "line": number,
                        "snippet": line.strip(),
                    }
                )
                break
        if len(results) >= args.limit:
            break
    payload = {
        "query": args.query,
        "scope": args.scope,
        "count": len(results),
        "results": results,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"query: {args.query}")
        print(f"scope: {args.scope}")
        print(f"matches: {len(results)}")
        for item in results:
            print(f"- {item['relative_path']}:{item['line']} {item['snippet']}")
    return 0


def cmd_lint(args: argparse.Namespace) -> int:
    shared_root = Path(args.shared_root)
    required = [wiki_root(shared_root) / item for item in WIKI_FILES]
    required.extend(wiki_root(shared_root) / item for item in WIKI_DIRS)
    required.extend(shared_root / item for item in RAW_DIRS)
    missing = [str(path.relative_to(shared_root)) for path in required if not path.exists()]
    lint_details = lint_wiki(shared_root, args.stale_days)
    llm_review = maybe_run_llm_review(shared_root, args.llm_review, args.llm_model)
    problems = []
    problems.extend(f"missing: {item}" for item in missing)
    problems.extend(
        f"broken_link: {item['source']} -> {item['target']}" for item in lint_details["broken_links"]
    )
    problems.extend(f"orphan_page: {item}" for item in lint_details["orphan_pages"])
    problems.extend(
        f"duplicate_title: {item['title']} ({', '.join(item['files'])})"
        for item in lint_details["duplicate_titles"]
    )
    warnings = [
        f"stale_page: {item['path']} ({item['days_old']}d)"
        for item in lint_details["stale_pages"]
    ]
    if llm_review.get("requested") and llm_review.get("status") != "ok":
        warnings.append(f"llm_review: {llm_review.get('status')}")
    ok = len(problems) == 0
    payload = {
        "ok": ok,
        "shared_root": str(shared_root),
        "wiki_root": str(wiki_root(shared_root)),
        "missing": missing,
        "problems": problems,
        "warnings": warnings,
        **lint_details,
        "llm_review": llm_review,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"ok: {'true' if ok else 'false'}")
        if problems:
            print("problems:")
            for item in problems:
                print(f"- {item}")
        if warnings:
            print("warnings:")
            for item in warnings:
                print(f"- {item}")
    return 0 if ok else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common(subparser: argparse.ArgumentParser) -> None:
        subparser.add_argument("--shared-root", required=True)
        subparser.add_argument("--template-root", required=True)
        subparser.add_argument("--team-name", default="Team")
        subparser.add_argument("--dry-run", action="store_true")
        subparser.add_argument("--json", action="store_true")

    init_parser = subparsers.add_parser("init")
    add_common(init_parser)
    init_parser.set_defaults(func=cmd_init)

    capture_parser = subparsers.add_parser("capture")
    add_common(capture_parser)
    capture_parser.add_argument("--source", required=True)
    capture_parser.add_argument("--author", default="")
    capture_parser.add_argument("--channel", default="")
    capture_parser.add_argument("--title", default="")
    text_group = capture_parser.add_mutually_exclusive_group(required=True)
    text_group.add_argument("--text")
    text_group.add_argument("--text-file")
    capture_parser.set_defaults(func=cmd_capture)

    promote_parser = subparsers.add_parser("promote")
    add_common(promote_parser)
    promote_parser.add_argument("--kind", required=True)
    promote_parser.add_argument("--capture", default="")
    promote_parser.add_argument("--page", default="")
    promote_parser.add_argument("--title", default="")
    promote_parser.add_argument("--summary", default="")
    promote_parser.set_defaults(func=cmd_promote)

    operator_set_parser = subparsers.add_parser("operator-set")
    add_common(operator_set_parser)
    operator_set_parser.add_argument("--user", default="")
    operator_set_parser.add_argument("--name", required=True)
    operator_set_parser.add_argument("--preferred-address", default="")
    operator_set_parser.add_argument("--alias", action="append", default=[])
    operator_set_parser.add_argument("--handle", action="append", default=[])
    operator_set_parser.add_argument("--communication-preferences", default="")
    operator_set_parser.add_argument("--decision-scope", default="")
    operator_set_parser.add_argument("--escalation-relevance", default="")
    operator_set_parser.set_defaults(func=cmd_operator_set)

    operator_show_parser = subparsers.add_parser("operator-show")
    add_common(operator_show_parser)
    operator_show_parser.set_defaults(func=cmd_operator_show)

    search_parser = subparsers.add_parser("search")
    search_parser.add_argument("--shared-root", required=True)
    search_parser.add_argument("--query", required=True)
    search_parser.add_argument("--scope", choices=SEARCH_SCOPES, default="wiki")
    search_parser.add_argument("--limit", type=int, default=10)
    search_parser.add_argument("--json", action="store_true")
    search_parser.set_defaults(func=cmd_search)

    lint_parser = subparsers.add_parser("lint")
    lint_parser.add_argument("--shared-root", required=True)
    lint_parser.add_argument("--stale-days", type=int, default=90)
    lint_parser.add_argument("--llm-review", action="store_true")
    lint_parser.add_argument("--llm-model", default="")
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
