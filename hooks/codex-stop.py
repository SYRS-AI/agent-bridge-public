#!/usr/bin/env python3
"""Agent Bridge Codex Stop hook."""

from __future__ import annotations

import json
import os
import sqlite3
import sys
from pathlib import Path


PRIORITY_ORDER = {"urgent": 0, "high": 1, "normal": 2, "low": 3}


def empty_response() -> int:
    json.dump({}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def load_event() -> dict:
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    if isinstance(data, dict):
        return data
    return {}


def bridge_task_db() -> Path:
    explicit = os.environ.get("BRIDGE_TASK_DB", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()
    if bridge_home:
        return Path(bridge_home).expanduser() / "state" / "tasks.db"
    return Path.home() / ".agent-bridge" / "state" / "tasks.db"


def highest_priority_task(conn: sqlite3.Connection, agent: str) -> sqlite3.Row | None:
    rows = conn.execute(
        """
        SELECT id, title, priority, status, assigned_to, claimed_by
        FROM tasks
        WHERE (
            assigned_to = ?
            AND status IN ('queued', 'blocked')
        ) OR (
            claimed_by = ?
            AND status = 'claimed'
        )
        """,
        (agent, agent),
    ).fetchall()
    if not rows:
        return None
    rows = sorted(
        rows,
        key=lambda row: (
            PRIORITY_ORDER.get(str(row["priority"] or "normal"), 99),
            int(row["id"]),
        ),
    )
    return rows[0]


def main() -> int:
    agent = os.environ.get("BRIDGE_AGENT_ID", "").strip()
    if not agent:
        return empty_response()

    event = load_event()
    if bool(event.get("stop_hook_active")):
        return empty_response()

    task_db = bridge_task_db()
    if not task_db.exists():
        return empty_response()

    with sqlite3.connect(task_db) as conn:
        conn.row_factory = sqlite3.Row
        row = highest_priority_task(conn, agent)

    if row is None:
        return empty_response()

    task_id = int(row["id"])
    title = str(row["title"] or "")
    priority = str(row["priority"] or "normal")
    status = str(row["status"] or "")

    if status == "claimed":
        action = (
            f"Agent Bridge still has open claimed work for you: task #{task_id} "
            f"[{priority}] {title}. "
            f"Run ~/.agent-bridge/agb inbox {agent} now, inspect the open tasks, "
            f"and continue the claimed task instead of ending the session."
        )
    else:
        action = (
            f"Agent Bridge queued work is waiting: task #{task_id} "
            f"[{priority}] {title}. "
            f"Run ~/.agent-bridge/agb inbox {agent} now, inspect the open tasks, "
            f"and claim the highest-priority queued task before ending the session."
        )

    payload = {
        "decision": "block",
        "reason": action,
        "hookSpecificOutput": {
            "hookEventName": "Stop",
            "additionalContext": f"Queue DB is source of truth for {agent}.",
        },
    }
    json.dump(payload, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
