#!/usr/bin/env python3
"""Agent Bridge PreCompact hook — captures a lightweight session dump.

Claude Code fires this event right before `/compact` or an auto-compact
compresses the conversation. The hook writes a capture note so the
short-term memory thread survives the compaction. Failures are swallowed
and the hook always exits 0 — compaction must never be blocked.

Settings.json wiring (installed by bridge-hooks.py ensure-pre-compact-hook):

    {
      "PreCompact": [
        {
          "hooks": [{
            "type": "command",
            "command": "python3 <BRIDGE_HOME>/hooks/pre-compact.py",
            "timeout": 20
          }]
        }
      ]
    }
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def _bridge_home() -> Path:
    env_home = os.environ.get("BRIDGE_HOME")
    if env_home:
        return Path(env_home)
    # Hook scripts live at <bridge-home>/hooks/. Walk up.
    return Path(__file__).resolve().parent.parent


def _agent_id() -> str:
    return (os.environ.get("BRIDGE_AGENT_ID") or "").strip()


def _agent_home() -> Path | None:
    env_home = os.environ.get("BRIDGE_AGENT_HOME")
    if env_home:
        return Path(env_home)
    agent = _agent_id()
    if not agent:
        return None
    candidate = _bridge_home() / "agents" / agent
    return candidate if candidate.exists() else None


def _stdin_payload() -> dict:
    """Claude Code passes hook metadata as JSON on stdin (trigger, custom instructions, etc)."""
    if sys.stdin.isatty():
        return {}
    raw = sys.stdin.read() or ""
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def main() -> int:
    try:
        agent = _agent_id()
        home = _agent_home()
        if not agent or home is None:
            return 0
        payload = _stdin_payload()
        trigger = str(payload.get("trigger") or payload.get("reason") or "").strip() or "unknown"
        custom = str(payload.get("custom_instructions") or "").strip()
        capture_text_parts = [
            f"trigger={trigger}",
            f"agent={agent}",
            f"ts={datetime.now().astimezone().isoformat(timespec='seconds')}",
        ]
        if custom:
            # Keep the custom-instructions excerpt short; the full prompt
            # is in the session transcript which Claude Code handles on its
            # own side via compactPrompt.
            capture_text_parts.append(f"custom={custom[:500]}")
        capture_text = " | ".join(capture_text_parts)

        bridge_memory = _bridge_home() / "bridge-memory.py"
        template_root = _bridge_home() / "agents" / "_template"
        if not bridge_memory.exists():
            return 0
        cmd = [
            sys.executable or "python3",
            str(bridge_memory),
            "capture",
            "--agent", agent,
            "--home", str(home),
            "--template-root", str(template_root),
            "--source", "pre-compact-hook",
            "--title", f"pre-compact dump ({trigger})",
            "--text", capture_text,
        ]
        try:
            subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=False)
        except (OSError, subprocess.TimeoutExpired):
            pass
    except Exception:
        # Never block a compaction on hook failure.
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
