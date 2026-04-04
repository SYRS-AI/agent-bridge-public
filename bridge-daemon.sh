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

cmd_sync_cycle() {
  local snapshot_file
  local nudge_output=""
  local agent
  local session
  local queued
  local claimed
  local idle
  local message

  bash "$SCRIPT_DIR/bridge-sync.sh" >/dev/null 2>&1 || true

  snapshot_file="$(mktemp)"
  bridge_write_agent_snapshot "$snapshot_file"
  nudge_output="$(bridge_task_daemon_step "$snapshot_file" 2>/dev/null || true)"
  rm -f "$snapshot_file"

  while IFS=$'\t' read -r agent session queued claimed idle; do
    [[ -z "$agent" || -z "$session" ]] && continue
    if ! bridge_tmux_session_exists "$session"; then
      continue
    fi

    message="[Agent Bridge] inbox에 대기 중인 task가 ${queued}건 있습니다. 현재 작업 경계에서 ${BRIDGE_HOME}/ab inbox ${agent} 로 확인하고 필요한 task를 claim하세요."
    bridge_tmux_paste_and_submit "$session" "$message" || true
    bridge_task_note_nudge "$agent" || true
    echo "[info] nudged ${agent} (queued=${queued}, claimed=${claimed}, idle=${idle}s)"
  done <<<"$nudge_output"
}

cmd_start() {
  if bridge_daemon_is_running; then
    echo "[info] bridge daemon already running (pid=$(bridge_daemon_pid))"
    return 0
  fi

  mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$SCRIPT_DIR/bridge-daemon.sh" run </dev/null >>"$BRIDGE_DAEMON_LOG" 2>&1 &
  else
    nohup bash "$SCRIPT_DIR/bridge-daemon.sh" run </dev/null >>"$BRIDGE_DAEMON_LOG" 2>&1 &
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
