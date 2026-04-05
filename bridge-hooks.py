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


def prompt_hook_command(bridge_home: Path, bash_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "clear-idle.sh"
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


def is_clear_idle_hook(command: str) -> bool:
    return "clear-idle.sh" in str(command)


def find_command_hook(
    event_hooks: list[dict[str, Any]], predicate: Any
) -> tuple[dict[str, Any], dict[str, Any]] | tuple[None, None]:
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
            if predicate(str(hook.get("command") or "")):
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
    if data.get("HOOK_STOP_HOOK"):
        print(f"stop_hook: {data['HOOK_STOP_HOOK']}")
    if data.get("HOOK_PROMPT_HOOK"):
        print(f"prompt_hook: {data['HOOK_PROMPT_HOOK']}")
    if data.get("HOOK_COMMAND"):
        print(f"command: {data['HOOK_COMMAND']}")
    if data.get("HOOK_ADDITIONAL_CONTEXT"):
        print(f"additional_context: {data['HOOK_ADDITIONAL_CONTEXT']}")


def cmd_status_stop_hook(args: argparse.Namespace) -> int:
    settings_path = Path(args.workdir).expanduser() / ".claude" / "settings.json"
    settings = ensure_settings_root(settings_path)
    stop_hooks = hooks_list(settings, "Stop")
    _group, hook = find_command_hook(stop_hooks, is_mark_idle_hook)
    command = str(hook.get("command") or "") if hook else ""
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "present" if hook else "missing",
        "HOOK_STOP_HOOK": "present" if hook else "missing",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": command,
        "HOOK_ADDITIONAL_CONTEXT": "true" if hook and bool(hook.get("additionalContext")) else "false",
    }
    print_payload(payload, args.format)
    return 0 if hook else 1


def ensure_command_hook(
    settings_path: Path,
    event_name: str,
    desired_command: str,
    matcher: Any,
    *,
    timeout: int = 3,
    additional_context: bool | None = None,
) -> bool:
    settings = ensure_settings_root(settings_path)
    event_hooks = hooks_list(settings, event_name)
    changed = False

    group, hook = find_command_hook(event_hooks, matcher)
    if hook is None:
        event_hooks.append(
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": desired_command,
                        "timeout": timeout,
                        **({"additionalContext": additional_context} if additional_context is not None else {}),
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
        if int(hook.get("timeout") or 0) != timeout:
            hook["timeout"] = timeout
            changed = True
        if additional_context is not None and bool(hook.get("additionalContext")) != bool(additional_context):
            hook["additionalContext"] = additional_context
            changed = True
        if group is None:
            changed = True

    if changed:
        save_json(settings_path, settings)

    return changed


def cmd_ensure_stop_hook(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    settings_path = Path(args.workdir).expanduser() / ".claude" / "settings.json"
    desired_command = stop_hook_command(bridge_home, args.bash_bin)
    changed = ensure_command_hook(
        settings_path,
        "Stop",
        desired_command,
        is_mark_idle_hook,
        timeout=3,
        additional_context=True,
    )

    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "updated" if changed else "unchanged",
        "HOOK_STOP_HOOK": "present",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": desired_command,
        "HOOK_ADDITIONAL_CONTEXT": "true",
    }
    print_payload(payload, args.format)
    return 0


def cmd_status_prompt_hook(args: argparse.Namespace) -> int:
    settings_path = Path(args.workdir).expanduser() / ".claude" / "settings.json"
    settings = ensure_settings_root(settings_path)
    prompt_hooks = hooks_list(settings, "UserPromptSubmit")
    _group, hook = find_command_hook(prompt_hooks, is_clear_idle_hook)
    command = str(hook.get("command") or "") if hook else ""
    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "present" if hook else "missing",
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "present" if hook else "missing",
        "HOOK_COMMAND": command,
    }
    print_payload(payload, args.format)
    return 0 if hook else 1


def cmd_ensure_prompt_hook(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    settings_path = Path(args.workdir).expanduser() / ".claude" / "settings.json"
    desired_command = prompt_hook_command(bridge_home, args.bash_bin)
    changed = ensure_command_hook(
        settings_path,
        "UserPromptSubmit",
        desired_command,
        is_clear_idle_hook,
        timeout=3,
    )

    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": "updated" if changed else "unchanged",
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "present",
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

    ensure_prompt_parser = subparsers.add_parser("ensure-prompt-hook")
    ensure_prompt_parser.add_argument("--workdir", required=True)
    ensure_prompt_parser.add_argument("--bridge-home", required=True)
    ensure_prompt_parser.add_argument("--bash-bin", required=True)
    ensure_prompt_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_prompt_parser.set_defaults(handler=cmd_ensure_prompt_hook)

    status_prompt_parser = subparsers.add_parser("status-prompt-hook")
    status_prompt_parser.add_argument("--workdir", required=True)
    status_prompt_parser.add_argument("--bridge-home", required=True)
    status_prompt_parser.add_argument("--bash-bin", required=True)
    status_prompt_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_prompt_parser.set_defaults(handler=cmd_status_prompt_hook)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
