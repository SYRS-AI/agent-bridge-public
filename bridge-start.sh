#!/usr/bin/env bash
# bridge-start.sh — roster 기반 tmux 세션 시작기

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-start.sh <agent> [--replace] [--attach] [--continue|--no-continue] [--dry-run] [--skip-project-skill]"
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
INSTALL_PROJECT_SKILL=1
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
    --skip-project-skill)
      INSTALL_PROJECT_SKILL=0
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
bridge_agent_clear_manual_stop "$AGENT"

SESSION="$(bridge_agent_session "$AGENT")"
WORK_DIR="$(bridge_agent_workdir "$AGENT")"
DEFAULT_WORK_DIR="$(bridge_agent_default_home "$AGENT")"
ENGINE="$(bridge_agent_engine "$AGENT")"
RUNNER="$SCRIPT_DIR/bridge-run.sh"
ENV_PREFIX="$(bridge_export_env_prefix)"
EFFECTIVE_CONTINUE_MODE="$(bridge_agent_continue "$AGENT")"
FORCE_FRESH_SESSION=0
SUPPRESS_MISSING_CHANNELS=0
CHANNEL_REASON=""

if [[ ! -d "$WORK_DIR" ]]; then
  if [[ "$WORK_DIR" == "$DEFAULT_WORK_DIR" ]]; then
    mkdir -p "$WORK_DIR"
  else
    bridge_die "workdir가 없습니다: $WORK_DIR"
  fi
fi

if bridge_tmux_session_exists "$SESSION"; then
  if [[ $REPLACE -eq 1 ]]; then
    bridge_tmux_kill_session "$SESSION"
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
  if bridge_project_claude_guidance_needed "$WORK_DIR"; then
    FORCE_FRESH_SESSION=1
  fi
  if [[ $INSTALL_PROJECT_SKILL -eq 1 ]]; then
    bridge_ensure_project_claude_guidance "$WORK_DIR" >/dev/null 2>&1 || true
  fi
  if ! bridge_project_skill_bootstrap_needed "$ENGINE" "$WORK_DIR"; then
    FORCE_FRESH_SESSION=1
  fi
  if ! bridge_claude_stop_hook_status "$WORK_DIR" >/dev/null 2>&1; then
    FORCE_FRESH_SESSION=1
  fi
  if ! bridge_claude_session_start_hook_status "$WORK_DIR" >/dev/null 2>&1; then
    FORCE_FRESH_SESSION=1
  fi
  if ! bridge_claude_prompt_hook_status "$WORK_DIR" >/dev/null 2>&1; then
    FORCE_FRESH_SESSION=1
  fi
  if [[ $INSTALL_PROJECT_SKILL -eq 1 ]]; then
    if ! bridge_bootstrap_project_skill "$ENGINE" "$WORK_DIR"; then
      bridge_warn "Claude bridge skill bootstrap skipped or conflicted: $WORK_DIR"
    fi
  fi
  bridge_bootstrap_claude_shared_skills "$AGENT" "$WORK_DIR" || true
  if ! bridge_ensure_claude_project_trust "$WORK_DIR" >/dev/null 2>&1; then
    bridge_warn "Claude project trust seed failed: $WORK_DIR"
  fi
  if ! bridge_ensure_claude_stop_hook "$WORK_DIR" >/dev/null; then
    bridge_die "Claude Stop hook 설정에 실패했습니다: $WORK_DIR"
  fi
  if ! bridge_ensure_claude_session_start_hook "$WORK_DIR" >/dev/null; then
    bridge_die "Claude SessionStart hook 설정에 실패했습니다: $WORK_DIR"
  fi
  if ! bridge_ensure_claude_prompt_hook "$WORK_DIR" >/dev/null; then
    bridge_die "Claude UserPromptSubmit hook 설정에 실패했습니다: $WORK_DIR"
  fi
  if ! bridge_disable_claude_webhook_channel "$AGENT" "$WORK_DIR" >/dev/null 2>&1; then
    bridge_warn "Claude backlog webhook channel cleanup skipped: $WORK_DIR"
  fi
elif [[ "$ENGINE" == "codex" ]]; then
  if ! bridge_project_skill_bootstrap_needed "$ENGINE" "$WORK_DIR"; then
    FORCE_FRESH_SESSION=1
  fi
  if [[ $INSTALL_PROJECT_SKILL -eq 1 ]]; then
    if ! bridge_bootstrap_project_skill "$ENGINE" "$WORK_DIR"; then
      bridge_warn "Codex bridge skill bootstrap skipped or conflicted: $WORK_DIR"
    fi
  fi
  if ! bridge_ensure_codex_hooks >/dev/null; then
    bridge_die "Codex hook 설정에 실패했습니다: $WORK_DIR"
  fi
fi

if [[ $FORCE_FRESH_SESSION -eq 1 ]]; then
  if [[ $CONTINUE_EXPLICIT -eq 1 && "$CONTINUE_MODE" == "1" ]]; then
    bridge_warn "Bridge project setup changed or was missing. Forcing a fresh session so CLAUDE.md, skills, and hooks are loaded."
  fi
  EFFECTIVE_CONTINUE_MODE=0
elif [[ $CONTINUE_EXPLICIT -eq 1 ]]; then
  EFFECTIVE_CONTINUE_MODE="$CONTINUE_MODE"
fi

if [[ "$ENGINE" == "claude" ]]; then
  CHANNEL_REASON="$(bridge_agent_channel_status_reason "$AGENT")"
  if [[ -n "$CHANNEL_REASON" ]]; then
    if bridge_agent_should_stop_on_attached_clean_exit "$AGENT"; then
      SUPPRESS_MISSING_CHANNELS=1
      bridge_warn "Channel runtime is incomplete for pending admin '$AGENT'. Starting without missing channel plugins until onboarding completes: $CHANNEL_REASON"
    elif [[ $DRY_RUN -eq 0 ]]; then
      bridge_die "$(bridge_agent_channel_setup_guidance "$AGENT" "$CHANNEL_REASON")"
    fi
  fi
fi

SESSION_CMD="$(bridge_join_quoted "$BRIDGE_BASH_BIN" "$RUNNER" "$AGENT")"
if [[ "$EFFECTIVE_CONTINUE_MODE" == "1" ]]; then
  SESSION_CMD+=" --continue"
else
  SESSION_CMD+=" --no-continue"
fi
if [[ "$(bridge_agent_loop "$AGENT")" != "1" ]]; then
  SESSION_CMD+=" --once"
fi
if [[ -n "$ENV_PREFIX" ]]; then
  SESSION_CMD="${ENV_PREFIX} ${SESSION_CMD}"
fi
if [[ $SUPPRESS_MISSING_CHANNELS -eq 1 ]]; then
  SESSION_CMD="BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1 ${SESSION_CMD}"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  if [[ $SUPPRESS_MISSING_CHANNELS -eq 1 ]]; then
    launch_channels="$(BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1 bridge_agent_launch_channels_csv "$AGENT")"
  else
    launch_channels="$(bridge_agent_launch_channels_csv "$AGENT")"
  fi
  echo "agent=$AGENT"
  echo "session=$SESSION"
  echo "workdir=$WORK_DIR"
  echo "continue=$EFFECTIVE_CONTINUE_MODE"
  echo "channels=$(bridge_agent_channels_csv "$AGENT")"
  echo "launch_channels=$launch_channels"
  echo "channel_status=$(bridge_agent_channel_status "$AGENT")"
  if [[ -n "$CHANNEL_REASON" ]]; then
    echo "channel_reason=$CHANNEL_REASON"
  fi
  echo "tmux_command=$SESSION_CMD"
  exit 0
fi

if [[ "$ENGINE" == "claude" ]]; then
  if [[ $SUPPRESS_MISSING_CHANNELS -eq 1 ]]; then
    BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1 bridge_ensure_claude_launch_channel_plugins "$AGENT"
  else
    bridge_ensure_claude_launch_channel_plugins "$AGENT"
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
  bridge_tmux_prepare_claude_session "$SESSION" 8 >/dev/null 2>&1 || true
  bridge_agent_mark_idle_now "$AGENT"
fi
if [[ -z "$(bridge_agent_session_id "$AGENT")" ]]; then
  bridge_refresh_agent_session_id "$AGENT" 12 0.25 >/dev/null 2>&1 || true
fi
echo "[info] 세션 '$SESSION' 시작 완료"

if [[ $ATTACH -eq 1 ]]; then
  bridge_attach_tmux_session "$SESSION"
fi
