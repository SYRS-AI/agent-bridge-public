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

nudge_agent_session() {
  local agent="$1"
  local session="$2"
  local queued="$3"
  local claimed="$4"
  local idle="$5"
  local nudge_key="${6:-}"
  local message
  local engine

  message="[Agent Bridge] inbox에 대기 중인 task가 ${queued}건 있습니다. 현재 작업 경계에서 `agb inbox ${agent}` 또는 `${BRIDGE_HOME}/agent-bridge inbox ${agent}` 로 확인하고 필요한 task를 claim하세요."
  engine="$(bridge_agent_engine "$agent")"
  bridge_tmux_send_and_submit "$session" "$engine" "$message" || return 1
  bridge_task_note_nudge "$agent" "$nudge_key" || true
  echo "[info] nudged ${agent} (queued=${queued}, claimed=${claimed}, idle=${idle}s)"
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
  local changed=1

  while IFS=$'\t' read -r agent queued claimed blocked active idle _last_seen _last_nudge session _engine _workdir; do
    [[ -z "$agent" ]] && continue
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    timeout="$(bridge_agent_idle_timeout "$agent")"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=0
    (( timeout > 0 )) || continue

    if [[ "$active" == "0" ]]; then
      if [[ "$queued" =~ ^[0-9]+$ ]] && (( queued > 0 )) && ! bridge_agent_is_active "$agent"; then
        if "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" >/dev/null 2>&1; then
          session="$(bridge_agent_session "$agent")"
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

    if ! [[ "$queued" =~ ^[0-9]+$ && "$claimed" =~ ^[0-9]+$ && "$blocked" =~ ^[0-9]+$ && "$idle" =~ ^[0-9]+$ ]]; then
      continue
    fi
    (( queued == 0 && claimed == 0 && blocked == 0 )) || continue
    (( idle >= timeout )) || continue
    bridge_agent_is_active "$agent" || continue

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
  local nudge_output=""
  local summary_output=""
  local agent
  local session
  local queued
  local claimed
  local idle
  local nudge_key
  local changed=1

  "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-sync.sh" >/dev/null 2>&1 || true

  snapshot_file="$(mktemp)"
  bridge_write_agent_snapshot "$snapshot_file"
  nudge_output="$(bridge_task_daemon_step "$snapshot_file" 2>/dev/null || true)"
  rm -f "$snapshot_file"

  while IFS=$'\t' read -r agent session queued claimed idle nudge_key; do
    [[ -z "$agent" || -z "$session" ]] && continue
    if ! bridge_tmux_session_exists "$session"; then
      continue
    fi

    nudge_agent_session "$agent" "$session" "$queued" "$claimed" "$idle" "$nudge_key" || true
  done <<<"$nudge_output"

  bridge_discord_relay_step || true

  summary_output="$(bridge_queue_cli summary --format tsv 2>/dev/null || true)"
  if [[ -n "$summary_output" ]] && process_on_demand_agents "$summary_output"; then
    changed=0
  fi
  if [[ "$changed" == "0" ]]; then
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-sync.sh" >/dev/null 2>&1 || true
  fi
}

cmd_start() {
  if bridge_daemon_is_running; then
    echo "[info] bridge daemon already running (pid=$(bridge_daemon_pid))"
    return 0
  fi

  mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"
  if command -v setsid >/dev/null 2>&1; then
    setsid "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" run </dev/null >>"$BRIDGE_DAEMON_LOG" 2>&1 &
  else
    nohup "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" run </dev/null >>"$BRIDGE_DAEMON_LOG" 2>&1 &
    disown || true
  fi
  sleep 0.2

  if bridge_daemon_is_running; then
    echo "[info] bridge daemon started (pid=$(bridge_daemon_pid))"
    return 0
  fi

  bridge_die "bridge daemon start failed"
}

cmd_run() {
  trap 'rm -f "$BRIDGE_DAEMON_PID_FILE"' EXIT
  echo "$$" >"$BRIDGE_DAEMON_PID_FILE"

  while true; do
    cmd_sync_cycle
    sleep "$BRIDGE_DAEMON_INTERVAL"
  done
}

cmd_stop() {
  local pid

  pid="$(bridge_daemon_pid)"
  if [[ -z "$pid" ]]; then
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
