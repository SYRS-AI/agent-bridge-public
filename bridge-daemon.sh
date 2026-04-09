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

daemon_info() {
  local message="$1"
  printf '[%s] [info] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$message"
}

bridge_agent_heartbeat_file() {
  local agent="$1"
  local workdir=""

  workdir="$(bridge_agent_workdir "$agent")"
  [[ -n "$workdir" ]] || return 1
  printf '%s/HEARTBEAT.md' "$workdir"
}

bridge_agent_heartbeat_state_file() {
  local agent="$1"
  printf '%s/heartbeat/%s.env' "$BRIDGE_STATE_DIR" "$agent"
}

bridge_agent_heartbeat_activity_state() {
  local agent="$1"
  local session=""
  local engine=""

  if ! bridge_agent_is_active "$agent"; then
    printf '%s' "stopped"
    return 0
  fi

  session="$(bridge_agent_session "$agent")"
  engine="$(bridge_agent_engine "$agent")"
  if bridge_tmux_session_has_prompt "$session" "$engine"; then
    printf '%s' "idle"
    return 0
  fi

  printf '%s' "working"
}

bridge_agent_heartbeat_due() {
  local agent="$1"
  local interval="${BRIDGE_HEARTBEAT_INTERVAL_SECONDS:-300}"
  local file=""
  local next_ts=0
  local now=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=300
  (( interval > 0 )) || return 0
  file="$(bridge_agent_heartbeat_state_file "$agent")"
  [[ -f "$file" ]] || return 0
  # shellcheck source=/dev/null
  source "$file"
  [[ "${HEARTBEAT_NEXT_TS:-0}" =~ ^[0-9]+$ ]] || return 0
  next_ts="${HEARTBEAT_NEXT_TS:-0}"
  now="$(date +%s)"
  (( now >= next_ts ))
}

bridge_note_agent_heartbeat() {
  local agent="$1"
  local interval="${BRIDGE_HEARTBEAT_INTERVAL_SECONDS:-300}"
  local file=""
  local now=0
  local next_ts=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=300
  (( interval > 0 )) || interval=300
  file="$(bridge_agent_heartbeat_state_file "$agent")"
  mkdir -p "$(dirname "$file")"
  now="$(date +%s)"
  next_ts=$(( now + interval ))
  cat >"$file" <<EOF
HEARTBEAT_UPDATED_TS=$now
HEARTBEAT_NEXT_TS=$next_ts
EOF
}

write_agent_heartbeat() {
  local agent="$1"
  local heartbeat_file=""
  local state="stopped"
  local summary=""
  local queued=0
  local claimed=0
  local blocked=0
  local active="no"
  local idle="-"
  local last_seen="-"
  local last_nudge="-"
  local session=""
  local workdir=""
  local temp_file=""

  heartbeat_file="$(bridge_agent_heartbeat_file "$agent")" || return 0
  workdir="$(bridge_agent_workdir "$agent")"
  [[ -d "$workdir" ]] || return 0
  mkdir -p "$(dirname "$heartbeat_file")"

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi
  state="$(bridge_agent_heartbeat_activity_state "$agent")"
  summary="$(bridge_queue_cli summary --agent "$agent" --format tsv 2>/dev/null | head -n 1 || true)"
  if [[ -n "$summary" ]]; then
    IFS=$'\t' read -r _agent queued claimed blocked _active idle last_seen last_nudge _session _engine _workdir <<<"$summary"
  fi

  temp_file="$(mktemp)"
  cat >"$temp_file" <<EOF
# Heartbeat

- generated_at: $(bridge_now_iso)
- agent: ${agent}
- description: $(bridge_agent_desc "$agent")
- engine: $(bridge_agent_engine "$agent")
- source: $(bridge_agent_source "$agent")
- session: ${session:--}
- workdir: ${workdir:--}
- active: ${active}
- activity_state: ${state}
- always_on: $(bridge_agent_is_always_on "$agent" && printf 'yes' || printf 'no')
- wake_status: $(bridge_agent_wake_status "$agent")
- notify_status: $(bridge_agent_notify_status "$agent")
- channel_status: $(bridge_agent_channel_status "$agent")

## Queue

- queued: ${queued}
- claimed: ${claimed}
- blocked: ${blocked}

## Runtime

- idle_seconds: ${idle}
- last_seen: ${last_seen}
- last_nudge: ${last_nudge}
EOF

  if [[ -f "$heartbeat_file" ]] && cmp -s "$temp_file" "$heartbeat_file"; then
    rm -f "$temp_file"
  else
    mv "$temp_file" "$heartbeat_file"
  fi
  bridge_note_agent_heartbeat "$agent"
}

refresh_agent_heartbeats() {
  local agent
  local changed=1

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    if ! bridge_agent_heartbeat_due "$agent"; then
      continue
    fi
    write_agent_heartbeat "$agent"
    changed=0
  done

  return "$changed"
}

bridge_watchdog_state_file() {
  printf '%s/watchdog.env' "$BRIDGE_STATE_DIR"
}

bridge_watchdog_report_file() {
  printf '%s/watchdog/latest.md' "$BRIDGE_SHARED_DIR"
}

bridge_watchdog_problem_key() {
  local report_json="$1"
  python3 - "$report_json" <<'PY'
import hashlib
import json
import sys

raw = sys.argv[1]
try:
    payload = json.loads(raw)
except Exception:
    print(hashlib.sha256(raw.encode("utf-8")).hexdigest() if raw else "")
    raise SystemExit(0)

canonical = json.dumps(
    payload.get("agents", []),
    sort_keys=True,
    separators=(",", ":"),
)
print(hashlib.sha256(canonical.encode("utf-8")).hexdigest() if canonical else "")
PY
}

bridge_watchdog_due() {
  local interval="${BRIDGE_WATCHDOG_INTERVAL_SECONDS:-1800}"
  local file=""
  local now=0
  local next_ts=0

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=1800
  (( interval > 0 )) || return 0
  file="$(bridge_watchdog_state_file)"
  [[ -f "$file" ]] || return 0
  # shellcheck source=/dev/null
  source "$file"
  [[ "${WATCHDOG_NEXT_TS:-0}" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  next_ts="${WATCHDOG_NEXT_TS:-0}"
  (( now >= next_ts ))
}

bridge_note_watchdog_scan() {
  local interval="${BRIDGE_WATCHDOG_INTERVAL_SECONDS:-1800}"
  local file=""
  local now=0
  local next_ts=0
  local last_key="${1:-}"
  local last_report_ts="${2:-0}"

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=1800
  (( interval > 0 )) || interval=1800
  file="$(bridge_watchdog_state_file)"
  mkdir -p "$(dirname "$file")"
  now="$(date +%s)"
  next_ts=$(( now + interval ))
  cat >"$file" <<EOF
WATCHDOG_UPDATED_TS=$now
WATCHDOG_NEXT_TS=$next_ts
WATCHDOG_LAST_KEY=$(printf '%q' "$last_key")
WATCHDOG_LAST_REPORT_TS=$(printf '%q' "$last_report_ts")
EOF
}

process_watchdog_report() {
  local admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  local title_prefix="[watchdog] "
  local title="[watchdog] agent profile drift"
  local report_file=""
  local report_json=""
  local problem_count=0
  local existing_id=""
  local current_key=""
  local last_key=""
  local last_report_ts=0
  local cooldown=0
  local now_ts=0
  local reported=0

  [[ "${BRIDGE_WATCHDOG_ENABLED:-1}" == "1" ]] || return 1
  [[ -n "$admin_agent" ]] || return 1
  bridge_agent_exists "$admin_agent" || return 1
  bridge_watchdog_due || return 1

  report_file="$(bridge_watchdog_report_file)"
  mkdir -p "$(dirname "$report_file")"
  if ! "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-watchdog.sh" scan >"$report_file"; then
    return 1
  fi
  if ! report_json="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-watchdog.sh" scan --json 2>/dev/null)"; then
    return 1
  fi
  problem_count="$(python3 - "$report_json" <<'PY'
import json, sys
try:
    payload = json.loads(sys.argv[1])
    print(int(payload.get("problem_count", 0)))
except Exception:
    print(0)
PY
)"
  [[ "$problem_count" =~ ^[0-9]+$ ]] || problem_count=0
  current_key="$(bridge_watchdog_problem_key "$report_json")"
  cooldown="${BRIDGE_WATCHDOG_COOLDOWN_SECONDS:-86400}"
  [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=86400
  now_ts="$(date +%s)"
  if [[ -f "$(bridge_watchdog_state_file)" ]]; then
    # shellcheck source=/dev/null
    source "$(bridge_watchdog_state_file)"
    last_key="${WATCHDOG_LAST_KEY:-}"
    last_report_ts="${WATCHDOG_LAST_REPORT_TS:-0}"
  fi
  [[ "$last_report_ts" =~ ^[0-9]+$ ]] || last_report_ts=0
  if (( problem_count == 0 )); then
    bridge_note_watchdog_scan "" 0
    return 1
  fi

  existing_id="$(bridge_queue_cli find-open --agent "$admin_agent" --title-prefix "$title_prefix" 2>/dev/null || true)"
  if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
    if [[ "$current_key" != "$last_key" ]]; then
      bridge_queue_cli update "$existing_id" --actor "daemon" --title "$title" --priority high --body-file "$report_file" >/dev/null 2>&1 && reported=1
    fi
  elif [[ "$current_key" != "$last_key" || $(( now_ts - last_report_ts )) -ge "$cooldown" ]]; then
    bridge_queue_cli create --to "$admin_agent" --from "daemon" --priority high --title "$title" --body-file "$report_file" >/dev/null 2>&1 && reported=1
  fi

  if (( reported == 1 )); then
    bridge_audit_log daemon watchdog_report "$admin_agent" \
      --detail agent="$admin_agent" \
      --detail problem_count="$problem_count" \
      --detail report_file="$report_file"
    bridge_note_watchdog_scan "$current_key" "$now_ts"
    daemon_info "watchdog reported ${problem_count} agent profile issue(s)"
    return 0
  fi

  bridge_note_watchdog_scan "$last_key" "$last_report_ts"
  return 1
}

bridge_daemon_autostart_state_file() {
  local agent="$1"
  printf '%s/daemon-autostart/%s.env' "$BRIDGE_STATE_DIR" "$agent"
}

bridge_daemon_autostart_allowed() {
  local agent="$1"
  local file=""
  local next_retry_ts=0
  local now=0

  file="$(bridge_daemon_autostart_state_file "$agent")"
  [[ -f "$file" ]] || return 0
  # shellcheck source=/dev/null
  source "$file"
  [[ "${AUTO_START_NEXT_RETRY_TS:-0}" =~ ^[0-9]+$ ]] || return 0
  next_retry_ts="${AUTO_START_NEXT_RETRY_TS:-0}"
  now="$(date +%s)"
  (( now >= next_retry_ts ))
}

bridge_daemon_note_autostart_failure() {
  local agent="$1"
  local reason="$2"
  local file=""
  local fail_count=0
  local next_retry_ts=0
  local delay=5
  local now=0

  file="$(bridge_daemon_autostart_state_file "$agent")"
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]]; then
    # shellcheck source=/dev/null
    source "$file"
  fi
  AUTO_START_FAIL_COUNT="${AUTO_START_FAIL_COUNT:-0}"
  [[ "$AUTO_START_FAIL_COUNT" =~ ^[0-9]+$ ]] || AUTO_START_FAIL_COUNT=0
  fail_count=$(( AUTO_START_FAIL_COUNT + 1 ))
  now="$(date +%s)"
  if (( fail_count >= 10 )); then
    delay=300
  elif (( fail_count >= 5 )); then
    delay=60
  elif (( fail_count >= 3 )); then
    delay=30
  fi
  next_retry_ts=$(( now + delay ))
  cat >"$file" <<EOF
AUTO_START_FAIL_COUNT=$fail_count
AUTO_START_NEXT_RETRY_TS=$next_retry_ts
AUTO_START_LAST_REASON=$(printf '%q' "$reason")
EOF
  daemon_info "auto-start backoff ${agent} (failures=${fail_count}, retry_in=${delay}s, reason=${reason})"
}

bridge_daemon_clear_autostart_failure() {
  local agent="$1"
  rm -f "$(bridge_daemon_autostart_state_file "$agent")"
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
  daemon_info "nudged ${agent} (queued=${queued}, claimed=${claimed}, idle=${idle}s)"
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
          daemon_info "advanced claude startup blocker for ${agent} (${state})"
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
    bridge_audit_log daemon channel_health_report "$agent" \
      --detail admin_agent="$admin_agent" \
      --detail mode=refresh \
      --detail body_file="$body_file" \
      --detail reason="$reason"
  elif [[ "$key" != "$last_key" || $(( now_ts - last_report_ts )) -ge ${BRIDGE_CHANNEL_HEALTH_REPORT_COOLDOWN_SECONDS:-1800} ]]; then
    create_output="$(bridge_queue_cli create --to "$admin_agent" --title "$title" --from daemon --priority urgent --body-file "$body_file" 2>/dev/null || true)"
    if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
      bridge_audit_log daemon channel_health_report "$agent" \
        --detail admin_agent="$admin_agent" \
        --detail mode=create \
        --detail task_id="${BASH_REMATCH[1]}" \
        --detail body_file="$body_file" \
        --detail reason="$reason"
      daemon_info "reported channel-health miss for ${agent} -> ${admin_agent} (#${BASH_REMATCH[1]})"
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

process_memory_daily_refresh_requests() {
  local agent
  local session
  local summary=""
  local live_agent=""
  local queued=0
  local claimed=0
  local blocked=0
  local attached=0
  local changed=1

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    bridge_agent_memory_daily_refresh_enabled "$agent" || continue
    bridge_agent_memory_daily_refresh_pending "$agent" || continue

    if ! bridge_agent_is_active "$agent"; then
      bridge_agent_clear_memory_daily_refresh "$agent"
      daemon_info "cleared pending memory-daily refresh for inactive ${agent}"
      changed=0
      continue
    fi

    session="$(bridge_agent_session "$agent")"
    [[ -n "$session" ]] || continue

    summary="$(bridge_queue_cli summary --agent "$agent" --format tsv 2>/dev/null | head -n 1 || true)"
    if [[ -n "$summary" ]]; then
      IFS=$'\t' read -r live_agent queued claimed blocked _live_active _live_idle _live_last_seen _live_last_nudge _live_session _live_engine _live_workdir <<<"$summary"
      [[ "$queued" =~ ^[0-9]+$ ]] || queued=0
      [[ "$claimed" =~ ^[0-9]+$ ]] || claimed=0
      [[ "$blocked" =~ ^[0-9]+$ ]] || blocked=0
      if [[ "$live_agent" != "$agent" ]]; then
        queued=0
        claimed=0
        blocked=0
      fi
    else
      queued=0
      claimed=0
      blocked=0
    fi

    if (( claimed > 0 || blocked > 0 )); then
      continue
    fi

    attached="$(bridge_tmux_session_attached_count "$session")"
    [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
    (( attached == 0 )) || continue

    if bridge_tmux_send_and_submit "$session" "claude" "/new" >/dev/null 2>&1; then
      bridge_agent_clear_memory_daily_refresh "$agent"
      bridge_audit_log daemon session_refresh_sent "$agent" \
        --detail session="$session" \
        --detail source=memory-daily
      daemon_info "refreshed ${agent} after memory-daily"
      changed=0
    fi
  done

  return "$changed"
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

cron_ready_rows_with_retry() {
  local limit="$1"
  local status_snapshot="${2:-}"
  local attempts="${BRIDGE_QUEUE_RETRY_ATTEMPTS:-5}"
  local delay="${BRIDGE_QUEUE_RETRY_DELAY_SECONDS:-0.2}"
  local defer_seconds="${BRIDGE_MEMORY_DAILY_MAX_DEFER_SECONDS:-10800}"
  local output=""
  local status=0
  local try
  local args=()

  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=5
  (( attempts > 0 )) || attempts=1
  [[ "$defer_seconds" =~ ^[0-9]+$ ]] || defer_seconds=10800
  args=(cron-ready --limit "$limit" --format tsv --memory-daily-defer-seconds "$defer_seconds")
  if [[ -n "$status_snapshot" ]]; then
    args+=(--status-snapshot "$status_snapshot")
  fi

  for try in $(seq 1 "$attempts"); do
    if output="$(bridge_queue_cli "${args[@]}" 2>/dev/null)"; then
      printf '%s' "$output"
      return 0
    fi
    status=$?
    sleep "$delay"
  done

  return "$status"
}

claim_cron_task_with_retry() {
  local task_id="$1"
  local agent="$2"
  local lease_seconds="$3"
  local attempts="${BRIDGE_QUEUE_RETRY_ATTEMPTS:-5}"
  local delay="${BRIDGE_QUEUE_RETRY_DELAY_SECONDS:-0.2}"
  local try

  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=5
  (( attempts > 0 )) || attempts=1

  for try in $(seq 1 "$attempts"); do
    if bridge_queue_cli claim "$task_id" --agent "$agent" --lease-seconds "$lease_seconds" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

start_cron_worker() {
  local task_id="$1"
  local log_file

  log_file="$(bridge_cron_worker_log_file "$task_id")"
  mkdir -p "$(dirname "$log_file")"
  bridge_require_python
  python3 - "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" "$task_id" "$log_file" <<'PY' >/dev/null
import os
import subprocess
import sys

bash_bin, daemon_script, task_id, log_file = sys.argv[1:]

with open(os.devnull, "rb") as stdin_handle, open(log_file, "ab", buffering=0) as log_handle:
    subprocess.Popen(
        [bash_bin, daemon_script, "run-cron-worker", task_id],
        stdin=stdin_handle,
        stdout=log_handle,
        stderr=log_handle,
        start_new_session=True,
        close_fds=True,
    )
PY
}

start_cron_dispatch_workers() {
  local max_parallel="${BRIDGE_CRON_DISPATCH_MAX_PARALLEL:-0}"
  local running_count
  local ready_rows=""
  local status_snapshot_file=""
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

  status_snapshot_file="$(mktemp)"
  bridge_write_roster_status_snapshot "$status_snapshot_file"
  ready_rows="$(cron_ready_rows_with_retry "$max_parallel" "$status_snapshot_file" || true)"
  rm -f "$status_snapshot_file"
  [[ -n "$ready_rows" ]] || return 0

  while IFS=$'\t' read -r task_id agent _priority _title _body_path; do
    [[ -n "$task_id" && -n "$agent" ]] || continue
    (( running_count < max_parallel )) || break

    if ! claim_cron_task_with_retry "$task_id" "$agent" "$BRIDGE_CRON_DISPATCH_LEASE_SECONDS"; then
      continue
    fi

    if start_cron_worker "$task_id"; then
      daemon_info "started cron worker for task #${task_id} (${agent})"
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
      daemon_info "refreshed cron followup task #${followup_task_id} for ${CRON_JOB_NAME:-$run_id}"
    else
      create_output="$(bridge_queue_cli create --to "$TASK_ASSIGNED_TO" --title "$followup_title" --from "$followup_actor" --priority "$followup_priority" --body-file "$followup_body_file" 2>/dev/null || true)"
      if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
        followup_task_id="${BASH_REMATCH[1]}"
      fi
    fi
  fi

  "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-cron.sh" finalize-run "$run_id" >/dev/null 2>&1 || true

  if [[ "${CRON_FAMILY:-}" == "memory-daily" && "${CRON_RUN_STATE:-}" == "success" && "${CRON_RESULT_STATUS:-}" != "error" ]]; then
    if bridge_agent_memory_daily_refresh_enabled "$TASK_ASSIGNED_TO"; then
      bridge_agent_note_memory_daily_refresh "$TASK_ASSIGNED_TO" "$run_id" "${CRON_SLOT:-}"
      bridge_audit_log daemon session_refresh_queued "$TASK_ASSIGNED_TO" \
        --detail run_id="$run_id" \
        --detail slot="${CRON_SLOT:-}" \
        --detail source=memory-daily
      daemon_info "queued memory-daily session refresh for ${TASK_ASSIGNED_TO} run_id=${run_id}"
    fi
  fi

  done_note_file="$(bridge_cron_dispatch_completion_note_file_by_id "$run_id")"
  bridge_cron_write_completion_note "$run_id" "$done_note_file" "$followup_task_id"
  bridge_queue_cli done "$task_id" --agent "$TASK_ASSIGNED_TO" --note-file "$done_note_file" >/dev/null
  bridge_audit_log daemon cron_worker_complete "$TASK_ASSIGNED_TO" \
    --detail run_id="$run_id" \
    --detail task_id="$task_id" \
    --detail state="${CRON_RUN_STATE:-unknown}" \
    --detail followup_task_id="${followup_task_id:-0}" \
    --detail job_name="${CRON_JOB_NAME:-$run_id}" \
    --detail slot="${CRON_SLOT:-}"
  daemon_info "completed cron worker task #${task_id} run_id=${run_id} state=${CRON_RUN_STATE:-unknown} followup=${followup_task_id:-0}"
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
    bridge_agent_exists "$agent" || continue
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    if bridge_agent_manual_stop_active "$agent"; then
      continue
    fi
    always_on=0
    if bridge_agent_is_always_on "$agent"; then
      always_on=1
    fi
    if [[ "$active" == "1" ]]; then
      bridge_daemon_clear_autostart_failure "$agent"
    fi

    if [[ "$active" == "0" ]]; then
      if ! bridge_daemon_autostart_allowed "$agent"; then
        continue
      fi
      if ((( always_on == 1 ))) && ! bridge_agent_is_active "$agent"; then
        if "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" >/dev/null 2>&1; then
          session="$(bridge_agent_session "$agent")"
          sleep 1
          if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
            bridge_daemon_clear_autostart_failure "$agent"
            daemon_info "ensured always-on ${agent}"
            changed=0
          else
            bridge_daemon_note_autostart_failure "$agent" "session-exited-quickly"
          fi
        else
          bridge_daemon_note_autostart_failure "$agent" "start-command-failed"
          bridge_warn "always-on auto-start failed: ${agent}"
        fi
      elif [[ "$queued" =~ ^[0-9]+$ ]] && (( queued > 0 )) && ! bridge_agent_is_active "$agent"; then
        if "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" >/dev/null 2>&1; then
          session="$(bridge_agent_session "$agent")"
          timeout="$(bridge_agent_idle_timeout "$agent")"
          [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=0
          sleep 1
          if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
            bridge_daemon_clear_autostart_failure "$agent"
            nudge_agent_session "$agent" "$session" "$queued" "$claimed" "0" || true
            daemon_info "auto-started ${agent} (queued=${queued}, timeout=${timeout}s)"
            changed=0
          else
            bridge_daemon_note_autostart_failure "$agent" "session-exited-quickly"
          fi
        else
          bridge_daemon_note_autostart_failure "$agent" "start-command-failed"
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
      daemon_info "auto-stopped ${agent} (idle=${idle}s, timeout=${timeout}s)"
      changed=0
    else
      bridge_warn "on-demand auto-stop failed: ${agent}"
    fi
  done <<<"$summary_output"

  return "$changed"
}

session_is_registered_agent_session() {
  local session="$1"
  local agent
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$(bridge_agent_session "$agent")" == "$session" ]]; then
      return 0
    fi
  done
  return 1
}

session_matches_idle_reap_patterns() {
  local session="$1"
  case "$session" in
    bridge-smoke-*|bridge-requester-*|auto-start-session-*|always-on-session-*|static-session-*|claude-static-bridge-smoke-*|worker-reuse-*|late-dynamic-agent-*|created-session-*|bootstrap-session-*|bootstrap-wrapper-session-*|broken-channel-*|codex-cli-session-*|project-claude-session-bridge-smoke-*|memtest*|bootstrap-fail*|memphase4-*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

reap_idle_dynamic_agents() {
  local threshold="${BRIDGE_DYNAMIC_IDLE_REAP_SECONDS:-3600}"
  local agent
  local session
  local attached
  local idle
  local summary
  local live_agent=""
  local queued=0
  local claimed=0
  local blocked=0
  local changed=1

  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3600
  (( threshold > 0 )) || return 0

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_source "$agent")" == "dynamic" ]] || continue
    session="$(bridge_agent_session "$agent")"
    [[ -n "$session" ]] || continue
    bridge_tmux_session_exists "$session" || continue

    attached="$(bridge_tmux_session_attached_count "$session")"
    [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
    (( attached == 0 )) || continue

    summary="$(bridge_queue_cli summary --agent "$agent" --format tsv 2>/dev/null | head -n 1 || true)"
    if [[ -n "$summary" ]]; then
      IFS=$'\t' read -r live_agent queued claimed blocked _live_active _live_idle _live_last_seen _live_last_nudge _live_session _live_engine _live_workdir <<<"$summary"
      [[ "$queued" =~ ^[0-9]+$ ]] || queued=0
      [[ "$claimed" =~ ^[0-9]+$ ]] || claimed=0
      [[ "$blocked" =~ ^[0-9]+$ ]] || blocked=0
      if [[ "$live_agent" != "$agent" ]]; then
        queued=0
        claimed=0
        blocked=0
      fi
    else
      queued=0
      claimed=0
      blocked=0
    fi
    (( queued == 0 && claimed == 0 && blocked == 0 )) || continue

    idle="$(bridge_tmux_session_idle_seconds "$session")"
    [[ "$idle" =~ ^[0-9]+$ ]] || idle=0
    (( idle >= threshold )) || continue

    if bridge_kill_agent_session "$agent" >/dev/null 2>&1; then
      bridge_archive_dynamic_agent "$agent"
      bridge_remove_dynamic_agent_file "$agent"
      daemon_info "reaped dynamic ${agent} (idle=${idle}s)"
      changed=0
    fi
  done

  return "$changed"
}

reap_idle_orphan_sessions() {
  local threshold="${BRIDGE_ORPHAN_SESSION_REAP_SECONDS:-600}"
  local session
  local attached
  local idle
  local changed=1

  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=600
  (( threshold > 0 )) || return 0

  while IFS= read -r session; do
    [[ -n "$session" ]] || continue
    session_is_registered_agent_session "$session" && continue
    session_matches_idle_reap_patterns "$session" || continue

    attached="$(bridge_tmux_session_attached_count "$session")"
    [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
    (( attached == 0 )) || continue

    idle="$(bridge_tmux_session_idle_seconds "$session")"
    [[ "$idle" =~ ^[0-9]+$ ]] || idle=0
    (( idle >= threshold )) || continue

    if tmux kill-session -t "$session" >/dev/null 2>&1; then
      daemon_info "reaped orphan session ${session} (idle=${idle}s)"
      changed=0
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

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

  # The daemon is long-lived, so dynamic agents created after startup will not
  # exist in memory unless we reload the roster each cycle.
  bridge_load_roster

  # Discord relay runs FIRST — lowest-latency path for DM wake
  bridge_discord_relay_step || true

  "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-sync.sh" >/dev/null 2>&1 || true
  bridge_load_roster
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
  if process_memory_daily_refresh_requests; then
    changed=0
  fi
  if refresh_agent_heartbeats; then
    changed=0
  fi
  if process_watchdog_report; then
    changed=0
  fi
  if [[ -n "$summary_output" ]] && process_on_demand_agents "$summary_output"; then
    changed=0
  fi
  if reap_idle_dynamic_agents; then
    changed=0
  fi
  if reap_idle_orphan_sessions; then
    changed=0
  fi
  if [[ "$changed" == "0" ]]; then
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-sync.sh" >/dev/null 2>&1 || true
  fi

  # Cron sync runs LAST, in the background with a timeout, so it never blocks
  # relay/auto-start above.  Only one sync runs at a time (PID-file guard).
  if [[ "${BRIDGE_CRON_SYNC_ENABLED:-${BRIDGE_LEGACY_CRON_SYNC_ENABLED:-${BRIDGE_OPENCLAW_CRON_SYNC_ENABLED:-0}}}" == "1" ]]; then
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
    daemon_info "bridge daemon already running (pid=$(bridge_daemon_pid))"
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
      daemon_info "bridge daemon started (pid=$(bridge_daemon_pid))"
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
      daemon_info "stale bridge daemon pid removed"
      return 0
    fi
    daemon_info "bridge daemon not running"
    return 0
  fi

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    rm -f "$BRIDGE_DAEMON_PID_FILE"
  daemon_info "bridge daemon stopped"
    return 0
  fi

  rm -f "$BRIDGE_DAEMON_PID_FILE"
  daemon_info "stale bridge daemon pid removed"
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
