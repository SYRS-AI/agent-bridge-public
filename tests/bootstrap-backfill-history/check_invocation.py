#!/usr/bin/env python3
"""Static check helper for tests/bootstrap-backfill-history/smoke.sh.

Parses bootstrap-memory-system.sh and reports whether the
`step_backfill_history_one` and `run_backfill_history` functions contain the
exact harvest-daily invocation contract from issue #322 Track C, plus whether
the only call site of `run_backfill_history` is gated on both
`BACKFILL_HISTORY_DAYS` (non-empty) and `MODE == "apply"`.

Kept as a sibling script (instead of an inline heredoc inside smoke.sh) so
unbalanced parentheses inside the Python body don't trip bash's
command-substitution tokenizer — same workaround as
tests/bootstrap-cron-schedules/parse_specs.py.

Two subcommands:

  invocation <bootstrap.sh>   prints {"missing": [...], "error": "..."}
  gate       <bootstrap.sh>   prints {"errors": [...]}
"""

from __future__ import annotations

import json
import re
import sys


def check_invocation(src_path: str) -> dict:
    src = open(src_path, encoding="utf-8").read()

    m = re.search(
        r"step_backfill_history_one\s*\(\)\s*\{(.*?)\n\}",
        src,
        re.DOTALL,
    )
    if not m:
        return {"error": "step_backfill_history_one function not found"}
    body = m.group(1)

    required = [
        "harvest-daily",
        "--agent",
        "--from",
        "--to",
        "--missing-only",
        "--tz Asia/Seoul",
    ]
    missing = [tok for tok in required if tok not in body]

    # Confirm the harvester is invoked through bridge-memory.py at $BRIDGE_HOME
    # (downstream installs run the harvester from $BRIDGE_HOME/bridge-memory.py
    # per the upgrade contract).
    if "bridge-memory.py" not in body:
        missing.append("bridge-memory.py")

    # Confirm per-agent failures don't abort the loop. step_backfill_history_one
    # returns 1 on failure but the run_backfill_history caller swallows the rc
    # into ok_count/fail_count counters.
    m2 = re.search(
        r"run_backfill_history\s*\(\)\s*\{(.*?)\n\}",
        src,
        re.DOTALL,
    )
    if not m2:
        return {"error": "run_backfill_history function not found"}
    caller = m2.group(1)
    if "fail_count" not in caller or "ok_count" not in caller:
        missing.append("per-agent failure isolation (ok_count/fail_count)")

    # Confirm the cap stays at 90 days as documented in the brief.
    if not re.search(r"BACKFILL_HISTORY_DAYS\s*>\s*90", src):
        missing.append("upper bound check '> 90'")

    return {"missing": missing}


def check_gate(src_path: str) -> dict:
    src = open(src_path, encoding="utf-8").read()

    call_sites = []
    for m in re.finditer(r"\brun_backfill_history\b", src):
        pos = m.start()
        line_start = src.rfind("\n", 0, pos) + 1
        line_end = src.find("\n", pos)
        line = src[line_start:line_end]
        # Skip the function definition itself.
        stripped = line.strip()
        if stripped.startswith("run_backfill_history()"):
            continue
        # Skip any single-line definition variant.
        if "()" in stripped and "{" in stripped:
            continue
        call_sites.append((pos, stripped))

    errors = []
    if not call_sites:
        errors.append("run_backfill_history is never called")

    for pos, line in call_sites:
        # Walk backwards to find the enclosing `if [[ ... ]]; then` block.
        # A 600-byte window is wide enough to span the multi-condition
        # composite while staying inside the same block.
        window = src[max(0, pos - 600):pos]
        if "BACKFILL_HISTORY_DAYS" not in window:
            errors.append(
                f"call site '{line}' is not gated on BACKFILL_HISTORY_DAYS"
            )
        if "MODE" not in window or "apply" not in window:
            errors.append(
                f"call site '{line}' is not gated on MODE==apply"
            )

    return {"errors": errors}


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(json.dumps({"error": "usage: check_invocation.py <invocation|gate> <bootstrap.sh>"}))
        return 2
    cmd = argv[1]
    src_path = argv[2]
    if cmd == "invocation":
        print(json.dumps(check_invocation(src_path)))
        return 0
    if cmd == "gate":
        print(json.dumps(check_gate(src_path)))
        return 0
    print(json.dumps({"error": f"unknown subcommand: {cmd}"}))
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
