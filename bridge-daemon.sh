#!/usr/bin/env bash
# bridge-daemon.sh — keeps dynamic bridge roster in sync with tmux sessions

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-daemon.sh <start|ensure|run|stop|status|sync>"
}

daemon_log_event() {
  local message="$1"
  local timestamp

  timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  mkdir -p "$BRIDGE_STATE_DIR"
  printf '[%s] %s\n' "$timestamp" "$message" >>"$BRIDGE_DAEMON_CRASH_LOG"
}

bridge_dashboard_post_if_changed() {
  local summary_output="$1"
  local summary_file

  [[ -n "$BRIDGE_DASHBOARD_WEBHOOK_URL" ]] || return 0
  [[ -n "$summary_output" ]] || return 0

  summary_file="$(mktemp)"
  printf '%s\n' "$summary_output" >"$summary_file"

  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-dashboard.py" \
    --summary-tsv "$summary_file" \
    --state-file "$BRIDGE_DASHBOARD_STATE_FILE" \
    --webhook-url "$BRIDGE_DASHBOARD_WEBHOOK_URL" \
    >/dev/null 2>&1 || true

  rm -f "$summary_file"
}

nudge_agent_session() {
  local agent="$1"
  local _session="$2"
  local queued="$3"
  local claimed="$4"
  local idle="$5"
  local nudge_key="${6:-}"
  local title
  local message
  local status=0
  local open_task_shell=""
  local task_id=""
  local task_title=""
  local task_priority=""

  title="$(bridge_queue_attention_title "$queued")"
  open_task_shell="$(bridge_queue_cli find-open --agent "$agent" --format shell 2>/dev/null || true)"
  if [[ -n "$open_task_shell" ]]; then
    # shellcheck disable=SC1091
    source /dev/stdin <<<"$open_task_shell"
  fi
  if [[ -n "$TASK_ID" && -n "$TASK_TITLE" ]]; then
    task_id="$TASK_ID"
    task_title="$TASK_TITLE"
    task_priority="${TASK_PRIORITY:-normal}"
  fi

  message="$(bridge_queue_attention_message "$agent" "$queued" "$task_id" "$task_priority" "$task_title")"
  if ! bridge_dispatch_notification "$agent" "$title" "$message" "" "normal"; then
    status=$?
    if [[ "$status" == "2" ]]; then
      return 2
    fi
    return 1
  fi
  bridge_task_note_nudge "$agent" "$nudge_key" || true
  echo "[info] nudged ${agent} (queued=${queued}, claimed=${claimed}, idle=${idle}s)"
}

recover_claude_bootstrap_blockers() {
  local agent
  local session
  local state=""

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
    session="$(bridge_agent_session "$agent")"
    [[ -n "$session" ]] || continue
    bridge_tmux_session_exists "$session" || continue

    state="$(bridge_tmux_claude_blocker_state "$session" 2>/dev/null || true)"
    case "$state" in
      trust|summary)
        if bridge_tmux_prepare_claude_session "$session" 6 >/dev/null 2>&1; then
          echo "[info] advanced claude startup blocker for ${agent} (${state})"
        else
          bridge_warn "failed to advance claude startup blocker for '${agent}' (${state})"
        fi
        ;;
    esac
  done
}

bridge_channel_health_state_file() {
  local agent="$1"
  printf '%s/channel-health/%s.env' "$BRIDGE_STATE_DIR" "$agent"
}

bridge_channel_health_body_file() {
  local agent="$1"
  printf '%s/channel-health/%s.md' "$BRIDGE_SHARED_DIR" "$agent"
}

bridge_write_channel_health_body() {
  local agent="$1"
  local file="$2"
  local required_channels=""
  local reason=""
  local session=""
  local workdir=""

  required_channels="$(bridge_agent_channels_csv "$agent")"
  reason="$(bridge_agent_channel_status_reason "$agent")"
  session="$(bridge_agent_session "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"

  mkdir -p "$(dirname "$file")"
  cat >"$file" <<EOF
# Channel Health Alert

- agent: ${agent}
- engine: $(bridge_agent_engine "$agent")
- session: ${session:--}
- workdir: ${workdir:--}
- required_channels: ${required_channels:-(unset)}
- detected_at: $(bridge_now_iso)

## Reason

${reason:-unknown channel health mismatch}

## Suggested next steps

1. Run \`agent-bridge setup agent ${agent}\`
2. Inspect \`agent-bridge status --all-agents\`
3. Restart the agent with \`bash bridge-start.sh ${agent} --replace\` after fixing the channel config
EOF
}

bridge_clear_channel_health_state() {
  local agent="$1"
  rm -f "$(bridge_channel_health_state_file "$agent")"
}

bridge_report_channel_health_miss() {
  local agent="$1"
  local admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  local status=""
  local reason=""
  local key=""
  local now_ts=""
  local state_file=""
  local body_file=""
  local title=""
  local title_prefix=""
  local existing_id=""
  local create_output=""
  local last_key=""
  local last_report_ts=0

  [[ -n "$admin_agent" ]] || return 0
  bridge_agent_exists "$admin_agent" || return 0
  [[ "$admin_agent" != "$agent" ]] || return 0

  status="$(bridge_agent_channel_status "$agent")"
  if [[ "$status" != "miss" ]]; then
    bridge_clear_channel_health_state "$agent"
    return 0
  fi

  reason="$(bridge_agent_channel_status_reason "$agent")"
  [[ -n "$reason" ]] || reason="unknown channel health mismatch"
  key="$(bridge_sha1 "${agent}|${reason}|$(bridge_agent_channels_csv "$agent")")"
  now_ts="$(date +%s)"
  state_file="$(bridge_channel_health_state_file "$agent")"
  body_file="$(bridge_channel_health_body_file "$agent")"
  title="[channel-health] ${agent} (miss)"
  title_prefix="[channel-health] ${agent} "

  if [[ -f "$state_file" ]]; then
    # shellcheck source=/dev/null
    source "$state_file"
    last_key="${LAST_KEY:-}"
    last_report_ts="${LAST_REPORT_TS:-0}"
  fi

  bridge_write_channel_health_body "$agent" "$body_file"
  existing_id="$(bridge_queue_cli find-open --agent "$admin_agent" --title-prefix "$title_prefix" 2>/dev/null || true)"
  if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
    bridge_queue_cli update "$existing_id" --actor "daemon" --title "$title" --priority urgent --body-file "$body_file" >/dev/null 2>&1 || true
  elif [[ "$key" != "$last_key" || $(( now_ts - last_report_ts )) -ge ${BRIDGE_CHANNEL_HEALTH_REPORT_COOLDOWN_SECONDS:-1800} ]]; then
    create_output="$(bridge_queue_cli create --to "$admin_agent" --title "$title" --from daemon --priority urgent --body-file "$body_file" 2>/dev/null || true)"
    if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
      echo "[info] reported channel-health miss for ${agent} -> ${admin_agent} (#${BASH_REMATCH[1]})"
    fi
  else
    return 0
  fi

  mkdir -p "$(dirname "$state_file")"
  cat >"$state_file" <<EOF
LAST_KEY=$(printf '%q' "$key")
LAST_REPORT_TS=$(printf '%q' "$now_ts")
EOF
}

process_channel_health() {
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -z "$agent" ]] && continue
    bridge_report_channel_health_miss "$agent" || true
  done
}

cron_worker_running_count() {
  local worker_dir
  local pid_file
  local pid
  local count=0

  worker_dir="$(bridge_cron_worker_dir)"
  mkdir -p "$worker_dir"

  shopt -s nullglob
  for pid_file in "$worker_dir"/*.pid; do
    pid="$(<"$pid_file")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      count=$((count + 1))
      continue
    fi
    rm -f "$pid_file"
  done
  shopt -u nullglob

  printf '%s' "$count"
}

start_cron_worker() {
  local task_id="$1"
  local log_file

  log_file="$(bridge_cron_worker_log_file "$task_id")"
  mkdir -p "$(dirname "$log_file")"

  if [[ "$(uname -s)" != "Darwin" ]] && command -v setsid >/dev/null 2>&1; then
    setsid "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" run-cron-worker "$task_id" </dev/null >>"$log_file" 2>&1 &
  else
    nohup "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" run-cron-worker "$task_id" </dev/null >>"$log_file" 2>&1 &
    disown || true
  fi
}

start_cron_dispatch_workers() {
  local max_parallel="${BRIDGE_CRON_DISPATCH_MAX_PARALLEL:-0}"
  local running_count
  local ready_rows=""
  local task_id
  local agent
  local _priority
  local _title
  local _body_path
  local started=0

  [[ "$max_parallel" =~ ^[0-9]+$ ]] || max_parallel=0
  (( max_parallel > 0 )) || return 0

  running_count="$(cron_worker_running_count)"
  (( running_count < max_parallel )) || return 0

  ready_rows="$(bridge_queue_cli cron-ready --limit "$max_parallel" --format tsv 2>/dev/null || true)"
  [[ -n "$ready_rows" ]] || return 0

  while IFS=$'\t' read -r task_id agent _priority _title _body_path; do
    [[ -n "$task_id" && -n "$agent" ]] || continue
    (( running_count < max_parallel )) || break

    if ! bridge_queue_cli claim "$task_id" --agent "$agent" --lease-seconds "$BRIDGE_CRON_DISPATCH_LEASE_SECONDS" >/dev/null 2>&1; then
      continue
    fi

    if start_cron_worker "$task_id"; then
      echo "[info] started cron worker for task #${task_id} (${agent})"
      running_count=$((running_count + 1))
      started=1
      continue
    fi

    bridge_warn "failed to start cron worker for task #${task_id}"
    bridge_queue_cli handoff "$task_id" --to "$agent" --from daemon --note "failed to start cron worker" >/dev/null 2>&1 || true
  done <<<"$ready_rows"

  return "$started"
}

cmd_run_cron_worker() {
  local task_id="${1:-}"
  local pid_file=""
  local run_id=""
  local done_note_file=""
  local followup_body_file=""
  local followup_task_id=""
  local followup_title=""
  local followup_title_prefix=""
  local existing_followup_id=""
  local create_output=""
  local followup_priority="normal"
  local followup_actor=""
  local subagent_status=0
  local TASK_ID=""
  local TASK_TITLE=""
  local TASK_STATUS=""
  local TASK_ASSIGNED_TO=""
  local TASK_CREATED_BY=""
  local TASK_PRIORITY=""
  local TASK_CLAIMED_BY=""
  local TASK_BODY_PATH=""
  local CRON_RUN_ID=""
  local CRON_JOB_ID=""
  local CRON_JOB_NAME=""
  local CRON_FAMILY=""
  local CRON_SLOT=""
  local CRON_TARGET_AGENT=""
  local CRON_TARGET_ENGINE=""
  local CRON_RESULT_STATUS=""
  local CRON_RESULT_SUMMARY=""
  local CRON_RUN_STATE=""
  local CRON_RESULT_FILE=""
  local CRON_STATUS_FILE=""
  local CRON_STDOUT_LOG=""
  local CRON_STDERR_LOG=""
  local CRON_PROMPT_FILE=""
  local CRON_NEEDS_HUMAN_FOLLOWUP=""

  [[ "$task_id" =~ ^[0-9]+$ ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-daemon.sh run-cron-worker <task-id>"

  pid_file="$(bridge_cron_worker_pid_file "$task_id")"
  mkdir -p "$(dirname "$pid_file")"
  echo "$$" >"$pid_file"
  trap "rm -f '$pid_file'" EXIT

  # shellcheck disable=SC1090
  source <(bridge_queue_cli show "$task_id" --format shell)

  if [[ -z "$TASK_ASSIGNED_TO" ]]; then
    bridge_warn "cron worker task #${task_id} missing assigned agent"
    return 1
  fi

  if [[ -z "$TASK_BODY_PATH" ]]; then
    run_id="task-${task_id}"
    done_note_file="$(bridge_cron_dispatch_completion_note_file_by_id "$run_id")"
    mkdir -p "$(dirname "$done_note_file")"
    {
      printf '# Cron Dispatch Result\n\n'
      printf -- '- task_id: %s\n' "$task_id"
      printf -- '- state: invalid_task\n'
      printf -- '- reason: missing body_path\n'
    } >"$done_note_file"
    bridge_queue_cli done "$task_id" --agent "$TASK_ASSIGNED_TO" --note-file "$done_note_file" >/dev/null 2>&1 || true
    return 0
  fi

  run_id="$(bridge_cron_run_id_from_body_path "$TASK_BODY_PATH")"
  # shellcheck disable=SC1090
  source <(bridge_cron_load_run_shell "$run_id")

  if [[ "$CRON_RUN_STATE" != "success" || ! -f "$CRON_RESULT_FILE" ]]; then
    if "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-cron.sh" run-subagent "$run_id" >/dev/null 2>&1; then
      subagent_status=0
    else
      subagent_status=$?
    fi
    # shellcheck disable=SC1090
    source <(bridge_cron_load_run_shell "$run_id")
  fi

  if [[ "$CRON_RUN_STATE" != "success" || "$CRON_RESULT_STATUS" == "error" || $subagent_status -ne 0 ]]; then
    CRON_NEEDS_HUMAN_FOLLOWUP="1"
    followup_priority="high"
  fi

  # Trust the subagent's needs_human_followup decision.
  # The alwaysFollowup override was creating noise tasks for no-op results
  # (e.g. "after hours, skipped"). Subagents already set the flag correctly.

  if [[ "$CRON_NEEDS_HUMAN_FOLLOWUP" == "1" ]]; then
    followup_body_file="$(bridge_cron_dispatch_followup_file_by_id "$run_id")"
    bridge_cron_write_followup_body "$run_id" "$followup_body_file"
    followup_actor="cron:${CRON_JOB_NAME:-$run_id}"
    followup_title="[cron-followup] ${CRON_JOB_NAME:-$run_id} (${CRON_SLOT:-$run_id})"
    followup_title_prefix="[cron-followup] ${CRON_JOB_NAME:-$run_id} ("
    existing_followup_id="$(bridge_queue_cli find-open --agent "$TASK_ASSIGNED_TO" --title-prefix "$followup_title_prefix" 2>/dev/null || true)"
    if [[ "$existing_followup_id" =~ ^[0-9]+$ ]]; then
      bridge_queue_cli update "$existing_followup_id" --actor "$followup_actor" --title "$followup_title" --priority "$followup_priority" --body-file "$followup_body_file" >/dev/null 2>&1 || true
      followup_task_id="$existing_followup_id"
      echo "[info] refreshed cron followup task #${followup_task_id} for ${CRON_JOB_NAME:-$run_id}"
    else
      create_output="$(bridge_queue_cli create --to "$TASK_ASSIGNED_TO" --title "$followup_title" --from "$followup_actor" --priority "$followup_priority" --body-file "$followup_body_file" 2>/dev/null || true)"
      if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
        followup_task_id="${BASH_REMATCH[1]}"
      fi
    fi
  fi

  done_note_file="$(bridge_cron_dispatch_completion_note_file_by_id "$run_id")"
  bridge_cron_write_completion_note "$run_id" "$done_note_file" "$followup_task_id"
  bridge_queue_cli done "$task_id" --agent "$TASK_ASSIGNED_TO" --note-file "$done_note_file" >/dev/null
  echo "[info] completed cron worker task #${task_id} run_id=${run_id} state=${CRON_RUN_STATE:-unknown} followup=${followup_task_id:-0}"
}

process_on_demand_agents() {
  local summary_output="$1"
  local agent
  local queued
  local claimed
  local blocked
  local active
  local idle
  local _last_seen
  local _last_nudge
  local session
  local _engine
  local _workdir
  local timeout
  local always_on=0
  local changed=1
  local live_summary=""
  local live_agent=""
  local live_queued=0
  local live_claimed=0
  local live_blocked=0

  while IFS=$'\t' read -r agent queued claimed blocked active idle _last_seen _last_nudge session _engine _workdir; do
    [[ -z "$agent" ]] && continue
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    always_on=0
    if bridge_agent_is_always_on "$agent"; then
      always_on=1
    fi

    if [[ "$active" == "0" ]]; then
      if ((( always_on == 1 ))) && ! bridge_agent_is_active "$agent"; then
        if "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" >/dev/null 2>&1; then
          echo "[info] ensured always-on ${agent}"
          changed=0
        else
          bridge_warn "always-on auto-start failed: ${agent}"
        fi
      elif [[ "$queued" =~ ^[0-9]+$ ]] && (( queued > 0 )) && ! bridge_agent_is_active "$agent"; then
        if "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" >/dev/null 2>&1; then
          session="$(bridge_agent_session "$agent")"
          timeout="$(bridge_agent_idle_timeout "$agent")"
          [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=0
          if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
            nudge_agent_session "$agent" "$session" "$queued" "$claimed" "0" || true
          fi
          echo "[info] auto-started ${agent} (queued=${queued}, timeout=${timeout}s)"
          changed=0
        else
          bridge_warn "on-demand auto-start failed: ${agent}"
        fi
      fi
      continue
    fi

    timeout="$(bridge_agent_idle_timeout "$agent")"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=0
    (( timeout > 0 )) || continue

    if ! [[ "$queued" =~ ^[0-9]+$ && "$claimed" =~ ^[0-9]+$ && "$blocked" =~ ^[0-9]+$ && "$idle" =~ ^[0-9]+$ ]]; then
      continue
    fi
    (( queued == 0 && claimed == 0 && blocked == 0 )) || continue
    (( idle >= timeout )) || continue
    bridge_agent_is_active "$agent" || continue

    live_summary="$(bridge_queue_cli summary --agent "$agent" --format tsv 2>/dev/null | head -n 1 || true)"
    if [[ -n "$live_summary" ]]; then
      IFS=$'\t' read -r live_agent live_queued live_claimed live_blocked _live_active _live_idle _live_last_seen _live_last_nudge _live_session _live_engine _live_workdir <<<"$live_summary"
      if [[ "$live_agent" == "$agent" ]]; then
        if ! [[ "$live_queued" =~ ^[0-9]+$ ]]; then live_queued=0; fi
        if ! [[ "$live_claimed" =~ ^[0-9]+$ ]]; then live_claimed=0; fi
        if ! [[ "$live_blocked" =~ ^[0-9]+$ ]]; then live_blocked=0; fi
        (( live_queued == 0 && live_claimed == 0 && live_blocked == 0 )) || continue
      fi
    fi

    if bridge_kill_agent_session "$agent" >/dev/null 2>&1; then
      echo "[info] auto-stopped ${agent} (idle=${idle}s, timeout=${timeout}s)"
      changed=0
    else
      bridge_warn "on-demand auto-stop failed: ${agent}"
    fi
  done <<<"$summary_output"

  return "$changed"
}

cmd_sync_cycle() {
  local snapshot_file
  local ready_agents_file
  local nudge_output=""
  local summary_output=""
  local agent
  local session
  local queued
  local claimed
  local idle
  local nudge_key
  local changed=1
  local cron_sync_timeout="${BRIDGE_CRON_SYNC_TIMEOUT:-30}"
  local timeout_bin=""

  # Discord relay runs FIRST — lowest-latency path for DM wake
  bridge_discord_relay_step || true

  "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-sync.sh" >/dev/null 2>&1 || true
  bridge_reconcile_idle_markers || true
  recover_claude_bootstrap_blockers || true
  process_channel_health || true

  snapshot_file="$(mktemp)"
  ready_agents_file="$(mktemp)"
  bridge_write_agent_snapshot "$snapshot_file"
  bridge_write_idle_ready_agents "$ready_agents_file"
  nudge_output="$(bridge_task_daemon_step "$snapshot_file" "$ready_agents_file" 2>/dev/null || true)"
  rm -f "$snapshot_file"
  rm -f "$ready_agents_file"

  start_cron_dispatch_workers || true

  while IFS=$'\t' read -r agent session queued claimed idle nudge_key; do
    [[ -z "$agent" || -z "$session" ]] && continue
    if ! bridge_tmux_session_exists "$session"; then
      continue
    fi

    if nudge_agent_session "$agent" "$session" "$queued" "$claimed" "$idle" "$nudge_key"; then
      continue
    fi
    case "$?" in
      2)
        continue
        ;;
    esac
  done <<<"$nudge_output"

  summary_output="$(bridge_queue_cli summary --format tsv 2>/dev/null || true)"
  if [[ -n "$summary_output" ]] && process_on_demand_agents "$summary_output"; then
    changed=0
  fi
  if [[ "$changed" == "0" ]]; then
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-sync.sh" >/dev/null 2>&1 || true
  fi

  # Cron sync runs LAST, in the background with a timeout, so it never blocks
  # relay/auto-start above.  Only one sync runs at a time (PID-file guard).
  if [[ "${BRIDGE_CRON_SYNC_ENABLED:-${BRIDGE_OPENCLAW_CRON_SYNC_ENABLED:-0}}" == "1" ]]; then
    local cron_sync_pid_file="$BRIDGE_STATE_DIR/cron-sync.pid"
    local cron_sync_running=0
    if [[ -f "$cron_sync_pid_file" ]]; then
      local prev_pid
      prev_pid="$(<"$cron_sync_pid_file")"
      if [[ -n "$prev_pid" ]] && kill -0 "$prev_pid" 2>/dev/null; then
        cron_sync_running=1
      else
        rm -f "$cron_sync_pid_file"
      fi
    fi
    if (( cron_sync_running == 0 )); then
      timeout_bin="$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)"
      (
        if [[ -n "$timeout_bin" ]]; then
          "$timeout_bin" "$cron_sync_timeout" "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-cron.sh" sync >/dev/null 2>&1
        else
          "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-cron.sh" sync >/dev/null 2>&1
        fi
        rm -f "$cron_sync_pid_file"
      ) &
      echo "$!" >"$cron_sync_pid_file"
    fi
  fi

  bridge_dashboard_post_if_changed "$summary_output" || true
}

cmd_start() {
  local start_deadline

  if bridge_daemon_is_running; then
    echo "[info] bridge daemon already running (pid=$(bridge_daemon_pid))"
    return 0
  fi

  mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"
  if [[ "$(uname -s)" != "Darwin" ]] && command -v setsid >/dev/null 2>&1; then
    setsid "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" run </dev/null >>"$BRIDGE_DAEMON_LOG" 2>&1 &
  else
    nohup "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" run </dev/null >>"$BRIDGE_DAEMON_LOG" 2>&1 &
    disown || true
  fi

  start_deadline=$(( $(date +%s) + BRIDGE_DAEMON_START_WAIT_SECONDS ))
  while (( $(date +%s) <= start_deadline )); do
    if bridge_daemon_is_running; then
      echo "[info] bridge daemon started (pid=$(bridge_daemon_pid))"
      return 0
    fi
    sleep 0.1
  done

  bridge_die "bridge daemon start failed"
}

cmd_run() {
  local cycle_status

  trap 'daemon_log_event "received SIGTERM"; exit 0' TERM
  trap 'daemon_log_event "received SIGINT"; exit 0' INT
  trap 'daemon_log_event "received SIGHUP"; exit 0' HUP
  trap 'status=$?; rm -f "$BRIDGE_DAEMON_PID_FILE"; if (( status != 0 )); then daemon_log_event "daemon exiting with status=$status"; fi' EXIT
  echo "$$" >"$BRIDGE_DAEMON_PID_FILE"

  while true; do
    if cmd_sync_cycle; then
      :
    else
      cycle_status=$?
      daemon_log_event "sync cycle failed with exit=$cycle_status"
    fi
    sleep "$BRIDGE_DAEMON_INTERVAL"
  done
}

cmd_stop() {
  local pid
  local recorded_pid

  pid="$(bridge_daemon_pid)"
  recorded_pid="$(bridge_daemon_recorded_pid)"
  if [[ -z "$pid" ]]; then
    if [[ -n "$recorded_pid" ]]; then
      rm -f "$BRIDGE_DAEMON_PID_FILE"
      echo "[info] stale bridge daemon pid removed"
      return 0
    fi
    echo "[info] bridge daemon not running"
    return 0
  fi

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    rm -f "$BRIDGE_DAEMON_PID_FILE"
    echo "[info] bridge daemon stopped"
    return 0
  fi

  rm -f "$BRIDGE_DAEMON_PID_FILE"
  echo "[info] stale bridge daemon pid removed"
}

cmd_status() {
  if bridge_daemon_is_running; then
    echo "running pid=$(bridge_daemon_pid) interval=${BRIDGE_DAEMON_INTERVAL}s db=${BRIDGE_TASK_DB}"
  else
    echo "stopped"
  fi
}

CMD="${1:-}"
case "$CMD" in
  start)
    cmd_start
    ;;
  ensure)
    cmd_start
    ;;
  run)
    cmd_run
    ;;
  run-cron-worker)
    shift || true
    cmd_run_cron_worker "$@"
    ;;
  stop)
    cmd_stop
    ;;
  status)
    cmd_status
    ;;
  sync)
    cmd_sync_cycle
    ;;
  *)
    usage
    exit 1
    ;;
esac
