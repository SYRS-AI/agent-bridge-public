#!/usr/bin/env python3
"""Manage Claude Code .mcp.json webhook channel entries for Agent Bridge."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load_json(path: Path) -> Any:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    tmp.replace(path)


def ensure_mcp_root(path: Path) -> dict[str, Any]:
    payload = load_json(path)
    if payload in (None, ""):
        payload = {}
    if not isinstance(payload, dict):
        raise SystemExit(f"mcp root must be a JSON object: {path}")
    return payload


def mcp_servers(payload: dict[str, Any]) -> dict[str, Any]:
    value = payload.get("mcpServers")
    if isinstance(value, dict):
      return value
    value = {}
    payload["mcpServers"] = value
    return value


def webhook_entry(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "transport": "stdio",
        "command": args.python_bin,
        "args": [args.server_script],
        "env": {
            "BRIDGE_WEBHOOK_PORT": str(args.port),
            "BRIDGE_WEBHOOK_AGENT": args.agent,
            "BRIDGE_HOME": args.bridge_home,
            "BRIDGE_STATE_DIR": args.bridge_state_dir,
            "PYTHONUNBUFFERED": "1",
        },
    }


def print_payload(data: dict[str, str], fmt: str) -> None:
    if fmt == "shell":
        for key, value in data.items():
            print(f"{key}={json.dumps(str(value))}")
        return

    print(f"mcp_file: {data['MCP_FILE']}")
    print(f"status: {data['MCP_STATUS']}")
    print(f"server_name: {data['MCP_SERVER_NAME']}")
    print(f"webhook_port: {data['MCP_WEBHOOK_PORT']}")
    print(f"command: {data['MCP_COMMAND']}")


def cmd_status_webhook_server(args: argparse.Namespace) -> int:
    mcp_path = Path(args.workdir).expanduser() / ".mcp.json"
    payload = ensure_mcp_root(mcp_path)
    entry = mcp_servers(payload).get(args.server_name)
    desired = webhook_entry(args)
    command = f"{desired['command']} {desired['args'][0]}"
    present = entry == desired
    print_payload(
        {
            "MCP_FILE": str(mcp_path),
            "MCP_STATUS": "present" if present else "missing",
            "MCP_SERVER_NAME": args.server_name,
            "MCP_WEBHOOK_PORT": str(args.port),
            "MCP_COMMAND": command,
        },
        args.format,
    )
    return 0 if present else 1


def cmd_ensure_webhook_server(args: argparse.Namespace) -> int:
    mcp_path = Path(args.workdir).expanduser() / ".mcp.json"
    payload = ensure_mcp_root(mcp_path)
    servers = mcp_servers(payload)
    desired = webhook_entry(args)
    changed = servers.get(args.server_name) != desired
    servers[args.server_name] = desired
    if changed:
        save_json(mcp_path, payload)

    command = f"{desired['command']} {desired['args'][0]}"
    print_payload(
        {
            "MCP_FILE": str(mcp_path),
            "MCP_STATUS": "updated" if changed else "unchanged",
            "MCP_SERVER_NAME": args.server_name,
            "MCP_WEBHOOK_PORT": str(args.port),
            "MCP_COMMAND": command,
        },
        args.format,
    )
    return 0


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--bridge-home", required=True)
    parser.add_argument("--bridge-state-dir", required=True)
    parser.add_argument("--python-bin", required=True)
    parser.add_argument("--server-script", required=True)
    parser.add_argument("--server-name", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--format", choices=("text", "shell"), default="text")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-channels.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    ensure_parser = subparsers.add_parser("ensure-webhook-server")
    add_common_args(ensure_parser)
    ensure_parser.set_defaults(handler=cmd_ensure_webhook_server)

    status_parser = subparsers.add_parser("status-webhook-server")
    add_common_args(status_parser)
    status_parser.set_defaults(handler=cmd_status_webhook_server)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
