#!/usr/bin/env bash
# shellcheck shell=bash

bridge_tmux_session_exists() {
  local session="$1"
  tmux has-session -t "$session" 2>/dev/null
}

bridge_require_tmux_session() {
  local session="$1"

  if bridge_tmux_session_exists "$session"; then
    return 0
  fi

  echo "현재 활성 세션:"
  tmux list-sessions 2>/dev/null || echo "  (없음)"
  bridge_die "tmux 세션 '$session'이 존재하지 않습니다."
}

bridge_attach_tmux_session() {
  local session="$1"

  if [[ -n "${TMUX:-}" ]]; then
    exec tmux switch-client -t "$session"
  fi

  exec tmux attach -t "$session"
}

bridge_tmux_bootstrap_session_options() {
  local session="$1"
  tmux set-option -t "$session" mouse on >/dev/null 2>&1 || true
  tmux set-option -t "$session" history-limit 10000 >/dev/null 2>&1 || true
}

bridge_tmux_engine_requires_prompt() {
  local engine="$1"

  case "$engine" in
    claude|codex)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_tmux_session_has_prompt() {
  local session="$1"
  local engine="$2"
  local recent=""
  local line=""
  local trimmed=""

  bridge_tmux_engine_requires_prompt "$engine" || return 0
  recent="$(bridge_capture_recent "$session" 20 2>/dev/null || true)"
  [[ -n "$recent" ]] || return 1

  while IFS= read -r line; do
    line="${line//$'\r'/}"
    line="${line//$'\u00A0'/ }"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$engine:$trimmed" in
      claude:❯*)
        return 0
        ;;
      codex:›*)
        return 0
        ;;
      *:">")
        return 0
        ;;
    esac
  done <<<"$recent"

  return 1
}

bridge_tmux_wait_for_prompt() {
  local session="$1"
  local engine="$2"
  local timeout="${3:-$BRIDGE_TMUX_PROMPT_WAIT_SECONDS}"
  local start_ts
  local elapsed

  bridge_tmux_engine_requires_prompt "$engine" || return 0
  if bridge_tmux_session_has_prompt "$session" "$engine"; then
    return 0
  fi
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=0
  (( timeout > 0 )) || return 1

  start_ts="$(date +%s)"
  while true; do
    sleep 0.2
    if bridge_tmux_session_has_prompt "$session" "$engine"; then
      return 0
    fi
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

bridge_tmux_paste_and_submit() {
  local session="$1"
  local text="$2"
  local buffer_name

  buffer_name="bridge-send-$$-$(bridge_nonce)"
  tmux set-buffer -b "$buffer_name" "$text"
  tmux paste-buffer -d -p -b "$buffer_name" -t "$session"

  sleep 0.05
  tmux send-keys -t "$session" C-m
}

bridge_tmux_type_and_submit() {
  local session="$1"
  local text="$2"
  local line
  local first_line=1

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ $first_line -eq 0 ]]; then
      tmux send-keys -t "$session" C-j
    fi
    if [[ -n "$line" ]]; then
      tmux send-keys -t "$session" -l "$line"
    fi
    first_line=0
  done <<<"$text"

  sleep 0.05
  tmux send-keys -t "$session" C-m
}

bridge_tmux_send_and_submit() {
  local session="$1"
  local engine="$2"
  local text="$3"

  if ! bridge_tmux_wait_for_prompt "$session" "$engine"; then
    bridge_warn "session prompt unavailable; skipping send to '$session'"
    return 1
  fi

  case "$engine" in
    claude)
      bridge_tmux_type_and_submit "$session" "$text"
      ;;
    *)
      bridge_tmux_paste_and_submit "$session" "$text"
      ;;
  esac
}

bridge_capture_recent() {
  local session="$1"
  local lines="${2:-30}"
  tmux capture-pane -t "$session" -p -S "-$lines"
}

bridge_sanitize_text() {
  printf '%s' "$1" | tr -d '\000-\011\013-\037'
}

bridge_tmux_session_activity_ts() {
  local session="$1"
  tmux display-message -p -t "$session" '#{session_activity}' 2>/dev/null || true
}
