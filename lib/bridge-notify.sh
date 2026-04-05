#!/usr/bin/env bash
# shellcheck shell=bash

bridge_notify_python() {
  bridge_require_python
  python3 "$BRIDGE_SCRIPT_DIR/bridge-notify.py" "$@"
}

bridge_notify_send() {
  local agent="$1"
  local title="$2"
  local message="$3"
  local task_id="${4:-}"
  local priority="${5:-normal}"
  local dry_run="${6:-0}"
  local kind=""
  local target=""
  local account=""
  local args=()

  kind="$(bridge_agent_notify_kind "$agent")"
  target="$(bridge_agent_notify_target "$agent")"
  account="$(bridge_agent_notify_account "$agent")"

  [[ -n "$kind" ]] || bridge_die "notify kind이 설정되지 않았습니다: $agent"
  [[ -n "$target" ]] || bridge_die "notify target이 설정되지 않았습니다: $agent"

  args=(
    send
    --agent "$agent"
    --kind "$kind"
    --target "$target"
    --openclaw-config "$(bridge_compat_config_file)"
  )
  if [[ -n "$account" ]]; then
    args+=(--account "$account")
  fi
  if [[ -n "$title" ]]; then
    args+=(--title "$title")
  fi
  if [[ -n "$message" ]]; then
    args+=(--message "$message")
  fi
  if [[ -n "$task_id" ]]; then
    args+=(--task-id "$task_id")
  fi
  if [[ -n "$priority" ]]; then
    args+=(--priority "$priority")
  fi
  if [[ "$dry_run" == "1" ]]; then
    args+=(--dry-run)
  fi

  bridge_notify_python "${args[@]}"
}

bridge_warn_missing_wake_channel() {
  local agent="$1"

  bridge_warn "Claude agent '${agent}' has no local session configured. Queue tasks remain durable, but idle wake cannot run without a live tmux session."
}

bridge_claude_session_can_wake() {
  local agent="$1"
  [[ -f "$(bridge_agent_idle_since_file "$agent")" ]]
}

bridge_notification_text() {
  local title="$1"
  local message="$2"
  local task_id="${3:-}"
  local priority="${4:-normal}"
  local header="[Agent Bridge]"

  if [[ -n "$priority" && "$priority" != "normal" ]]; then
    header+=" $priority"
  fi
  if [[ -n "$task_id" ]]; then
    header+=" task #${task_id}"
  fi
  if [[ -n "$title" ]]; then
    header+=": ${title}"
  fi

  if [[ -n "$message" ]]; then
    printf '%s\n%s' "$header" "$message"
    return 0
  fi

  printf '%s' "$header"
}

bridge_dispatch_notification() {
  local agent="$1"
  local title="$2"
  local message="$3"
  local task_id="${4:-}"
  local priority="${5:-normal}"
  local engine=""
  local session=""
  local text=""

  engine="$(bridge_agent_engine "$agent")"
  case "$engine" in
    claude)
      session="$(bridge_agent_session "$agent")"
      if [[ -z "$session" ]] || ! bridge_tmux_session_exists "$session"; then
        return 2
      fi
      if ! bridge_agent_has_wake_channel "$agent"; then
        bridge_warn_missing_wake_channel "$agent"
        return 2
      fi
      if ! bridge_claude_session_can_wake "$agent" "$session"; then
        return 2
      fi

      text="$(bridge_notification_text "$title" "$message" "$task_id" "$priority")"
      if bridge_tmux_send_and_submit "$session" "$engine" "$text"; then
        return 0
      fi
      bridge_warn "Claude idle wake delivery failed for '${agent}'"
      return 1
      ;;
    *)
      session="$(bridge_agent_session "$agent")"
      if [[ -z "$session" ]]; then
        bridge_warn "session unavailable; skipping direct send to '${agent}'"
        return 1
      fi
      if ! bridge_tmux_session_exists "$session"; then
        bridge_warn "session unavailable; skipping direct send to '${agent}'"
        return 1
      fi
      text="$(bridge_notification_text "$title" "$message" "$task_id" "$priority")"
      bridge_tmux_send_and_submit "$session" "$engine" "$text"
      ;;
  esac
}
