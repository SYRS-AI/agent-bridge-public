#!/usr/bin/env python3
"""SQLite-backed task queue for Agent Bridge."""

from __future__ import annotations

import argparse
import csv
import os
import shlex
import sqlite3
import sys
import time
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


OPEN_STATUSES = ("queued", "claimed", "blocked")
PRIORITY_CHOICES = ("low", "normal", "high", "urgent")
STATUS_CHOICES = ("queued", "claimed", "blocked", "done", "cancelled")


def now_ts() -> int:
    return int(time.time())


def isoformat_ts(value: int | None) -> str:
    if not value:
        return "-"
    return datetime.fromtimestamp(int(value), tz=timezone.utc).astimezone().isoformat(timespec="seconds")


def get_db_path() -> Path:
    bridge_home = Path(os.environ.get("BRIDGE_HOME", str(Path.home() / "agent-bridge")))
    state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", str(bridge_home / "state")))
    db_path = Path(os.environ.get("BRIDGE_TASK_DB", str(state_dir / "tasks.db")))
    db_path.parent.mkdir(parents=True, exist_ok=True)
    return db_path


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(get_db_path())
    conn.row_factory = sqlite3.Row
    with conn:
      conn.execute("PRAGMA journal_mode=WAL")
      conn.execute("PRAGMA foreign_keys=ON")
    init_db(conn)
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    with conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              title TEXT NOT NULL,
              assigned_to TEXT NOT NULL,
              created_by TEXT NOT NULL,
              priority TEXT NOT NULL DEFAULT 'normal',
              status TEXT NOT NULL DEFAULT 'queued',
              created_ts INTEGER NOT NULL,
              updated_ts INTEGER NOT NULL,
              body_text TEXT,
              body_path TEXT,
              claimed_by TEXT,
              claimed_ts INTEGER,
              lease_until_ts INTEGER,
              closed_ts INTEGER
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS task_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
              event_type TEXT NOT NULL,
              actor TEXT NOT NULL,
              created_ts INTEGER NOT NULL,
              note_text TEXT,
              note_path TEXT,
              from_agent TEXT,
              to_agent TEXT
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS agent_state (
              agent TEXT PRIMARY KEY,
              engine TEXT,
              session TEXT,
              workdir TEXT,
              active INTEGER NOT NULL DEFAULT 0,
              last_seen_ts INTEGER,
              last_heartbeat_ts INTEGER,
              session_activity_ts INTEGER,
              last_nudge_ts INTEGER,
              last_nudge_key TEXT
            )
            """
        )
        ensure_column(conn, "agent_state", "last_nudge_key", "TEXT")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_assigned_status ON tasks(assigned_to, status)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_claimed_status ON tasks(claimed_by, status)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_lease ON tasks(status, lease_until_ts)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_task_events_task ON task_events(task_id, created_ts)")


def ensure_column(conn: sqlite3.Connection, table: str, column: str, spec: str) -> None:
    existing = {row["name"] for row in conn.execute(f"PRAGMA table_info({table})")}
    if column in existing:
        return
    conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {spec}")


def normalize_path(path_value: str | None) -> str | None:
    if not path_value:
        return None
    path = Path(path_value).expanduser()
    if not path.exists():
        raise SystemExit(f"file not found: {path_value}")
    return str(path.resolve())


def emit_event(
    conn: sqlite3.Connection,
    task_id: int,
    *,
    event_type: str,
    actor: str,
    created_ts: int,
    note_text: str | None = None,
    note_path: str | None = None,
    from_agent: str | None = None,
    to_agent: str | None = None,
) -> None:
    conn.execute(
        """
        INSERT INTO task_events (
          task_id, event_type, actor, created_ts, note_text, note_path, from_agent, to_agent
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (task_id, event_type, actor, created_ts, note_text, note_path, from_agent, to_agent),
    )


def require_task(conn: sqlite3.Connection, task_id: int) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    if row is None:
        raise SystemExit(f"task not found: {task_id}")
    return row


def priority_sort_sql() -> str:
    return """
      CASE priority
        WHEN 'urgent' THEN 0
        WHEN 'high' THEN 1
        WHEN 'normal' THEN 2
        WHEN 'low' THEN 3
        ELSE 4
      END
    """


def agent_summary_rows(conn: sqlite3.Connection, agents: Iterable[str] | None) -> list[sqlite3.Row]:
    names = [name for name in agents or [] if name]
    params: list[object] = []
    if names:
        values_sql = " UNION ALL ".join(["SELECT ? AS agent"] * len(names))
        params.extend(names)
        base_sql = f"WITH requested AS ({values_sql}) SELECT agent FROM requested"
    else:
        base_sql = """
            SELECT agent FROM agent_state
            UNION
            SELECT assigned_to AS agent FROM tasks
            UNION
            SELECT claimed_by AS agent FROM tasks WHERE claimed_by IS NOT NULL
        """

    sql = f"""
        WITH agent_names AS (
          {base_sql}
        ),
        assigned AS (
          SELECT
            assigned_to AS agent,
            SUM(CASE WHEN status = 'queued' AND title NOT LIKE '[cron-dispatch]%' THEN 1 ELSE 0 END) AS queued_count,
            SUM(CASE WHEN status = 'blocked' AND title NOT LIKE '[cron-dispatch]%' THEN 1 ELSE 0 END) AS blocked_count
          FROM tasks
          GROUP BY assigned_to
        ),
        claimed AS (
          SELECT claimed_by AS agent, COUNT(*) AS claimed_count
          FROM tasks
          WHERE status = 'claimed' AND claimed_by IS NOT NULL
          GROUP BY claimed_by
        )
        SELECT
          agent_names.agent,
          COALESCE(assigned.queued_count, 0) AS queued_count,
          COALESCE(assigned.blocked_count, 0) AS blocked_count,
          COALESCE(claimed.claimed_count, 0) AS claimed_count,
          COALESCE(agent_state.active, 0) AS active,
          agent_state.last_seen_ts,
          agent_state.last_heartbeat_ts,
          agent_state.session_activity_ts,
          agent_state.last_nudge_ts,
          COALESCE(agent_state.session, '') AS session,
          COALESCE(agent_state.engine, '') AS engine,
          COALESCE(agent_state.workdir, '') AS workdir
        FROM agent_names
        LEFT JOIN assigned ON assigned.agent = agent_names.agent
        LEFT JOIN claimed ON claimed.agent = agent_names.agent
        LEFT JOIN agent_state ON agent_state.agent = agent_names.agent
        ORDER BY agent_names.agent
    """
    return conn.execute(sql, params).fetchall()


def print_summary(rows: list[sqlite3.Row], fmt: str) -> None:
    if fmt == "tsv":
        for row in rows:
            activity_ts = row["session_activity_ts"] or row["last_seen_ts"] or 0
            idle_seconds = max(0, now_ts() - int(activity_ts)) if activity_ts else -1
            fields = [
                row["agent"],
                str(row["queued_count"]),
                str(row["claimed_count"]),
                str(row["blocked_count"]),
                str(row["active"]),
                str(idle_seconds),
                str(row["last_seen_ts"] or 0),
                str(row["last_nudge_ts"] or 0),
                row["session"],
                row["engine"],
                row["workdir"],
            ]
            print("\t".join(fields))
        return

    if not rows:
        print("(agent summary empty)")
        return

    print("agent       queued  claimed  blocked  active  idle  session")
    for row in rows:
        activity_ts = row["session_activity_ts"] or row["last_seen_ts"] or 0
        idle_seconds = max(0, now_ts() - int(activity_ts)) if activity_ts else -1
        idle_label = "-" if idle_seconds < 0 else f"{idle_seconds}s"
        print(
            f"{row['agent']:<10} {row['queued_count']:>6}  {row['claimed_count']:>7}  "
            f"{row['blocked_count']:>7}  {row['active']:>6}  {idle_label:>5}  {row['session'] or '-'}"
        )


def cmd_create(args: argparse.Namespace) -> int:
    actor = args.actor or os.environ.get("USER", "unknown")
    body_path = normalize_path(args.body_file)
    body_text = args.body
    created_ts = now_ts()

    with closing(connect()) as conn, conn:
        cursor = conn.execute(
            """
            INSERT INTO tasks (
              title, assigned_to, created_by, priority, status, created_ts, updated_ts, body_text, body_path
            ) VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?)
            """,
            (
                args.title.strip(),
                args.assigned_to,
                actor,
                args.priority,
                created_ts,
                created_ts,
                body_text,
                body_path,
            ),
        )
        task_id = int(cursor.lastrowid)
        emit_event(
            conn,
            task_id,
            event_type="created",
            actor=actor,
            created_ts=created_ts,
            note_text=body_text,
            note_path=body_path,
            to_agent=args.assigned_to,
        )

    if args.format == "shell":
        fields = {
            "TASK_ID": task_id,
            "TASK_TITLE": args.title.strip(),
            "TASK_ASSIGNED_TO": args.assigned_to,
            "TASK_CREATED_BY": actor,
            "TASK_PRIORITY": args.priority,
            "TASK_BODY_PATH": body_path or "",
            "TASK_BODY_TEXT": body_text or "",
        }
        for key, value in fields.items():
            print(f"{key}={shlex.quote(str(value))}")
        return 0

    print(f"created task #{task_id} for {args.assigned_to} [{args.priority}] {args.title.strip()}")
    return 0


def cmd_inbox(args: argparse.Namespace) -> int:
    statuses = list(args.status or [])
    if args.all:
        statuses = list(STATUS_CHOICES)
    if not statuses:
        statuses = list(OPEN_STATUSES)

    placeholders = ",".join(["?"] * len(statuses))
    params: list[object] = [args.agent, *statuses]
    sql = f"""
        SELECT id, status, priority, title, updated_ts, created_by, claimed_by, body_path
        FROM tasks
        WHERE assigned_to = ?
          AND status IN ({placeholders})
        ORDER BY {priority_sort_sql()}, CASE status WHEN 'claimed' THEN 0 WHEN 'queued' THEN 1 ELSE 2 END, id
    """

    with closing(connect()) as conn:
        rows = conn.execute(sql, params).fetchall()

    if not rows:
        print(f"(inbox empty for {args.agent})")
        return 0

    print(f"inbox: {args.agent}")
    print("id  status   priority  owner      title")
    for row in rows:
        owner = row["claimed_by"] or row["created_by"]
        print(f"{row['id']:<3} {row['status']:<8} {row['priority']:<8} {owner:<10} {row['title']}")
        if row["body_path"]:
            print(f"    file: {row['body_path']}")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    with closing(connect()) as conn:
        task = require_task(conn, args.task_id)
        events = conn.execute(
            """
            SELECT event_type, actor, created_ts, note_text, note_path, from_agent, to_agent
            FROM task_events
            WHERE task_id = ?
            ORDER BY id
            """,
            (args.task_id,),
        ).fetchall()

    if args.format == "shell":
        fields = {
            "TASK_ID": task["id"],
            "TASK_TITLE": task["title"],
            "TASK_STATUS": task["status"],
            "TASK_ASSIGNED_TO": task["assigned_to"],
            "TASK_CREATED_BY": task["created_by"],
            "TASK_PRIORITY": task["priority"],
            "TASK_CLAIMED_BY": task["claimed_by"] or "",
            "TASK_BODY_PATH": task["body_path"] or "",
        }
        for key, value in fields.items():
            print(f"{key}={shlex.quote(str(value))}")
        return 0

    print(f"task #{task['id']}: {task['title']}")
    print(f"status: {task['status']}")
    print(f"assigned_to: {task['assigned_to']}")
    print(f"created_by: {task['created_by']}")
    print(f"priority: {task['priority']}")
    print(f"created_at: {isoformat_ts(task['created_ts'])}")
    print(f"updated_at: {isoformat_ts(task['updated_ts'])}")
    print(f"claimed_by: {task['claimed_by'] or '-'}")
    print(f"lease_until: {isoformat_ts(task['lease_until_ts'])}")
    if task["body_text"]:
        print("body:")
        print(task["body_text"])
    if task["body_path"]:
        print(f"body_file: {task['body_path']}")
    print("")
    print("events:")
    for event in events:
        transfer = ""
        if event["from_agent"] or event["to_agent"]:
            transfer = f" ({event['from_agent'] or '-'} -> {event['to_agent'] or '-'})"
        print(f"- {isoformat_ts(event['created_ts'])} {event['event_type']} by {event['actor']}{transfer}")
        if event["note_text"]:
            print(f"  note: {event['note_text']}")
        if event["note_path"]:
            print(f"  file: {event['note_path']}")
    return 0


def cmd_claim(args: argparse.Namespace) -> int:
    agent = args.agent
    lease_seconds = int(args.lease_seconds)
    current_ts = now_ts()
    lease_until_ts = current_ts + lease_seconds

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if task["status"] == "claimed" and task["claimed_by"] == agent:
            conn.execute(
                "UPDATE tasks SET lease_until_ts = ? WHERE id = ?",
                (lease_until_ts, args.task_id),
            )
            print(f"task #{args.task_id} already claimed by {agent}; lease extended")
            return 0

        if task["status"] != "queued":
            raise SystemExit(f"task #{args.task_id} is not claimable (status={task['status']})")
        if task["assigned_to"] != agent:
            raise SystemExit(f"task #{args.task_id} is assigned to {task['assigned_to']}, not {agent}")

        conn.execute(
            """
            UPDATE tasks
            SET status = 'claimed',
                claimed_by = ?,
                claimed_ts = ?,
                lease_until_ts = ?,
                updated_ts = ?
            WHERE id = ?
            """,
            (agent, current_ts, lease_until_ts, current_ts, args.task_id),
        )
        emit_event(conn, args.task_id, event_type="claimed", actor=agent, created_ts=current_ts, to_agent=agent)

    print(f"claimed task #{args.task_id} as {agent} (lease={lease_seconds}s)")
    return 0


def cmd_done(args: argparse.Namespace) -> int:
    agent = args.agent
    note_path = normalize_path(args.note_file)
    current_ts = now_ts()

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if task["status"] == "done":
            print(f"task #{args.task_id} already done")
            return 0
        if task["assigned_to"] != agent and task["claimed_by"] not in (None, agent):
            raise SystemExit(f"task #{args.task_id} is owned by {task['claimed_by']}, not {agent}")

        conn.execute(
            """
            UPDATE tasks
            SET status = 'done',
                claimed_by = NULL,
                claimed_ts = NULL,
                lease_until_ts = NULL,
                updated_ts = ?,
                closed_ts = ?
            WHERE id = ?
            """,
            (current_ts, current_ts, args.task_id),
        )
        emit_event(
            conn,
            args.task_id,
            event_type="done",
            actor=agent,
            created_ts=current_ts,
            note_text=args.note,
            note_path=note_path,
            from_agent=agent,
            to_agent=task["assigned_to"],
        )

    print(f"completed task #{args.task_id} as {agent}")
    return 0


def cmd_handoff(args: argparse.Namespace) -> int:
    actor = args.actor or os.environ.get("USER", "unknown")
    note_path = normalize_path(args.note_file)
    current_ts = now_ts()

    with closing(connect()) as conn, conn:
        task = require_task(conn, args.task_id)
        if task["status"] in ("done", "cancelled"):
            raise SystemExit(f"task #{args.task_id} is already closed (status={task['status']})")

        conn.execute(
            """
            UPDATE tasks
            SET assigned_to = ?,
                status = 'queued',
                claimed_by = NULL,
                claimed_ts = NULL,
                lease_until_ts = NULL,
                updated_ts = ?
            WHERE id = ?
            """,
            (args.assigned_to, current_ts, args.task_id),
        )
        emit_event(
            conn,
            args.task_id,
            event_type="handoff",
            actor=actor,
            created_ts=current_ts,
            note_text=args.note,
            note_path=note_path,
            from_agent=task["assigned_to"],
            to_agent=args.assigned_to,
        )

    print(f"handed off task #{args.task_id} to {args.assigned_to}")
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    with closing(connect()) as conn:
        rows = agent_summary_rows(conn, args.agent)
    print_summary(rows, args.format)
    return 0


def cmd_cron_ready(args: argparse.Namespace) -> int:
    sql = """
        SELECT id, assigned_to, priority, title, body_path
        FROM tasks
        WHERE status = 'queued'
          AND title LIKE '[cron-dispatch]%'
        ORDER BY id
        LIMIT ?
    """

    with closing(connect()) as conn:
        rows = conn.execute(sql, (int(args.limit),)).fetchall()

    if args.format == "tsv":
        for row in rows:
            print(
                "\t".join(
                    [
                        str(row["id"]),
                        str(row["assigned_to"]),
                        str(row["priority"]),
                        str(row["title"]),
                        str(row["body_path"] or ""),
                    ]
                )
            )
        return 0

    if not rows:
        print("(no queued cron-dispatch tasks)")
        return 0

    print("id  assigned_to  priority  title")
    for row in rows:
        print(f"{row['id']:<3} {row['assigned_to']:<11} {row['priority']:<8} {row['title']}")
        if row["body_path"]:
            print(f"    file: {row['body_path']}")
    return 0


def load_snapshot(path: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with open(path, "r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            if row.get("agent"):
                rows.append(row)
    return rows


def cmd_daemon_step(args: argparse.Namespace) -> int:
    snapshot_rows = load_snapshot(args.snapshot)
    current_ts = now_ts()
    lease_seconds = int(args.lease_seconds)
    heartbeat_window = int(args.heartbeat_window)
    idle_threshold = int(args.idle_threshold)
    nudge_cooldown = int(args.nudge_cooldown)
    queued_ids_by_agent: dict[str, list[int]] = {}

    with closing(connect()) as conn, conn:
        for row in snapshot_rows:
            active = 1 if str(row.get("active", "0")) == "1" else 0
            activity_ts = int(row.get("session_activity_ts") or 0)
            conn.execute(
                """
                INSERT INTO agent_state (
                  agent, engine, session, workdir, active, last_seen_ts, last_heartbeat_ts, session_activity_ts
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(agent) DO UPDATE SET
                  engine = excluded.engine,
                  session = excluded.session,
                  workdir = excluded.workdir,
                  active = excluded.active,
                  last_seen_ts = excluded.last_seen_ts,
                  last_heartbeat_ts = excluded.last_heartbeat_ts,
                  session_activity_ts = excluded.session_activity_ts
                """,
                (
                    row["agent"],
                    row.get("engine", ""),
                    row.get("session", ""),
                    row.get("workdir", ""),
                    active,
                    current_ts if active else None,
                    current_ts,
                    activity_ts or None,
                ),
            )

        for row in snapshot_rows:
            active = 1 if str(row.get("active", "0")) == "1" else 0
            activity_ts = int(row.get("session_activity_ts") or 0)
            if not active or not activity_ts:
                continue
            if current_ts - activity_ts > heartbeat_window:
                continue
            conn.execute(
                """
                UPDATE tasks
                SET lease_until_ts = CASE
                  WHEN lease_until_ts IS NULL OR lease_until_ts < ? THEN ?
                  ELSE lease_until_ts
                END
                WHERE status = 'claimed' AND claimed_by = ?
                """,
                (current_ts + lease_seconds, current_ts + lease_seconds, row["agent"]),
            )

        expired = conn.execute(
            """
            SELECT id, claimed_by
            FROM tasks
            WHERE status = 'claimed'
              AND lease_until_ts IS NOT NULL
              AND lease_until_ts < ?
            """,
            (current_ts,),
        ).fetchall()
        for row in expired:
            conn.execute(
                """
                UPDATE tasks
                SET status = 'queued',
                    claimed_by = NULL,
                    claimed_ts = NULL,
                    lease_until_ts = NULL,
                    updated_ts = ?
                WHERE id = ?
                """,
                (current_ts, row["id"]),
            )
            emit_event(
                conn,
                int(row["id"]),
                event_type="lease_expired",
                actor="daemon",
                created_ts=current_ts,
                note_text="lease expired after missing heartbeat",
                from_agent=row["claimed_by"],
            )

        rows = conn.execute(
            """
            SELECT assigned_to, id
            FROM tasks
            WHERE status = 'queued'
              AND title NOT LIKE '[cron-dispatch]%'
            ORDER BY assigned_to, id
            """
        ).fetchall()
        for row in rows:
            queued_ids_by_agent.setdefault(str(row["assigned_to"]), []).append(int(row["id"]))

        rows = conn.execute(
            f"""
            WITH assigned AS (
              SELECT assigned_to AS agent, COUNT(*) AS queued_count
              FROM tasks
              WHERE status = 'queued'
                AND title NOT LIKE '[cron-dispatch]%'
              GROUP BY assigned_to
            ),
            claimed AS (
              SELECT claimed_by AS agent, COUNT(*) AS claimed_count
              FROM tasks
              WHERE status = 'claimed' AND claimed_by IS NOT NULL
              GROUP BY claimed_by
            )
            SELECT
              agent_state.agent,
              agent_state.session,
              COALESCE(assigned.queued_count, 0) AS queued_count,
              COALESCE(claimed.claimed_count, 0) AS claimed_count,
              agent_state.session_activity_ts,
              agent_state.last_seen_ts,
              agent_state.last_nudge_ts,
              agent_state.last_nudge_key
            FROM agent_state
            LEFT JOIN assigned ON assigned.agent = agent_state.agent
            LEFT JOIN claimed ON claimed.agent = agent_state.agent
            WHERE agent_state.active = 1
              AND COALESCE(assigned.queued_count, 0) > 0
              AND COALESCE(claimed.claimed_count, 0) = 0
            ORDER BY agent_state.agent
            """
        ).fetchall()

    printed = False
    for row in rows:
        activity_ts = row["session_activity_ts"] or row["last_seen_ts"] or 0
        if not activity_ts:
            continue
        idle_seconds = max(0, current_ts - int(activity_ts))
        if idle_seconds < idle_threshold:
            continue
        queue_ids = queued_ids_by_agent.get(str(row["agent"]), [])
        if not queue_ids:
            continue
        nudge_key = ",".join(str(task_id) for task_id in queue_ids)
        last_nudge_ts = int(row["last_nudge_ts"] or 0)
        last_nudge_key = row["last_nudge_key"] or ""
        last_nudged_ids = {item for item in last_nudge_key.split(",") if item}
        has_new_queue_ids = any(str(task_id) not in last_nudged_ids for task_id in queue_ids)
        if last_nudge_ts and current_ts - last_nudge_ts < nudge_cooldown and not has_new_queue_ids:
            continue
        # Suppress repeats for the same queue until the session shows activity again,
        # but allow a fresh nudge when new queued task ids arrive.
        if last_nudge_ts and int(activity_ts) and last_nudge_ts >= int(activity_ts) and not has_new_queue_ids:
            continue
        printed = True
        print(
            "\t".join(
                [
                    row["agent"],
                    row["session"],
                    str(row["queued_count"]),
                    str(row["claimed_count"]),
                    str(idle_seconds),
                    nudge_key,
                ]
            )
        )

    if args.format == "text" and not printed:
        print("(no nudge candidates)")
    return 0


def cmd_note_nudge(args: argparse.Namespace) -> int:
    current_ts = now_ts()
    with closing(connect()) as conn, conn:
        conn.execute(
            """
            INSERT INTO agent_state (agent, last_nudge_ts, last_nudge_key)
            VALUES (?, ?, ?)
            ON CONFLICT(agent) DO UPDATE SET
              last_nudge_ts = excluded.last_nudge_ts,
              last_nudge_key = excluded.last_nudge_key
            """,
            (args.agent, current_ts, args.key),
        )
    print(f"recorded nudge for {args.agent}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-queue.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("init")

    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--to", dest="assigned_to", required=True)
    create_parser.add_argument("--title", required=True)
    create_parser.add_argument("--from", dest="actor")
    create_parser.add_argument("--priority", choices=PRIORITY_CHOICES, default="normal")
    create_parser.add_argument("--format", choices=("text", "shell"), default="text")
    body_group = create_parser.add_mutually_exclusive_group()
    body_group.add_argument("--body")
    body_group.add_argument("--body-file")
    create_parser.set_defaults(handler=cmd_create)

    inbox_parser = subparsers.add_parser("inbox")
    inbox_parser.add_argument("--agent", required=True)
    inbox_parser.add_argument("--status", action="append", choices=STATUS_CHOICES)
    inbox_parser.add_argument("--all", action="store_true")
    inbox_parser.set_defaults(handler=cmd_inbox)

    show_parser = subparsers.add_parser("show")
    show_parser.add_argument("task_id", type=int)
    show_parser.add_argument("--format", choices=("text", "shell"), default="text")
    show_parser.set_defaults(handler=cmd_show)

    claim_parser = subparsers.add_parser("claim")
    claim_parser.add_argument("task_id", type=int)
    claim_parser.add_argument("--agent", required=True)
    claim_parser.add_argument("--lease-seconds", default=os.environ.get("BRIDGE_TASK_LEASE_SECONDS", "900"))
    claim_parser.set_defaults(handler=cmd_claim)

    done_parser = subparsers.add_parser("done")
    done_parser.add_argument("task_id", type=int)
    done_parser.add_argument("--agent", required=True)
    note_group = done_parser.add_mutually_exclusive_group()
    note_group.add_argument("--note")
    note_group.add_argument("--note-file")
    done_parser.set_defaults(handler=cmd_done)

    handoff_parser = subparsers.add_parser("handoff")
    handoff_parser.add_argument("task_id", type=int)
    handoff_parser.add_argument("--to", dest="assigned_to", required=True)
    handoff_parser.add_argument("--from", dest="actor")
    handoff_group = handoff_parser.add_mutually_exclusive_group()
    handoff_group.add_argument("--note")
    handoff_group.add_argument("--note-file")
    handoff_parser.set_defaults(handler=cmd_handoff)

    summary_parser = subparsers.add_parser("summary")
    summary_parser.add_argument("--agent", action="append")
    summary_parser.add_argument("--format", choices=("text", "tsv"), default="text")
    summary_parser.set_defaults(handler=cmd_summary)

    cron_ready_parser = subparsers.add_parser("cron-ready")
    cron_ready_parser.add_argument("--limit", type=int, default=50)
    cron_ready_parser.add_argument("--format", choices=("text", "tsv"), default="tsv")
    cron_ready_parser.set_defaults(handler=cmd_cron_ready)

    daemon_parser = subparsers.add_parser("daemon-step")
    daemon_parser.add_argument("--snapshot", required=True)
    daemon_parser.add_argument("--lease-seconds", default=os.environ.get("BRIDGE_TASK_LEASE_SECONDS", "900"))
    daemon_parser.add_argument(
        "--heartbeat-window",
        default=os.environ.get("BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS", "300"),
    )
    daemon_parser.add_argument(
        "--idle-threshold",
        default=os.environ.get("BRIDGE_TASK_IDLE_NUDGE_SECONDS", "120"),
    )
    daemon_parser.add_argument(
        "--nudge-cooldown",
        default=os.environ.get("BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS", "900"),
    )
    daemon_parser.add_argument("--format", choices=("text", "tsv"), default="tsv")
    daemon_parser.set_defaults(handler=cmd_daemon_step)

    nudge_parser = subparsers.add_parser("note-nudge")
    nudge_parser.add_argument("--agent", required=True)
    nudge_parser.add_argument("--key")
    nudge_parser.set_defaults(handler=cmd_note_nudge)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.command == "init":
        with closing(connect()):
            pass
        print(f"initialized task db at {get_db_path()}")
        return 0
    return int(args.handler(args))


if __name__ == "__main__":
    sys.exit(main())
