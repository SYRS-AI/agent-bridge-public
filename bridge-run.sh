#!/usr/bin/env bash
# bridge-run.sh — roster 기반 에이전트 실행기

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-run.sh <agent> [--once] [--continue|--no-continue] [--safe-mode] [--dry-run]"
  echo "       bash $SCRIPT_DIR/bridge-run.sh --list"
  echo ""
  echo "등록된 에이전트:"
  bridge_list_agents
}

LIST_ONLY=0
ONCE=0
DRY_RUN=0
CONTINUE_EXPLICIT=0
CONTINUE_MODE=1
SAFE_MODE=0
AGENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --once)
      ONCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --safe-mode)
      SAFE_MODE=1
      shift
      ;;
    --continue)
      CONTINUE_EXPLICIT=1
      CONTINUE_MODE=1
      shift
      ;;
    --no-continue)
      CONTINUE_EXPLICIT=1
      CONTINUE_MODE=0
      shift
      ;;
    -*)
      bridge_die "알 수 없는 옵션: $1"
      ;;
    *)
      if [[ -z "$AGENT" ]]; then
        AGENT="$1"
      else
        bridge_die "에이전트는 하나만 지정할 수 있습니다."
      fi
      shift
      ;;
  esac
done

# Export BRIDGE_AGENT_ID before roster load so bridge_load_roster can pick up
# the per-agent scoped snapshot when this script runs under an isolated UID
# that cannot read the 0600 agent-roster.local.sh. See issue #116.
if [[ -n "$AGENT" ]]; then
  export BRIDGE_AGENT_ID="$AGENT"
fi
bridge_load_roster

if [[ $LIST_ONLY -eq 1 ]]; then
  bridge_list_agents
  exit 0
fi

if [[ -z "$AGENT" ]]; then
  usage
  exit 1
fi

bridge_require_agent "$AGENT"

if [[ $CONTINUE_EXPLICIT -eq 1 ]]; then
  BRIDGE_AGENT_CONTINUE["$AGENT"]="$CONTINUE_MODE"
fi

if [[ $SAFE_MODE -eq 1 ]]; then
  ONCE=1
fi

WORK_DIR="$(bridge_agent_workdir "$AGENT")"
ENGINE="$(bridge_agent_engine "$AGENT")"
SESSION="$(bridge_agent_session "$AGENT")"
if [[ $SAFE_MODE -eq 1 ]]; then
  LAUNCH_CMD="$(bridge_build_safe_launch_cmd "$AGENT")"
else
  LAUNCH_CMD="$(bridge_agent_launch_cmd "$AGENT")"
fi

if [[ -z "$WORK_DIR" || -z "$LAUNCH_CMD" ]]; then
  bridge_die "'$AGENT'의 workdir 또는 launch command가 비어 있습니다."
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "agent=$AGENT"
  echo "engine=$ENGINE"
  echo "workdir=$WORK_DIR"
  echo "loop=$(bridge_agent_loop "$AGENT")"
  echo "continue=$(bridge_agent_continue "$AGENT")"
  echo "session_id=$(bridge_agent_session_id "$AGENT")"
  echo "safe_mode=$SAFE_MODE"
  echo "channels=$(bridge_agent_channels_csv "$AGENT")"
  echo "channel_status=$(bridge_agent_channel_status "$AGENT")"
  echo "launch=$LAUNCH_CMD"
  exit 0
fi

export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/usr/local/bin:$PATH"
export BRIDGE_AGENT_ID="$AGENT"
export BRIDGE_ADMIN_AGENT_ID="$(bridge_admin_agent_id)"
export BRIDGE_AGENT_WORKDIR="$WORK_DIR"
export BRIDGE_AGENT_ISOLATION_MODE="$(bridge_agent_isolation_mode "$AGENT")"
export BRIDGE_AGENT_OS_USER="$(bridge_agent_os_user "$AGENT")"
export BRIDGE_AGENT_INJECT_TIMESTAMP="$(bridge_agent_inject_timestamp "$AGENT")"
export BRIDGE_AGENT_PROMPT_GUARD_POLICY="$(bridge_guard_policy_raw "$AGENT")"
export BRIDGE_PROMPT_GUARD_CANARY_TOKENS="$(bridge_agent_prompt_guard_canary "$AGENT")"

mkdir -p "$(bridge_agent_log_dir "$AGENT")" "$BRIDGE_SHARED_DIR"
cd "$WORK_DIR" || bridge_die "$WORK_DIR 디렉토리가 없습니다."

LOGFILE="$(bridge_agent_log_dir "$AGENT")/$(date '+%Y%m%d').log"
ERRFILE="$(bridge_agent_log_dir "$AGENT")/$(date '+%Y%m%d').err.log"
BRIDGE_RUN_ROSTER_SIGNATURE=""

log_line() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$line" | tee -a "$LOGFILE"
}

log_loop_help() {
  bridge_run_session_attached || return 0
  log_line "tmux에서 쉘로 돌아가기: Ctrl-b 를 누른 뒤 d 를 누르세요."
  log_line "에이전트를 완전히 종료하기: 바깥 터미널에서 'agb kill ${AGENT}' 를 실행하세요."
}

bridge_run_session_attached() {
  local attached

  [[ -n "$SESSION" ]] || return 1
  attached="$(bridge_tmux_session_attached_count "$SESSION" 2>/dev/null || printf '0')"
  [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
  (( attached > 0 ))
}

bridge_run_detach_attached_clients() {
  [[ -n "$SESSION" ]] || return 0
  bridge_tmux_detach_clients "$SESSION" >/dev/null 2>&1 || true
}

bridge_run_stop_foreground_session() {
  if [[ "$(bridge_agent_source "$AGENT")" == "static" ]]; then
    bridge_agent_mark_manual_stop "$AGENT"
  fi
  bridge_agent_clear_idle_marker "$AGENT"
}

bridge_run_cleanup_mcp_orphans() {
  local min_age="${BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS:-0}"

  [[ "${BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED:-1}" == "1" ]] || return 0
  [[ "$min_age" =~ ^[0-9]+$ ]] || min_age=0

  # Give orphaned MCP grandchildren a brief chance to be reparented to init
  # before scanning, otherwise the conservative detector can miss them.
  sleep 0.2
  bridge_mcp_orphan_cleanup "session-exit:${AGENT}" "$min_age" 1 >/dev/null 2>&1 || true
}

bridge_run_roster_signature() {
  local payload=""
  local file=""

  for file in "$BRIDGE_ROSTER_FILE" "$BRIDGE_ROSTER_LOCAL_FILE"; do
    payload+="${file}"$'\n'
    if [[ -f "$file" ]]; then
      payload+="present"$'\n'
      payload+="$(cat "$file")"$'\n'
    else
      payload+="missing"$'\n'
    fi
  done

  bridge_sha1 "$payload"
}

bridge_run_refresh_roster_if_changed() {
  local signature=""

  signature="$(bridge_run_roster_signature)"
  if [[ -n "$BRIDGE_RUN_ROSTER_SIGNATURE" && "$signature" == "$BRIDGE_RUN_ROSTER_SIGNATURE" ]]; then
    return 0
  fi

  bridge_load_roster
  bridge_require_agent "$AGENT"
  if [[ $CONTINUE_EXPLICIT -eq 1 ]]; then
    BRIDGE_AGENT_CONTINUE["$AGENT"]="$CONTINUE_MODE"
  fi
  WORK_DIR="$(bridge_agent_workdir "$AGENT")"
  ENGINE="$(bridge_agent_engine "$AGENT")"
  SESSION="$(bridge_agent_session "$AGENT")"
  [[ -n "$WORK_DIR" ]] || bridge_die "'$AGENT'의 workdir가 비어 있습니다."
  cd "$WORK_DIR" || bridge_die "$WORK_DIR 디렉토리가 없습니다."
  if [[ -n "$BRIDGE_RUN_ROSTER_SIGNATURE" ]]; then
    log_line "[info] roster changed on disk; reloading before next relaunch"
  fi
  BRIDGE_RUN_ROSTER_SIGNATURE="$signature"
}

bridge_run_reconcile_next_session_state() {
  local next_file=""
  local marker_file=""
  local age_seconds=""
  local ttl_seconds="${BRIDGE_NEXT_SESSION_AUTO_CLEAR_SECONDS:-300}"

  [[ "$ENGINE" == "claude" ]] || return 0
  [[ $SAFE_MODE -eq 0 ]] || return 0
  next_file="$(bridge_agent_next_session_file "$AGENT")"
  [[ -f "$next_file" ]] || return 0

  age_seconds="$(bridge_agent_maybe_expire_next_session "$AGENT" "$ttl_seconds" || true)"
  if [[ "$age_seconds" =~ ^[0-9]+$ ]]; then
    marker_file="$(bridge_agent_next_session_marker_file "$AGENT")"
    log_line "[info] auto-cleared stale NEXT-SESSION.md after ${age_seconds}s (previous handoff digest was already delivered)"
    bridge_audit_log daemon next_session_autocleared "$AGENT" \
      --detail age_seconds="$age_seconds" \
      --detail ttl_seconds="$ttl_seconds" \
      --detail next_session_file="$next_file" \
      --detail marker_file="$marker_file"
    return 0
  fi

  if [[ "$(bridge_agent_continue "$AGENT")" == "1" ]]; then
    log_line "[warn] NEXT-SESSION.md present at $next_file -> --resume suppressed for this restart. Delete it after handoff verification."
  fi
}

bridge_run_schedule_idle_marker_and_inbox_bootstrap() {
  local next_file="$WORK_DIR/NEXT-SESSION.md"
  local marker_file=""

  [[ "$ENGINE" == "claude" ]] || return 0
  [[ $SAFE_MODE -eq 0 ]] || return 0
  marker_file="$(bridge_agent_initial_inbox_marker_file "$AGENT")"

  (
    "$BRIDGE_BASH_BIN" -lc '
      set -euo pipefail
      script_dir="$1"
      session="$2"
      agent="$3"
      marker_file="$4"
      next_file="$5"
      source "$script_dir/bridge-lib.sh"
      if bridge_tmux_wait_for_prompt "$session" claude 30; then
        if [[ -z "$(bridge_agent_session_id "$agent")" ]]; then
          # Claude session metadata can appear after tmux startup. Refresh once
          # more at prompt-ready time so static resume state is persisted before
          # the agent later goes inactive.
          bridge_refresh_agent_session_id "$agent" 24 0.5 >/dev/null 2>&1 || true
        fi
        bridge_agent_mark_idle_now "$agent"
        if [[ ! -f "$next_file" && ! -f "$marker_file" ]]; then
          task_id="$(bridge_queue_cli find-open --agent "$agent" 2>/dev/null | head -n 1 || true)"
          if [[ -n "$task_id" ]]; then
            if bridge_inject_metadata_only_enabled; then
              inject_text="$(bridge_format_injection_meta inbox-bootstrap agent="$agent" top="$task_id")"
            else
              inject_text="[Agent Bridge] ACTION REQUIRED — queued tasks detected. Run exactly: ~/.agent-bridge/agb inbox $agent"
            fi
            bridge_tmux_send_and_submit "$session" claude "$inject_text" "$agent"
          fi
          mkdir -p "$(dirname "$marker_file")"
          printf "%s\n" "$(date +%s)" >"$marker_file"
        fi
      fi
    ' -- "$SCRIPT_DIR" "$SESSION" "$AGENT" "$marker_file" "$next_file"
  ) >/dev/null 2>&1 &
}

bridge_run_should_auto_accept_dev_channels() {
  local launch_cmd="$1"
  local allowed=""
  local effective=""
  local item=""
  local -a items=()

  [[ "$ENGINE" == "claude" ]] || return 1
  [[ $SAFE_MODE -eq 0 ]] || return 1
  effective="$(bridge_extract_development_channels_from_command "$launch_cmd")"
  [[ -n "$effective" ]] || return 1
  allowed="$(bridge_agent_auto_accept_dev_channels_csv "$AGENT")"
  [[ -n "$allowed" ]] || return 1

  IFS=',' read -r -a items <<<"$allowed"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if bridge_channel_csv_contains "$effective" "$item"; then
      return 0
    fi
  done

  return 1
}

bridge_run_schedule_dev_channels_accept() {
  local launch_cmd="$1"

  bridge_run_should_auto_accept_dev_channels "$launch_cmd" || return 0
  log_line "[info] auto-accepting Claude development-channels prompt for allowlisted dev channel(s)"
  (
    "$BRIDGE_BASH_BIN" -lc '
      set -euo pipefail
      script_dir="$1"
      session="$2"
      source "$script_dir/bridge-lib.sh"
      bridge_tmux_wait_for_prompt "$session" claude 15 1 >/dev/null 2>&1 || true
    ' -- "$SCRIPT_DIR" "$SESSION"
  ) >/dev/null 2>&1 &
}

bridge_run_sync_dev_plugin_cache() {
  local channels=""
  local output=""
  local line=""

  [[ "$ENGINE" == "claude" ]] || return 0
  [[ $SAFE_MODE -eq 0 ]] || return 0
  channels="$(bridge_agent_effective_dev_channels_csv "$AGENT")"
  [[ -n "$channels" ]] || return 0

  if output="$(python3 "$SCRIPT_DIR/bridge-dev-plugin-cache.py" sync --channels "$channels" 2>&1)"; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      log_line "[dev-plugin-cache] $line"
    done <<<"$output"
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      log_line "[dev-plugin-cache] $line"
    done <<<"$output"
    bridge_warn "development plugin cache sync failed for ${AGENT}"
  fi
}

bridge_run_safe_mode_resume_hint() {
  local mode=""
  local admin_agent=""

  mode="$(bridge_safe_mode_resume_mode "$AGENT")"
  admin_agent="$(bridge_require_admin_agent 2>/dev/null || true)"
  log_line "[safe-mode] booting ${AGENT} with minimal launch"
  log_line "[safe-mode] ignored roster launch_cmd: $(bridge_agent_launch_cmd_raw "$AGENT")"
  if [[ -n "$(bridge_agent_channels_csv "$AGENT")" ]]; then
    log_line "[safe-mode] suppressed channels: $(bridge_agent_channels_csv "$AGENT")"
  fi
  if [[ -n "$(bridge_agent_effective_dev_channels_csv "$AGENT")" ]]; then
    log_line "[safe-mode] suppressed development channels: $(bridge_agent_effective_dev_channels_csv "$AGENT")"
  fi
  log_line "[safe-mode] skipped project bootstrap and channel plugin loading"
  log_line "[safe-mode] resume strategy: ${mode}"
  if [[ -n "$admin_agent" && "$AGENT" == "$admin_agent" ]]; then
    log_line "[safe-mode] return to normal mode with: agb admin"
  else
    log_line "[safe-mode] return to normal mode with: agent-bridge agent start ${AGENT}"
  fi
}

bridge_run_fail_backoff_seconds() {
  local count="$1"
  local csv="${BRIDGE_RUN_FAIL_BACKOFFS_CSV:-5,10,20,40,80}"
  local -a values=()
  local index=0

  IFS=',' read -r -a values <<<"$csv"
  [[ "$count" =~ ^[0-9]+$ ]] || count=1
  index=$((count - 1))
  if (( index < 0 )); then
    index=0
  fi
  if (( index < ${#values[@]} )); then
    printf '%s' "${values[$index]}"
  elif (( ${#values[@]} > 0 )); then
    printf '%s' "${values[$((${#values[@]} - 1))]}"
  else
    printf '%s' "80"
  fi
}

log_line "${AGENT} 에이전트 시작 (engine=${ENGINE}, dir=${WORK_DIR})"
BRIDGE_RUN_ROSTER_SIGNATURE="$(bridge_run_roster_signature)"
if [[ $SAFE_MODE -eq 1 ]]; then
  bridge_run_safe_mode_resume_hint
fi

FAIL_COUNT=0
RESTART_COUNT=0
RAPID_FAIL_COUNT=0
RAPID_FAIL_WINDOW="${BRIDGE_RUN_RAPID_FAIL_WINDOW_SECONDS:-10}"
MAX_RAPID_FAILS="${BRIDGE_RUN_MAX_RAPID_FAILS:-5}"
HEALTHY_RUN_RESET_SECONDS="${BRIDGE_RUN_HEALTHY_RESET_SECONDS:-60}"
while true; do
  local_err_size_before=0
  local_err_size_after=0
  run_started_at=0
  run_ended_at=0
  run_duration=0
  rapid_failure=0
  sleep_seconds=5
  bridge_run_refresh_roster_if_changed
  export BRIDGE_AGENT_LOOP_RESTART_COUNT="$RESTART_COUNT"
  bridge_run_reconcile_next_session_state
  if [[ $SAFE_MODE -eq 1 ]]; then
    LAUNCH_CMD="$(bridge_build_safe_launch_cmd "$AGENT")"
  else
    LAUNCH_CMD="$(bridge_agent_launch_cmd "$AGENT")"
  fi
  [[ -n "$LAUNCH_CMD" ]] || bridge_die "'$AGENT'의 launch command가 비어 있습니다."

  if [[ "$ENGINE" == "claude" && $SAFE_MODE -eq 0 ]]; then
    bridge_run_sync_dev_plugin_cache
    bridge_ensure_claude_launch_channel_plugins "$AGENT"
    bridge_run_schedule_dev_channels_accept "$LAUNCH_CMD"
    bridge_run_schedule_idle_marker_and_inbox_bootstrap
  fi

  log_line "실행: ${LAUNCH_CMD}"
  if [[ -f "$ERRFILE" ]]; then
    local_err_size_before="$(wc -c <"$ERRFILE" 2>/dev/null || echo 0)"
  fi
  run_started_at="$(date +%s)"
  if "$BRIDGE_BASH_BIN" -lc "$LAUNCH_CMD" 2> >(tee -a "$ERRFILE" >&2); then
    EXIT_CODE=0
  else
    EXIT_CODE=$?
  fi
  run_ended_at="$(date +%s)"
  if [[ "$run_started_at" =~ ^[0-9]+$ && "$run_ended_at" =~ ^[0-9]+$ ]]; then
    run_duration=$((run_ended_at - run_started_at))
  fi
  if [[ -f "$ERRFILE" ]]; then
    local_err_size_after="$(wc -c <"$ERRFILE" 2>/dev/null || echo 0)"
  fi

  bridge_run_cleanup_mcp_orphans

  if [[ $ONCE -eq 1 ]]; then
    if [[ $local_err_size_after -gt $local_err_size_before ]]; then
      log_line "stderr captured: ${ERRFILE}"
    fi
    log_line "1회 실행 종료 (코드: ${EXIT_CODE})"
    exit "$EXIT_CODE"
  fi

  if [[ $EXIT_CODE -eq 0 ]] && bridge_run_session_attached; then
    if bridge_agent_should_stop_on_attached_clean_exit "$AGENT"; then
      if [[ $FAIL_COUNT -gt 0 ]]; then
        bridge_agent_clear_crash_report "$AGENT"
      fi
      bridge_run_stop_foreground_session
      log_line "정상 종료. admin 온보딩이 아직 완료되지 않았으므로 자동 재시작하지 않습니다. 다시 열려면 'agb admin'을 실행하세요."
      exit 0
    else
      log_line "정상 종료. 온보딩 완료/일반 루프 에이전트이므로 tmux client는 분리하고, 에이전트는 백그라운드에서 계속 재시작합니다."
      bridge_run_detach_attached_clients
    fi
  fi

  if [[ $EXIT_CODE -ne 0 ]]; then
    if [[ "$run_duration" =~ ^[0-9]+$ ]] && [[ "$HEALTHY_RUN_RESET_SECONDS" =~ ^[0-9]+$ ]] && (( run_duration >= HEALTHY_RUN_RESET_SECONDS )); then
      FAIL_COUNT=0
      RAPID_FAIL_COUNT=0
      bridge_agent_clear_crash_report "$AGENT"
    fi
    if [[ $local_err_size_after -gt $local_err_size_before ]]; then
      log_line "stderr captured: ${ERRFILE}"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [[ "$run_duration" =~ ^[0-9]+$ ]] && [[ "$RAPID_FAIL_WINDOW" =~ ^[0-9]+$ ]] && (( run_duration < RAPID_FAIL_WINDOW )); then
      rapid_failure=1
      RAPID_FAIL_COUNT=$((RAPID_FAIL_COUNT + 1))
    else
      RAPID_FAIL_COUNT=0
    fi
    if [[ $FAIL_COUNT -eq 5 || $(( FAIL_COUNT % 10 )) -eq 0 ]]; then
      bridge_agent_write_crash_report "$AGENT" "$ENGINE" "$FAIL_COUNT" "$EXIT_CODE" "$ERRFILE" "$LAUNCH_CMD"
      bridge_audit_log daemon crash_loop_detected "$AGENT" \
        --detail engine="$ENGINE" \
        --detail fail_count="$FAIL_COUNT" \
        --detail exit_code="$EXIT_CODE" \
        --detail stderr_file="$ERRFILE"
    fi
    if [[ $rapid_failure -eq 1 && "$RAPID_FAIL_COUNT" =~ ^[0-9]+$ && "$MAX_RAPID_FAILS" =~ ^[0-9]+$ && $RAPID_FAIL_COUNT -ge $MAX_RAPID_FAILS ]]; then
      bridge_agent_write_crash_report "$AGENT" "$ENGINE" "$FAIL_COUNT" "$EXIT_CODE" "$ERRFILE" "$LAUNCH_CMD"
      bridge_agent_write_broken_launch_state "$AGENT" "$ENGINE" "$FAIL_COUNT" "$EXIT_CODE" "$ERRFILE" "$LAUNCH_CMD" "$local_err_size_before"
      bridge_audit_log daemon crash_loop_broken "$AGENT" \
        --detail engine="$ENGINE" \
        --detail fail_count="$FAIL_COUNT" \
        --detail exit_code="$EXIT_CODE" \
        --detail rapid_fail_count="$RAPID_FAIL_COUNT" \
        --detail rapid_fail_window="$RAPID_FAIL_WINDOW"
      log_line "[fail] ${RAPID_FAIL_COUNT} consecutive rapid failures under ${RAPID_FAIL_WINDOW}s. Circuit breaker opened."
      log_line "[fail] recovery: agent-bridge agent safe-mode ${AGENT}"
      log_loop_help
      exit 1
    fi
    if [[ $rapid_failure -eq 1 ]]; then
      sleep_seconds="$(bridge_run_fail_backoff_seconds "$RAPID_FAIL_COUNT")"
      log_line "비정상 종료 (코드: ${EXIT_CODE}, 연속실패: ${FAIL_COUNT}회, rapid=${RAPID_FAIL_COUNT}/${MAX_RAPID_FAILS}, 실행시간: ${run_duration}s). ${sleep_seconds}초 후 재시작..."
    else
      log_line "비정상 종료 (코드: ${EXIT_CODE}, 연속실패: ${FAIL_COUNT}회, 실행시간: ${run_duration}s). 5초 후 재시작..."
    fi
    log_loop_help
    RESTART_COUNT=$((RESTART_COUNT + 1))
    if [[ $rapid_failure -eq 1 ]]; then
      sleep "$sleep_seconds"
    elif [[ $FAIL_COUNT -ge 10 ]]; then
      log_line "연속 ${FAIL_COUNT}회 실패. 60초 대기..."
      sleep 60
    else
      sleep 5
    fi
  else
    if [[ $FAIL_COUNT -gt 0 ]]; then
      bridge_agent_clear_crash_report "$AGENT"
      bridge_audit_log daemon crash_loop_recovered "$AGENT" \
        --detail engine="$ENGINE" \
        --detail previous_fail_count="$FAIL_COUNT"
    fi
    FAIL_COUNT=0
    RAPID_FAIL_COUNT=0
    log_line "정상 종료. 5초 후 재시작..."
    log_loop_help
    RESTART_COUNT=$((RESTART_COUNT + 1))
    sleep 5
  fi
done
