#!/usr/bin/env bash
# bridge-run.sh — roster 기반 에이전트 실행기

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-run.sh <agent> [--once] [--continue|--no-continue] [--dry-run]"
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

WORK_DIR="$(bridge_agent_workdir "$AGENT")"
LAUNCH_CMD="$(bridge_agent_launch_cmd "$AGENT")"
ENGINE="$(bridge_agent_engine "$AGENT")"

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
  echo "channels=$(bridge_agent_channels_csv "$AGENT")"
  echo "channel_status=$(bridge_agent_channel_status "$AGENT")"
  echo "launch=$LAUNCH_CMD"
  exit 0
fi

export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/usr/local/bin:$PATH"
export BRIDGE_AGENT_ID="$AGENT"
export BRIDGE_AGENT_INJECT_TIMESTAMP="$(bridge_agent_inject_timestamp "$AGENT")"

mkdir -p "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR"
cd "$WORK_DIR" || bridge_die "$WORK_DIR 디렉토리가 없습니다."

LOGFILE="$BRIDGE_LOG_DIR/${AGENT}-$(date '+%Y%m%d').log"
ERRFILE="$BRIDGE_LOG_DIR/${AGENT}-$(date '+%Y%m%d').err.log"

log_line() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$line" | tee -a "$LOGFILE"
}

log_line "${AGENT} 에이전트 시작 (engine=${ENGINE}, dir=${WORK_DIR})"

FAIL_COUNT=0
while true; do
  local_err_size_before=0
  local_err_size_after=0
  log_line "실행: ${LAUNCH_CMD}"
  if [[ -f "$ERRFILE" ]]; then
    local_err_size_before="$(wc -c <"$ERRFILE" 2>/dev/null || echo 0)"
  fi
  if "$BRIDGE_BASH_BIN" -lc "$LAUNCH_CMD" 2> >(tee -a "$ERRFILE" >&2); then
    EXIT_CODE=0
  else
    EXIT_CODE=$?
  fi
  if [[ -f "$ERRFILE" ]]; then
    local_err_size_after="$(wc -c <"$ERRFILE" 2>/dev/null || echo 0)"
  fi

  if [[ $ONCE -eq 1 ]]; then
    if [[ $local_err_size_after -gt $local_err_size_before ]]; then
      log_line "stderr captured: ${ERRFILE}"
    fi
    log_line "1회 실행 종료 (코드: ${EXIT_CODE})"
    exit "$EXIT_CODE"
  fi

  if [[ $EXIT_CODE -ne 0 ]]; then
    if [[ $local_err_size_after -gt $local_err_size_before ]]; then
      log_line "stderr captured: ${ERRFILE}"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [[ $FAIL_COUNT -eq 5 || $(( FAIL_COUNT % 10 )) -eq 0 ]]; then
      bridge_agent_write_crash_report "$AGENT" "$ENGINE" "$FAIL_COUNT" "$EXIT_CODE" "$ERRFILE" "$LAUNCH_CMD"
      bridge_audit_log daemon crash_loop_detected "$AGENT" \
        --detail engine="$ENGINE" \
        --detail fail_count="$FAIL_COUNT" \
        --detail exit_code="$EXIT_CODE" \
        --detail stderr_file="$ERRFILE"
    fi
    log_line "비정상 종료 (코드: ${EXIT_CODE}, 연속실패: ${FAIL_COUNT}회). 5초 후 재시작..."
    if [[ $FAIL_COUNT -ge 10 ]]; then
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
    log_line "정상 종료. 5초 후 재시작..."
    sleep 5
  fi
done
