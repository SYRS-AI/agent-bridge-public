#!/usr/bin/env python3
"""Interactive Discord and Telegram onboarding helpers for Agent Bridge."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import sys
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class SetupError(Exception):
    """Raised when setup validation fails with a user-facing message."""


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
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def save_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def load_dotenv(path: Path) -> dict[str, str]:
    payload: dict[str, str] = {}
    if not path.exists():
        return payload
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        payload[key.strip()] = value.strip()
    return payload


def normalize_id_list(values: list[str] | tuple[str, ...] | None, label: str) -> list[str]:
    results: list[str] = []
    seen: set[str] = set()
    for raw in values or []:
        for chunk in re.split(r"[\s,]+", str(raw).strip()):
            if not chunk:
                continue
            if not re.fullmatch(r"\d{6,}", chunk):
                raise SetupError(f"{label} must be Discord snowflake IDs: {chunk}")
            if chunk in seen:
                continue
            seen.add(chunk)
            results.append(chunk)
    return results


def prompt_text(prompt: str, default: str = "", secret: bool = False) -> str:
    if default:
        prompt_text_value = f"{prompt} [{default}]: "
    else:
        prompt_text_value = f"{prompt}: "
    if secret:
        value = getpass.getpass(prompt_text_value)
    else:
        value = input(prompt_text_value)
    value = value.strip()
    if value:
        return value
    return default.strip()


def prompt_yes_no(prompt: str, default: bool) -> bool:
    suffix = "[Y/n]" if default else "[y/N]"
    value = input(f"{prompt} {suffix}: ").strip().lower()
    if not value:
        return default
    return value in {"y", "yes"}


def inspect_discord_dir(discord_dir: Path) -> dict[str, Any]:
    env_path = discord_dir / ".env"
    access_path = discord_dir / "access.json"
    env = load_dotenv(env_path)
    access_payload = load_json(access_path, {})
    groups = access_payload.get("groups") or {}
    channels = [str(channel_id) for channel_id in groups.keys() if str(channel_id).strip()]
    allow_from = normalize_id_list(access_payload.get("allowFrom") or [], "allow_from")
    require_values = []
    for channel_id in channels:
        entry = groups.get(channel_id) or {}
        require_values.append(bool(entry.get("requireMention", False)))
    require_mention = bool(require_values and all(require_values))
    return {
        "env_path": env_path,
        "access_path": access_path,
        "token": env.get("DISCORD_BOT_TOKEN", "").strip(),
        "channels": channels,
        "allow_from": allow_from,
        "require_mention": require_mention,
        "access_payload": access_payload if isinstance(access_payload, dict) else {},
    }


def load_channel_accounts(config_path: Path, kind: str) -> dict[str, dict[str, Any]]:
    payload = load_json(config_path, {})
    channels = payload.get("channels") or {}
    channel_cfg = channels.get(kind) or {}
    accounts = channel_cfg.get("accounts") or {}
    if not isinstance(accounts, dict):
        return {}
    return {str(name): cfg for name, cfg in accounts.items() if isinstance(cfg, dict)}


def extract_token_from_text(text: str, kind: str) -> str:
    stripped = text.strip()
    if not stripped:
        return ""

    if kind == "telegram":
        keys = ("TELEGRAM_BOT_TOKEN", "BOT_TOKEN", "TOKEN")
    elif kind == "discord":
        keys = ("DISCORD_BOT_TOKEN", "BOT_TOKEN", "TOKEN")
    else:
        keys = ("TOKEN",)

    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]
    for key in keys:
        prefix = f"{key}="
        for line in lines:
            if line.startswith(prefix):
                return line.split("=", 1)[1].strip().strip("'").strip('"')

    if len(lines) == 1 and "=" not in lines[0]:
        return lines[0]

    return ""


def load_account_token(config_path: Path, kind: str, account: str) -> str:
    accounts = load_channel_accounts(config_path, kind)
    account_cfg = accounts.get(account)
    if not account_cfg:
        raise SetupError(f"Configured {kind} account not found: {account}")
    token = str(account_cfg.get("token") or "").strip()
    if token:
        return token
    token_file = str(account_cfg.get("tokenFile") or "").strip()
    if token_file:
        token_path = Path(token_file).expanduser()
        if token_path.exists():
            token = extract_token_from_text(token_path.read_text(encoding="utf-8"), kind)
            if token:
                return token
    raise SetupError(f"Configured {kind} account token is empty: {account}")


def load_claude_plugin_channel_token(kind: str) -> str:
    channels_home = Path(
        os.environ.get("BRIDGE_CLAUDE_CHANNELS_HOME", str(Path.home() / ".claude" / "channels"))
    ).expanduser()
    env_path = channels_home / kind / ".env"
    if not env_path.exists():
        return ""
    return extract_token_from_text(env_path.read_text(encoding="utf-8"), kind)


def candidate_channel_accounts(agent: str, accounts: dict[str, dict[str, Any]]) -> list[str]:
    candidates = [agent]
    if "-" in agent:
        candidates.append(agent.rsplit("-", 1)[-1])
    candidates.append("default")

    ordered: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        candidate = str(candidate).strip()
        if not candidate or candidate in seen:
            continue
        if candidate in accounts:
            seen.add(candidate)
            ordered.append(candidate)
    return ordered


def inspect_telegram_dir(telegram_dir: Path) -> dict[str, Any]:
    env_path = telegram_dir / ".env"
    access_path = telegram_dir / "access.json"
    env = load_dotenv(env_path)
    access_payload = load_json(access_path, {})
    allow_from = normalize_id_list(access_payload.get("allowFrom") or [], "allow_from")
    default_chat = str(access_payload.get("defaultChatId") or "").strip()
    return {
        "env_path": env_path,
        "access_path": access_path,
        "token": env.get("TELEGRAM_BOT_TOKEN", "").strip(),
        "allow_from": allow_from,
        "default_chat": default_chat,
        "access_payload": access_payload if isinstance(access_payload, dict) else {},
    }


def http_json(token: str, url: str, method: str = "GET", payload: dict[str, Any] | None = None) -> Any:
    body = None
    headers = {
        "Authorization": f"Bot {token}",
        "User-Agent": "agent-bridge-setup/0.1",
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = Request(url, data=body, headers=headers, method=method)
    try:
        with urlopen(request, timeout=15) as response:
            data = response.read().decode("utf-8")
            if not data:
                return {}
            return json.loads(data)
    except HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise SetupError(f"Discord API {method} {url} failed: HTTP {exc.code}: {details}") from exc
    except URLError as exc:
        raise SetupError(f"Discord API {method} {url} failed: {exc.reason}") from exc


def validate_discord(token: str, channels: list[str], api_base_url: str, send_test: bool, agent: str) -> dict[str, Any]:
    api_base = api_base_url.rstrip("/")
    bot = http_json(token, f"{api_base}/users/@me")
    channel_results = []

    for channel_id in channels:
        channel_info = http_json(token, f"{api_base}/channels/{channel_id}")
        result = {
            "id": channel_id,
            "name": str(channel_info.get("name") or channel_info.get("id") or channel_id),
            "read": "ok",
            "send": "skipped",
        }
        if send_test:
            payload = {
                "content": (
                    f"[Agent Bridge setup] {agent} write access check. "
                    "Safe to ignore."
                )
            }
            response = http_json(token, f"{api_base}/channels/{channel_id}/messages", method="POST", payload=payload)
            result["send"] = "ok"
            result["message_id"] = str(response.get("id") or "")
        channel_results.append(result)

    return {
        "status": "ok",
        "bot": {
            "id": str(bot.get("id") or ""),
            "username": str(bot.get("username") or ""),
        },
        "channels": channel_results,
    }


def http_telegram_json(token: str, api_base_url: str, method: str, payload: dict[str, Any] | None = None) -> Any:
    body = None
    headers = {
        "User-Agent": "agent-bridge-setup/0.1",
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    base = api_base_url.rstrip("/")
    request = Request(
        f"{base}/bot{token}/{method}",
        data=body,
        headers=headers,
        method="POST" if payload is not None else "GET",
    )
    try:
        with urlopen(request, timeout=15) as response:
            data = response.read().decode("utf-8")
            if not data:
                return {}
            payload = json.loads(data)
    except HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise SetupError(f"Telegram API {method} failed: HTTP {exc.code}: {details}") from exc
    except URLError as exc:
        raise SetupError(f"Telegram API {method} failed: {exc.reason}") from exc

    if not payload.get("ok", False):
        raise SetupError(f"Telegram API {method} failed: {payload}")
    return payload.get("result") or {}


def validate_telegram(
    token: str,
    api_base_url: str,
    send_test: bool,
    agent: str,
    test_chat_id: str,
) -> dict[str, Any]:
    bot = http_telegram_json(token, api_base_url, "getMe")
    result: dict[str, Any] = {
        "status": "ok",
        "bot": {
            "id": str(bot.get("id") or ""),
            "username": str(bot.get("username") or ""),
        },
        "send": "skipped",
        "test_chat_id": test_chat_id,
    }
    if send_test and test_chat_id:
        response = http_telegram_json(
            token,
            api_base_url,
            "sendMessage",
            {
                "chat_id": test_chat_id,
                "text": f"[Agent Bridge setup] {agent} write access check. Safe to ignore.",
                "disable_web_page_preview": True,
            },
        )
        result["send"] = "ok"
        result["message_id"] = str(response.get("message_id") or "")
    return result


def build_access_payload(existing: dict[str, Any], channels: list[str], allow_from: list[str], require_mention: bool) -> dict[str, Any]:
    payload = dict(existing)
    old_groups = payload.get("groups") or {}
    groups: dict[str, Any] = {}
    for channel_id in channels:
        old_entry = old_groups.get(channel_id) or {}
        preserved_allow_from = normalize_id_list(old_entry.get("allowFrom") or [], "group allow_from")
        groups[channel_id] = {
            "requireMention": require_mention,
            "allowFrom": preserved_allow_from,
        }

    pending = payload.get("pending")
    if not isinstance(pending, dict):
        pending = {}

    payload["dmPolicy"] = "allowlist"
    payload["allowFrom"] = allow_from
    payload["groups"] = groups
    payload["pending"] = pending
    return payload


def print_result(result: dict[str, Any], *, stream: Any = sys.stdout) -> None:
    print(f"agent: {result['agent']}", file=stream)
    print(f"discord_dir: {result['discord_dir']}", file=stream)
    print(f"env_file: {result['env_file']}", file=stream)
    print(f"access_file: {result['access_file']}", file=stream)
    print(f"token_source: {result['token_source']}", file=stream)
    print(f"channels: {', '.join(result['channels'])}", file=stream)
    if result["allow_from"]:
        print(f"allow_from: {', '.join(result['allow_from'])}", file=stream)
    else:
        print("allow_from: (none)", file=stream)
    print(f"require_mention: {'yes' if result['require_mention'] else 'no'}", file=stream)
    print(f"write_status: {result['write_status']}", file=stream)

    validation = result.get("validation") or {}
    print(f"validation: {validation.get('status', 'skipped')}", file=stream)
    if validation.get("bot"):
        bot = validation["bot"]
        print(f"bot: {bot.get('username', '')} ({bot.get('id', '')})", file=stream)
    for channel in validation.get("channels") or []:
        line = f"channel {channel['id']}: read={channel.get('read', '-')}"
        send_status = channel.get("send")
        if send_status:
            line += f" send={send_status}"
        print(line, file=stream)

    for warning in result.get("warnings") or []:
        print(f"warning: {warning}", file=stream)

    if result.get("error"):
        print(f"error: {result['error']}", file=stream)


def print_telegram_result(result: dict[str, Any], *, stream: Any = sys.stdout) -> None:
    print(f"agent: {result['agent']}", file=stream)
    print(f"telegram_dir: {result['telegram_dir']}", file=stream)
    print(f"env_file: {result['env_file']}", file=stream)
    print(f"access_file: {result['access_file']}", file=stream)
    print(f"token_source: {result['token_source']}", file=stream)
    if result["allow_from"]:
        print(f"allow_from: {', '.join(result['allow_from'])}", file=stream)
    else:
        print("allow_from: (none)", file=stream)
    if result["default_chat"]:
        print(f"default_chat: {result['default_chat']}", file=stream)
    else:
        print("default_chat: (unset)", file=stream)
    print(f"write_status: {result['write_status']}", file=stream)

    validation = result.get("validation") or {}
    print(f"validation: {validation.get('status', 'skipped')}", file=stream)
    if validation.get("bot"):
        bot = validation["bot"]
        print(f"bot: {bot.get('username', '')} ({bot.get('id', '')})", file=stream)
    if validation.get("test_chat_id"):
        print(f"test_chat_id: {validation['test_chat_id']}", file=stream)
    if validation.get("send"):
        print(f"send: {validation['send']}", file=stream)

    for warning in result.get("warnings") or []:
        print(f"warning: {warning}", file=stream)

    if result.get("error"):
        print(f"error: {result['error']}", file=stream)


def cmd_discord(args: argparse.Namespace) -> int:
    discord_dir = Path(args.discord_dir).expanduser()
    inspected = inspect_discord_dir(discord_dir)
    access_payload = inspected["access_payload"]
    warnings: list[str] = []
    interactive = sys.stdin.isatty() and sys.stdout.isatty() and not args.yes

    result: dict[str, Any] = {
        "agent": args.agent,
        "discord_dir": str(discord_dir),
        "env_file": str(inspected["env_path"]),
        "access_file": str(inspected["access_path"]),
        "token_source": "",
        "channels": [],
        "allow_from": [],
        "require_mention": False,
        "write_status": "pending",
        "validation": {"status": "skipped", "channels": []},
        "warnings": warnings,
    }

    try:
        accounts = load_channel_accounts(Path(args.runtime_config), "discord") if args.runtime_config else {}
        token = str(args.token or "").strip()
        token_source = ""
        if token:
            token_source = "flag"
        elif args.channel_account:
            token = load_account_token(Path(args.runtime_config), "discord", args.channel_account)
            token_source = f"channel:{args.channel_account}"
        elif inspected["token"]:
            token = inspected["token"]
            token_source = "existing:.discord/.env"
        elif accounts:
            candidates = candidate_channel_accounts(args.agent, accounts)
            if candidates and not interactive:
                choice = candidates[0]
                token = load_account_token(Path(args.runtime_config), "discord", choice)
                token_source = f"channel:{choice}"
            elif interactive and candidates:
                default_account = candidates[0]
                choice = prompt_text(
                    "Discord channel account to import (enter 'skip' to paste manually)",
                    default_account,
                )
                if choice.lower() not in {"skip", "none", "manual"}:
                    token = load_account_token(Path(args.runtime_config), "discord", choice)
                    token_source = f"channel:{choice}"
        elif not token:
            token = load_claude_plugin_channel_token("discord")
            if token:
                token_source = "claude-plugin:.claude/channels/discord/.env"

        if not token and interactive:
            token = prompt_text("Discord bot token", secret=True)
            token_source = "prompt"
        if not token:
            raise SetupError("Discord bot token is required. Pass --token or --channel-account, or run in an interactive TTY.")

        explicit_channels = normalize_id_list(args.channel or [], "channel ids")
        default_channels = explicit_channels or inspected["channels"]
        if not default_channels and args.suggested_channel:
            default_channels = normalize_id_list([args.suggested_channel], "suggested channel id")
        if interactive and not explicit_channels:
            default_csv = ",".join(default_channels)
            raw_channels = prompt_text("Discord channel id(s), comma-separated", default_csv)
            channels = normalize_id_list([raw_channels], "channel ids")
        else:
            channels = default_channels
        if not channels:
            raise SetupError("At least one Discord channel id is required. Pass --channel or set BRIDGE_AGENT_DISCORD_CHANNEL_ID for the agent.")

        explicit_allow_from = normalize_id_list(args.allow_from or [], "allow_from")
        if interactive and not explicit_allow_from:
            default_allow_csv = ",".join(inspected["allow_from"])
            raw_allow_from = prompt_text("Optional DM allowFrom user id(s), comma-separated", default_allow_csv)
            allow_from = normalize_id_list([raw_allow_from], "allow_from")
        else:
            allow_from = explicit_allow_from or inspected["allow_from"]

        require_mention = bool(args.require_mention or inspected["require_mention"])
        send_test = not args.skip_send_test
        if interactive and not args.skip_validate and not args.skip_send_test:
            send_test = prompt_yes_no("Send a Discord write-access test message now?", True)

        if not args.suggested_channel:
            warnings.append(
                f"BRIDGE_AGENT_DISCORD_CHANNEL_ID is unset for {args.agent}. "
                f"Add BRIDGE_AGENT_DISCORD_CHANNEL_ID[\"{args.agent}\"]=\"{channels[0]}\" to agent-roster.local.sh for wake relay metadata."
            )
        elif args.suggested_channel not in channels:
            warnings.append(
                f"Roster primary Discord channel ({args.suggested_channel}) is not in the configured access.json allowlist. "
                f"Update the roster or include that channel here."
            )

        result["token_source"] = token_source or "existing:.discord/.env"
        result["channels"] = channels
        result["allow_from"] = allow_from
        result["require_mention"] = require_mention

        access_doc = build_access_payload(access_payload, channels, allow_from, require_mention)

        if args.dry_run:
            result["write_status"] = "dry_run"
            result["validation"] = {"status": "dry_run", "channels": []}
            print_result(result)
            return 0

        discord_dir.mkdir(parents=True, exist_ok=True)
        save_text(inspected["env_path"], f"DISCORD_BOT_TOKEN={token}\n")
        save_json(inspected["access_path"], access_doc)
        result["write_status"] = "ok"

        if args.skip_validate:
            result["validation"] = {"status": "skipped", "channels": []}
            print_result(result)
            return 0

        validation = validate_discord(token, channels, args.api_base_url, send_test, args.agent)
        result["validation"] = validation
        print_result(result)
        return 0
    except SetupError as exc:
        result["error"] = str(exc)
        if result["write_status"] == "pending":
            result["write_status"] = "skipped"
        if result["token_source"] == "":
            result["token_source"] = "(unset)"
        print_result(result, stream=sys.stderr)
        return 1


def cmd_telegram(args: argparse.Namespace) -> int:
    telegram_dir = Path(args.telegram_dir).expanduser()
    inspected = inspect_telegram_dir(telegram_dir)
    access_payload = inspected["access_payload"]
    warnings: list[str] = []
    interactive = sys.stdin.isatty() and sys.stdout.isatty() and not args.yes

    result: dict[str, Any] = {
        "agent": args.agent,
        "telegram_dir": str(telegram_dir),
        "env_file": str(inspected["env_path"]),
        "access_file": str(inspected["access_path"]),
        "token_source": "",
        "allow_from": [],
        "default_chat": "",
        "write_status": "pending",
        "validation": {"status": "skipped"},
        "warnings": warnings,
    }

    try:
        accounts = load_channel_accounts(Path(args.runtime_config), "telegram") if args.runtime_config else {}
        token = str(args.token or "").strip()
        token_source = ""
        if token:
            token_source = "flag"
        elif args.channel_account:
            token = load_account_token(Path(args.runtime_config), "telegram", args.channel_account)
            token_source = f"channel:{args.channel_account}"
        elif inspected["token"]:
            token = inspected["token"]
            token_source = "existing:.telegram/.env"
        elif accounts:
            candidates = candidate_channel_accounts(args.agent, accounts)
            if candidates and not interactive:
                choice = candidates[0]
                token = load_account_token(Path(args.runtime_config), "telegram", choice)
                token_source = f"channel:{choice}"
            elif interactive and candidates:
                default_account = candidates[0]
                choice = prompt_text(
                    "Configured Telegram channel account to import (enter 'skip' to paste manually)",
                    default_account,
                )
                if choice.lower() not in {"skip", "none", "manual"}:
                    token = load_account_token(Path(args.runtime_config), "telegram", choice)
                    token_source = f"channel:{choice}"
        elif not token:
            token = load_claude_plugin_channel_token("telegram")
            if token:
                token_source = "claude-plugin:.claude/channels/telegram/.env"

        if not token and interactive:
            token = prompt_text("Telegram bot token", secret=True)
            token_source = "prompt"
        if not token:
            raise SetupError("Telegram bot token is required. Pass --token or --channel-account, or run in an interactive TTY.")

        explicit_allow_from = normalize_id_list(args.allow_from or [], "allow_from")
        if interactive and not explicit_allow_from:
            default_allow_csv = ",".join(inspected["allow_from"])
            raw_allow_from = prompt_text("Allowed Telegram user/chat id(s), comma-separated", default_allow_csv)
            allow_from = normalize_id_list([raw_allow_from], "allow_from")
        else:
            allow_from = explicit_allow_from or inspected["allow_from"]

        default_chat = str(args.default_chat or inspected["default_chat"]).strip()
        if interactive and not args.default_chat:
            default_chat = prompt_text("Default Telegram chat id for test messages / notify target (optional)", default_chat)

        test_chat_id = str(args.test_chat or default_chat or (allow_from[0] if allow_from else "")).strip()
        send_test = not args.skip_send_test and bool(test_chat_id)
        if interactive and not args.skip_validate and test_chat_id:
            send_test = prompt_yes_no("Send a Telegram write-access test message now?", True)
        if not allow_from:
            warnings.append(
                f"No Telegram allow_from ids configured for {args.agent}. Update {telegram_dir / 'access.json'} so the plugin can accept messages from intended users."
            )
        if not default_chat:
            warnings.append(
                f"No default Telegram chat id configured for {args.agent}. Set --default-chat if you want a stable notify/test target."
            )

        result["token_source"] = token_source or "existing:.telegram/.env"
        result["allow_from"] = allow_from
        result["default_chat"] = default_chat

        access_doc = dict(access_payload)
        access_doc["dmPolicy"] = "allowlist"
        access_doc["allowFrom"] = allow_from
        if default_chat:
            access_doc["defaultChatId"] = default_chat
        elif "defaultChatId" in access_doc:
            access_doc.pop("defaultChatId", None)
        pending = access_doc.get("pending")
        if not isinstance(pending, dict):
            access_doc["pending"] = {}

        if args.dry_run:
            result["write_status"] = "dry_run"
            result["validation"] = {"status": "dry_run"}
            print_telegram_result(result)
            return 0

        telegram_dir.mkdir(parents=True, exist_ok=True)
        save_text(inspected["env_path"], f"TELEGRAM_BOT_TOKEN={token}\n")
        save_json(inspected["access_path"], access_doc)
        result["write_status"] = "ok"

        if args.skip_validate:
            result["validation"] = {"status": "skipped"}
            print_telegram_result(result)
            return 0

        validation = validate_telegram(token, args.api_base_url, send_test, args.agent, test_chat_id)
        result["validation"] = validation
        print_telegram_result(result)
        return 0
    except SetupError as exc:
        result["error"] = str(exc)
        if result["write_status"] == "pending":
            result["write_status"] = "skipped"
        if result["token_source"] == "":
            result["token_source"] = "(unset)"
        print_telegram_result(result, stream=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-setup.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    discord_parser = subparsers.add_parser("discord")
    discord_parser.add_argument("--agent", required=True)
    discord_parser.add_argument("--discord-dir", required=True)
    discord_parser.add_argument("--suggested-channel", default="")
    discord_parser.add_argument("--runtime-config", default="")
    discord_parser.add_argument("--openclaw-config", dest="runtime_config", help=argparse.SUPPRESS)
    discord_parser.add_argument("--channel-account")
    discord_parser.add_argument("--openclaw-account", dest="channel_account", help=argparse.SUPPRESS)
    discord_parser.add_argument("--token")
    discord_parser.add_argument("--channel", action="append", default=[])
    discord_parser.add_argument("--allow-from", action="append", default=[])
    discord_parser.add_argument("--require-mention", action="store_true")
    discord_parser.add_argument("--yes", action="store_true")
    discord_parser.add_argument("--skip-validate", action="store_true")
    discord_parser.add_argument("--skip-send-test", action="store_true")
    discord_parser.add_argument("--dry-run", action="store_true")
    discord_parser.add_argument("--api-base-url", default="https://discord.com/api/v10")
    discord_parser.set_defaults(handler=cmd_discord)

    telegram_parser = subparsers.add_parser("telegram")
    telegram_parser.add_argument("--agent", required=True)
    telegram_parser.add_argument("--telegram-dir", required=True)
    telegram_parser.add_argument("--runtime-config", default="")
    telegram_parser.add_argument("--openclaw-config", dest="runtime_config", help=argparse.SUPPRESS)
    telegram_parser.add_argument("--channel-account")
    telegram_parser.add_argument("--openclaw-account", dest="channel_account", help=argparse.SUPPRESS)
    telegram_parser.add_argument("--token")
    telegram_parser.add_argument("--allow-from", action="append", default=[])
    telegram_parser.add_argument("--default-chat", default="")
    telegram_parser.add_argument("--test-chat", default="")
    telegram_parser.add_argument("--yes", action="store_true")
    telegram_parser.add_argument("--skip-validate", action="store_true")
    telegram_parser.add_argument("--skip-send-test", action="store_true")
    telegram_parser.add_argument("--dry-run", action="store_true")
    telegram_parser.add_argument("--api-base-url", default="https://api.telegram.org")
    telegram_parser.set_defaults(handler=cmd_telegram)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
