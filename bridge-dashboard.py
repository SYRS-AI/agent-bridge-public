#!/usr/bin/env python3
"""Daemon dashboard: post concise agent status changes to Discord webhook."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

NOISE_NAME_RE = re.compile(
    r"(?:^|[-_])(smoke|tester|requester|worker-reuse|auto-start-agent|codex-cli-agent)(?:[-_]|$)"
)
TITLE_SPLIT_RE = re.compile(r"\s+[—-]\s+")


def now_iso() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")


def now_clock() -> str:
    return datetime.now().astimezone().strftime("%H:%M")


def now_epoch() -> int:
    return int(datetime.now().timestamp())


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    tmp.replace(path)


def parse_int(raw: str | None, default: int = 0) -> int:
    try:
        return int(raw or default)
    except (TypeError, ValueError):
        return default


def build_agent_summary(summary_tsv: str) -> dict[str, dict[str, Any]]:
    agents: dict[str, dict[str, Any]] = {}
    for line in summary_tsv.strip().splitlines():
        if not line or line.startswith("agent\t"):
            continue
        parts = line.split("\t")
        if len(parts) < 11:
            continue
        agent = parts[0]
        agents[agent] = {
            "agent": agent,
            "queued": parse_int(parts[1]),
            "claimed": parse_int(parts[2]),
            "blocked": parse_int(parts[3]),
            "active": parts[4] == "1",
            "idle": parse_int(parts[5], -1),
            "last_seen_ts": parse_int(parts[6]),
            "last_nudge_ts": parse_int(parts[7]),
            "session": parts[8],
            "engine": parts[9],
            "workdir": parts[10],
        }
    return agents


def load_roster_tsv(path: Path) -> dict[str, dict[str, str]]:
    entries: dict[str, dict[str, str]] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return entries
    if not lines:
        return entries
    header = lines[0].split("\t")
    for raw in lines[1:]:
        if not raw.strip():
            continue
        parts = raw.split("\t")
        record = {header[index]: parts[index] if index < len(parts) else "" for index in range(len(header))}
        agent = record.get("agent", "").strip()
        if agent:
            entries[agent] = record
    return entries


def is_noise_agent(agent: str) -> bool:
    return bool(NOISE_NAME_RE.search(agent))


def merge_agents(
    summary_agents: dict[str, dict[str, Any]],
    roster_entries: dict[str, dict[str, str]],
) -> dict[str, dict[str, Any]]:
    merged: dict[str, dict[str, Any]] = {}
    if roster_entries:
        for agent, meta in sorted(roster_entries.items()):
            if meta.get("source") != "static":
                continue
            row = {
                "agent": agent,
                "queued": 0,
                "claimed": 0,
                "blocked": 0,
                "active": False,
                "idle": -1,
                "last_seen_ts": 0,
                "last_nudge_ts": 0,
                "session": meta.get("session", ""),
                "engine": meta.get("engine", ""),
                "workdir": meta.get("cwd", ""),
            }
            row.update(summary_agents.get(agent, {}))
            if not row.get("workdir"):
                row["workdir"] = meta.get("cwd", "")
            merged[agent] = row
        return merged

    for agent, row in summary_agents.items():
        if is_noise_agent(agent):
            continue
        merged[agent] = row
    return dict(sorted(merged.items()))


def display_name_from_heading(path: Path) -> str:
    try:
        for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw.strip()
            if not line.startswith("# "):
                continue
            title = TITLE_SPLIT_RE.split(line[2:].strip(), maxsplit=1)[0].strip()
            if title and "<" not in title:
                return title
    except FileNotFoundError:
        return ""
    return ""


def resolve_display_name(agent: str, workdir: str, cache: dict[str, str]) -> str:
    if agent in cache:
        return cache[agent]
    base = Path(workdir).expanduser() if workdir else None
    for rel in ("SOUL.md", "CLAUDE.md"):
        if base:
            title = display_name_from_heading(base / rel)
            if title:
                cache[agent] = title
                return title
    cache[agent] = agent
    return agent


def normalize_task_title(title: str) -> str:
    cleaned = re.sub(r"^\[[^\]]+\]\s*", "", title.strip())
    if cleaned.startswith("[cron-dispatch]"):
        return ""
    return cleaned


def load_open_task_titles(db_path: Path | None, agents: set[str]) -> dict[str, str]:
    if not agents or db_path is None or not db_path.exists():
        return {}
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    placeholders = ",".join("?" for _ in agents)
    query = f"""
        SELECT assigned_to, claimed_by, title, priority, status, created_ts
        FROM tasks
        WHERE status IN ('queued', 'claimed')
          AND (assigned_to IN ({placeholders}) OR claimed_by IN ({placeholders}))
    """
    params = [*agents, *agents]
    ranking = {"urgent": 0, "high": 1, "normal": 2, "low": 3}
    best: dict[str, tuple[tuple[int, int, int], str]] = {}
    try:
        for row in conn.execute(query, params):
            title = normalize_task_title(row["title"] or "")
            if not title:
                continue
            owner = row["claimed_by"] if row["status"] == "claimed" and row["claimed_by"] else row["assigned_to"]
            if not owner or owner not in agents:
                continue
            key = (
                0 if row["status"] == "claimed" else 1,
                ranking.get(row["priority"] or "normal", 4),
                int(row["created_ts"] or 0),
            )
            current = best.get(owner)
            if current is None or key < current[0]:
                best[owner] = (key, title)
    finally:
        conn.close()
    return {agent: value[1] for agent, value in best.items()}


def classify_state(agent: dict[str, Any], idle_threshold_seconds: int) -> str:
    if not agent["active"]:
        return "stopped"
    if agent["claimed"] > 0 or agent["queued"] > 0:
        return "working"
    if agent["idle"] >= idle_threshold_seconds:
        return "idle"
    return "working"


def build_snapshots(
    agents: dict[str, dict[str, Any]],
    *,
    idle_threshold_seconds: int,
    task_titles: dict[str, str],
) -> dict[str, dict[str, Any]]:
    snapshots: dict[str, dict[str, Any]] = {}
    display_cache: dict[str, str] = {}
    for agent, row in agents.items():
        snapshots[agent] = {
            "display": resolve_display_name(agent, row.get("workdir", ""), display_cache),
            "state": classify_state(row, idle_threshold_seconds),
            "queued": row["queued"],
            "claimed": row["claimed"],
            "blocked": row["blocked"],
            "idle_seconds": row["idle"],
            "task_title": task_titles.get(agent, ""),
        }
    return snapshots


def snapshots_fingerprint(snapshots: dict[str, dict[str, Any]]) -> str:
    payload = {
        agent: {
            "state": data["state"],
            "queued": data["queued"],
            "claimed": data["claimed"],
            "blocked": data["blocked"],
            "task_title": data["task_title"],
        }
        for agent, data in sorted(snapshots.items())
    }
    return hashlib.md5(json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()[:12]


def format_idle_duration(seconds: int) -> str:
    minutes = max(1, seconds // 60)
    hours, minutes = divmod(minutes, 60)
    if hours and minutes:
        return f"{hours}시간 {minutes}분"
    if hours:
        return f"{hours}시간"
    return f"{minutes}분"


def join_names(names: list[str], limit: int = 8) -> str:
    if not names:
        return "(없음)"
    if len(names) <= limit:
        return ", ".join(names)
    return ", ".join(names[:limit]) + f" 외 {len(names) - limit}"


def format_change_line(agent: str, previous: dict[str, Any], current: dict[str, Any]) -> str | None:
    prev_state = previous.get("state")
    cur_state = current["state"]
    if prev_state == cur_state:
        return None
    display = current["display"]
    if cur_state == "working":
        suffix = f" — {current['task_title']}" if current.get("task_title") else ""
        return f"🟢 {display} 작업 시작{suffix}"
    if cur_state == "idle":
        return f"⏸️ {display} idle ({format_idle_duration(current['idle_seconds'])})"
    return f"😴 {display} 꺼짐"


def format_summary_block(snapshots: dict[str, dict[str, Any]]) -> str:
    grouped = {"working": [], "idle": [], "stopped": []}
    for _, data in sorted(snapshots.items(), key=lambda item: item[1]["display"]):
        grouped[data["state"]].append(data["display"])
    lines = [
        f"📊 에이전트 현황 ({now_clock()})",
        f"🟢 일하는 중: {join_names(grouped['working'])}",
        f"⏸️ 대기 중: {join_names(grouped['idle'])}",
        f"😴 꺼짐: {join_names(grouped['stopped'])}",
    ]
    return "\n".join(lines)


def build_message(
    snapshots: dict[str, dict[str, Any]],
    previous_snapshots: dict[str, dict[str, Any]],
    *,
    summary_due: bool,
    force: bool,
) -> tuple[str, bool]:
    if not snapshots:
        return "", False

    if force or not previous_snapshots:
        return format_summary_block(snapshots), True

    lines = []
    for agent in sorted(snapshots):
        previous = previous_snapshots.get(agent, {})
        line = format_change_line(agent, previous, snapshots[agent])
        if line:
            lines.append(line)

    summary_included = False
    if summary_due:
        if lines:
            lines.append("")
        lines.append(format_summary_block(snapshots))
        summary_included = True

    return "\n".join(lines), summary_included


def post_discord_webhook(webhook_url: str, content: str) -> bool:
    payload = json.dumps({"content": content}).encode("utf-8")
    req = Request(
        webhook_url,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "agent-bridge-dashboard/0.1",
        },
        method="POST",
    )
    try:
        with urlopen(req, timeout=10) as resp:
            return 200 <= resp.status < 300
    except (HTTPError, URLError, TimeoutError) as exc:
        print(f"[dashboard] webhook post failed: {exc}", file=sys.stderr)
        return False


def main() -> int:
    parser = argparse.ArgumentParser(prog="bridge-dashboard.py")
    parser.add_argument("--summary-tsv", required=True, help="Path to summary TSV from bridge-queue.py summary --format tsv")
    parser.add_argument("--state-file", required=True, help="Path to persist dashboard state")
    parser.add_argument("--webhook-url", default="", help="Discord webhook URL")
    parser.add_argument("--roster-tsv", default="", help="Optional active roster TSV path")
    parser.add_argument("--task-db", default="", help="Optional task DB path for labeling active work")
    parser.add_argument("--idle-threshold-seconds", type=int, default=900, help="Idle threshold before an active session is considered idle")
    parser.add_argument("--summary-interval-seconds", type=int, default=3600, help="Periodic summary interval; 0 disables periodic summaries")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true", help="Post even if unchanged")
    args = parser.parse_args()

    webhook_url = args.webhook_url or os.environ.get("BRIDGE_DASHBOARD_WEBHOOK_URL", "")
    roster_tsv_value = args.roster_tsv or os.environ.get("BRIDGE_ACTIVE_ROSTER_TSV", "")
    task_db_value = args.task_db or os.environ.get("BRIDGE_TASK_DB", "")
    roster_tsv = Path(roster_tsv_value) if roster_tsv_value else None
    task_db = Path(task_db_value) if task_db_value else None

    if not webhook_url and not args.dry_run:
        return 0

    summary_path = Path(args.summary_tsv)
    if not summary_path.exists():
        print("[dashboard] summary file not found", file=sys.stderr)
        return 1

    summary_agents = build_agent_summary(summary_path.read_text(encoding="utf-8"))
    roster_entries = load_roster_tsv(roster_tsv) if roster_tsv else {}
    merged_agents = merge_agents(summary_agents, roster_entries)
    task_titles = load_open_task_titles(task_db, set(merged_agents))
    snapshots = build_snapshots(
        merged_agents,
        idle_threshold_seconds=max(60, args.idle_threshold_seconds),
        task_titles=task_titles,
    )

    state_path = Path(args.state_file)
    state = load_json(state_path)
    previous_snapshots = state.get("agents", {}) if isinstance(state.get("agents", {}), dict) else {}
    last_summary_ts = parse_int(state.get("last_summary_ts"), 0)
    summary_due = args.summary_interval_seconds > 0 and (
        args.force or not previous_snapshots or (now_epoch() - last_summary_ts) >= args.summary_interval_seconds
    )

    message, summary_included = build_message(
        snapshots,
        previous_snapshots,
        summary_due=summary_due,
        force=args.force,
    )
    fingerprint = snapshots_fingerprint(snapshots)

    if not message and not args.force:
        return 0

    if args.dry_run:
        print(message)
        print(f"\nfingerprint: {fingerprint} (prev: {state.get('fingerprint', '')})")
        return 0

    if post_discord_webhook(webhook_url, message):
        state["fingerprint"] = fingerprint
        state["last_posted_at"] = now_iso()
        state["agents"] = snapshots
        if summary_included:
            state["last_summary_ts"] = now_epoch()
        save_json(state_path, state)
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
