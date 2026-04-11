#!/usr/bin/env bash
# shellcheck shell=bash

bridge_tmux_session_exists() {
  local session="$1"
  tmux has-session -t "$(bridge_tmux_session_target "$session")" 2>/dev/null
}

bridge_tmux_session_target() {
  local session="$1"
  printf '=%s' "$session"
}

bridge_tmux_pane_target() {
  local session="$1"
  printf '=%s:' "$session"
}

bridge_tmux_kill_session() {
  local session="$1"
  tmux kill-session -t "$(bridge_tmux_session_target "$session")"
}

bridge_tmux_detach_clients() {
  local session="$1"
  tmux detach-client -s "$(bridge_tmux_session_target "$session")"
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

  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "[info] session '$session' started; attach manually with: tmux attach -t $(bridge_tmux_session_target "$session")"
    return 0
  fi

  if [[ -n "${TMUX:-}" ]]; then
    exec tmux switch-client -t "$(bridge_tmux_session_target "$session")"
  fi

  exec tmux attach -t "$(bridge_tmux_session_target "$session")"
}

bridge_tmux_bootstrap_session_options() {
  local session="$1"
  tmux set-option -t "$(bridge_tmux_session_target "$session")" mouse on >/dev/null 2>&1 || true
  tmux set-option -t "$(bridge_tmux_session_target "$session")" history-limit 10000 >/dev/null 2>&1 || true
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

bridge_tmux_claude_blocker_state_from_text() {
  local text="$1"

  if [[ "$text" == *"Quick safety check:"* && "$text" == *"Yes, I trust this folder"* ]]; then
    printf '%s' "trust"
    return 0
  fi

  if [[ "$text" == *"Resume from summary (recommended)"* && "$text" == *"Resume full session as-is"* ]]; then
    printf '%s' "summary"
    return 0
  fi

  if [[ "$text" == *"WARNING: Loading development channels"* && "$text" == *"I am using this for local development"* ]]; then
    printf '%s' "devchannels"
    return 0
  fi

  printf '%s' "none"
}

bridge_tmux_claude_blocker_state() {
  local session="$1"
  local recent=""

  recent="$(bridge_capture_recent "$session" 80 2>/dev/null || true)"
  [[ -n "$recent" ]] || {
    printf '%s' "none"
    return 0
  }

  bridge_tmux_claude_blocker_state_from_text "$recent"
}

bridge_tmux_claude_prompt_line_ready() {
  local trimmed="$1"
  local remainder=""

  if [[ "$trimmed" == ❯* ]]; then
    remainder="${trimmed#❯}"
  elif [[ "$trimmed" == '>'* ]]; then
    remainder="${trimmed#>}"
  else
    return 1
  fi

  remainder="${remainder#"${remainder%%[![:space:]]*}"}"
  if [[ -z "$remainder" ]]; then
    return 0
  fi
  if [[ "$remainder" =~ ^[0-9]+\.[[:space:]] ]]; then
    return 1
  fi
  return 0
}

bridge_tmux_codex_prompt_line_ready() {
  local trimmed="$1"
  [[ "$trimmed" == ›* || "$trimmed" == '>'* ]]
}

bridge_tmux_prompt_line_has_pending_input() {
  local engine="$1"
  local trimmed="$2"

  case "$engine" in
    claude)
      if [[ "$trimmed" == ❯* || "$trimmed" == '>'* ]]; then
        ! bridge_tmux_claude_prompt_line_ready "$trimmed"
        return
      fi
      ;;
    codex)
      return 1
      ;;
    *)
      return 1
      ;;
  esac

  return 1
}

bridge_tmux_session_has_prompt() {
  local session="$1"
  local engine="$2"
  local recent=""
 
  bridge_tmux_engine_requires_prompt "$engine" || return 0
  recent="$(bridge_capture_recent "$session" 20 2>/dev/null || true)"
  [[ -n "$recent" ]] || return 1

  bridge_tmux_session_has_prompt_from_text "$engine" "$recent"
}

bridge_tmux_session_has_prompt_from_text() {
  local engine="$1"
  local recent="$2"
  local line=""
  local trimmed=""

  bridge_tmux_engine_requires_prompt "$engine" || return 0
  [[ -n "$recent" ]] || return 1

  while IFS= read -r line; do
    line="${line//$'\r'/}"
    line="${line//$'\u00A0'/ }"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$engine" in
      claude)
        if bridge_tmux_claude_prompt_line_ready "$trimmed"; then
          return 0
        fi
        ;;
      codex)
        if bridge_tmux_codex_prompt_line_ready "$trimmed"; then
          return 0
        fi
        ;;
      *)
        if [[ "$trimmed" == '>'* ]]; then
          local remainder="${trimmed#>}"
          remainder="${remainder#"${remainder%%[![:space:]]*}"}"
          [[ -z "$remainder" ]] && return 0
        fi
        ;;
    esac
  done <<<"$recent"

  return 1
}

bridge_tmux_session_has_pending_input_from_text() {
  local engine="$1"
  local recent="$2"
  local line=""
  local trimmed=""

  bridge_tmux_engine_requires_prompt "$engine" || return 1
  [[ -n "$recent" ]] || return 1

  if [[ "$engine" == "claude" ]]; then
    if [[ "$(bridge_tmux_claude_blocker_state_from_text "$recent")" != "none" ]]; then
      return 1
    fi
  fi

  while IFS= read -r line; do
    line="${line//$'\r'/}"
    line="${line//$'\u00A0'/ }"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if bridge_tmux_prompt_line_has_pending_input "$engine" "$trimmed"; then
      return 0
    fi
  done <<<"$recent"

  return 1
}

bridge_tmux_session_has_pending_input() {
  local session="$1"
  local engine="$2"
  local recent=""

  bridge_tmux_engine_requires_prompt "$engine" || return 1
  recent="$(bridge_capture_recent "$session" 20 2>/dev/null || true)"
  [[ -n "$recent" ]] || return 1
  bridge_tmux_session_has_pending_input_from_text "$engine" "$recent"
}

bridge_tmux_session_recent_keypress() {
  local session="$1"
  local threshold="${2:-3}"
  local last_input=""
  local now=""

  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3
  (( threshold > 0 )) || return 1
  last_input="$(tmux display-message -p -t "$(bridge_tmux_pane_target "$session")" '#{session_activity}' 2>/dev/null || true)"
  [[ "$last_input" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  (( now - last_input < threshold ))
}

bridge_tmux_session_inject_busy() {
  local session="$1"
  local engine="$2"
  local grace="${3:-3}"

  if bridge_tmux_session_has_pending_input "$session" "$engine"; then
    return 0
  fi

  local attached="0"
  attached="$(bridge_tmux_session_attached_count "$session" 2>/dev/null || printf '0')"
  if [[ "$attached" =~ ^[1-9][0-9]*$ ]] && bridge_tmux_session_recent_keypress "$session" "$grace"; then
    return 0
  fi

  return 1
}

bridge_tmux_claude_advance_blocker() {
  local session="$1"
  local allow_devchannels="${2:-0}"
  local state=""

  state="$(bridge_tmux_claude_blocker_state "$session")"
  case "$state" in
    trust|summary)
      tmux send-keys -t "$(bridge_tmux_pane_target "$session")" C-m
      sleep 0.3
      return 0
      ;;
    devchannels)
      if [[ "$allow_devchannels" == "1" ]]; then
        tmux send-keys -t "$(bridge_tmux_pane_target "$session")" C-m
        sleep 0.3
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_tmux_wait_for_prompt() {
  local session="$1"
  local engine="$2"
  local timeout="${3:-$BRIDGE_TMUX_PROMPT_WAIT_SECONDS}"
  local allow_devchannels="${4:-0}"
  local start_ts
  local elapsed
  local bootstrap_actions=0

  bridge_tmux_engine_requires_prompt "$engine" || return 0
  if bridge_tmux_session_has_prompt "$session" "$engine"; then
    return 0
  fi
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=0
  (( timeout > 0 )) || return 1

  start_ts="$(date +%s)"
  while true; do
    if [[ "$engine" == "claude" ]]; then
      if bridge_tmux_claude_advance_blocker "$session" "$allow_devchannels"; then
        bootstrap_actions=$((bootstrap_actions + 1))
        if (( bootstrap_actions >= 4 )); then
          return 1
        fi
      else
        sleep 0.2
      fi
    else
      sleep 0.2
    fi
    if bridge_tmux_session_has_prompt "$session" "$engine"; then
      return 0
    fi
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

bridge_tmux_prepare_claude_session() {
  local session="$1"
  local timeout="${2:-8}"
  local start_ts
  local elapsed
  local advanced=0

  start_ts="$(date +%s)"
  while true; do
    if [[ "$(bridge_tmux_claude_blocker_state "$session")" == "none" ]]; then
      return 0
    fi
    if bridge_tmux_claude_advance_blocker "$session"; then
      advanced=$((advanced + 1))
      if (( advanced >= 4 )); then
        return 1
      fi
    fi
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= timeout )); then
      return 1
    fi
    sleep 0.2
  done
}

bridge_tmux_paste_and_submit() {
  local session="$1"
  local text="$2"
  local buffer_name

  buffer_name="bridge-send-$$-$(bridge_nonce)"
  tmux set-buffer -b "$buffer_name" -- "$text"
  tmux paste-buffer -d -p -b "$buffer_name" -t "$(bridge_tmux_pane_target "$session")"

  sleep 0.05
  tmux send-keys -t "$(bridge_tmux_pane_target "$session")" C-m
}

bridge_tmux_type_and_submit() {
  local session="$1"
  local text="$2"
  local line
  local first_line=1

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ $first_line -eq 0 ]]; then
      tmux send-keys -t "$(bridge_tmux_pane_target "$session")" C-j
    fi
    if [[ -n "$line" ]]; then
      tmux send-keys -t "$(bridge_tmux_pane_target "$session")" -l -- "$line"
    fi
    first_line=0
  done <<<"$text"

  sleep 0.05
  tmux send-keys -t "$(bridge_tmux_pane_target "$session")" C-m
}

bridge_tmux_send_and_submit() {
  local session="$1"
  local engine="$2"
  local text="$3"
  local inject_grace="${BRIDGE_TMUX_INJECT_IDLE_GRACE_SECONDS:-3}"

  if ! bridge_tmux_wait_for_prompt "$session" "$engine"; then
    bridge_warn "session prompt unavailable; skipping send to '$session'"
    return 1
  fi
  if bridge_tmux_session_inject_busy "$session" "$engine" "$inject_grace"; then
    bridge_warn "session busy; deferring send to '$session'"
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
  tmux capture-pane -t "$(bridge_tmux_pane_target "$session")" -p -S "-$lines"
}

bridge_sanitize_text() {
  printf '%s' "$1" | tr -d '\000-\011\013-\037'
}

bridge_tmux_session_activity_ts() {
  local session="$1"
  # Use window_activity (updates on pane output) instead of session_activity
  # (only updates on key input). Agents produce output during conversations
  # without key input, so session_activity causes false idle detection.
  tmux display-message -p -t "$(bridge_tmux_pane_target "$session")" '#{window_activity}' 2>/dev/null || true
}

bridge_tmux_session_attached_count() {
  local session="$1"
  tmux display-message -p -t "$(bridge_tmux_pane_target "$session")" '#{session_attached}' 2>/dev/null || true
}

bridge_tmux_session_idle_seconds() {
  local session="$1"
  local activity
  local now

  activity="$(bridge_tmux_session_activity_ts "$session")"
  [[ "$activity" =~ ^[0-9]+$ ]] || {
    printf '0'
    return 0
  }
  now="$(date +%s)"
  (( activity > now )) && activity="$now"
  printf '%s' "$(( now - activity ))"
}
