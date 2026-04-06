#!/usr/bin/env python3
"""Render a compact Agent Bridge dashboard from roster and queue state."""

from __future__ import annotations

import argparse
import csv
import os
import signal
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path


PRIORITY_ORDER = {"urgent": 0, "high": 1, "normal": 2, "low": 3}


def iso_now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def fmt_age(ts: int | None) -> str:
    if not ts:
        return "-"
    delta = max(0, int(datetime.now(timezone.utc).timestamp()) - int(ts))
    if delta < 60:
        return f"{delta}s"
    if delta < 3600:
        return f"{delta // 60}m"
    if delta < 86400:
        return f"{delta // 3600}h"
    return f"{delta // 86400}d"


def fmt_idle(ts: int | None) -> str:
    return fmt_age(ts)


def fmt_remaining(ts: int | None) -> str:
    if not ts:
        return "-"
    delta = int(ts) - int(datetime.now(timezone.utc).timestamp())
    if delta <= 0:
        return "due"
    if delta < 60:
        return f"{delta}s"
    if delta < 3600:
        return f"{delta // 60}m"
    if delta < 86400:
        return f"{delta // 3600}h"
    return f"{delta // 86400}d"


def classify_stale(active: bool, activity_ts: int | None, warn_seconds: int, critical_seconds: int) -> str:
    if not active:
        return "-"
    if not activity_ts:
        return "crit"
    age = max(0, int(datetime.now(timezone.utc).timestamp()) - int(activity_ts))
    if critical_seconds > 0 and age >= critical_seconds:
        return "crit"
    if warn_seconds > 0 and age >= warn_seconds:
        return "warn"
    return "ok"


def short_path(path: str, max_parts: int = 2) -> str:
    if not path:
        return "-"
    parts = [part for part in Path(path).parts if part not in ("/", "")]
    if len(parts) <= max_parts:
        return "/".join(parts) or path
    return ".../" + "/".join(parts[-max_parts:])


def read_roster(path: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with open(path, "r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            if row.get("agent"):
                rows.append(row)
    # Preserve BRIDGE_AGENT_IDS order from the roster snapshot so that
    # active agent index numbers match agb kill/attach numbering.
    return rows


def db_connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def daemon_status(pid_file: str) -> tuple[bool, str]:
    try:
        pid = Path(pid_file).read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return (False, "-")
    except Exception:
        return (False, "?")

    if not pid:
        return (False, "-")

    try:
        os.kill(int(pid), 0)
    except OSError:
        return (False, pid)
    return (True, pid)


def fetch_agent_metrics(conn: sqlite3.Connection) -> dict[str, dict[str, int | str | None]]:
    sql = """
      WITH assigned AS (
        SELECT
          assigned_to AS agent,
          SUM(CASE WHEN status = 'queued' THEN 1 ELSE 0 END) AS queued_count,
          SUM(CASE WHEN status = 'blocked' THEN 1 ELSE 0 END) AS blocked_count
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
        agent_state.agent,
        COALESCE(assigned.queued_count, 0) AS queued_count,
        COALESCE(assigned.blocked_count, 0) AS blocked_count,
        COALESCE(claimed.claimed_count, 0) AS claimed_count,
        COALESCE(agent_state.active, 0) AS active,
        agent_state.last_seen_ts,
        agent_state.last_heartbeat_ts,
        agent_state.session_activity_ts,
        agent_state.last_nudge_ts
      FROM agent_state
      LEFT JOIN assigned ON assigned.agent = agent_state.agent
      LEFT JOIN claimed ON claimed.agent = agent_state.agent
    """
    data: dict[str, dict[str, int | str | None]] = {}
    for row in conn.execute(sql):
        data[row["agent"]] = {
            "queued_count": row["queued_count"],
            "blocked_count": row["blocked_count"],
            "claimed_count": row["claimed_count"],
            "active": row["active"],
            "last_seen_ts": row["last_seen_ts"],
            "last_heartbeat_ts": row["last_heartbeat_ts"],
            "session_activity_ts": row["session_activity_ts"],
            "last_nudge_ts": row["last_nudge_ts"],
        }
    return data


def fetch_totals(conn: sqlite3.Connection) -> dict[str, int]:
    sql = """
      SELECT
        SUM(CASE WHEN status = 'queued' THEN 1 ELSE 0 END) AS queued_count,
        SUM(CASE WHEN status = 'claimed' THEN 1 ELSE 0 END) AS claimed_count,
        SUM(CASE WHEN status = 'blocked' THEN 1 ELSE 0 END) AS blocked_count,
        SUM(CASE WHEN status = 'queued' AND priority = 'urgent' THEN 1 ELSE 0 END) AS urgent_count,
        SUM(CASE WHEN status = 'claimed' AND lease_until_ts IS NOT NULL AND lease_until_ts < strftime('%s', 'now') THEN 1 ELSE 0 END) AS overdue_count
      FROM tasks
    """
    row = conn.execute(sql).fetchone()
    return {
        "queued_count": int(row["queued_count"] or 0),
        "claimed_count": int(row["claimed_count"] or 0),
        "blocked_count": int(row["blocked_count"] or 0),
        "urgent_count": int(row["urgent_count"] or 0),
        "overdue_count": int(row["overdue_count"] or 0),
    }


def fetch_open_tasks(conn: sqlite3.Connection, limit: int) -> list[sqlite3.Row]:
    sql = """
      SELECT id, assigned_to, status, priority, title, created_by, claimed_by, updated_ts, lease_until_ts
      FROM tasks
      WHERE status IN ('queued', 'claimed', 'blocked')
      ORDER BY
        CASE priority
          WHEN 'urgent' THEN 0
          WHEN 'high' THEN 1
          WHEN 'normal' THEN 2
          WHEN 'low' THEN 3
          ELSE 4
        END,
        CASE status
          WHEN 'claimed' THEN 0
          WHEN 'queued' THEN 1
          ELSE 2
        END,
        updated_ts DESC,
        id DESC
      LIMIT ?
    """
    return list(conn.execute(sql, (limit,)))


def render_bar(value: int, width: int = 10, char: str = "#") -> str:
    capped = min(max(0, value), width)
    return char * capped + "." * (width - capped)


def render_dashboard(args: argparse.Namespace) -> str:
    roster = read_roster(args.roster_snapshot)
    queue_db = Path(args.db)
    daemon_running, daemon_pid = daemon_status(args.daemon_pid_file)

    metrics: dict[str, dict[str, int | str | None]] = {}
    totals = {
        "queued_count": 0,
        "claimed_count": 0,
        "blocked_count": 0,
        "urgent_count": 0,
        "overdue_count": 0,
    }
    open_tasks: list[sqlite3.Row] = []

    if queue_db.exists():
        with db_connect(str(queue_db)) as conn:
            metrics = fetch_agent_metrics(conn)
            totals = fetch_totals(conn)
            open_tasks = fetch_open_tasks(conn, args.open_limit)

    full_total_agents = len(roster)
    full_active_count = sum(1 for row in roster if str(row.get("active", "0")) == "1")
    health_warn_count = 0
    health_critical_count = 0
    wake_missing_count = sum(1 for row in roster if row.get("wake") == "miss")

    for row in roster:
        metric = metrics.get(row["agent"], {})
        active = str(row.get("active", "0")) == "1"
        activity_ts = metric.get("session_activity_ts") or metric.get("last_seen_ts")
        stale = classify_stale(
            active,
            int(activity_ts) if activity_ts else None,
            args.stale_warn_seconds,
            args.stale_critical_seconds,
        )
        if stale == "warn":
            health_warn_count += 1
        elif stale == "crit":
            health_critical_count += 1

    if not args.all_agents:
        roster = [
            row
            for row in roster
            if str(row.get("active", "0")) == "1"
            or int(metrics.get(row["agent"], {}).get("queued_count", 0) or 0) > 0
            or int(metrics.get(row["agent"], {}).get("claimed_count", 0) or 0) > 0
            or int(metrics.get(row["agent"], {}).get("blocked_count", 0) or 0) > 0
        ]

    visible_agents = len(roster)

    lines: list[str] = []
    lines.append("Agent Bridge Status")
    lines.append(
        f"updated {iso_now()} | daemon {'running' if daemon_running else 'stopped'} pid={daemon_pid} | "
        f"active {full_active_count}/{full_total_agents} | shown {visible_agents} | "
        f"health warn={health_warn_count} crit={health_critical_count} | wake miss={wake_missing_count} | db {queue_db}"
    )
    lines.append("")
    lines.append(
        "Totals  "
        f"queued {totals['queued_count']} [{render_bar(totals['queued_count'])}]  "
        f"claimed {totals['claimed_count']} [{render_bar(totals['claimed_count'])}]  "
        f"blocked {totals['blocked_count']} [{render_bar(totals['blocked_count'])}]  "
        f"urgent {totals['urgent_count']}  overdue {totals['overdue_count']}  "
        f"health warn>={fmt_age(int(datetime.now(timezone.utc).timestamp()) - args.stale_warn_seconds) if args.stale_warn_seconds > 0 else 'off'} "
        f"crit>={fmt_age(int(datetime.now(timezone.utc).timestamp()) - args.stale_critical_seconds) if args.stale_critical_seconds > 0 else 'off'}"
    )
    lines.append("")
    lines.append("Agents")
    lines.append("  #  agent           eng     on  q   c   b   idle  stale wake   nudge  load        session        workdir")

    active_index = 0
    for row in roster:
        agent = row["agent"]
        metric = metrics.get(agent, {})
        active = str(row.get("active", "0")) == "1"
        if active:
            active_index += 1
            idx_label = f"{active_index:>3}"
        else:
            idx_label = "  -"
        queued = int(metric.get("queued_count", 0) or 0)
        claimed = int(metric.get("claimed_count", 0) or 0)
        blocked = int(metric.get("blocked_count", 0) or 0)
        activity_ts = metric.get("session_activity_ts") or metric.get("last_seen_ts")
        last_nudge_ts = metric.get("last_nudge_ts")
        stale = classify_stale(
            active,
            int(activity_ts) if activity_ts else None,
            args.stale_warn_seconds,
            args.stale_critical_seconds,
        )
        load_bar = f"q:{render_bar(queued, width=4, char='=')} c:{render_bar(claimed, width=4, char='*')}"
        lines.append(
            f"{idx_label}  {agent:<15} {row['engine']:<7} "
            f"{'yes' if active else 'no ':<3} "
            f"{queued:>2}  {claimed:>2}  {blocked:>2}  "
            f"{fmt_idle(int(activity_ts) if activity_ts else None):>4}  "
            f"{stale:>5} "
            f"{(row.get('wake') or '-'):>6} "
            f"{fmt_age(int(last_nudge_ts) if last_nudge_ts else None):>5}  "
            f"{load_bar:<12}  "
            f"{(row.get('session') or '-')[:12]:<12}  {short_path(row.get('workdir', ''))}"
        )

    lines.append("")
    lines.append("Open Tasks")
    if not open_tasks:
        lines.append("(no queued or claimed tasks)")
    else:
        lines.append("id  pri     status   to              owner           age   lease  title")
        for task in open_tasks:
            owner = task["claimed_by"] or task["created_by"]
            lines.append(
                f"{task['id']:<3} {task['priority']:<7} {task['status']:<8} "
                f"{task['assigned_to']:<15} {owner:<14} {fmt_age(task['updated_ts']):>4}  "
                f"{fmt_remaining(task['lease_until_ts']):>5}  {task['title']}"
            )

    if args.footer:
        lines.append("")
        lines.append(args.footer)

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(prog="bridge-status.py")
    parser.add_argument("--roster-snapshot", required=True)
    parser.add_argument("--db", required=True)
    parser.add_argument("--daemon-pid-file", required=True)
    parser.add_argument("--open-limit", type=int, default=8)
    parser.add_argument("--stale-warn-seconds", type=int, default=3600)
    parser.add_argument("--stale-critical-seconds", type=int, default=14400)
    parser.add_argument("--footer", default="")
    parser.add_argument("--all-agents", action="store_true")
    args = parser.parse_args()
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    print(render_dashboard(args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
