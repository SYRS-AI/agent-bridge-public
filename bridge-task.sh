#!/usr/bin/env bash
# bridge-task.sh — SQLite-backed task queue operations

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-task.sh create --to <agent> --title <title> [--body <text> | --body-file <path>] [--from <agent>] [--priority low|normal|high|urgent]
  bash $SCRIPT_DIR/bridge-task.sh inbox [agent] [--all]
  bash $SCRIPT_DIR/bridge-task.sh show <task-id>
  bash $SCRIPT_DIR/bridge-task.sh claim <task-id> [--agent <agent>] [--lease <seconds>]
  bash $SCRIPT_DIR/bridge-task.sh done <task-id> [--agent <agent>] [--note <text> | --note-file <path>]
  bash $SCRIPT_DIR/bridge-task.sh cancel <task-id> [--actor <name>] [--note <text> | --note-file <path>]
  bash $SCRIPT_DIR/bridge-task.sh update <task-id> [--status queued|claimed|blocked] [--priority ...] [--title ...] [--note ...]
  bash $SCRIPT_DIR/bridge-task.sh handoff <task-id> --to <agent> [--from <agent>] [--note <text> | --note-file <path>]
  bash $SCRIPT_DIR/bridge-task.sh summary [agent...]
EOF
}

infer_actor_if_possible() {
  local actor="${1:-}"

  if [[ -n "$actor" ]]; then
    printf '%s' "$actor"
    return 0
  fi

  if actor="$(bridge_infer_current_agent 2>/dev/null)"; then
    printf '%s' "$actor"
    return 0
  fi

  printf '%s' "${USER:-unknown}"
}

emit_inferred_actor_hint() {
  local explicit_actor="${1:-}"
  local inferred_actor="${2:-}"

  [[ -z "$explicit_actor" ]] || return 0
  [[ -n "$inferred_actor" ]] || return 0

  echo "[hint] --from omitted; inferred sender: ${inferred_actor}. Use --from <agent> to override." >&2
}

notify_task_requester() {
  local task_id="$1"
  local actor="$2"
  local note="$3"
  local note_file="$4"
  local TASK_ID=""
  local TASK_TITLE=""
  local TASK_CREATED_BY=""
  local TASK_PRIORITY=""
  local creator
  local creator_engine=""
  local completion_title=""
  local completion_body=""
  local notice_message=""
  local ORIG_TASK_ID=""
  local ORIG_TASK_TITLE=""
  local ORIG_TASK_PRIORITY=""

  # shellcheck disable=SC1090
  source <(bridge_queue_cli show "$task_id" --format shell)

  creator="$TASK_CREATED_BY"
  [[ -n "$creator" ]] || return 0
  [[ "$creator" != "$actor" ]] || return 0
  bridge_agent_exists "$creator" || return 0
  [[ "$TASK_TITLE" == \[task-complete\]* ]] && return 0
  creator_engine="$(bridge_agent_engine "$creator")"

  ORIG_TASK_ID="$TASK_ID"
  ORIG_TASK_TITLE="$TASK_TITLE"
  ORIG_TASK_PRIORITY="$TASK_PRIORITY"
  completion_title="[task-complete] ${ORIG_TASK_TITLE}"
  completion_body="completed_by: ${actor}"
  completion_body+=$'\n'"original_task: #${ORIG_TASK_ID}"
  completion_body+=$'\n'"inspect: agb show ${ORIG_TASK_ID}"
  if [[ -n "$note" ]]; then
    completion_body+=$'\n\n'"completion_note:"$'\n'"${note}"
  elif [[ -n "$note_file" ]]; then
    completion_body+=$'\n'"completion_note_file: ${note_file}"
  fi

  TASK_ID=""
  TASK_TITLE=""
  TASK_PRIORITY=""
  # shellcheck disable=SC1090
  source <(bridge_queue_cli create --to "$creator" --title "$completion_title" --from bridge --priority "$ORIG_TASK_PRIORITY" --body "$completion_body" --format shell)

  if [[ "$creator_engine" != "claude" ]] && ! bridge_agent_is_active "$creator"; then
    return 0
  fi

  notice_message="agb inbox ${creator}"
  bridge_dispatch_notification "$creator" "$TASK_TITLE" "$notice_message" "$TASK_ID" "$TASK_PRIORITY" || true
}

cmd_create() {
  local target=""
  local title=""
  local actor=""
  local explicit_actor=""
  local priority="normal"
  local body=""
  local body_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        [[ $# -lt 2 ]] && bridge_die "--to 뒤에 agent를 지정하세요."
        target="$2"
        shift 2
        ;;
      --title)
        [[ $# -lt 2 ]] && bridge_die "--title 뒤에 제목을 지정하세요."
        title="$2"
        shift 2
        ;;
      --from)
        [[ $# -lt 2 ]] && bridge_die "--from 뒤에 actor를 지정하세요."
        actor="$2"
        shift 2
        ;;
      --priority)
        [[ $# -lt 2 ]] && bridge_die "--priority 뒤에 값을 지정하세요."
        priority="$2"
        shift 2
        ;;
      --body)
        [[ $# -lt 2 ]] && bridge_die "--body 뒤에 본문을 지정하세요."
        body="$2"
        shift 2
        ;;
      --body-file)
        [[ $# -lt 2 ]] && bridge_die "--body-file 뒤에 파일 경로를 지정하세요."
        body_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "알 수 없는 옵션: $1"
        ;;
    esac
  done

  [[ -z "$target" ]] && bridge_die "--to는 필수입니다."
  [[ -z "$title" ]] && bridge_die "--title은 필수입니다."
  bridge_require_agent "$target"
  explicit_actor="$actor"
  actor="$(infer_actor_if_possible "$actor")"
  emit_inferred_actor_hint "$explicit_actor" "$actor"

  args=(create --to "$target" --title "$title" --from "$actor" --priority "$priority")
  if [[ -n "$body" ]]; then
    args+=(--body "$body")
  fi
  if [[ -n "$body_file" ]]; then
    args+=(--body-file "$body_file")
  fi

  bridge_queue_cli "${args[@]}"
}

cmd_inbox() {
  local agent=""
  local all_statuses=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -lt 2 ]] && bridge_die "--agent 뒤에 agent를 지정하세요."
        agent="$2"
        shift 2
        ;;
      --all)
        all_statuses=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        bridge_die "알 수 없는 옵션: $1"
        ;;
      *)
        if [[ -n "$agent" ]]; then
          bridge_die "agent는 하나만 지정할 수 있습니다."
        fi
        agent="$1"
        shift
        ;;
    esac
  done

  agent="$(bridge_resolve_agent "$agent")"
  args=(inbox --agent "$agent")
  if [[ $all_statuses -eq 1 ]]; then
    args+=(--all)
  fi
  bridge_queue_cli "${args[@]}"
}

cmd_show() {
  [[ $# -ne 1 ]] && bridge_die "Usage: bash $SCRIPT_DIR/bridge-task.sh show <task-id>"
  bridge_queue_cli show "$1"
}

cmd_claim() {
  local task_id=""
  local agent=""
  local lease=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -lt 2 ]] && bridge_die "--agent 뒤에 agent를 지정하세요."
        agent="$2"
        shift 2
        ;;
      --lease)
        [[ $# -lt 2 ]] && bridge_die "--lease 뒤에 초 단위를 지정하세요."
        lease="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        bridge_die "알 수 없는 옵션: $1"
        ;;
      *)
        if [[ -n "$task_id" ]]; then
          bridge_die "task id는 하나만 지정할 수 있습니다."
        fi
        task_id="$1"
        shift
        ;;
    esac
  done

  [[ -z "$task_id" ]] && bridge_die "task id가 필요합니다."
  agent="$(bridge_resolve_agent "$agent")"
  args=(claim "$task_id" --agent "$agent")
  if [[ -n "$lease" ]]; then
    args+=(--lease-seconds "$lease")
  fi
  bridge_queue_cli "${args[@]}"
}

cmd_done() {
  local task_id=""
  local agent=""
  local note=""
  local note_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -lt 2 ]] && bridge_die "--agent 뒤에 agent를 지정하세요."
        agent="$2"
        shift 2
        ;;
      --note)
        [[ $# -lt 2 ]] && bridge_die "--note 뒤에 텍스트를 지정하세요."
        note="$2"
        shift 2
        ;;
      --note-file)
        [[ $# -lt 2 ]] && bridge_die "--note-file 뒤에 파일 경로를 지정하세요."
        note_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        bridge_die "알 수 없는 옵션: $1"
        ;;
      *)
        if [[ -n "$task_id" ]]; then
          bridge_die "task id는 하나만 지정할 수 있습니다."
        fi
        task_id="$1"
        shift
        ;;
    esac
  done

  [[ -z "$task_id" ]] && bridge_die "task id가 필요합니다."
  agent="$(bridge_resolve_agent "$agent")"
  args=("done" "$task_id" --agent "$agent")
  if [[ -n "$note" ]]; then
    args+=(--note "$note")
  fi
  if [[ -n "$note_file" ]]; then
    args+=(--note-file "$note_file")
  fi
  bridge_queue_cli "${args[@]}"
  notify_task_requester "$task_id" "$agent" "$note" "$note_file"
}

cmd_update() {
  local task_id=""
  local actor=""

  task_id="${1:-}"
  shift || true
  [[ -n "$task_id" ]] || bridge_die "task_id is required"

  actor="$(infer_actor_if_possible "")"

  bridge_queue_cli update "$task_id" --actor "$actor" "$@"
}

cmd_cancel() {
  local task_id=""
  local actor=""
  local note=""
  local note_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --actor)
        [[ $# -lt 2 ]] && bridge_die "--actor 뒤에 이름을 지정하세요."
        actor="$2"
        shift 2
        ;;
      --note)
        [[ $# -lt 2 ]] && bridge_die "--note 뒤에 텍스트를 지정하세요."
        note="$2"
        shift 2
        ;;
      --note-file)
        [[ $# -lt 2 ]] && bridge_die "--note-file 뒤에 파일 경로를 지정하세요."
        note_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        bridge_die "알 수 없는 옵션: $1"
        ;;
      *)
        if [[ -n "$task_id" ]]; then
          bridge_die "task id는 하나만 지정할 수 있습니다."
        fi
        task_id="$1"
        shift
        ;;
    esac
  done

  [[ -z "$task_id" ]] && bridge_die "task id가 필요합니다."
  actor="$(infer_actor_if_possible "$actor")"
  args=("cancel" "$task_id" --actor "$actor")
  if [[ -n "$note" ]]; then
    args+=(--note "$note")
  fi
  if [[ -n "$note_file" ]]; then
    args+=(--note-file "$note_file")
  fi
  bridge_queue_cli "${args[@]}"
}

cmd_handoff() {
  local task_id=""
  local target=""
  local actor=""
  local note=""
  local note_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        [[ $# -lt 2 ]] && bridge_die "--to 뒤에 agent를 지정하세요."
        target="$2"
        shift 2
        ;;
      --from)
        [[ $# -lt 2 ]] && bridge_die "--from 뒤에 actor를 지정하세요."
        actor="$2"
        shift 2
        ;;
      --note)
        [[ $# -lt 2 ]] && bridge_die "--note 뒤에 텍스트를 지정하세요."
        note="$2"
        shift 2
        ;;
      --note-file)
        [[ $# -lt 2 ]] && bridge_die "--note-file 뒤에 파일 경로를 지정하세요."
        note_file="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        bridge_die "알 수 없는 옵션: $1"
        ;;
      *)
        if [[ -n "$task_id" ]]; then
          bridge_die "task id는 하나만 지정할 수 있습니다."
        fi
        task_id="$1"
        shift
        ;;
    esac
  done

  [[ -z "$task_id" ]] && bridge_die "task id가 필요합니다."
  [[ -z "$target" ]] && bridge_die "--to는 필수입니다."
  bridge_require_agent "$target"
  actor="$(infer_actor_if_possible "$actor")"

  args=(handoff "$task_id" --to "$target" --from "$actor")
  if [[ -n "$note" ]]; then
    args+=(--note "$note")
  fi
  if [[ -n "$note_file" ]]; then
    args+=(--note-file "$note_file")
  fi
  bridge_queue_cli "${args[@]}"
}

cmd_summary() {
  local args=(summary)
  local agent

  for agent in "$@"; do
    bridge_require_agent "$agent"
    args+=(--agent "$agent")
  done

  bridge_queue_cli "${args[@]}"
}

COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
  usage
  exit 1
fi
shift || true

case "$COMMAND" in
  create)
    cmd_create "$@"
    ;;
  inbox)
    cmd_inbox "$@"
    ;;
  show)
    cmd_show "$@"
    ;;
  claim)
    cmd_claim "$@"
    ;;
  done)
    cmd_done "$@"
    ;;
  cancel)
    cmd_cancel "$@"
    ;;
  handoff)
    cmd_handoff "$@"
    ;;
  update)
    cmd_update "$@"
    ;;
  summary)
    cmd_summary "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 명령입니다: $COMMAND"
    ;;
esac
