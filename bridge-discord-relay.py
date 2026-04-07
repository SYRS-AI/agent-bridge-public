#!/usr/bin/env python3
"""Lightweight Discord -> Agent Bridge wake relay for on-demand agents."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def load_json(path: Path, default: Any) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    tmp.replace(path)


def load_token(runtime_config: Path, relay_account: str) -> str:
    payload = load_json(runtime_config, {})
    token = (
        (((payload.get("channels") or {}).get("discord") or {}).get("accounts") or {})
        .get(relay_account, {})
        .get("token")
    )
    if not token:
        raise SystemExit(f"discord relay token not found for account '{relay_account}'")
    return token


def read_snapshot(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("agent\tchannel_id\t"):
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                print(f"[discord-relay] malformed snapshot row fields={len(parts)} raw={line!r}", file=sys.stderr)
                continue
            if len(parts) == 4:
                agent, channel_id, active, idle_timeout = parts
                session = ""
            else:
                agent, channel_id, active, idle_timeout = parts[:4]
                session = "\t".join(parts[4:])
            try:
                idle_timeout_value = int(idle_timeout)
            except ValueError:
                print(f"[discord-relay] malformed idle_timeout raw={line!r}", file=sys.stderr)
                continue
            if not agent or not channel_id:
                print(f"[discord-relay] malformed snapshot row missing agent/channel raw={line!r}", file=sys.stderr)
                continue
            rows.append(
                {
                    "agent": agent,
                    "channel_id": channel_id,
                    "active": active == "1",
                    "idle_timeout": idle_timeout_value,
                    "session": session,
                }
            )
    return rows


def snowflake_int(value: str | int | None) -> int:
    if value is None:
        return 0
    return int(str(value))


def open_dm_channel(token: str, recipient_id: str) -> str | None:
    """POST /users/@me/channels to open/get a DM channel with a user."""
    payload = json.dumps({"recipient_id": recipient_id}).encode("utf-8")
    req = Request(
        "https://discord.com/api/v10/users/@me/channels",
        data=payload,
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": "agent-bridge-relay/0.1",
        },
        method="POST",
    )
    try:
        with urlopen(req, timeout=15) as response:
            data = json.loads(response.read().decode("utf-8"))
            return str(data.get("id") or "")
    except (HTTPError, URLError):
        return None


def load_dm_allowlist(agent_home_root: str, agent: str) -> list[str]:
    """Read allowFrom user IDs from agent's .discord/access.json."""
    access_path = Path(agent_home_root) / agent / ".discord" / "access.json"
    if not access_path.exists():
        return []
    try:
        data = json.loads(access_path.read_text(encoding="utf-8"))
        return [str(uid) for uid in (data.get("allowFrom") or []) if uid]
    except Exception:
        return []


def fetch_channel_messages(token: str, channel_id: str, limit: int) -> list[dict[str, Any]]:
    query = urlencode({"limit": str(limit)})
    url = f"https://discord.com/api/v10/channels/{channel_id}/messages?{query}"
    req = Request(
        url,
        headers={
            "Authorization": f"Bot {token}",
            "User-Agent": "agent-bridge-discord-relay/0.1",
        },
        method="GET",
    )

    for attempt in range(2):
        try:
            with urlopen(req, timeout=15) as response:
                payload = response.read().decode("utf-8")
                data = json.loads(payload)
                if isinstance(data, list):
                    return data
                return []
        except HTTPError as err:
            if err.code == 429 and attempt == 0:
                try:
                    retry_payload = json.loads(err.read().decode("utf-8"))
                    retry_after = float(retry_payload.get("retry_after", 1.0))
                except Exception:
                    retry_after = 1.0
                time.sleep(min(max(retry_after, 0.5), 5.0))
                continue
            raise
        except URLError:
            if attempt == 0:
                time.sleep(1.0)
                continue
            raise

    return []


def display_name(message: dict[str, Any]) -> str:
    author = message.get("author") or {}
    member = message.get("member") or {}
    return (
        member.get("nick")
        or author.get("global_name")
        or author.get("username")
        or author.get("id")
        or "unknown"
    )


def message_preview(message: dict[str, Any], limit: int = 180) -> str:
    content = " ".join((message.get("content") or "").split())
    attachments = message.get("attachments") or []
    if not content and attachments:
        names = [attachment.get("filename") for attachment in attachments if attachment.get("filename")]
        content = f"[attachments] {', '.join(names[:3])}"
    if not content:
        content = "[no text]"
    if len(content) > limit:
        return content[: limit - 3] + "..."
    return content


def enqueue_task(bridge_home: Path, agent: str, channel_id: str, messages: list[dict[str, Any]]) -> str:
    latest = messages[-1]
    latest_author = display_name(latest)
    latest_preview = message_preview(latest)
    title = f"[Discord] wake {agent} for channel {channel_id}"
    body = (
        f"Discord relay detected {len(messages)} new human message(s) in channel {channel_id} "
        f"while {agent} was offline.\n\n"
        f"Latest author: {latest_author}\n"
        f"Latest message id: {latest.get('id')}\n"
        f"Preview: {latest_preview}\n\n"
        f"Wake the session, reconnect Discord, and read the backlog directly in Discord. "
        f"This task is a wake signal, not a full message transport."
    )
    cmd = [
        str(bridge_home / "agent-bridge"),
        "task",
        "create",
        "--to",
        agent,
        "--from",
        "discord-relay",
        "--priority",
        "high",
        "--title",
        title,
        "--body",
        body,
    ]
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def tmux_session_active(session: str) -> bool:
    if not session:
        return False
    result = subprocess.run(
        ["tmux", "has-session", "-t", session],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def has_open_wake_task(bridge_home: Path, agent: str) -> bool:
    db_path = bridge_home / "state" / "tasks.db"
    if not db_path.exists():
        return False

    with sqlite3.connect(db_path) as conn:
        row = conn.execute(
            """
            SELECT 1
            FROM tasks
            WHERE assigned_to = ?
              AND created_by = 'discord-relay'
              AND status IN ('queued', 'claimed', 'blocked')
            LIMIT 1
            """,
            (agent,),
        ).fetchone()
    return row is not None


def cmd_sync(args: argparse.Namespace) -> int:
    snapshot = read_snapshot(Path(args.agent_snapshot))
    if not snapshot:
        return 0

    if not args.runtime_config:
        raise SystemExit("--runtime-config is required")
    token = load_token(Path(args.runtime_config), args.relay_account)
    state_path = Path(args.state_file)
    state = load_json(state_path, {"channels": {}})
    channels = state.setdefault("channels", {})
    now_ts = int(time.time())

    for row in snapshot:
        channel_id = row["channel_id"]
        channel_state = channels.setdefault(channel_id, {"agent": row["agent"]})
        channel_state["agent"] = row["agent"]

        try:
            messages = fetch_channel_messages(token, channel_id, args.poll_limit)
        except HTTPError as err:
            print(
                f"[discord-relay] channel={channel_id} agent={row['agent']} http_error={err.code}",
                file=sys.stderr,
            )
            continue
        except URLError as err:
            print(
                f"[discord-relay] channel={channel_id} agent={row['agent']} url_error={err.reason}",
                file=sys.stderr,
            )
            continue

        if not messages:
            continue

        messages.sort(key=lambda item: snowflake_int(item.get("id")))
        latest_id = str(messages[-1].get("id"))
        last_seen_id = channel_state.get("last_seen_id")

        if not last_seen_id:
            channel_state["last_seen_id"] = latest_id
            channel_state["seeded_at"] = now_ts
            continue

        new_messages = [item for item in messages if snowflake_int(item.get("id")) > snowflake_int(last_seen_id)]
        if not new_messages:
            continue

        channel_state["last_seen_id"] = latest_id
        channel_state["last_seen_ts"] = now_ts

        live_active = row["active"] or tmux_session_active(str(row.get("session") or ""))
        if live_active:
            continue

        human_messages = [item for item in new_messages if not ((item.get("author") or {}).get("bot"))]
        if not human_messages:
            continue

        if has_open_wake_task(Path(args.bridge_home), row["agent"]):
            channel_state["last_suppressed_ts"] = now_ts
            channel_state["last_suppressed_reason"] = "open_wake_task"
            continue

        last_enqueue_ts = int(channel_state.get("last_enqueue_ts") or 0)
        if args.cooldown_seconds > 0 and now_ts - last_enqueue_ts < args.cooldown_seconds:
            channel_state["last_suppressed_ts"] = now_ts
            channel_state["last_suppressed_reason"] = "cooldown"
            continue

        output = enqueue_task(Path(args.bridge_home), row["agent"], channel_id, human_messages)
        channel_state["last_enqueue_ts"] = now_ts
        channel_state["last_enqueue_message_id"] = str(human_messages[-1].get("id"))
        channel_state["last_enqueue_preview"] = message_preview(human_messages[-1])
        print(
            f"[discord-relay] enqueued agent={row['agent']} channel={channel_id} "
            f"messages={len(human_messages)} :: {output}"
        )

    # DM monitoring: open DM channels for allowlisted users and poll them
    dm_channels = state.setdefault("dm_channels", {})
    agent_home_root = Path(args.bridge_home) / "agents"

    # Scan ALL agents with .discord dirs — not just snapshot (which only has active agents)
    all_dm_agents: list[str] = []
    if agent_home_root.is_dir():
        for agent_dir in sorted(agent_home_root.iterdir()):
            if not agent_dir.is_dir() or agent_dir.name.startswith("."):
                continue
            if (agent_dir / ".discord" / ".env").exists():
                all_dm_agents.append(agent_dir.name)

    # Build session lookup from snapshot for active check
    session_by_agent = {row["agent"]: row.get("session", "") for row in snapshot}

    for agent in all_dm_agents:

        allow_ids = load_dm_allowlist(str(agent_home_root), agent)
        if not allow_ids:
            continue

        # Use agent's own bot token if available, otherwise skip
        agent_env_path = agent_home_root / agent / ".discord" / ".env"
        if not agent_env_path.exists():
            continue
        try:
            agent_token = agent_env_path.read_text(encoding="utf-8").split("=", 1)[1].strip()
        except Exception:
            continue

        for user_id in allow_ids:
            dm_key = f"dm:{agent}:{user_id}"
            dm_state = dm_channels.setdefault(dm_key, {"agent": agent, "user_id": user_id})

            # Open/get DM channel if not cached
            if not dm_state.get("channel_id"):
                ch_id = open_dm_channel(agent_token, user_id)
                if not ch_id:
                    continue
                dm_state["channel_id"] = ch_id

            channel_id = dm_state["channel_id"]
            try:
                messages = fetch_channel_messages(agent_token, channel_id, args.poll_limit)
            except (HTTPError, URLError):
                continue

            if not messages:
                continue

            messages.sort(key=lambda item: snowflake_int(item.get("id")))
            latest_id = str(messages[-1].get("id"))
            last_seen_id = dm_state.get("last_seen_id")

            if not last_seen_id:
                # DM: don't skip on seed — first message IS the wake signal
                dm_state["last_seen_id"] = latest_id
                dm_state["seeded_at"] = now_ts
                new_messages = messages  # treat all as new on first contact
            else:
                new_messages = [item for item in messages if snowflake_int(item.get("id")) > snowflake_int(last_seen_id)]
            if not new_messages:
                continue

            dm_state["last_seen_id"] = latest_id
            dm_state["last_seen_ts"] = now_ts

            session_name = session_by_agent.get(agent, agent)
            if tmux_session_active(session_name):
                continue

            human_messages = [item for item in new_messages if not ((item.get("author") or {}).get("bot"))]
            if not human_messages:
                continue

            if has_open_wake_task(Path(args.bridge_home), agent):
                continue

            output = enqueue_task(Path(args.bridge_home), agent, channel_id, human_messages)
            dm_state["last_enqueue_ts"] = now_ts
            print(
                f"[discord-relay] DM enqueued agent={agent} user={user_id} "
                f"messages={len(human_messages)} :: {output}"
            )

    save_json(state_path, state)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Discord wake relay for Agent Bridge on-demand agents")
    subparsers = parser.add_subparsers(dest="command", required=True)

    sync_parser = subparsers.add_parser("sync")
    sync_parser.add_argument("--agent-snapshot", required=True)
    sync_parser.add_argument("--bridge-home", required=True)
    sync_parser.add_argument("--state-file", required=True)
    sync_parser.add_argument("--runtime-config")
    sync_parser.add_argument("--openclaw-config", dest="runtime_config", help=argparse.SUPPRESS)
    sync_parser.add_argument("--relay-account", default="default")
    sync_parser.add_argument("--poll-limit", type=int, default=5)
    sync_parser.add_argument("--cooldown-seconds", type=int, default=60)
    sync_parser.set_defaults(handler=cmd_sync)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
