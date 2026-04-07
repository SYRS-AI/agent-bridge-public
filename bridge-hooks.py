#!/usr/bin/env python3
"""Manage Claude Code and Codex hook settings for Agent Bridge."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import shlex
from datetime import datetime
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
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def stop_hook_command(bridge_home: Path, bash_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "mark-idle.sh"
    return shlex.join([bash_bin, str(hook_path)])


def prompt_hook_command(bridge_home: Path, bash_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "clear-idle.sh"
    return shlex.join([bash_bin, str(hook_path)])


def codex_session_start_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "codex-session-start.py"
    return shlex.join([python_bin, str(hook_path)])


def codex_stop_hook_command(bridge_home: Path, python_bin: str) -> str:
    hook_path = bridge_home / "hooks" / "codex-stop.py"
    return shlex.join([python_bin, str(hook_path)])


def resolve_settings_path(args: argparse.Namespace) -> Path:
    settings_file = getattr(args, "settings_file", None)
    if settings_file:
        return Path(settings_file).expanduser()
    return Path(args.workdir).expanduser() / ".claude" / "settings.json"


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


def is_codex_session_start_hook(command: str) -> bool:
    return "codex-session-start.py" in str(command)


def is_codex_stop_hook(command: str) -> bool:
    return "codex-stop.py" in str(command)


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
    settings_path = resolve_settings_path(args)
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
    status_message: str | None = None,
    group_matcher: str | None = None,
) -> bool:
    settings = ensure_settings_root(settings_path)
    event_hooks = hooks_list(settings, event_name)
    changed = False

    group, hook = find_command_hook(event_hooks, matcher)
    if hook is None:
        event_hooks.append(
            {
                **({"matcher": group_matcher} if group_matcher is not None else {}),
                "hooks": [
                    {
                        "type": "command",
                        "command": desired_command,
                        "timeout": timeout,
                        **({"statusMessage": status_message} if status_message is not None else {}),
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
        if status_message is not None and str(hook.get("statusMessage") or "") != status_message:
            hook["statusMessage"] = status_message
            changed = True
        if additional_context is not None and bool(hook.get("additionalContext")) != bool(additional_context):
            hook["additionalContext"] = additional_context
            changed = True
        if group_matcher is not None and group is not None and str(group.get("matcher") or "") != group_matcher:
            group["matcher"] = group_matcher
            changed = True
        if group is None:
            changed = True

    if changed:
        save_json(settings_path, settings)

    return changed


def cmd_ensure_stop_hook(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    settings_path = resolve_settings_path(args)
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
    settings_path = resolve_settings_path(args)
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
    settings_path = resolve_settings_path(args)
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


def codex_hooks_path(args: argparse.Namespace) -> Path:
    hooks_file = getattr(args, "codex_hooks_file", None)
    if hooks_file:
        return Path(hooks_file).expanduser()
    return Path.home() / ".codex" / "hooks.json"


def print_codex_payload(data: dict[str, str], fmt: str) -> None:
    if fmt == "shell":
        for key, value in data.items():
            print(shell_line(key, value))
        return

    print(f"hooks_file: {data['CODEX_HOOKS_FILE']}")
    print(f"status: {data['CODEX_HOOK_STATUS']}")
    print(f"session_start_hook: {data['CODEX_SESSION_START_HOOK']}")
    print(f"stop_hook: {data['CODEX_STOP_HOOK']}")
    print(f"session_start_command: {data['CODEX_SESSION_START_COMMAND']}")
    print(f"stop_command: {data['CODEX_STOP_COMMAND']}")
    print("feature_flag: launch_cli_override")


def cmd_status_codex_hooks(args: argparse.Namespace) -> int:
    hooks_path = codex_hooks_path(args)
    settings = ensure_settings_root(hooks_path)
    session_hooks = hooks_list(settings, "SessionStart")
    stop_hooks = hooks_list(settings, "Stop")
    _session_group, session_hook = find_command_hook(session_hooks, is_codex_session_start_hook)
    _stop_group, stop_hook = find_command_hook(stop_hooks, is_codex_stop_hook)
    payload = {
        "CODEX_HOOKS_FILE": str(hooks_path),
        "CODEX_HOOK_STATUS": "present" if session_hook and stop_hook else "missing",
        "CODEX_SESSION_START_HOOK": "present" if session_hook else "missing",
        "CODEX_STOP_HOOK": "present" if stop_hook else "missing",
        "CODEX_SESSION_START_COMMAND": str(session_hook.get("command") or "") if session_hook else "",
        "CODEX_STOP_COMMAND": str(stop_hook.get("command") or "") if stop_hook else "",
    }
    print_codex_payload(payload, args.format)
    return 0 if session_hook and stop_hook else 1


def cmd_ensure_codex_hooks(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home).expanduser()
    hooks_path = codex_hooks_path(args)
    hooks_path.parent.mkdir(parents=True, exist_ok=True)
    session_command = codex_session_start_hook_command(bridge_home, args.python_bin)
    stop_command = codex_stop_hook_command(bridge_home, args.python_bin)
    changed = False
    changed = ensure_command_hook(
        hooks_path,
        "SessionStart",
        session_command,
        is_codex_session_start_hook,
        timeout=3,
        status_message="Loading Agent Bridge queue context",
        group_matcher="startup|resume",
    ) or changed
    changed = ensure_command_hook(
        hooks_path,
        "Stop",
        stop_command,
        is_codex_stop_hook,
        timeout=3,
        status_message="Checking Agent Bridge inbox",
    ) or changed

    payload = {
        "CODEX_HOOKS_FILE": str(hooks_path),
        "CODEX_HOOK_STATUS": "updated" if changed else "unchanged",
        "CODEX_SESSION_START_HOOK": "present",
        "CODEX_STOP_HOOK": "present",
        "CODEX_SESSION_START_COMMAND": session_command,
        "CODEX_STOP_COMMAND": stop_command,
    }
    print_codex_payload(payload, args.format)
    return 0


def next_backup_path(path: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    candidate = path.with_name(f"{path.stem}.agent-bridge.bak-{stamp}{path.suffix}")
    index = 1
    while candidate.exists():
      candidate = path.with_name(f"{path.stem}.agent-bridge.bak-{stamp}-{index}{path.suffix}")
      index += 1
    return candidate


def cmd_link_shared_settings(args: argparse.Namespace) -> int:
    settings_path = Path(args.workdir).expanduser() / ".claude" / "settings.json"
    shared_path = Path(args.shared_settings_file).expanduser()
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    shared_path.parent.mkdir(parents=True, exist_ok=True)

    backup_path = ""
    status = "unchanged"

    if settings_path.is_symlink():
        current_target = os.path.realpath(settings_path)
        desired_target = os.path.realpath(shared_path)
        if current_target == desired_target:
            status = "unchanged"
        else:
            settings_path.unlink()
            status = "updated"
    elif settings_path.exists():
        backup = next_backup_path(settings_path)
        shutil.copy2(settings_path, backup)
        settings_path.unlink()
        backup_path = str(backup)
        status = "updated"
    else:
        status = "updated"

    if not settings_path.exists():
        rel_target = os.path.relpath(shared_path, start=settings_path.parent)
        settings_path.symlink_to(rel_target)

    payload = {
        "HOOK_SETTINGS_FILE": str(settings_path),
        "HOOK_STATUS": status,
        "HOOK_STOP_HOOK": "",
        "HOOK_PROMPT_HOOK": "",
        "HOOK_COMMAND": str(shared_path),
        "HOOK_ADDITIONAL_CONTEXT": "",
    }
    print_payload(payload, args.format)
    if backup_path and args.format != "shell":
        print(f"backup_file: {backup_path}")
        print(f"symlink_target: {os.readlink(settings_path)}")
    elif args.format == "shell":
        print(shell_line("HOOK_BACKUP_FILE", backup_path))
        print(shell_line("HOOK_SYMLINK_TARGET", os.readlink(settings_path)))
    return 0


def claude_user_settings_path(args: argparse.Namespace) -> Path:
    user_file = getattr(args, "claude_user_file", None)
    if user_file:
        return Path(user_file).expanduser()
    return Path.home() / ".claude.json"


def cmd_ensure_project_trust(args: argparse.Namespace) -> int:
    user_file = claude_user_settings_path(args)
    workdir = str(Path(args.workdir).expanduser())
    payload = load_json(user_file)
    if payload in (None, ""):
        payload = {}
    if not isinstance(payload, dict):
        raise SystemExit(f"claude user settings root must be a JSON object: {user_file}")

    projects = payload.get("projects")
    if not isinstance(projects, dict):
        projects = {}
        payload["projects"] = projects

    project = projects.get(workdir)
    if not isinstance(project, dict):
        project = {}
        projects[workdir] = project

    changed = False
    if project.get("hasTrustDialogAccepted") is not True:
        project["hasTrustDialogAccepted"] = True
        changed = True
    if not isinstance(project.get("allowedTools"), list):
        project["allowedTools"] = []
        changed = True
    if not isinstance(project.get("mcpContextUris"), list):
        project["mcpContextUris"] = []
        changed = True
    if not isinstance(project.get("mcpServers"), dict):
        project["mcpServers"] = {}
        changed = True
    if not isinstance(project.get("enabledMcpjsonServers"), list):
        project["enabledMcpjsonServers"] = []
        changed = True
    if not isinstance(project.get("disabledMcpjsonServers"), list):
        project["disabledMcpjsonServers"] = []
        changed = True

    if changed:
        save_json(user_file, payload)

    status = "updated" if changed else "unchanged"
    if args.format == "shell":
        print(shell_line("HOOK_SETTINGS_FILE", str(user_file)))
        print(shell_line("HOOK_STATUS", status))
        print(shell_line("HOOK_PROJECT", workdir))
        print(shell_line("HOOK_TRUST_ACCEPTED", "true"))
    else:
        print(f"settings_file: {user_file}")
        print(f"status: {status}")
        print(f"project: {workdir}")
        print("trust_accepted: true")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge-hooks.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    ensure_parser = subparsers.add_parser("ensure-stop-hook")
    ensure_parser.add_argument("--workdir")
    ensure_parser.add_argument("--settings-file")
    ensure_parser.add_argument("--bridge-home", required=True)
    ensure_parser.add_argument("--bash-bin", required=True)
    ensure_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_parser.set_defaults(handler=cmd_ensure_stop_hook)

    status_parser = subparsers.add_parser("status-stop-hook")
    status_parser.add_argument("--workdir")
    status_parser.add_argument("--settings-file")
    status_parser.add_argument("--bridge-home", required=True)
    status_parser.add_argument("--bash-bin", required=True)
    status_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_parser.set_defaults(handler=cmd_status_stop_hook)

    ensure_prompt_parser = subparsers.add_parser("ensure-prompt-hook")
    ensure_prompt_parser.add_argument("--workdir")
    ensure_prompt_parser.add_argument("--settings-file")
    ensure_prompt_parser.add_argument("--bridge-home", required=True)
    ensure_prompt_parser.add_argument("--bash-bin", required=True)
    ensure_prompt_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_prompt_parser.set_defaults(handler=cmd_ensure_prompt_hook)

    status_prompt_parser = subparsers.add_parser("status-prompt-hook")
    status_prompt_parser.add_argument("--workdir")
    status_prompt_parser.add_argument("--settings-file")
    status_prompt_parser.add_argument("--bridge-home", required=True)
    status_prompt_parser.add_argument("--bash-bin", required=True)
    status_prompt_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_prompt_parser.set_defaults(handler=cmd_status_prompt_hook)

    ensure_codex_parser = subparsers.add_parser("ensure-codex-hooks")
    ensure_codex_parser.add_argument("--codex-hooks-file")
    ensure_codex_parser.add_argument("--bridge-home", required=True)
    ensure_codex_parser.add_argument("--python-bin", required=True)
    ensure_codex_parser.add_argument("--format", choices=("text", "shell"), default="text")
    ensure_codex_parser.set_defaults(handler=cmd_ensure_codex_hooks)

    status_codex_parser = subparsers.add_parser("status-codex-hooks")
    status_codex_parser.add_argument("--codex-hooks-file")
    status_codex_parser.add_argument("--format", choices=("text", "shell"), default="text")
    status_codex_parser.set_defaults(handler=cmd_status_codex_hooks)

    link_shared_parser = subparsers.add_parser("link-shared-settings")
    link_shared_parser.add_argument("--workdir", required=True)
    link_shared_parser.add_argument("--shared-settings-file", required=True)
    link_shared_parser.add_argument("--format", choices=("text", "shell"), default="text")
    link_shared_parser.set_defaults(handler=cmd_link_shared_settings)

    trust_parser = subparsers.add_parser("ensure-project-trust")
    trust_parser.add_argument("--workdir", required=True)
    trust_parser.add_argument("--claude-user-file")
    trust_parser.add_argument("--format", choices=("text", "shell"), default="text")
    trust_parser.set_defaults(handler=cmd_ensure_project_trust)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
