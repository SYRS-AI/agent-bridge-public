#!/usr/bin/env python3
"""Shared Agent Bridge inbox check hook."""

from __future__ import annotations

import argparse
import json
import os
import sys

from bridge_hook_common import codex_stop_reason, queue_attention_message, queue_summary


def load_event() -> dict:
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=("text", "codex"), default="text")
    args = parser.parse_args(argv)

    agent = os.environ.get("BRIDGE_AGENT_ID", "").strip()
    if not agent:
        if args.format == "codex":
            json.dump({}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
        return 0

    if args.format == "codex":
        event = load_event()
        if bool(event.get("stop_hook_active")):
            json.dump({}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
            return 0

    pending, row = queue_summary(agent)
    if pending == 0 or row is None:
        if args.format == "codex":
            json.dump({}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
        return 0

    if args.format == "codex":
        json.dump(
            {
                "decision": "block",
                "reason": codex_stop_reason(agent, row),
                "hookSpecificOutput": {
                    "hookEventName": "Stop",
                    "additionalContext": f"Queue DB is source of truth for {agent}.",
                },
            },
            sys.stdout,
            ensure_ascii=False,
        )
        sys.stdout.write("\n")
        return 0

    sys.stdout.write(queue_attention_message(agent, pending, row))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
