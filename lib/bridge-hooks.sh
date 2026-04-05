#!/usr/bin/env bash
# shellcheck shell=bash

bridge_hooks_python() {
  bridge_require_python
  python3 "$BRIDGE_SCRIPT_DIR/bridge-hooks.py" "$@"
}

bridge_hook_mark_idle_path() {
  printf '%s/mark-idle.sh' "$BRIDGE_HOOKS_DIR"
}

bridge_hook_clear_idle_path() {
  printf '%s/clear-idle.sh' "$BRIDGE_HOOKS_DIR"
}

bridge_hook_settings_file_for() {
  local workdir="$1"
  printf '%s/.claude/settings.json' "$workdir"
}

bridge_claude_stop_hook_status() {
  local workdir="$1"
  bridge_hooks_python status-stop-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
}

bridge_claude_prompt_hook_status() {
  local workdir="$1"
  bridge_hooks_python status-prompt-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
}

bridge_ensure_claude_stop_hook() {
  local workdir="$1"
  bridge_hooks_python ensure-stop-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
}

bridge_ensure_claude_prompt_hook() {
  local workdir="$1"
  bridge_hooks_python ensure-prompt-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
}
