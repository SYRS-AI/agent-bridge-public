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
    --openclaw-config "$BRIDGE_OPENCLAW_HOME/openclaw.json"
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

bridge_warn_missing_notify_transport() {
  local agent="$1"

  bridge_warn "Claude agent '${agent}' has no external webhook transport configured; bridge will rely on local tmux delivery when the session is active. To support channel delivery, configure BRIDGE_AGENT_NOTIFY_KIND/TARGET in agent-roster.local.sh."
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
  local kind=""
  local session=""
  local text=""

  engine="$(bridge_agent_engine "$agent")"
  case "$engine" in
    claude)
      kind="$(bridge_agent_notify_kind "$agent")"
      if bridge_agent_has_notify_transport "$agent"; then
        case "$kind" in
          discord)
            ;;
          *)
            if bridge_notify_send "$agent" "$title" "$message" "$task_id" "$priority"; then
              return 0
            fi
            bridge_warn "external notify failed for Claude agent '${agent}'; falling back to local tmux delivery if possible"
            ;;
        esac
      fi
      session="$(bridge_agent_session "$agent")"
      if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
        text="$(bridge_notification_text "$title" "$message" "$task_id" "$priority")"
        bridge_tmux_send_and_submit "$session" "$engine" "$text"
        return $?
      fi
      if ! bridge_agent_has_notify_transport "$agent"; then
        bridge_warn_missing_notify_transport "$agent"
      elif [[ "$kind" == "discord" ]]; then
        bridge_warn "discord bot channel posts do not reliably reach Claude sessions; use discord-webhook or keep the session active for local delivery: ${agent}"
      fi
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
