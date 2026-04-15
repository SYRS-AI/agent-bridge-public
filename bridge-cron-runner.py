#!/usr/bin/env python3
"""Disposable cron child runner for Agent Bridge."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


RESULT_SCHEMA = {
    "type": "object",
    "properties": {
        "status": {"type": "string"},
        "summary": {"type": "string"},
        "findings": {"type": "array", "items": {"type": "string"}},
        "actions_taken": {"type": "array", "items": {"type": "string"}},
        "needs_human_followup": {"type": "boolean"},
        "recommended_next_steps": {"type": "array", "items": {"type": "string"}},
        "artifacts": {"type": "array", "items": {"type": "string"}},
        "confidence": {"type": "string"},
    },
    "required": [
        "status",
        "summary",
        "findings",
        "actions_taken",
        "needs_human_followup",
        "recommended_next_steps",
        "artifacts",
        "confidence",
    ],
    "additionalProperties": False,
}

COMMON_BIN_DIRS = [
    Path.home() / ".local" / "bin",
    Path.home() / ".nix-profile" / "bin",
    Path.home() / "bin",
    Path("/opt/homebrew/bin"),
    Path("/usr/local/bin"),
]


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def bridge_home() -> Path | None:
    value = os.environ.get("BRIDGE_HOME")
    if not value:
        return None
    return Path(value).expanduser().resolve()


def rel_for_output(path_value: str) -> str:
    path = Path(path_value).expanduser().resolve()
    home = bridge_home()
    if home is not None:
        try:
            return str(path.relative_to(home))
        except ValueError:
            pass
    return str(path)


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def normalize_result(payload: dict[str, Any]) -> dict[str, Any]:
    result = dict(payload)
    result.setdefault("findings", [])
    result.setdefault("actions_taken", [])
    result.setdefault("needs_human_followup", False)
    result.setdefault("recommended_next_steps", [])
    result.setdefault("artifacts", [])
    result.setdefault("confidence", "medium")
    return result


def validate_result(payload: dict[str, Any]) -> dict[str, Any]:
    result = normalize_result(payload)
    missing = [key for key in RESULT_SCHEMA["required"] if key not in result]
    if missing:
        raise ValueError(f"result missing required fields: {', '.join(missing)}")
    if not isinstance(result["summary"], str) or not result["summary"].strip():
        raise ValueError("result summary must be a non-empty string")
    return result


def csv_items(raw: str) -> list[str]:
    values: list[str] = []
    seen: set[str] = set()
    for chunk in str(raw or "").split(","):
        item = chunk.strip()
        if not item or item in seen:
            continue
        seen.add(item)
        values.append(item)
    return values


def channel_enabled(channels: list[str], prefix: str) -> bool:
    return any(item == prefix or item.startswith(f"{prefix}@") for item in channels)


def bool_flag(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return bool(value)


def disposable_needs_channels(request: dict[str, Any]) -> bool:
    return bool_flag(request.get("disposable_needs_channels"))


def build_prompt(request: dict[str, Any], payload_text: str) -> str:
    allow_channel_delivery = bool_flag(request.get("allow_channel_delivery"))
    child_channels_enabled = disposable_needs_channels(request)
    target_channels = csv_items(request.get("target_channels", ""))
    channel_name = str(request.get("job_delivery_channel") or "").strip()
    channel_target = str(request.get("job_delivery_target") or "").strip()
    lines = [
        "You are a disposable cron execution worker for Agent Bridge.",
        "",
        "Act on behalf of the parent agent below.",
        "Do the heavy cron work in this disposable run, then return JSON only.",
        "",
        "Hard rules:",
    ]
    if allow_channel_delivery:
        lines.append("- You may send a user-facing message when the payload explicitly requires it.")
        if child_channels_enabled:
            lines.extend(
                [
                    "- Use only the configured target agent channel tools that are available in this run.",
                    f"- Preferred delivery channel: {channel_name or 'configured target agent channels'}",
                    f"- Preferred delivery target: {channel_target or '(not specified)'}",
                    "- Do not use agent-bridge urgent/task create/task done/handoff for delivery.",
                    "- If direct delivery succeeds and nothing else requires parent review, set needs_human_followup=false.",
                    "- If delivery cannot be completed, set needs_human_followup=true and explain the blocker in recommended_next_steps.",
                    "- Keep the summary concise and operator-facing.",
                ]
            )
        else:
            lines.extend(
                [
                    "- Target agent channels are informational in this disposable run unless the cron job explicitly opts in to load channel tools.",
                    "- If delivery would be needed but channel tools are unavailable, set needs_human_followup=true and explain the intended delivery in recommended_next_steps.",
                    "- Do not use agent-bridge urgent/task create/task done/handoff for delivery.",
                    "- Keep the summary concise and operator-facing.",
                ]
            )
    else:
        lines.extend(
            [
                "- Do not send user-facing messages directly.",
                "- Do not post to Discord, Telegram, email, or any human channel.",
                "- Do not call agent-bridge urgent/task create/task done/handoff for delivery.",
                "- If the legacy cron would normally notify someone, record that in recommended_next_steps instead.",
                "- Set needs_human_followup=true only when the parent agent must review, decide, or act after this run, or when the run fails.",
                "- Routine monitoring with no material change should set needs_human_followup=false.",
                "- If you already completed the work and no parent follow-up is required, leave recommended_next_steps empty and set needs_human_followup=false.",
                "- Keep the summary concise and operator-facing.",
            ]
        )
    if target_channels:
        lines.extend(["", f"Target channels: {', '.join(target_channels)}"])
    lines.extend(
        [
            "",
            f"Parent agent: {request['target_agent']} ({request['target_engine']})",
            f"Job: {request['job_name']}",
            f"Family: {request['family']}",
            f"Slot: {request['slot']}",
            f"Run ID: {request['run_id']}",
            f"Payload file: {request['payload_file']}",
            "",
            "Legacy cron payload follows:",
            "",
            payload_text.rstrip(),
            "",
            "Return JSON only matching the provided schema.",
        ]
    )
    return "\n".join(lines).strip() + "\n"


def augmented_path() -> str:
    entries: list[str] = []
    seen: set[str] = set()
    for raw_entry in os.environ.get("PATH", "").split(os.pathsep):
        entry = raw_entry.strip()
        if not entry or entry in seen:
            continue
        seen.add(entry)
        entries.append(entry)
    for candidate in COMMON_BIN_DIRS:
        entry = str(candidate)
        if candidate.is_dir() and entry not in seen:
            seen.add(entry)
            entries.insert(0, entry)
    return os.pathsep.join(entries)


def runner_env() -> dict[str, str]:
    env = dict(os.environ)
    env["PATH"] = augmented_path()
    return env


def apply_channel_runtime_env(request: dict[str, Any], env: dict[str, str]) -> dict[str, str]:
    channels = csv_items(request.get("target_channels", ""))
    updated = dict(env)
    if channel_enabled(channels, "plugin:discord"):
        discord_dir = str(request.get("target_discord_state_dir") or "").strip()
        if discord_dir:
            updated["DISCORD_STATE_DIR"] = discord_dir
    if channel_enabled(channels, "plugin:telegram"):
        telegram_dir = str(request.get("target_telegram_state_dir") or "").strip()
        if telegram_dir:
            updated["TELEGRAM_STATE_DIR"] = telegram_dir
    return updated


def validate_channel_delivery_request(request: dict[str, Any]) -> None:
    if not bool_flag(request.get("allow_channel_delivery")):
        return

    channels = csv_items(request.get("target_channels", ""))
    if not channels:
        raise RuntimeError("channel delivery is allowed for this run, but target agent has no configured channels")

    preferred = str(request.get("job_delivery_channel") or "").strip().lower()
    if preferred:
        expected = f"plugin:{preferred}"
        if not channel_enabled(channels, expected):
            raise RuntimeError(
                f"channel delivery requested for {preferred}, but target agent channels are {', '.join(channels)}"
            )


def resolve_binary(name: str, override_env: str) -> str:
    override = os.environ.get(override_env, "").strip()
    if override:
        path = Path(override).expanduser()
        if not path.is_file():
            raise FileNotFoundError(f"{override_env} points to a missing file: {path}")
        return str(path.resolve())

    resolved = shutil.which(name, path=augmented_path())
    if resolved:
        return resolved

    searched = [str(path) for path in COMMON_BIN_DIRS]
    raise FileNotFoundError(f"{name} binary not found; searched PATH and common dirs: {', '.join(searched)}")


def run_codex(request: dict[str, Any], prompt: str, schema_path: Path, timeout: int) -> tuple[list[str], subprocess.CompletedProcess[str]]:
    workdir = request["target_workdir"]
    codex_bin = resolve_binary("codex", "BRIDGE_CODEX_BIN")
    command = [
        codex_bin,
        "exec",
        "--ephemeral",
        "--json",
        "--output-schema",
        str(schema_path),
        "-C",
        workdir,
        "--skip-git-repo-check",
        "--dangerously-bypass-approvals-and-sandbox",
        prompt,
    ]
    completed = subprocess.run(
        command,
        cwd=workdir,
        env=runner_env(),
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    return command, completed


def run_claude(request: dict[str, Any], prompt: str, timeout: int) -> tuple[list[str], subprocess.CompletedProcess[str]]:
    workdir = request["target_workdir"]
    claude_bin = resolve_binary("claude", "BRIDGE_CLAUDE_BIN")
    channels = csv_items(request.get("target_channels", ""))
    command = [
        claude_bin,
        "-p",
        "--output-format",
        "json",
        "--json-schema",
        json.dumps(RESULT_SCHEMA, ensure_ascii=True),
        "--permission-mode",
        "bypassPermissions",
        prompt,
    ]
    if channels and disposable_needs_channels(request):
        command[2:2] = ["--channels", ",".join(channels)]
    env = apply_channel_runtime_env(request, runner_env())
    completed = subprocess.run(
        command,
        cwd=workdir,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    return command, completed


def parse_codex_output(stdout_text: str) -> dict[str, Any]:
    agent_message: str | None = None
    for raw_line in stdout_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        item = event.get("item")
        if event.get("type") == "item.completed" and isinstance(item, dict) and item.get("type") == "agent_message":
            text = item.get("text")
            if isinstance(text, str) and text.strip():
                agent_message = text
    if not agent_message:
        raise ValueError("codex output did not contain a final agent_message event")
    return validate_result(json.loads(agent_message))


def parse_claude_output(stdout_text: str) -> dict[str, Any]:
    text = stdout_text.strip()
    if not text:
        raise ValueError("claude output was empty")

    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        payload = json.loads(text.splitlines()[-1])

    if isinstance(payload, list):
        for event in reversed(payload):
            if isinstance(event, dict) and isinstance(event.get("structured_output"), dict):
                return validate_result(event["structured_output"])
        raise ValueError("claude output array did not contain structured_output")

    if not isinstance(payload, dict):
        raise ValueError("claude output was not a JSON object")

    structured = payload.get("structured_output")
    if isinstance(structured, dict):
        return validate_result(structured)

    result_text = payload.get("result")
    if isinstance(result_text, str):
        result_text = result_text.strip()
        if result_text:
            try:
                parsed_result = json.loads(result_text)
            except json.JSONDecodeError:
                parsed_result = None
            if isinstance(parsed_result, dict):
                return validate_result(parsed_result)

            if payload.get("subtype") == "success" and not payload.get("is_error", False):
                return validate_result(
                    {
                        "status": "completed",
                        "summary": result_text,
                        "findings": [],
                        "actions_taken": ["Claude returned plain-text result instead of structured_output"],
                        "needs_human_followup": False,
                        "recommended_next_steps": [],
                        "artifacts": [],
                        "confidence": "low",
                    }
                )

    raise ValueError("claude output did not contain structured_output")


def write_status(
    status_file: Path,
    *,
    run_id: str,
    state: str,
    engine: str,
    request_file: Path,
    result_file: Path,
    started_at: str | None = None,
    completed_at: str | None = None,
    exit_code: int | None = None,
    error: str | None = None,
) -> None:
    payload: dict[str, Any] = {
        "run_id": run_id,
        "state": state,
        "engine": engine,
        "updated_at": now_iso(),
        "request_file": str(request_file),
        "result_file": str(result_file),
    }
    if started_at:
        payload["started_at"] = started_at
    if completed_at:
        payload["completed_at"] = completed_at
    if exit_code is not None:
        payload["exit_code"] = exit_code
    if error:
        payload["error"] = error
    write_json(status_file, payload)


def cmd_run(args: argparse.Namespace) -> int:
    request_file = Path(args.request_file).expanduser().resolve()
    if not request_file.is_file():
        print(f"error: request file not found: {request_file}", file=sys.stderr)
        return 2

    request = read_json(request_file)
    engine = request.get("target_engine", "")
    run_id = request.get("run_id", "")
    workdir = request.get("target_workdir", "")
    payload_file = Path(request["payload_file"]).expanduser().resolve()
    result_file = Path(request["result_file"]).expanduser().resolve()
    status_file = Path(request["status_file"]).expanduser().resolve()
    stdout_log = Path(request["stdout_log"]).expanduser().resolve()
    stderr_log = Path(request["stderr_log"]).expanduser().resolve()
    run_dir = request_file.parent
    schema_file = run_dir / "result-schema.json"
    prompt_file = run_dir / "prompt.txt"

    if args.dry_run:
        print("status: dry_run")
        print(f"run_id: {run_id}")
        print(f"engine: {engine}")
        print(f"workdir: {workdir}")
        print(f"request_file: {rel_for_output(str(request_file))}")
        print(f"payload_file: {rel_for_output(str(payload_file))}")
        print(f"result_file: {rel_for_output(str(result_file))}")
        print(f"status_file: {rel_for_output(str(status_file))}")
        print(f"stdout_log: {rel_for_output(str(stdout_log))}")
        print(f"stderr_log: {rel_for_output(str(stderr_log))}")
        return 0

    payload_text = payload_file.read_text(encoding="utf-8")
    prompt = build_prompt(request, payload_text)
    write_text(prompt_file, prompt)
    write_json(schema_file, RESULT_SCHEMA)
    validate_channel_delivery_request(request)

    timeout = int(os.environ.get("BRIDGE_CRON_SUBAGENT_TIMEOUT_SECONDS", "900"))
    started_at = now_iso()
    write_status(
        status_file,
        run_id=run_id,
        state="running",
        engine=engine,
        request_file=request_file,
        result_file=result_file,
        started_at=started_at,
    )

    start_monotonic = time.monotonic()
    command: list[str]
    completed: subprocess.CompletedProcess[str]
    final_state = "error"
    child_result: dict[str, Any] | None = None
    error_message: str | None = None

    try:
        if engine == "codex":
            command, completed = run_codex(request, prompt, schema_file, timeout)
            write_text(stdout_log, completed.stdout)
            write_text(stderr_log, completed.stderr)
            if completed.returncode != 0:
                raise RuntimeError(f"codex exec failed with exit code {completed.returncode}")
            child_result = parse_codex_output(completed.stdout)
        elif engine == "claude":
            command, completed = run_claude(request, prompt, timeout)
            write_text(stdout_log, completed.stdout)
            write_text(stderr_log, completed.stderr)
            if completed.returncode != 0:
                raise RuntimeError(f"claude -p failed with exit code {completed.returncode}")
            child_result = parse_claude_output(completed.stdout)
        else:
            raise RuntimeError(f"unsupported engine for cron subagent: {engine}")

        final_state = "success" if child_result.get("status") != "error" else "error"
    except subprocess.TimeoutExpired as exc:
        command = exc.cmd if isinstance(exc.cmd, list) else [str(exc.cmd)]
        write_text(stdout_log, exc.stdout or "")
        write_text(stderr_log, exc.stderr or "")
        error_message = f"timed out after {timeout}s"
        final_state = "timed_out"
        completed = subprocess.CompletedProcess(command, 124, exc.stdout or "", exc.stderr or "")
    except Exception as exc:  # noqa: BLE001
        error_message = str(exc)
        if "completed" not in locals():
            completed = subprocess.CompletedProcess([], 1, "", "")
        if "command" not in locals():
            command = []

    completed_at = now_iso()
    duration_ms = int((time.monotonic() - start_monotonic) * 1000)

    if child_result is None:
        child_result = {
            "status": "error",
            "summary": error_message or "cron subagent failed",
            "findings": [],
            "actions_taken": [],
            "needs_human_followup": True,
            "recommended_next_steps": ["Inspect stdout.log and stderr.log"],
            "artifacts": [],
            "confidence": "low",
        }

    result_payload = {
        "run_id": run_id,
        "engine": engine,
        "status": child_result["status"],
        "summary": child_result["summary"],
        "findings": child_result["findings"],
        "actions_taken": child_result["actions_taken"],
        "needs_human_followup": child_result["needs_human_followup"],
        "recommended_next_steps": child_result["recommended_next_steps"],
        "artifacts": child_result["artifacts"],
        "confidence": child_result["confidence"],
        "started_at": started_at,
        "completed_at": completed_at,
        "duration_ms": duration_ms,
        "request_file": str(request_file),
        "payload_file": str(payload_file),
        "stdout_log": str(stdout_log),
        "stderr_log": str(stderr_log),
        "prompt_file": str(prompt_file),
        "command": command,
        "command_pretty": " ".join(shlex.quote(part) for part in command),
        "child_exit_code": completed.returncode,
    }
    if error_message:
        result_payload["runner_error"] = error_message

    write_json(result_file, result_payload)
    write_status(
        status_file,
        run_id=run_id,
        state=final_state,
        engine=engine,
        request_file=request_file,
        result_file=result_file,
        started_at=started_at,
        completed_at=completed_at,
        exit_code=completed.returncode,
        error=error_message,
    )

    print(f"status: {final_state}")
    print(f"run_id: {run_id}")
    print(f"engine: {engine}")
    print(f"result_file: {rel_for_output(str(result_file))}")
    print(f"status_file: {rel_for_output(str(status_file))}")
    print(f"summary: {child_result['summary']}")
    return 0 if final_state == "success" else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    run = subparsers.add_parser("run")
    run.add_argument("--request-file", required=True)
    run.add_argument("--dry-run", action="store_true")
    run.set_defaults(func=cmd_run)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
