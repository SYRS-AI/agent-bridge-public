#!/usr/bin/env bash
# bridge-setup.sh — guided onboarding for Discord-backed agents

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  $(basename "$0") discord <agent> [--token <token>] [--openclaw-account <account>] [--openclaw-config <path>] [--channel <id>]... [--allow-from <id>]... [--require-mention] [--skip-validate] [--skip-send-test] [--yes] [--dry-run]
  $(basename "$0") agent <agent> [--skip-discord] [--test-start] [discord setup options...]

Examples:
  $(basename "$0") discord tester
  $(basename "$0") discord tester --openclaw-account default --channel 123456789012345678
  $(basename "$0") agent tester
  $(basename "$0") agent tester --test-start
EOF
}

bridge_setup_python() {
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-setup.py" "$@"
}

bridge_find_agent_claude_md() {
  local agent="$1"
  local target_root=""
  local candidate
  local candidates=()

  if bridge_profile_has_source "$agent"; then
    candidates+=("$(bridge_profile_source_root "$agent")/CLAUDE.md")
  fi

  target_root="$(bridge_resolve_profile_target "$agent" || true)"
  if [[ -n "$target_root" ]]; then
    candidates+=("$target_root/CLAUDE.md")
  fi

  candidates+=("$(bridge_agent_workdir "$agent")/CLAUDE.md")

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

bridge_setup_primary_access_channel() {
  local discord_dir="$1"

  bridge_require_python
  python3 - "$discord_dir" <<'PY'
import json
import os
import sys

path = os.path.join(sys.argv[1], "access.json")
try:
    payload = json.load(open(path, "r", encoding="utf-8"))
except FileNotFoundError:
    raise SystemExit(0)

groups = payload.get("groups") or {}
for channel_id in groups.keys():
    channel_id = str(channel_id).strip()
    if channel_id:
        print(channel_id)
        break
PY
}

bridge_setup_access_channels() {
  local discord_dir="$1"

  bridge_require_python
  python3 - "$discord_dir" <<'PY'
import json
import os
import sys

path = os.path.join(sys.argv[1], "access.json")
try:
    payload = json.load(open(path, "r", encoding="utf-8"))
except FileNotFoundError:
    raise SystemExit(0)

groups = payload.get("groups") or {}
for channel_id in groups.keys():
    channel_id = str(channel_id).strip()
    if channel_id:
        print(channel_id)
PY
}

run_discord() {
  local agent="${1:-}"
  local workdir=""
  local discord_dir=""
  local suggested_channel=""
  local openclaw_config="$BRIDGE_OPENCLAW_HOME/openclaw.json"
  local py_args=()
  local base_args=()

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") discord <agent> [...]"
  bridge_require_agent "$agent"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token|--openclaw-account|--openclaw-config|--channel|--allow-from|--api-base-url)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        if [[ "$1" == "--openclaw-config" ]]; then
          openclaw_config="$2"
        fi
        py_args+=("$1" "$2")
        shift 2
        ;;
      --require-mention|--skip-validate|--skip-send-test|--yes|--dry-run)
        py_args+=("$1")
        shift
        ;;
      *)
        bridge_die "지원하지 않는 setup discord 옵션입니다: $1"
        ;;
    esac
  done

  workdir="$(bridge_agent_workdir "$agent")"
  discord_dir="$(bridge_agent_discord_state_dir "$agent")"
  suggested_channel="$(bridge_agent_discord_channel_id "$agent")"
  base_args=(
    discord
    --agent "$agent"
    --discord-dir "$discord_dir"
    --openclaw-config "$openclaw_config"
  )
  if [[ -n "$suggested_channel" ]]; then
    base_args+=(--suggested-channel "$suggested_channel")
  fi

  bridge_setup_python "${base_args[@]}" "${py_args[@]}"
}

run_agent() {
  local agent="${1:-}"
  local skip_discord=0
  local test_start=0
  local failures=0
  local warnings=()
  local discord_args=()
  local engine=""
  local session=""
  local workdir=""
  local profile_target=""
  local claude_path=""
  local hook_output=""
  local notify_status=""
  local roster_channel=""
  local access_channel=""
  local access_channels=()
  local start_output=""

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") agent <agent> [...]"
  bridge_require_agent "$agent"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-discord)
        skip_discord=1
        shift
        ;;
      --test-start)
        test_start=1
        shift
        ;;
      --token|--openclaw-account|--openclaw-config|--channel|--allow-from|--api-base-url)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        discord_args+=("$1" "$2")
        shift 2
        ;;
      --require-mention|--skip-validate|--skip-send-test|--yes|--dry-run)
        discord_args+=("$1")
        shift
        ;;
      *)
        bridge_die "지원하지 않는 setup agent 옵션입니다: $1"
        ;;
    esac
  done

  engine="$(bridge_agent_engine "$agent")"
  session="$(bridge_agent_session "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"
  profile_target="$(bridge_resolve_profile_target "$agent" || true)"
  notify_status="$(bridge_agent_notify_status "$agent")"
  roster_channel="$(bridge_agent_discord_channel_id "$agent")"
  access_channel="$(bridge_setup_primary_access_channel "$(bridge_agent_discord_state_dir "$agent")" || true)"
  mapfile -t access_channels < <(bridge_setup_access_channels "$(bridge_agent_discord_state_dir "$agent")" || true)

  if [[ $skip_discord -eq 0 ]]; then
    echo "== Discord setup =="
    if ! run_discord "$agent" "${discord_args[@]}"; then
      failures=$((failures + 1))
    fi
    echo
    access_channel="$(bridge_setup_primary_access_channel "$(bridge_agent_discord_state_dir "$agent")" || true)"
    mapfile -t access_channels < <(bridge_setup_access_channels "$(bridge_agent_discord_state_dir "$agent")" || true)
  fi

  echo "== Agent preflight =="
  printf 'agent: %s\n' "$agent"
  printf 'engine: %s\n' "$engine"
  printf 'session: %s\n' "$session"
  printf 'workdir: %s\n' "$workdir"
  printf 'discord_dir: %s\n' "$(bridge_agent_discord_state_dir "$agent")"
  if [[ -n "$roster_channel" ]]; then
    printf 'roster_discord_channel: %s\n' "$roster_channel"
  else
    printf 'roster_discord_channel: (unset)\n'
  fi
  printf 'notify_transport: %s\n' "$notify_status"

  if [[ "$engine" == "claude" ]]; then
    echo
    echo "== Claude Stop hook =="
    if hook_output="$(bridge_ensure_claude_stop_hook "$workdir" 2>&1)"; then
      echo "$hook_output"
    else
      echo "$hook_output"
      failures=$((failures + 1))
    fi

    claude_path="$(bridge_find_agent_claude_md "$agent" || true)"
    if [[ -n "$claude_path" ]]; then
      printf 'claude_md: ok (%s)\n' "$claude_path"
    else
      printf 'claude_md: missing\n'
      failures=$((failures + 1))
      warnings+=("Add a CLAUDE.md file in the tracked profile or live workdir before cutover.")
    fi
  else
    printf 'claude_md: n/a (engine=%s)\n' "$engine"
  fi

  if bridge_profile_has_source "$agent"; then
    echo
    echo "== Profile status =="
    if ! "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-profile.sh" status "$agent"; then
      failures=$((failures + 1))
    fi
  else
    echo
    echo "== Profile status =="
    if [[ -n "$profile_target" ]]; then
      printf 'tracked_profile: no\n'
      printf 'profile_target: %s\n' "$profile_target"
    else
      printf 'tracked_profile: no\n'
      printf 'profile_target: (unset)\n'
    fi
  fi

  echo
  echo "== Start dry-run =="
  if start_output="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --dry-run 2>&1)"; then
    echo "start_dry_run: ok"
    echo "$start_output"
  else
    echo "start_dry_run: error"
    echo "$start_output"
    failures=$((failures + 1))
  fi

  if [[ $test_start -eq 1 ]]; then
    echo
    echo "== Session smoke =="
    if tmux has-session -t "$session" 2>/dev/null; then
      echo "session_smoke: already_active (left running)"
    else
      if "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" >/dev/null 2>&1; then
        sleep 1
        if tmux has-session -t "$session" 2>/dev/null; then
          echo "session_smoke: ok"
          tmux kill-session -t "$session" >/dev/null 2>&1 || true
          "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-sync.sh" >/dev/null 2>&1 || true
          echo "session_smoke_cleanup: stopped"
        else
          echo "session_smoke: failed (tmux session did not stay up)"
          failures=$((failures + 1))
        fi
      else
        echo "session_smoke: failed (bridge-start returned non-zero)"
        failures=$((failures + 1))
      fi
    fi
  fi

  if [[ -z "$roster_channel" && -n "$access_channel" ]]; then
    warnings+=("Set BRIDGE_AGENT_DISCORD_CHANNEL_ID[\"$agent\"]=\"$access_channel\" in agent-roster.local.sh so wake relay can monitor the primary Discord channel.")
  fi
  if [[ -n "$roster_channel" && ${#access_channels[@]} -gt 0 ]]; then
    local access_match=0
    local channel_id=""
    for channel_id in "${access_channels[@]}"; do
      if [[ "$channel_id" == "$roster_channel" ]]; then
        access_match=1
        break
      fi
    done
    if [[ $access_match -eq 0 ]]; then
      warnings+=("Roster Discord channel $roster_channel is not in $(bridge_agent_discord_state_dir "$agent")/access.json. Re-run 'agent-bridge setup discord $agent' or update the allowlist.")
    fi
  fi
  if [[ "$engine" == "claude" && "$notify_status" == "miss" ]]; then
    warnings+=("Claude role has no notify transport metadata. Queue tasks still work, but configure BRIDGE_AGENT_NOTIFY_* if you want external notifications.")
  fi

  if [[ ${#warnings[@]} -gt 0 ]]; then
    echo
    echo "== Next steps =="
    printf -- '- %s\n' "${warnings[@]}"
  fi

  if (( failures > 0 )); then
    return 1
  fi
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  discord)
    run_discord "$@"
    ;;
  agent)
    run_agent "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 setup 명령입니다: $subcommand"
    ;;
esac
