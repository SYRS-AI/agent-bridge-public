#!/bin/bash
# bridge-action.sh — roster 기반 에이전트 액션 전송

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-action.sh <agent> <action> [--wait <seconds>] [--dry-run]"
  echo "       bash $SCRIPT_DIR/bridge-action.sh --list [agent]"
  echo ""
  echo "등록된 에이전트:"
  bridge_list_agents
}

LIST_ONLY=0
DRY_RUN=0
TARGET=""
ACTION=""
WAIT_SECONDS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --wait)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then
        bridge_die "--wait 뒤에 숫자(초)를 지정하세요. 예: --wait 30"
      fi
      WAIT_SECONDS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -*)
      bridge_die "알 수 없는 옵션: $1"
      ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      elif [[ -z "$ACTION" ]]; then
        ACTION="$1"
      else
        bridge_die "위치 인자가 너무 많습니다."
      fi
      shift
      ;;
  esac
done

if [[ $LIST_ONLY -eq 1 ]]; then
  if [[ -n "$TARGET" ]]; then
    bridge_require_agent "$TARGET"
    echo "지원 액션 ($TARGET):"
    bridge_list_actions "$TARGET" || true
  else
    usage
  fi
  exit 0
fi

if [[ -z "$TARGET" || -z "$ACTION" ]]; then
  usage
  exit 1
fi

bridge_require_agent "$TARGET"
ACTION_TEXT="$(bridge_agent_action "$TARGET" "$ACTION")"
if [[ -z "$ACTION_TEXT" ]]; then
  echo "지원 액션 ($TARGET):"
  bridge_list_actions "$TARGET" || true
  bridge_die "'$TARGET' 에이전트는 '$ACTION' 액션을 지원하지 않습니다."
fi

SESSION="$(bridge_agent_session "$TARGET")"
ENGINE="$(bridge_agent_engine "$TARGET")"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "agent=$TARGET"
  echo "session=$SESSION"
  echo "action=$ACTION"
  echo "payload=$ACTION_TEXT"
  exit 0
fi

bridge_require_tmux_session "$SESSION"

mkdir -p "$BRIDGE_LOG_DIR"
TIMESTAMP="$(date '+%H:%M:%S')"
LOGFILE="$BRIDGE_LOG_DIR/bridge-$(date '+%Y%m%d').log"
echo "[${TIMESTAMP}] ↺ ${TARGET}/${SESSION}: $(bridge_sanitize_text "$ACTION_TEXT")" >> "$LOGFILE"

bridge_tmux_send_and_submit "$SESSION" "$ENGINE" "$ACTION_TEXT"

echo -e "${GREEN}[${TIMESTAMP}] ↺ ${TARGET}: ${ACTION} 전송 완료${NC}"

if [[ $WAIT_SECONDS -gt 0 ]]; then
  bridge_info "[대기] ${WAIT_SECONDS}초 후 응답 캡처..."
  sleep "$WAIT_SECONDS"
  bridge_info "--- ${TARGET} 세션 최근 출력 (마지막 30줄) ---"
  bridge_capture_recent "$SESSION" 30
  bridge_info "--- 캡처 끝 ---"
fi
