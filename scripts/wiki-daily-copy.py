#!/usr/bin/env python3
"""wiki-daily-copy.py — byte-equivalent promotion of agent daily notes
into ``shared/wiki/agents/<agent>/daily/<agent>-YYYY-MM-DD.md``.

Implements ``wiki-graph-rules.md §2`` ("Daily memory files copied from
an agent home into ``shared/wiki/agents/<agent>/daily/...`` are
read-only replicas"). Replaces the broken librarian promote path that
was routing daily notes into ``shared/wiki/operating-rules.md`` due to
fallback-kind collapse.

Generic — no deployment-specific agent list. Walks every subdir under
``<bridge-home>/agents/`` that has a ``memory/`` directory with
``YYYY-MM-DD.md`` files.

Usage:
  wiki-daily-copy.py                            # copy today only
  wiki-daily-copy.py --date 2026-04-19
  wiki-daily-copy.py --since 2026-04-17         # catch up range
  wiki-daily-copy.py --all                      # full backfill
  wiki-daily-copy.py --dry-run                  # report without writing
  wiki-daily-copy.py --json                     # JSON summary

Copy contract:
  - Target path: <wiki>/agents/<agent>/daily/<agent>-<YYYY-MM-DD>.md
  - Idempotent: SHA-256 match → skip. Any other difference → rewrite.
  - Only ``.md`` files under ``memory/`` whose stem parses as a date.
  - Preserves mtime from source for downstream mtime-based scanners.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

_DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")
_SKIP_AGENT_DIRS = {"_template", "shared", "--help"}


def bridge_home() -> Path:
    env = os.environ.get("AGENT_BRIDGE_HOME") or os.environ.get("BRIDGE_HOME")
    if env:
        return Path(env).expanduser().resolve()
    script = Path(__file__).resolve().parent
    return script.parent


def wiki_root(home: Path) -> Path:
    env = os.environ.get("AGENT_BRIDGE_WIKI")
    if env:
        return Path(env).expanduser().resolve()
    return home / "shared" / "wiki"


def iter_agent_dirs(home: Path):
    agents_root = home / "agents"
    if not agents_root.is_dir():
        return
    for entry in sorted(agents_root.iterdir()):
        if not entry.is_dir():
            continue
        if entry.name in _SKIP_AGENT_DIRS:
            continue
        memory = entry / "memory"
        if not memory.is_dir():
            continue
        yield entry.name, memory


def parse_date_token(stem: str) -> str | None:
    match = _DATE_RE.match(stem)
    return stem if match else None


def in_range(date_str: str, since: str | None, until: str | None) -> bool:
    if since and date_str < since:
        return False
    if until and date_str > until:
        return False
    return True


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def copy_if_needed(
    src: Path,
    dest: Path,
    dry_run: bool,
) -> str:
    """Return one of: created / replaced / unchanged / dry-run-create /
    dry-run-replace."""
    if not dest.exists():
        if dry_run:
            return "dry-run-create"
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
        return "created"
    # Both exist — compare content.
    src_hash = sha256_of(src)
    dest_hash = sha256_of(dest)
    if src_hash == dest_hash:
        return "unchanged"
    if dry_run:
        return "dry-run-replace"
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    return "replaced"


def run(args: argparse.Namespace) -> int:
    home = bridge_home()
    wiki = wiki_root(home)
    if not wiki.exists():
        print(f"[error] wiki root not found: {wiki}", file=sys.stderr)
        return 1

    today = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d")
    since = args.since
    until = args.until
    if not since and not until and not args.all:
        # Default: copy today only.
        if args.date:
            since = until = args.date
        else:
            since = until = today

    summary = {
        "bridge_home": str(home),
        "wiki_root": str(wiki),
        "mode": "all" if args.all else ("range" if (since != until) else "single-date"),
        "since": since,
        "until": until,
        "agents_seen": 0,
        "files_seen": 0,
        "created": 0,
        "replaced": 0,
        "unchanged": 0,
        "dry_run_create": 0,
        "dry_run_replace": 0,
        "errors": 0,
        "per_agent": {},
    }

    for agent, memory_dir in iter_agent_dirs(home):
        summary["agents_seen"] += 1
        per_agent = summary["per_agent"].setdefault(
            agent,
            {"files": 0, "created": 0, "replaced": 0, "unchanged": 0, "errors": 0},
        )
        target_dir = wiki / "agents" / agent / "daily"
        for src in sorted(memory_dir.glob("*.md")):
            date_str = parse_date_token(src.stem)
            if not date_str:
                continue
            if not args.all and not in_range(date_str, since, until):
                continue
            summary["files_seen"] += 1
            per_agent["files"] += 1
            dest = target_dir / f"{agent}-{date_str}.md"
            try:
                outcome = copy_if_needed(src, dest, args.dry_run)
            except OSError as exc:
                summary["errors"] += 1
                per_agent["errors"] += 1
                print(f"[error] {src} -> {dest}: {exc}", file=sys.stderr)
                continue
            if outcome == "created":
                summary["created"] += 1
                per_agent["created"] += 1
            elif outcome == "replaced":
                summary["replaced"] += 1
                per_agent["replaced"] += 1
            elif outcome == "unchanged":
                summary["unchanged"] += 1
                per_agent["unchanged"] += 1
            elif outcome == "dry-run-create":
                summary["dry_run_create"] += 1
            elif outcome == "dry-run-replace":
                summary["dry_run_replace"] += 1

    if args.json:
        json.dump(summary, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    else:
        pieces = [
            f"agents={summary['agents_seen']}",
            f"files={summary['files_seen']}",
            f"created={summary['created']}",
            f"replaced={summary['replaced']}",
            f"unchanged={summary['unchanged']}",
        ]
        if args.dry_run:
            pieces.append(f"dry-create={summary['dry_run_create']}")
            pieces.append(f"dry-replace={summary['dry_run_replace']}")
        if summary["errors"]:
            pieces.append(f"errors={summary['errors']}")
        print("wiki-daily-copy: " + " ".join(pieces))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="wiki-daily-copy",
        description=(
            "Copy agent memory/YYYY-MM-DD.md daily notes to the shared "
            "wiki as byte-equivalent read-only replicas. Idempotent."
        ),
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--date", help="Copy only this date (YYYY-MM-DD).")
    group.add_argument(
        "--all", action="store_true", help="Backfill every date present."
    )
    parser.add_argument("--since", help="Range start (inclusive, YYYY-MM-DD).")
    parser.add_argument("--until", help="Range end (inclusive, YYYY-MM-DD).")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report planned actions without modifying the wiki.",
    )
    parser.add_argument(
        "--json", action="store_true", help="Emit a machine-readable summary."
    )
    args = parser.parse_args(argv)
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
