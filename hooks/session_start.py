#!/usr/bin/env python3
"""Shared Agent Bridge SessionStart hook.

Matcher handling (Track 2):
- Claude Code fires this hook with a `matcher` field when settings.json
  uses matcher-based entries. Known values: `startup`, `resume`, `compact`.
- The hook reads the matcher from `--matcher` first, then a JSON payload
  on stdin (Claude Code hands `{"matcher": "compact", ...}` in via stdin).
- For `compact`, the hook appends a short note telling the session that
  it just came out of a compaction, pointing at the raw capture store.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

from bridge_hook_common import (
    bridge_state_dir,
    remember_session_start,
    session_start_context,
)


_KNOWN_MATCHERS = {"startup", "resume", "compact"}
# Compaction typically fires the SessionStart hook once, but upstream may
# redeliver (retries, nested session-resumes). Suppress duplicate compact
# notes that arrive within this window so the note is emitted at most once
# per logical compact event.
_COMPACT_NOTE_DEDUP_SECONDS = 300


def _matcher_from_stdin() -> str:
    """Read the matcher value from a JSON payload on stdin (if present)."""
    if sys.stdin.isatty():
        return ""
    raw = sys.stdin.read() or ""
    if not raw.strip():
        return ""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return ""
    return str(data.get("matcher") or data.get("source") or "").strip().lower()


def _compact_note() -> str:
    return (
        "\n\n---\n"
        "This session resumed from a compaction. Prior conversation content has been\n"
        "summarized automatically; recent capture notes may be available via\n"
        "`bridge-memory search --scope raw --query <keyword>`.\n"
    )


def _compact_note_marker(agent: str) -> Path:
    return bridge_state_dir() / "agents" / agent / "compact-note-last-ts"


def _compact_note_should_emit(agent: str, now_epoch: int | None = None) -> bool:
    """Return True iff we should emit the compact note for this invocation.

    The marker stores the epoch of the last emission. If the previous
    emission is within the dedup window we suppress; otherwise we update
    the marker and emit. This stops duplicate compact notes when the
    SessionStart hook is redelivered for the same underlying compact.
    """
    now_epoch = now_epoch or int(time.time())
    marker = _compact_note_marker(agent)
    try:
        previous = int(marker.read_text(encoding="utf-8").strip() or "0")
    except (OSError, ValueError):
        previous = 0
    if previous and now_epoch - previous < _COMPACT_NOTE_DEDUP_SECONDS:
        return False
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        tmp = marker.with_suffix(".tmp")
        tmp.write_text(f"{now_epoch}\n", encoding="utf-8")
        tmp.replace(marker)
    except OSError:
        # Failing to write the marker must not block the hook from
        # serving the session; worst case the dedup is a no-op.
        return True
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=("text", "codex"), default="text")
    parser.add_argument(
        "--matcher",
        default="",
        help="Claude Code matcher (startup|resume|compact); overrides stdin payload",
    )
    args = parser.parse_args(argv)

    agent = os.environ.get("BRIDGE_AGENT_ID", "").strip()
    if not agent:
        if args.format == "codex":
            json.dump({}, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")
        return 0

    matcher = (args.matcher or _matcher_from_stdin()).lower()
    if matcher and matcher not in _KNOWN_MATCHERS:
        matcher = ""

    remember_session_start(agent)
    context = session_start_context(agent)
    if matcher == "compact" and _compact_note_should_emit(agent):
        context = context + _compact_note()

    if args.format == "codex":
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "matcher": matcher or "startup",
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
