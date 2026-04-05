#!/usr/bin/env bash
# bridge-start.sh — roster 기반 tmux 세션 시작기

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-start.sh <agent> [--replace] [--attach] [--continue|--no-continue] [--dry-run]"
  echo "       bash $SCRIPT_DIR/bridge-start.sh --list"
  echo ""
  echo "등록된 에이전트:"
  bridge_list_agents
}

LIST_ONLY=0
REPLACE=0
ATTACH=0
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
    --replace)
      REPLACE=1
      shift
      ;;
    --attach)
      ATTACH=1
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

SESSION="$(bridge_agent_session "$AGENT")"
WORK_DIR="$(bridge_agent_workdir "$AGENT")"
DEFAULT_WORK_DIR="$(bridge_agent_default_home "$AGENT")"
ENGINE="$(bridge_agent_engine "$AGENT")"
RUNNER="$SCRIPT_DIR/bridge-run.sh"
ENV_PREFIX="$(bridge_export_env_prefix)"
SESSION_CMD="$(bridge_join_quoted "$BRIDGE_BASH_BIN" "$RUNNER" "$AGENT")"
if [[ "$(bridge_agent_loop "$AGENT")" != "1" ]]; then
  SESSION_CMD+=" --once"
fi
if [[ -n "$ENV_PREFIX" ]]; then
  SESSION_CMD="${ENV_PREFIX} ${SESSION_CMD}"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "agent=$AGENT"
  echo "session=$SESSION"
  echo "workdir=$WORK_DIR"
  echo "continue=$(bridge_agent_continue "$AGENT")"
  echo "tmux_command=$SESSION_CMD"
  exit 0
fi

if [[ ! -d "$WORK_DIR" ]]; then
  if [[ "$WORK_DIR" == "$DEFAULT_WORK_DIR" ]]; then
    mkdir -p "$WORK_DIR"
  else
    bridge_die "workdir가 없습니다: $WORK_DIR"
  fi
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  if [[ $REPLACE -eq 1 ]]; then
    tmux kill-session -t "$SESSION"
    echo "[info] 기존 세션 '$SESSION' 제거"
  else
    echo "[info] 세션 '$SESSION'이 이미 실행 중입니다."
    if [[ $ATTACH -eq 1 ]]; then
      bridge_attach_tmux_session "$SESSION"
    fi
    exit 0
  fi
fi

if [[ "$ENGINE" == "claude" ]]; then
  if ! bridge_ensure_claude_stop_hook "$WORK_DIR" >/dev/null; then
    bridge_die "Claude Stop hook 설정에 실패했습니다: $WORK_DIR"
  fi
  if ! bridge_ensure_claude_prompt_hook "$WORK_DIR" >/dev/null; then
    bridge_die "Claude UserPromptSubmit hook 설정에 실패했습니다: $WORK_DIR"
  fi
  if ! bridge_disable_claude_webhook_channel "$AGENT" "$WORK_DIR" >/dev/null 2>&1; then
    bridge_warn "Claude backlog webhook channel cleanup skipped: $WORK_DIR"
  fi
fi

bridge_agent_clear_idle_marker "$AGENT"

# Refresh the launch window so a new session id can be detected for this run.
# shellcheck disable=SC2034
BRIDGE_AGENT_CREATED_AT["$AGENT"]="$(date +%s)"
bridge_persist_agent_state "$AGENT"

tmux new-session -d -s "$SESSION" -c "$WORK_DIR" "$SESSION_CMD"
bridge_tmux_bootstrap_session_options "$SESSION"
if [[ "$ENGINE" == "claude" ]]; then
  bridge_agent_mark_idle_now "$AGENT"
fi
if [[ -z "$(bridge_agent_session_id "$AGENT")" ]]; then
  bridge_refresh_agent_session_id "$AGENT" 12 0.25 >/dev/null 2>&1 || true
fi
echo "[info] 세션 '$SESSION' 시작 완료"

if [[ $ATTACH -eq 1 ]]; then
  bridge_attach_tmux_session "$SESSION"
fi
