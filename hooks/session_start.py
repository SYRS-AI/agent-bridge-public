#!/usr/bin/env python3
"""Shared Agent Bridge SessionStart hook."""

from __future__ import annotations

import argparse
import json
import os
import sys

from bridge_hook_common import session_start_context


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

    context = session_start_context(agent)
    if args.format == "codex":
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "additionalContext": context,
                }
            },
            sys.stdout,
            ensure_ascii=False,
        )
        sys.stdout.write("\n")
        return 0

    sys.stdout.write(context)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
