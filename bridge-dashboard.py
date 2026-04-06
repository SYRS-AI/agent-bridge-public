#!/usr/bin/env python3
"""Daemon dashboard: post agent status changes to Discord webhook."""

from __future__ import annotations

import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def now_iso() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")


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


def build_agent_summary(summary_tsv: str) -> list[dict[str, Any]]:
    agents: list[dict[str, Any]] = []
    for line in summary_tsv.strip().splitlines():
        if not line or line.startswith("agent\t"):
            continue
        parts = line.split("\t")
        if len(parts) < 6:
            continue
        agent = parts[0]
        queued = int(parts[1]) if parts[1].isdigit() else 0
        claimed = int(parts[2]) if parts[2].isdigit() else 0
        blocked = int(parts[3]) if parts[3].isdigit() else 0
        active = parts[4] == "1" if len(parts) > 4 else False
        idle = int(parts[5]) if len(parts) > 5 and parts[5].isdigit() else 0
        agents.append({
            "agent": agent,
            "active": active,
            "queued": queued,
            "claimed": claimed,
            "blocked": blocked,
            "idle": idle,
        })
    return agents


def build_status_digest(agents: list[dict[str, Any]]) -> dict[str, Any]:
    active_agents = [a for a in agents if a["active"]]
    total_queued = sum(a["queued"] for a in agents)
    total_claimed = sum(a["claimed"] for a in agents)
    total_blocked = sum(a["blocked"] for a in agents)
    return {
        "active_count": len(active_agents),
        "active_names": sorted(a["agent"] for a in active_agents),
        "total_agents": len(agents),
        "total_queued": total_queued,
        "total_claimed": total_claimed,
        "total_blocked": total_blocked,
        "agents_with_queue": sorted(
            [{"agent": a["agent"], "queued": a["queued"], "claimed": a["claimed"]}
             for a in agents if a["queued"] > 0 or a["claimed"] > 0],
            key=lambda x: -(x["queued"] + x["claimed"]),
        ),
    }


def digest_fingerprint(digest: dict[str, Any]) -> str:
    key = json.dumps({
        "active_names": digest["active_names"],
        "total_queued": digest["total_queued"],
        "total_claimed": digest["total_claimed"],
        "total_blocked": digest["total_blocked"],
        "agents_with_queue": digest["agents_with_queue"],
    }, sort_keys=True)
    return hashlib.md5(key.encode()).hexdigest()[:12]


def format_discord_message(digest: dict[str, Any], timestamp: str) -> str:
    lines: list[str] = []

    active_list = ", ".join(f"**{n}**" for n in digest["active_names"]) or "(none)"
    lines.append(f"🟢 Active: {digest['active_count']}/{digest['total_agents']} — {active_list}")

    if digest["total_queued"] > 0 or digest["total_claimed"] > 0:
        queue_parts: list[str] = []
        if digest["total_queued"] > 0:
            queue_parts.append(f"queued {digest['total_queued']}")
        if digest["total_claimed"] > 0:
            queue_parts.append(f"claimed {digest['total_claimed']}")
        if digest["total_blocked"] > 0:
            queue_parts.append(f"blocked {digest['total_blocked']}")
        lines.append(f"📋 Queue: {' | '.join(queue_parts)}")

        for item in digest["agents_with_queue"][:5]:
            parts = []
            if item["queued"] > 0:
                parts.append(f"q:{item['queued']}")
            if item["claimed"] > 0:
                parts.append(f"c:{item['claimed']}")
            lines.append(f"  └ {item['agent']}: {' '.join(parts)}")
    else:
        lines.append("📋 Queue: empty")

    lines.append(f"⏱️ {timestamp}")
    return "\n".join(lines)


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
    import argparse

    parser = argparse.ArgumentParser(prog="bridge-dashboard.py")
    parser.add_argument("--summary-tsv", required=True,
                        help="Path to summary TSV from bridge-queue.py summary --format tsv")
    parser.add_argument("--state-file", required=True,
                        help="Path to persist last-posted fingerprint")
    parser.add_argument("--webhook-url", default=os.environ.get("BRIDGE_DASHBOARD_WEBHOOK_URL", ""),
                        help="Discord webhook URL")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true",
                        help="Post even if unchanged")
    args = parser.parse_args()

    if not args.webhook_url and not args.dry_run:
        return 0  # silently skip if no webhook configured

    summary_path = Path(args.summary_tsv)
    if not summary_path.exists():
        print("[dashboard] summary file not found", file=sys.stderr)
        return 1

    summary_tsv = summary_path.read_text(encoding="utf-8")
    agents = build_agent_summary(summary_tsv)
    digest = build_status_digest(agents)
    fingerprint = digest_fingerprint(digest)
    timestamp = now_iso()

    state_path = Path(args.state_file)
    state = load_json(state_path)
    last_fingerprint = state.get("fingerprint", "")

    if fingerprint == last_fingerprint and not args.force:
        return 0  # no change

    message = format_discord_message(digest, timestamp)

    if args.dry_run:
        print(message)
        print(f"\nfingerprint: {fingerprint} (prev: {last_fingerprint})")
        return 0

    if post_discord_webhook(args.webhook_url, message):
        state["fingerprint"] = fingerprint
        state["last_posted_at"] = timestamp
        state["last_digest"] = digest
        save_json(state_path, state)
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
