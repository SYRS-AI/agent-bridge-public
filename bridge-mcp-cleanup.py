#!/usr/bin/env python3
"""Detect and optionally kill orphaned MCP server processes.

The detector is intentionally conservative. It only treats a matching MCP
process as orphaned when its immediate parent is init/launchd, or when its
parent is another matching MCP process whose chain is already orphaned.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Iterable


DEFAULT_PATTERNS = [
    r"npm(\s+exec)?\s+@upstash/context7-mcp",
    r"npm(\s+exec)?\s+@playwright/mcp",
    r"npm(\s+exec)?.*firebase-tools.*mcp",
    r"\bbun\b.*server\.ts",
    r"\bnode\b.*context7.*mcp",
    r"\bnode\b.*playwright.*mcp",
    r"\bnode\b.*firebase.*mcp",
    # Issue #223: bun plugin roots accumulate as PID-1 orphans across
    # agent restarts (shared-mode + tmux-kill-session + daemon reconcile
    # all leave them reparented). Matching only `bun server.ts` was not
    # enough — its parent `bun run --cwd .../plugins/<kind>` is
    # unmatched, so the chain check in is_orphan_candidate() refused the
    # server.ts child too. Restrict the patterns to Agent Bridge plugin
    # paths so a developer's own `bun run --cwd ./myapp build` never
    # matches.
    r"\bbun\s+run\s+--cwd\s+.+?\.agent-bridge/plugins/",
    r"\bbun\s+run\s+--cwd\s+.+?/claude-plugins-official/",
]


@dataclass(frozen=True)
class Proc:
    pid: int
    ppid: int
    age_seconds: int
    rss_kb: int
    command: str


def parse_etime(value: str) -> int:
    days = 0
    if "-" in value:
        day_text, value = value.split("-", 1)
        try:
            days = int(day_text)
        except ValueError:
            days = 0
    parts = value.split(":")
    try:
        if len(parts) == 3:
            hours, minutes, seconds = [int(part) for part in parts]
        elif len(parts) == 2:
            hours = 0
            minutes, seconds = [int(part) for part in parts]
        elif len(parts) == 1:
            hours = 0
            minutes = 0
            seconds = int(parts[0])
        else:
            return 0
    except ValueError:
        return 0
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def ps_output() -> tuple[str, bool]:
    try:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,etimes=,rss=,command="],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return completed.stdout, True
    except subprocess.CalledProcessError:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,etime=,rss=,command="],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return completed.stdout, False


def load_processes() -> dict[int, Proc]:
    output, age_is_seconds = ps_output()
    processes: dict[int, Proc] = {}
    for line in output.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) < 5:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
            rss = int(parts[3])
        except ValueError:
            continue
        age = int(parts[2]) if age_is_seconds else parse_etime(parts[2])
        processes[pid] = Proc(pid=pid, ppid=ppid, age_seconds=age, rss_kb=rss, command=parts[4])
    return processes


def compile_patterns(patterns: Iterable[str]) -> list[re.Pattern[str]]:
    compiled = []
    for pattern in patterns:
        pattern = pattern.strip()
        if pattern:
            compiled.append(re.compile(pattern))
    return compiled


def matched_pattern(proc: Proc, patterns: list[re.Pattern[str]]) -> str:
    if proc.pid == os.getpid():
        return ""
    if "bridge-mcp-cleanup.py" in proc.command:
        return ""
    for pattern in patterns:
        if pattern.search(proc.command):
            return pattern.pattern
    return ""


def is_orphan_candidate(
    proc: Proc,
    processes: dict[int, Proc],
    matches: dict[int, str],
    min_age: int,
    seen: set[int] | None = None,
) -> bool:
    if proc.age_seconds < min_age:
        return False
    if not matches.get(proc.pid):
        return False
    if proc.ppid in {0, 1}:
        return True
    parent = processes.get(proc.ppid)
    if parent is None:
        return True
    if not matches.get(parent.pid):
        return False
    if seen is None:
        seen = set()
    if proc.pid in seen:
        return False
    seen.add(proc.pid)
    return is_orphan_candidate(parent, processes, matches, min_age, seen)


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def kill_pid(pid: int, grace_seconds: float) -> tuple[bool, str]:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return True, "already-gone"
    except PermissionError as exc:
        return False, str(exc)

    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        if not alive(pid):
            return True, "terminated"
        time.sleep(0.05)

    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return True, "terminated"
    except PermissionError as exc:
        return False, str(exc)
    return True, "killed"


def build_report(args: argparse.Namespace) -> dict[str, object]:
    patterns = compile_patterns(args.pattern or DEFAULT_PATTERNS)
    processes = load_processes()
    matches = {pid: matched_pattern(proc, patterns) for pid, proc in processes.items()}
    matched = [
        {
            "pid": proc.pid,
            "ppid": proc.ppid,
            "age_seconds": proc.age_seconds,
            "rss_kb": proc.rss_kb,
            "pattern": matches[proc.pid],
            "command": proc.command,
        }
        for proc in processes.values()
        if matches.get(proc.pid)
    ]
    orphans = [
        item
        for item in matched
        if is_orphan_candidate(processes[int(item["pid"])], processes, matches, args.min_age)
    ]
    # Kill children before their orphan MCP parents.
    orphans.sort(key=lambda item: int(item["pid"]), reverse=True)

    killed = []
    errors = []
    if args.kill:
        for item in orphans:
            pid = int(item["pid"])
            ok, status = kill_pid(pid, args.grace_seconds)
            enriched = dict(item)
            enriched["kill_status"] = status
            if ok:
                killed.append(enriched)
            else:
                errors.append(enriched)

    killed_rss_kb = sum(int(item.get("rss_kb") or 0) for item in killed)
    return {
        "trigger": args.trigger,
        "dry_run": not args.kill,
        "min_age_seconds": args.min_age,
        "matched_count": len(matched),
        "orphan_count": len(orphans),
        "killed_count": len(killed),
        "freed_mb_estimate": round(killed_rss_kb / 1024, 1),
        "matched": matched,
        "orphans": orphans,
        "killed": killed,
        "errors": errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser(prog="bridge-mcp-cleanup.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name in ("scan", "cleanup"):
        child = subparsers.add_parser(name)
        child.add_argument("--json", action="store_true")
        child.add_argument("--min-age", type=int, default=300)
        child.add_argument("--pattern", action="append")
        child.add_argument("--trigger", default=name)
        child.add_argument("--grace-seconds", type=float, default=1.0)
        child.add_argument("--kill", action="store_true")
        child.add_argument("--dry-run", action="store_true")

    args = parser.parse_args()
    if args.command == "scan":
        args.kill = False
    elif args.dry_run:
        args.kill = False

    report = build_report(args)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"matched: {report['matched_count']}")
        print(f"orphans: {report['orphan_count']}")
        print(f"killed: {report['killed_count']}")
        print(f"freed_mb_estimate: {report['freed_mb_estimate']}")
        for item in report["orphans"]:
            print(f"- pid={item['pid']} ppid={item['ppid']} age={item['age_seconds']} pattern={item['pattern']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
