#!/usr/bin/env python3
"""Helper for tests/bootstrap-cron-schedules/smoke.sh.

Parses the CRON_SPECS array and step_memory_daily_cron_one schedule out
of bootstrap-memory-system.sh and prints a JSON summary on stdout.

Kept as a sibling script (instead of an inline heredoc inside smoke.sh)
because bash command substitution mishandles unbalanced parentheses
inside a heredoc body — see the comment in smoke.sh for context.
"""

from __future__ import annotations

import json
import re
import sys


def parse(src_path: str) -> dict:
    src = open(src_path, encoding="utf-8").read()

    # Find the CRON_SPECS=( ... ) array and walk byte-by-byte to the
    # matching top-level close-paren. A simple [^)]* regex would stop
    # early because the array body contains close-paren characters
    # inside comment text.
    start = src.find("CRON_SPECS=(")
    if start < 0:
        return {"error": "CRON_SPECS array not found"}
    cursor = start + len("CRON_SPECS=(")
    depth = 1
    end = -1
    while cursor < len(src):
        ch = src[cursor]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                end = cursor
                break
        cursor += 1
    if end < 0:
        return {"error": "CRON_SPECS array not closed"}
    body = src[start + len("CRON_SPECS=("): end]

    specs = []
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith('"') or not line.endswith('"'):
            continue
        inner = line[1:-1]
        parts = inner.split("|")
        if len(parts) < 4:
            continue
        title = parts[0].strip()
        expr = parts[1].strip()
        tz = parts[2].strip()
        script = parts[3].strip()
        specs.append({"title": title, "expr": expr, "tz": tz, "script": script})

    md_match = re.search(
        r'step_memory_daily_cron_one\s*\(\)\s*\{[^}]*?local\s+sched=\"([^\"]+)\"',
        src,
        re.DOTALL,
    )
    memory_daily_expr = md_match.group(1) if md_match else None

    return {"specs": specs, "memory_daily_expr": memory_daily_expr}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(json.dumps({"error": "usage: parse_specs.py <bootstrap.sh>"}))
        return 2
    print(json.dumps(parse(argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
