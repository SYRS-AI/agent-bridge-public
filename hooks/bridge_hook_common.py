#!/usr/bin/env python3
"""Shared Agent Bridge hook helpers for Claude Code and Codex."""

from __future__ import annotations

import os
import sqlite3
from pathlib import Path

PRIORITY_ORDER = {"urgent": 0, "high": 1, "normal": 2, "low": 3}


def bridge_task_db() -> Path:
    explicit = os.environ.get("BRIDGE_TASK_DB", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()
    if bridge_home:
        return Path(bridge_home).expanduser() / "state" / "tasks.db"
    return Path.home() / ".agent-bridge" / "state" / "tasks.db"


def session_start_context(agent: str) -> str:
    return (
        f"Agent Bridge queue protocol applies to {agent}. "
        f"Queue DB is source of truth. "
        f"When a task boundary is reached or Agent Bridge asks for attention, "
        f"run exactly: ~/.agent-bridge/agb inbox {agent}. "
        f"If a task is queued, claim the highest-priority one first. "
        f"If a task is already claimed by you, continue that task."
    )


def queue_summary(agent: str) -> tuple[int, sqlite3.Row | None]:
    task_db = bridge_task_db()
    if not task_db.exists():
        return 0, None

    with sqlite3.connect(task_db) as conn:
        conn.row_factory = sqlite3.Row
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
        return 0, None

    ordered = sorted(
        rows,
        key=lambda row: (
            PRIORITY_ORDER.get(str(row["priority"] or "normal"), 99),
            int(row["id"]),
        ),
    )
    return len(rows), ordered[0]


def queue_attention_message(agent: str, pending: int, row: sqlite3.Row | None) -> str:
    lines = [f"[Agent Bridge] {pending} pending task(s) for {agent}."]
    if row is not None:
        lines.append(
            f"Highest priority: Task #{int(row['id'])} [{str(row['priority'] or 'normal')}] {str(row['title'] or '')}"
        )
    lines.append("ACTION REQUIRED: Use your Bash tool now. Do not acknowledge or reply conversationally first.")
    lines.append(f"Run exactly: ~/.agent-bridge/agb inbox {agent}")
    lines.append("If tasks are listed, show and claim the first one immediately.")
    lines.append("Queue DB is source of truth.")
    return "\n".join(lines)


def codex_stop_reason(agent: str, row: sqlite3.Row) -> str:
    task_id = int(row["id"])
    title = str(row["title"] or "")
    priority = str(row["priority"] or "normal")
    status = str(row["status"] or "")
    if status == "claimed":
        return (
            f"Agent Bridge still has open claimed work for you: task #{task_id} "
            f"[{priority}] {title}. "
            f"Run ~/.agent-bridge/agb inbox {agent} now, inspect the open tasks, "
            f"and continue the claimed task instead of ending the session."
        )
    return (
        f"Agent Bridge queued work is waiting: task #{task_id} "
        f"[{priority}] {title}. "
        f"Run ~/.agent-bridge/agb inbox {agent} now, inspect the open tasks, "
        f"and claim the highest-priority queued task before ending the session."
    )
