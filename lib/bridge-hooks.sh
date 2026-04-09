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

bridge_codex_hooks_file() {
  printf '%s/.codex/hooks.json' "$HOME"
}

bridge_hook_settings_file_for() {
  local workdir="$1"
  printf '%s/.claude/settings.json' "$workdir"
}

bridge_hook_shared_settings_base_file() {
  printf '%s/.claude/settings.json' "$BRIDGE_AGENT_HOME_ROOT"
}

bridge_hook_shared_settings_overlay_file() {
  printf '%s/.claude/settings.local.json' "$BRIDGE_AGENT_HOME_ROOT"
}

bridge_hook_shared_settings_effective_file() {
  printf '%s/.claude/settings.effective.json' "$BRIDGE_AGENT_HOME_ROOT"
}

bridge_claude_settings_mode() {
  local workdir="$1"
  if [[ "$(bridge_path_is_within_root "$workdir" "$BRIDGE_AGENT_HOME_ROOT")" == "1" ]]; then
    printf 'shared'
  else
    printf 'local'
  fi
}

bridge_link_claude_settings_to_shared() {
  local workdir="$1"
  bridge_hooks_python render-shared-settings \
    --base-settings-file "$(bridge_hook_shared_settings_base_file)" \
    --overlay-settings-file "$(bridge_hook_shared_settings_overlay_file)" \
    --effective-settings-file "$(bridge_hook_shared_settings_effective_file)" >/dev/null
  bridge_hooks_python link-shared-settings --workdir "$workdir" --shared-settings-file "$(bridge_hook_shared_settings_effective_file)"
}

bridge_ensure_claude_project_trust() {
  local workdir="$1"
  bridge_hooks_python ensure-project-trust --workdir "$workdir"
}

bridge_claude_stop_hook_status() {
  local workdir="$1"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-stop-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  else
    bridge_hooks_python status-stop-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  fi
}

bridge_claude_session_start_hook_status() {
  local workdir="$1"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-session-start-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  else
    bridge_hooks_python status-session-start-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_claude_prompt_hook_status() {
  local workdir="$1"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-prompt-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  else
    bridge_hooks_python status-prompt-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  fi
}

bridge_ensure_claude_stop_hook() {
  local workdir="$1"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-stop-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin bash >/dev/null
    bridge_link_claude_settings_to_shared "$workdir"
  else
    bridge_hooks_python ensure-stop-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  fi
}

bridge_ensure_claude_session_start_hook() {
  local workdir="$1"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-session-start-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir"
  else
    bridge_hooks_python ensure-session-start-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_ensure_claude_prompt_hook() {
  local workdir="$1"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-prompt-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin bash --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir"
  else
    bridge_hooks_python ensure-prompt-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN" --python-bin "$(command -v python3)"
  fi
}

bridge_codex_hooks_status() {
  bridge_hooks_python status-codex-hooks --codex-hooks-file "$(bridge_codex_hooks_file)"
}

bridge_ensure_codex_hooks() {
  bridge_hooks_python ensure-codex-hooks --codex-hooks-file "$(bridge_codex_hooks_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
}
