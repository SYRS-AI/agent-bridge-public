#!/usr/bin/env bash
# bridge-send.sh — roster 기반 tmux 에이전트 메시지 전송

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-send.sh --urgent <agent> \"<message>\" [--wait <seconds>]"
  echo "       bash $SCRIPT_DIR/bridge-send.sh --list"
  echo "활성 로스터: $BRIDGE_ACTIVE_ROSTER_MD"
  echo ""
  echo "일반 작업 전달은 task queue를 사용하세요:"
  echo "  $BRIDGE_HOME/agent-bridge task create --to tester --title \"재테스트\" --body-file $BRIDGE_SHARED_DIR/report.md"
  echo ""
  echo "등록된 에이전트:"
  bridge_list_agents
}

LIST_ONLY=0
URGENT_ONLY=0
TARGET=""
MESSAGE=""
WAIT_SECONDS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --urgent)
      URGENT_ONLY=1
      shift
      ;;
    --wait)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then
        bridge_die "--wait 뒤에 숫자(초)를 지정하세요. 예: --wait 30"
      fi
      WAIT_SECONDS="$2"
      shift 2
      ;;
    -*)
      bridge_die "알 수 없는 옵션: $1"
      ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      elif [[ -z "$MESSAGE" ]]; then
        MESSAGE="$1"
      else
        bridge_die "메시지는 하나의 인자로 감싸서 전달하세요."
      fi
      shift
      ;;
  esac
done

if [[ $LIST_ONLY -eq 1 ]]; then
  bridge_list_agents
  exit 0
fi

if [[ -z "$TARGET" || -z "$MESSAGE" ]]; then
  usage
  exit 1
fi

if [[ $URGENT_ONLY -ne 1 ]]; then
  bridge_die "직접 메시지는 --urgent일 때만 허용합니다. 일반 작업은 'agent-bridge task create'를 사용하세요."
fi

bridge_require_agent "$TARGET"

MSG_LEN=${#MESSAGE}
if [[ $MSG_LEN -gt $BRIDGE_MAX_MESSAGE_LEN ]]; then
  bridge_warn "메시지가 ${MSG_LEN}자입니다. 길면 $BRIDGE_SHARED_DIR 아래 파일에 저장하고 경로만 전달하세요."
fi

SESSION="$(bridge_agent_session "$TARGET")"
ENGINE="$(bridge_agent_engine "$TARGET")"
bridge_require_tmux_session "$SESSION"

mkdir -p "$BRIDGE_LOG_DIR"
TIMESTAMP="$(date '+%H:%M:%S')"
LOGFILE="$BRIDGE_LOG_DIR/bridge-$(date '+%Y%m%d').log"
SAFE_MSG="$(bridge_sanitize_text "$MESSAGE")"
OUTBOUND_MESSAGE="[AGENT BRIDGE URGENT] $MESSAGE"

echo "[${TIMESTAMP}] !URGENT ${TARGET}/${SESSION}: ${SAFE_MSG}" >> "$LOGFILE"

bridge_tmux_send_and_submit "$SESSION" "$ENGINE" "$OUTBOUND_MESSAGE"

echo -e "${GREEN}[${TIMESTAMP}] !URGENT ${TARGET}: 전송 완료 (${MSG_LEN}자)${NC}"

if [[ $WAIT_SECONDS -gt 0 ]]; then
  bridge_info "[대기] ${WAIT_SECONDS}초 후 응답 캡처..."
  sleep "$WAIT_SECONDS"
  bridge_info "--- ${TARGET} 세션 최근 출력 (마지막 30줄) ---"
  bridge_capture_recent "$SESSION" 30
  bridge_info "--- 캡처 끝 ---"
fi
