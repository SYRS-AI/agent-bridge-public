#!/usr/bin/env python3
"""sync-memory-schema.py — push the canonical ``_template/MEMORY-SCHEMA.md``
content to every agent home, with a per-agent backup so customizations
are never lost without a paper trail.

Usage:
  sync-memory-schema.py                 # dry-run (default, no writes)
  sync-memory-schema.py --apply         # write changes
  sync-memory-schema.py --apply --only mailbot,patch
  sync-memory-schema.py --json          # machine-readable summary

Backup policy:
  - If an agent's current MEMORY-SCHEMA.md differs from the new
    template content, the existing file is copied to
    ``MEMORY-SCHEMA.md.pre-sync-<stamp>`` before rewrite.
  - Identical files are left alone (no backup, no write).

Generic. No deployment-specific agent list. Iterates every subdir of
``<bridge-home>/agents/`` that isn't in the skip set.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

SKIP_DIRS = {"_template", "shared", "--help"}


def bridge_home() -> Path:
    env = os.environ.get("AGENT_BRIDGE_HOME") or os.environ.get("BRIDGE_HOME")
    if env:
        return Path(env).expanduser().resolve()
    script = Path(__file__).resolve().parent
    return script.parent


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def iter_agents(home: Path):
    root = home / "agents"
    if not root.is_dir():
        return
    for entry in sorted(root.iterdir()):
        if not entry.is_dir():
            continue
        if entry.name in SKIP_DIRS:
            continue
        if entry.name.startswith("."):
            continue
        yield entry.name, entry


def run(args: argparse.Namespace) -> int:
    home = bridge_home()
    template = home / "agents" / "_template" / "MEMORY-SCHEMA.md"
    if not template.exists():
        print(f"[error] template not found: {template}", file=sys.stderr)
        return 1

    only = set(a.strip() for a in args.only.split(",")) if args.only else None
    template_bytes = template.read_bytes()
    template_hash = hashlib.sha256(template_bytes).hexdigest()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    summary = {
        "bridge_home": str(home),
        "template_path": str(template),
        "template_sha256": template_hash,
        "stamp": stamp,
        "mode": "apply" if args.apply else "dry-run",
        "agents_seen": 0,
        "already_current": 0,
        "updated": 0,
        "would_update": 0,
        "missing_target": 0,
        "per_agent": {},
    }

    for agent, agent_dir in iter_agents(home):
        if only is not None and agent not in only:
            continue
        summary["agents_seen"] += 1
        per = summary["per_agent"].setdefault(
            agent,
            {"status": "", "backup": ""},
        )
        target = agent_dir / "MEMORY-SCHEMA.md"
        if not target.exists():
            per["status"] = "missing-target"
            summary["missing_target"] += 1
            continue
        if target.read_bytes() == template_bytes:
            per["status"] = "already-current"
            summary["already_current"] += 1
            continue
        if not args.apply:
            per["status"] = "would-update"
            summary["would_update"] += 1
            continue
        backup = target.with_name(
            f"MEMORY-SCHEMA.md.pre-sync-{stamp}"
        )
        try:
            shutil.copy2(target, backup)
            target.write_bytes(template_bytes)
            per["status"] = "updated"
            per["backup"] = backup.name
            summary["updated"] += 1
        except OSError as exc:
            per["status"] = f"error: {exc}"
            print(
                f"[error] {agent}: {exc}", file=sys.stderr
            )

    if args.json:
        json.dump(summary, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    else:
        pieces = [
            f"mode={summary['mode']}",
            f"agents={summary['agents_seen']}",
            f"already-current={summary['already_current']}",
        ]
        if args.apply:
            pieces.append(f"updated={summary['updated']}")
        else:
            pieces.append(f"would-update={summary['would_update']}")
        if summary["missing_target"]:
            pieces.append(f"missing={summary['missing_target']}")
        print("sync-memory-schema: " + " ".join(pieces))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="sync-memory-schema",
        description=(
            "Overwrite each agent's MEMORY-SCHEMA.md with the content "
            "from the _template. Leaves a per-agent backup on change."
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write changes. Without this flag, dry-run is the default.",
    )
    parser.add_argument(
        "--only",
        default="",
        help="Comma-separated list of agent names to update.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a machine-readable summary.",
    )
    args = parser.parse_args(argv)
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
