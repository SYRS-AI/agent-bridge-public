#!/usr/bin/env python3
"""Send short Agent Bridge notifications over Discord or Telegram."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_text_file(path: str | None) -> str:
    if not path:
        return ""
    return Path(path).read_text(encoding="utf-8").strip()


def load_account_config(config_path: Path, kind: str, account: str) -> dict[str, Any]:
    payload = load_json(config_path)
    channels = payload.get("channels") or {}
    channel_cfg = channels.get(kind) or {}
    accounts = channel_cfg.get("accounts") or {}
    account_cfg = accounts.get(account)
    if not isinstance(account_cfg, dict):
        raise SystemExit(f"{kind} account not found: {account}")
    return account_cfg


def load_account_token(account_cfg: dict[str, Any]) -> str:
    token = str(account_cfg.get("token") or "").strip()
    if token:
        return token
    token_file = str(account_cfg.get("tokenFile") or "").strip()
    if token_file:
        token = load_text_file(token_file)
        if token:
            return token
    raise SystemExit("channel account token is missing")


def normalize_target(kind: str, target: str) -> str:
    value = str(target).strip()
    if kind == "telegram" and value.startswith("agent:"):
        return value.rsplit(":", 1)[-1]
    return value


def build_message(title: str, message: str, task_id: str, priority: str) -> str:
    title = title.strip()
    message = message.strip()
    task_id = str(task_id or "").strip()
    priority = str(priority or "").strip()

    header = "[Agent Bridge]"
    if priority and priority != "normal":
        header += f" {priority}"
    if task_id:
        header += f" task #{task_id}"
    if title:
        header += f": {title}"

    parts = [header]
    if message:
        parts.append(message)
    return "\n".join(parts)


def send_discord(token: str, channel_id: str, text: str) -> None:
    payload = json.dumps({"content": text}).encode("utf-8")
    req = Request(
        f"https://discord.com/api/v10/channels/{channel_id}/messages",
        data=payload,
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": "agent-bridge-notify/0.1",
        },
        method="POST",
    )
    with urlopen(req, timeout=15):
        return


def send_telegram(token: str, chat_id: str, text: str) -> None:
    payload = urlencode(
        {
            "chat_id": chat_id,
            "text": text,
            "disable_web_page_preview": "true",
        }
    ).encode("utf-8")
    req = Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=payload,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "agent-bridge-notify/0.1",
        },
        method="POST",
    )
    with urlopen(req, timeout=15):
        return


def cmd_send(args: argparse.Namespace) -> int:
    kind = str(args.kind).strip()
    target = normalize_target(kind, args.target)
    account = str(args.account or "default").strip()
    text = build_message(args.title or "", args.message or "", args.task_id or "", args.priority or "normal")

    payload = {
        "agent": args.agent,
        "kind": kind,
        "target": target,
        "account": account,
        "text": text,
    }

    if args.dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    account_cfg = load_account_config(Path(args.openclaw_config), kind, account)
    token = load_account_token(account_cfg)

    try:
        if kind == "discord":
            send_discord(token, target, text)
        elif kind == "telegram":
            send_telegram(token, target, text)
        else:
            raise SystemExit(f"unsupported notify kind: {kind}")
    except HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"{kind} notify failed: HTTP {exc.code}: {details}") from exc
    except URLError as exc:
        raise SystemExit(f"{kind} notify failed: {exc.reason}") from exc

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-notify.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    send_parser = subparsers.add_parser("send")
    send_parser.add_argument("--agent")
    send_parser.add_argument("--kind", required=True, choices=("discord", "telegram"))
    send_parser.add_argument("--target", required=True)
    send_parser.add_argument("--account", default="default")
    send_parser.add_argument("--openclaw-config", required=True)
    send_parser.add_argument("--title")
    send_parser.add_argument("--message")
    send_parser.add_argument("--task-id")
    send_parser.add_argument("--priority", default="normal")
    send_parser.add_argument("--dry-run", action="store_true")
    send_parser.set_defaults(handler=cmd_send)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
