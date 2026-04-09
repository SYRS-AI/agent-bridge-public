#!/usr/bin/env python3
"""Shared Agent Bridge hook helpers for Claude Code and Codex."""

from __future__ import annotations

import json
import os
import sqlite3
from datetime import datetime, timezone
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


def bridge_state_dir() -> Path:
    explicit = os.environ.get("BRIDGE_STATE_DIR", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()
    if bridge_home:
        return Path(bridge_home).expanduser() / "state"
    return Path.home() / ".agent-bridge" / "state"


def timestamp_state_path(agent: str) -> Path:
    return bridge_state_dir() / "timestamps" / f"{agent}.json"


def load_timestamp_state(agent: str) -> dict[str, int]:
    path = timestamp_state_path(agent)
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(payload, dict):
        return {}
    state: dict[str, int] = {}
    for key in ("session_started_at", "last_prompt_at"):
        value = payload.get(key)
        if isinstance(value, int):
            state[key] = value
    return state


def save_timestamp_state(agent: str, payload: dict[str, int]) -> None:
    path = timestamp_state_path(agent)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def agent_timestamp_enabled(agent: str) -> bool:
    raw = os.environ.get("BRIDGE_AGENT_INJECT_TIMESTAMP", "").strip().lower()
    if not raw:
        return True
    return raw not in {"0", "false", "no", "off"}


def format_duration(seconds: int | None) -> str:
    if seconds is None:
        return "(first message)"
    if seconds < 0:
        seconds = 0
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    parts: list[str] = []
    if hours:
        parts.append(f"{hours}h")
    if minutes or hours:
        parts.append(f"{minutes}m")
    parts.append(f"{secs}s")
    return " ".join(parts)


def remember_session_start(agent: str, now_epoch: int | None = None) -> None:
    if not agent_timestamp_enabled(agent):
        return
    now_epoch = now_epoch or int(datetime.now(timezone.utc).timestamp())
    state = load_timestamp_state(agent)
    changed = False
    if "session_started_at" not in state:
        state["session_started_at"] = now_epoch
        changed = True
    if changed:
        save_timestamp_state(agent, state)


def prompt_timestamp_context(agent: str, now: datetime | None = None) -> str:
    now_dt = now or datetime.now().astimezone()
    now_epoch = int(now_dt.timestamp())
    state = load_timestamp_state(agent)
    session_started_at = state.get("session_started_at", now_epoch)
    last_prompt_at = state.get("last_prompt_at")
    context = (
        "<timestamp>\n"
        f"now: {now_dt.strftime('%Y-%m-%d %H:%M:%S %Z (%a)')}\n"
        f"since_last: {format_duration(None if last_prompt_at is None else now_epoch - last_prompt_at)}\n"
        f"session_age: {format_duration(now_epoch - session_started_at)}\n"
        "</timestamp>\n"
        "<question_escalation>\n"
        "If you are about to ask the user the same unanswered question a second time, escalate before asking again.\n"
        f"Run exactly: ~/.agent-bridge/agent-bridge escalate question --agent {agent} --question \"<question>\" --context \"<why you need the answer>\"\n"
        "Use --wait-seconds when the elapsed wait materially matters.\n"
        "</question_escalation>"
    )
    state["session_started_at"] = session_started_at
    state["last_prompt_at"] = now_epoch
    save_timestamp_state(agent, state)
    return context


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
