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

bridge_tmux_session_pane_pid() {
  local session="$1"
  tmux display-message -p -t "$(bridge_tmux_pane_target "$session")" '#{pane_pid}' 2>/dev/null || true
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
  # tmux's set-option requires the `=<session>:` exact-match form (with
  # trailing colon). The bare `=<session>` form returned by
  # bridge_tmux_session_target fails with "no such session" and the
  # silent `|| true` swallowed it, leaving session-level `mouse` off
  # and wheel events dead (issue #139). Reuse pane target which already
  # appends the colon.
  local target
  target="$(bridge_tmux_pane_target "$session")"
  tmux set-option -t "$target" mouse on >/dev/null 2>&1 || true
  tmux set-option -t "$target" history-limit 10000 >/dev/null 2>&1 || true
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
  local remainder=""

  case "$engine" in
    claude)
      # Issue #132: the previous implementation inverted bridge_tmux_claude_prompt_line_ready
      # which only flagged blocker menus (`1. Yes 2. No`), so "> typed text"
      # — an operator mid-compose — was NOT classified as pending. That is
      # precisely why a post-3s-pause daemon injection could interleave with
      # the operator's keystrokes. Here we detect any non-empty remainder
      # after the prompt glyph as pending, except for the numbered-menu
      # blocker pattern (which is handled separately via blocker_state).
      if [[ "$trimmed" == ❯* ]]; then
        remainder="${trimmed#❯}"
      elif [[ "$trimmed" == '>'* ]]; then
        remainder="${trimmed#>}"
      else
        return 1
      fi
      remainder="${remainder#"${remainder%%[![:space:]]*}"}"
      [[ -n "$remainder" ]] || return 1
      [[ "$remainder" =~ ^[0-9]+\.[[:space:]] ]] && return 1
      return 0
      ;;
    codex)
      # Issue #175: prior `return 1` meant `bridge_tmux_session_has_pending_input`
      # was a no-op for codex, so the paste_and_submit retry in issue #175
      # could never observe the "typed but never submitted" race. Mirror the
      # claude remainder-detection: `› <text>` (or the fallback `> <text>`)
      # with non-whitespace remainder counts as pending.
      if [[ "$trimmed" == ›* ]]; then
        remainder="${trimmed#›}"
      elif [[ "$trimmed" == '>'* ]]; then
        remainder="${trimmed#>}"
      else
        return 1
      fi
      remainder="${remainder#"${remainder%%[![:space:]]*}"}"
      [[ -n "$remainder" ]] || return 1
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
  local last_prompt_line=""

  bridge_tmux_engine_requires_prompt "$engine" || return 1
  [[ -n "$recent" ]] || return 1

  if [[ "$engine" == "claude" ]]; then
    if [[ "$(bridge_tmux_claude_blocker_state_from_text "$recent")" != "none" ]]; then
      return 1
    fi
  fi

  # Issue #132: the Claude input box is always the last prompt-glyph line in
  # the TUI. Earlier lines that happen to start with "> " are scrollback
  # (quoted text in an agent response, markdown blockquotes). Remember the
  # LAST line that looks like a prompt and evaluate pending-input on that
  # one only, so quoted content above cannot trigger a permanent defer.
  # Issue #175 (codex review finding): the same applies to codex — a
  # queued `› old text` in scrollback previously caused the old codex
  # branch to return 0 on the first match and mark an idle session as
  # busy. Track last_prompt_line for codex too and evaluate pending-input
  # after the loop on that final line only.
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    line="${line//$'\u00A0'/ }"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$engine" in
      claude)
        if [[ "$trimmed" == ❯* || "$trimmed" == '>'* ]]; then
          last_prompt_line="$trimmed"
        fi
        ;;
      codex)
        if [[ "$trimmed" == ›* || "$trimmed" == '>'* ]]; then
          last_prompt_line="$trimmed"
        fi
        ;;
      *)
        if bridge_tmux_prompt_line_has_pending_input "$engine" "$trimmed"; then
          return 0
        fi
        ;;
    esac
  done <<<"$recent"

  if [[ -n "$last_prompt_line" ]]; then
    bridge_tmux_prompt_line_has_pending_input "$engine" "$last_prompt_line"
    return
  fi

  return 1
}

bridge_tmux_session_has_pending_input() {
  local session="$1"
  local engine="$2"
  local recent=""

  bridge_tmux_engine_requires_prompt "$engine" || return 1
  # Issue #132: use tmux -J so a wrapped prompt line (long mid-compose input
  # that wraps the "> " glyph off to the next visual line on narrow panes) is
  # still detectable as a single logical line. And widen the capture window
  # from 20 to 40 lines so agent output churn cannot push the input box out
  # of view between daemon passes.
  recent="$(bridge_capture_recent "$session" 40 join 2>/dev/null || true)"
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

bridge_tmux_paste_signature() {
  # Return a short, distinctive substring from the text we're about to paste,
  # used by bridge_tmux_paste_landed to verify the paste actually reached the
  # composer. First non-empty line truncated to 40 chars — the nudge payload
  # begins with "[Agent Bridge] ..." which is unlikely to collide with codex
  # ghost-text placeholders or scrollback occupying the last visible lines.
  local text="$1"
  local first_line
  first_line="$(printf '%s' "$text" | awk 'NF{gsub(/^[[:space:]]+/, ""); print; exit}' 2>/dev/null || true)"
  printf '%s' "${first_line:0:40}"
}

bridge_tmux_paste_landed() {
  # Landing verification: compare pre- and post-paste captures. The paste
  # landed iff the signature appears in the post capture more often than in
  # the pre capture. Plain substring presence is not enough because prior
  # nudges may have left identical headers in scrollback.
  local pre="$1"
  local post="$2"
  local signature="$3"
  [[ -n "$signature" ]] || return 1
  local pre_hits post_hits
  pre_hits=$(printf '%s' "$pre" | grep -cF -- "$signature" 2>/dev/null || printf '0')
  post_hits=$(printf '%s' "$post" | grep -cF -- "$signature" 2>/dev/null || printf '0')
  [[ "$pre_hits" =~ ^[0-9]+$ ]] || pre_hits=0
  [[ "$post_hits" =~ ^[0-9]+$ ]] || post_hits=0
  (( post_hits > pre_hits ))
}

bridge_tmux_paste_and_submit() {
  local session="$1"
  local text="$2"
  local engine="${3:-codex}"
  local buffer_name
  local pane_target
  pane_target="$(bridge_tmux_pane_target "$session")"

  buffer_name="bridge-send-$$-$(bridge_nonce)"

  # Issue #195: previous implementation called `paste-buffer -d -p` and
  # trusted that the paste landed in the composer. Codex cold sessions with
  # ghost-text placeholders ("Explain this codebase", "Summarize recent
  # commits") silently drop the first bracketed paste — the C-m that follows
  # lands on a still-empty composer and the daemon logs "nudged" for a
  # delivery that never happened. Verify the paste actually reached the
  # composer via before/after capture diff. On miss, retry without
  # bracketed-paste (-p); if still missing, fall back to per-key input.
  local signature pre_capture post_capture
  signature="$(bridge_tmux_paste_signature "$text")"
  pre_capture="$(bridge_capture_recent "$session" 15 2>/dev/null || true)"

  tmux set-buffer -b "$buffer_name" -- "$text"
  tmux paste-buffer -p -b "$buffer_name" -t "$pane_target"
  sleep 0.1

  post_capture="$(bridge_capture_recent "$session" 15 2>/dev/null || true)"
  if ! bridge_tmux_paste_landed "$pre_capture" "$post_capture" "$signature"; then
    # Bracketed paste may have been absorbed by the placeholder lifecycle
    # instead of the composer. Retry without the -p flag — codex's paste
    # handler treats raw paste as character input, which reliably clears
    # the placeholder on first keystroke.
    tmux paste-buffer -b "$buffer_name" -t "$pane_target"
    sleep 0.15
    post_capture="$(bridge_capture_recent "$session" 15 2>/dev/null || true)"
    if ! bridge_tmux_paste_landed "$pre_capture" "$post_capture" "$signature"; then
      # Both paste attempts lost; fall back to per-key input. type_and_submit
      # bypasses paste-buffer entirely and has its own verify/retry around
      # the submit key (issue #146).
      tmux delete-buffer -b "$buffer_name" 2>/dev/null || true
      bridge_warn "paste did not land in '${session}' composer; falling back to type_and_submit"
      bridge_audit_log daemon tmux_paste_landing_failed "$session" \
        --detail engine="$engine" \
        --detail signature="$signature"
      bridge_tmux_type_and_submit "$session" "$text"
      return $?
    fi
  fi
  tmux delete-buffer -b "$buffer_name" 2>/dev/null || true

  # Issue #175: symmetric verify/retry mirrors bridge_tmux_type_and_submit
  # (issue #146). Fresh codex sessions can miss the first C-m when the TUI
  # hasn't absorbed the paste within the 50ms grace — the submit lands on
  # an empty input line and the paste stays buffered. Warm sessions land
  # instantly; the retry branch only fires under the observed race.
  sleep 0.05
  tmux send-keys -t "$pane_target" C-m
  sleep 0.1
  if bridge_tmux_session_has_pending_input "$session" "$engine"; then
    sleep 0.15
    tmux send-keys -t "$pane_target" C-m
  fi
}

bridge_tmux_type_and_submit() {
  local session="$1"
  local text="$2"
  local line
  local first_line=1
  local pane_target
  pane_target="$(bridge_tmux_pane_target "$session")"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ $first_line -eq 0 ]]; then
      tmux send-keys -t "$pane_target" C-j
    fi
    if [[ -n "$line" ]]; then
      tmux send-keys -t "$pane_target" -l -- "$line"
    fi
    first_line=0
  done <<<"$text"

  # Issue #146: the previous implementation used a fixed 50ms grace
  # before C-m. Under load, Claude's TUI occasionally took longer to
  # absorb the typed keystrokes, so the submit arrived on an empty
  # input line and the handoff was silently dropped. The input stayed
  # populated with the typed text — operators saw "typed but never
  # submitted." Keep the fast-path latency unchanged (one 50ms grace
  # + one C-m) and add a verify/retry: if the input line still reports
  # pending content after the submit, resend C-m once with a wider
  # grace. Doing this unconditionally for every send would block the
  # helper on slow captures; the verify step only reads the last 20
  # lines of scrollback and the retry only fires when we actually
  # observe the race symptom.
  sleep 0.05
  tmux send-keys -t "$pane_target" C-m
  sleep 0.1
  if bridge_tmux_session_has_pending_input "$session" claude; then
    sleep 0.15
    tmux send-keys -t "$pane_target" C-m
  fi
}

bridge_tmux_send_and_submit() {
  local session="$1"
  local engine="$2"
  local text="$3"
  # Issue #132a: optional 4th arg turns on the pending-attention spool so a
  # busy-gate hit no longer silently drops the event. Unspecified → legacy
  # hard-failure behavior for callers that want immediate operator feedback
  # (e.g., bridge-action.sh: the operator ran `agb send` and should see
  # the failure rather than a background deferral).
  local spool_agent="${4:-}"
  # Issue #132: previous default was 3s. Operators frequently pause >3s while
  # composing (reading, thinking, switching windows), which left a window for
  # daemon injections to land mid-compose. The input-buffer-content check
  # (bridge_tmux_session_has_pending_input) is the primary gate; this
  # timestamp gate is the fallback for cases where the input line itself
  # couldn't be matched. A 10s default is still well under the operator's
  # tolerance for a deferred notification but materially reduces the leak.
  local inject_grace="${BRIDGE_TMUX_INJECT_IDLE_GRACE_SECONDS:-10}"

  if ! bridge_tmux_wait_for_prompt "$session" "$engine"; then
    bridge_warn "session prompt unavailable; skipping send to '$session'"
    if bridge_tmux_spool_enabled "$spool_agent"; then
      bridge_tmux_pending_attention_append "$spool_agent" "$text"
      bridge_tmux_session_ring_bell "$session"
      return 0
    fi
    return 1
  fi
  if bridge_tmux_session_inject_busy "$session" "$engine" "$inject_grace"; then
    if bridge_tmux_spool_enabled "$spool_agent"; then
      bridge_tmux_pending_attention_append "$spool_agent" "$text"
      bridge_tmux_session_ring_bell "$session"
      return 0
    fi
    bridge_warn "session busy; deferring send to '$session'"
    return 1
  fi

  case "$engine" in
    claude)
      bridge_tmux_type_and_submit "$session" "$text"
      ;;
    *)
      bridge_tmux_paste_and_submit "$session" "$text" "$engine"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Issue #132a: pending-attention spool.
#
# When a daemon-initiated inject hits the busy gate, rather than silently
# dropping it, the text is escaped and appended to the per-agent spool file
# (bridge_agent_pending_attention_file). A subsequent daemon pass calls
# bridge_tmux_pending_attention_flush, which drains the spool in FIFO order
# and re-injects while the gate is clear. Entries aged past
# BRIDGE_TMUX_INJECT_MAX_DEFER_SECONDS (default 600s) get a `[deferred]`
# marker so the operator can see they are older than a live signal.
#
# The lock is a mkdir spinlock (matches the repo's existing convention in
# lib/bridge-channels.sh::bridge_allocate_dynamic_webhook_port) so the path
# works on Linux and macOS without requiring `flock`.
# ---------------------------------------------------------------------------

bridge_tmux_spool_enabled() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  [[ "${BRIDGE_TMUX_INJECT_SPOOL_ENABLED:-1}" == "1" ]] || return 1
  return 0
}

bridge_tmux_pending_attention_escape() {
  local text="$1"
  text="${text//\\/\\\\}"
  text="${text//$'\t'/\\t}"
  text="${text//$'\r'/\\r}"
  text="${text//$'\n'/\\n}"
  printf '%s' "$text"
}

bridge_tmux_pending_attention_unescape() {
  local text="$1"
  local out=""
  local i=0
  local ch=""
  local next=""
  local len=${#text}
  while (( i < len )); do
    ch="${text:$i:1}"
    if [[ "$ch" == "\\" && $((i + 1)) -lt $len ]]; then
      next="${text:$((i + 1)):1}"
      case "$next" in
        n) out+=$'\n' ;;
        r) out+=$'\r' ;;
        t) out+=$'\t' ;;
        \\) out+=$'\\' ;;
        *) out+="\\$next" ;;
      esac
      i=$((i + 2))
    else
      out+="$ch"
      i=$((i + 1))
    fi
  done
  printf '%s' "$out"
}

bridge_tmux_pending_attention_with_lock() {
  local agent="$1"
  local action="$2"
  shift 2
  local lock_dir=""
  local pid_file=""
  local holder_pid=""
  local attempts=0
  local max_attempts="${BRIDGE_TMUX_PENDING_ATTENTION_LOCK_MAX_ATTEMPTS:-200}"
  local rc=0
  [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=200

  lock_dir="$(bridge_agent_pending_attention_lock_dir "$agent")"
  pid_file="$lock_dir/holder.pid"
  mkdir -p "$(dirname "$lock_dir")"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    # Stale-lock recovery: if the holder PID file exists and the holder
    # process is gone, reclaim the lock dir. This avoids the previous
    # implementation's force-rmdir-after-N-attempts which could yank the
    # lock from a still-live holder mid-critical-section and break FIFO
    # ordering of the spool. (Codex review of #132a flagged this.)
    if [[ -f "$pid_file" ]]; then
      holder_pid="$(cat "$pid_file" 2>/dev/null || true)"
      if [[ "$holder_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
        rm -f "$pid_file" 2>/dev/null
        rmdir "$lock_dir" 2>/dev/null
        continue
      fi
    fi
    attempts=$((attempts + 1))
    if (( attempts >= max_attempts )); then
      # Hard failure rather than lock theft. Caller can retry next pass
      # (the daemon's flush is idempotent — a missed cycle just defers).
      bridge_warn "pending-attention lock contention for '$agent'; giving up after ${max_attempts} attempts"
      return 75
    fi
    sleep 0.05
  done

  printf '%d' $$ >"$pid_file" 2>/dev/null
  "$action" "$agent" "$@"
  rc=$?
  rm -f "$pid_file" 2>/dev/null
  rmdir "$lock_dir" >/dev/null 2>&1 || true
  return $rc
}

_bridge_tmux_pending_attention_append_locked() {
  local agent="$1"
  local text="$2"
  local spool_file=""
  local escaped=""
  local ts=""

  spool_file="$(bridge_agent_pending_attention_file "$agent")"
  mkdir -p "$(dirname "$spool_file")"
  ts="$(date +%s)"
  escaped="$(bridge_tmux_pending_attention_escape "$text")"
  printf '%s\t%s\n' "$ts" "$escaped" >>"$spool_file"
}

bridge_tmux_pending_attention_append() {
  local agent="$1"
  local text="$2"
  [[ -n "$agent" ]] || return 1
  bridge_tmux_pending_attention_with_lock "$agent" \
    _bridge_tmux_pending_attention_append_locked "$text"
}

_bridge_tmux_pending_attention_drain_locked() {
  local agent="$1"
  local spool_file=""

  spool_file="$(bridge_agent_pending_attention_file "$agent")"
  [[ -f "$spool_file" ]] || return 0
  cat "$spool_file"
  : >"$spool_file"
}

bridge_tmux_pending_attention_drain() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  bridge_tmux_pending_attention_with_lock "$agent" \
    _bridge_tmux_pending_attention_drain_locked
}

_bridge_tmux_pending_attention_prepend_locked() {
  local agent="$1"
  local lines="$2"
  local spool_file=""
  local tmp=""

  spool_file="$(bridge_agent_pending_attention_file "$agent")"
  mkdir -p "$(dirname "$spool_file")"
  tmp="$(mktemp "${spool_file}.XXXXXX")"
  printf '%s' "$lines" >"$tmp"
  if [[ -f "$spool_file" ]]; then
    cat "$spool_file" >>"$tmp"
  fi
  mv "$tmp" "$spool_file"
}

bridge_tmux_pending_attention_prepend() {
  local agent="$1"
  local lines="$2"
  [[ -n "$agent" ]] || return 1
  [[ -n "$lines" ]] || return 0
  bridge_tmux_pending_attention_with_lock "$agent" \
    _bridge_tmux_pending_attention_prepend_locked "$lines"
}

bridge_tmux_pending_attention_count() {
  local agent="$1"
  local spool_file=""
  spool_file="$(bridge_agent_pending_attention_file "$agent")"
  [[ -f "$spool_file" ]] || { printf '0'; return 0; }
  awk 'NF>0' "$spool_file" | wc -l | awk '{print $1}'
}

bridge_tmux_session_ring_bell() {
  local session="$1"
  [[ -n "$session" ]] || return 0
  # Best-effort operator cue when an inject is deferred. Rationale for this
  # exact mechanism: `tmux send-keys -l $'\a'` would feed BEL as keyboard
  # input to the pane program, which Claude/Codex TUIs just absorb as
  # Ctrl-G — the operator sees nothing. `display-message` is more reliable:
  # tmux renders it on the status line of any attached client, which is a
  # visible cue on its own. The embedded `\a` is kept on the hope that some
  # clients' terminals still honor it; tmux may sanitize it, which is fine.
  # The durable signal remains the spool file + the session-start context
  # line added in hooks/bridge_hook_common.py::bootstrap_artifact_context.
  tmux display-message -t "$(bridge_tmux_pane_target "$session")" \
    $'\a[Agent Bridge] deferred event queued — input busy' \
    >/dev/null 2>&1 || true
}

bridge_tmux_pending_attention_flush() {
  local session="$1"
  local engine="$2"
  local agent="$3"
  local max_defer="${BRIDGE_TMUX_INJECT_MAX_DEFER_SECONDS:-600}"
  local drained=""
  local now=""
  local unflushed=""
  local line=""
  local ts=""
  local escaped=""
  local decoded=""
  local age=0

  [[ -n "$agent" ]] || return 0
  bridge_tmux_spool_enabled "$agent" || return 0
  drained="$(bridge_tmux_pending_attention_drain "$agent" || true)"
  [[ -n "$drained" ]] || return 0

  now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ts="${line%%$'\t'*}"
    escaped="${line#*$'\t'}"
    decoded="$(bridge_tmux_pending_attention_unescape "$escaped")"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      age=$((now - ts))
      if (( age > max_defer )); then
        decoded="[deferred] $decoded"
      fi
    else
      # Unknown age — safer to warn the operator that the replay is stale
      # than to present it as a live signal.
      decoded="[deferred] $decoded"
    fi

    # Pass no agent so send_and_submit returns hard failure on busy instead
    # of re-spooling. Remaining entries go back to the spool via prepend.
    if bridge_tmux_send_and_submit "$session" "$engine" "$decoded"; then
      continue
    fi

    unflushed+="$line"$'\n'
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      unflushed+="$line"$'\n'
    done
    break
  done <<<"$drained"

  if [[ -n "$unflushed" ]]; then
    bridge_tmux_pending_attention_prepend "$agent" "$unflushed"
    return 1
  fi
  return 0
}

bridge_capture_recent() {
  local session="$1"
  local lines="${2:-30}"
  # Pass "join" as $3 to join visually wrapped lines (-J). Needed when the
  # caller regexes single-line artifacts that can wrap across physical pane
  # lines on narrow terminals — e.g., the Claude HUD "Context <bar> NN%"
  # meter (issue #126) and the Claude "> <typed text>" input box at the
  # bottom of the TUI (issue #132). Default behavior (unjoined) preserves
  # every historical caller's output verbatim.
  local mode="${3:-}"
  if [[ "$mode" == "join" ]]; then
    tmux capture-pane -t "$(bridge_tmux_pane_target "$session")" -p -J -S "-$lines"
  else
    tmux capture-pane -t "$(bridge_tmux_pane_target "$session")" -p -S "-$lines"
  fi
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
