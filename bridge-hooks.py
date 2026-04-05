#!/usr/bin/env python3
"""Manage Claude Code hook settings for Agent Bridge."""

from __future__ import annotations

import argparse
import json
import shlex
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


def stop_hook_command(bridge_home: Path, bash_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "mark-idle.sh"
    return shlex.join([bash_bin, str(hook_path)])


def ensure_settings_root(path: Path) -> dict[str, Any]:
    payload = load_json(path)
    if payload in (None, ""):
        payload = {}
    if not isinstance(payload, dict):
        raise SystemExit(f"settings root must be a JSON object: {path}")
    return payload


def hooks_list(settings: dict[str, Any], event_name: str) -> list[dict[str, Any]]:
    hooks_root = settings.get("hooks")
    if not isinstance(hooks_root, dict):
        hooks_root = {}
        settings["hooks"] = hooks_root

    event_value = hooks_root.get(event_name)
    if isinstance(event_value, list):
        return event_value

    event_list: list[dict[str, Any]] = []
    hooks_root[event_name] = event_list
    return event_list


def is_mark_idle_hook(command: str) -> bool:
    return "mark-idle.sh" in str(command)


def find_stop_hook(event_hooks: list[dict[str, Any]]) -> tuple[dict[str, Any], dict[str, Any]] | tuple[None, None]:
    for group in event_hooks:
        if not isinstance(group, dict):
            continue
        hooks = group.get("hooks")
        if not isinstance(hooks, list):
            continue
        for hook in hooks:
            if not isinstance(hook, dict):
                continue
            if hook.get("type") != "command":
                continue
            if is_mark_idle_hook(str(hook.get("command") or "")):
                return group, hook
    return None, None


def shell_line(key: str, value: str) -> str:
    return f"{key}={shlex.quote(str(value))}"


def print_payload(data: dict[str, str], fmt: str) -> None:
    if fmt == "shell":
      for key, value in data.items():
          print(shell_line(key, value))
      return

    print(f"settings_file: {data['HOOK_SETTINGS_FILE']}")
    print(f"status: {data['HOOK_STATUS']}")
    print(f"stop_hook: {data['HOOK_STOP_HOOK']}")
    if data.get("HOOK_COMMAND"):
        print(f"command: {data['HOOK_COMMAND']}")


def cmd_status_stop_hook(args: argparse.Namespace) -> int:
    settings_path = Path(args.workdir).expanduser() / ".claude" / "settings.json"
    settings = ensure_settings_root(settings_path)
    stop_hooks = hooks_list(settings, "Stop")
    _group, hook = find_stop_hook(stop_hooks)
    command = str(hook.get("command") or "") if hook else ""
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "present" if hook else "missing",
        "HOOK_STOP_HOOK": "present" if hook else "missing",
        "HOOK_COMMAND": command,
    }
    print_payload(payload, args.format)
    return 0 if hook else 1


def cmd_ensure_stop_hook(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    settings_path = Path(args.workdir).expanduser() / ".claude" / "settings.json"
    settings = ensure_settings_root(settings_path)
    stop_hooks = hooks_list(settings, "Stop")
    desired_command = stop_hook_command(bridge_home, args.bash_bin)
    changed = False

    group, hook = find_stop_hook(stop_hooks)
    if hook is None:
        stop_hooks.append(
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": desired_command,
                        "timeout": 3,
                    }
                ]
            }
        )
        changed = True
    else:
        if hook.get("type") != "command":
            hook["type"] = "command"
            changed = True
        if str(hook.get("command") or "") != desired_command:
            hook["command"] = desired_command
            changed = True
        if int(hook.get("timeout") or 0) != 3:
            hook["timeout"] = 3
            changed = True
        if group is None:
            changed = True

    if changed:
        save_json(settings_path, settings)

    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "updated" if changed else "unchanged",
        "HOOK_STOP_HOOK": "present",
        "HOOK_COMMAND": desired_command,
    }
    print_payload(payload, args.format)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-hooks.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    ensure_parser = subparsers.add_parser("ensure-stop-hook")
    ensure_parser.add_argument("--workdir", required=True)
    ensure_parser.add_argument("--bridge-home", required=True)
    ensure_parser.add_argument("--bash-bin", required=True)
    ensure_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_parser.set_defaults(handler=cmd_ensure_stop_hook)

    status_parser = subparsers.add_parser("status-stop-hook")
    status_parser.add_argument("--workdir", required=True)
    status_parser.add_argument("--bridge-home", required=True)
    status_parser.add_argument("--bash-bin", required=True)
    status_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_parser.set_defaults(handler=cmd_status_stop_hook)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
