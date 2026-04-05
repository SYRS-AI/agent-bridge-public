#!/usr/bin/env bash
# bridge-cron.sh — OpenClaw cron inventory and queue adapters

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") inventory [--agent <openclaw-agent>] [--family <family>] [--mode recurring|one-shot|all] [--enabled yes|no|all] [--limit <count>] [--json]
  $(basename "$0") show <job-name-or-id> [--json]
  $(basename "$0") enqueue <job-name-or-id> [--slot <slot-key>] [--target <bridge-agent>] [--from <actor>] [--priority normal|high] [--dry-run]
  $(basename "$0") sync [--dry-run] [--json] [--since <iso-datetime>] [--now <iso-datetime>]
  $(basename "$0") run-subagent <run-id> [--dry-run]
  $(basename "$0") errors report [--agent <bridge|openclaw-agent>] [--family <family>] [--limit <count>] [--json]
  $(basename "$0") cleanup report [--mode expired-one-shot] [--json]
  $(basename "$0") cleanup prune [--mode expired-one-shot] [--dry-run]
EOF
}

run_inventory() {
  local py_args=(
    inventory
    --jobs-file "$BRIDGE_OPENCLAW_CRON_JOBS_FILE"
  )

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent|--family|--mode|--enabled|--limit)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        py_args+=("$1" "$2")
        shift 2
        ;;
      --json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 옵션입니다: $1"
        ;;
    esac
  done

  bridge_require_openclaw_cron_jobs
  bridge_cron_python "${py_args[@]}"
}

run_show() {
  local job_ref="${1:-}"
  local py_args=(
    show
    --jobs-file "$BRIDGE_OPENCLAW_CRON_JOBS_FILE"
  )

  shift || true
  [[ -n "$job_ref" ]] || bridge_die "Usage: $(basename "$0") show <job-name-or-id> [--json]"
  py_args+=("$job_ref")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        py_args+=("$1")
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 옵션입니다: $1"
        ;;
    esac
  done

  bridge_require_openclaw_cron_jobs
  bridge_cron_python "${py_args[@]}"
}

write_materialized_payload() {
  local payload_file="$1"
  local slot="$2"

  mkdir -p "$(dirname "$payload_file")"
  {
    printf '# [cron] %s\n\n' "$CRON_JOB_NAME"
    printf -- '- slot: %s\n' "$slot"
    printf -- '- openclaw_agent: %s\n' "$CRON_JOB_AGENT"
    printf -- '- family: %s\n' "$CRON_JOB_FAMILY"
    printf -- '- schedule: %s\n' "$CRON_JOB_SCHEDULE_TEXT"
    printf -- '- source_file: %s\n' "$BRIDGE_OPENCLAW_CRON_JOBS_FILE"
    printf -- '- payload_kind: %s\n' "$CRON_JOB_PAYLOAD_KIND"
    printf '\n## Original Payload\n\n'
    printf '%s\n' "$CRON_JOB_PAYLOAD_TEXT"
  } >"$payload_file"
}

write_dispatch_body() {
  local body_file="$1"
  local slot="$2"
  local run_id="$3"
  local payload_file="$4"
  local request_file="$5"
  local result_file="$6"
  local status_file="$7"
  local target="$8"
  local target_engine="$9"

  mkdir -p "$(dirname "$body_file")"
  {
    printf '# [cron-dispatch] %s\n\n' "$CRON_JOB_NAME"
    printf -- '- run_id: %s\n' "$run_id"
    printf -- '- slot: %s\n' "$slot"
    printf -- '- target_agent: %s\n' "$target"
    printf -- '- target_engine: %s\n' "$target_engine"
    printf -- '- openclaw_agent: %s\n' "$CRON_JOB_AGENT"
    printf -- '- family: %s\n' "$CRON_JOB_FAMILY"
    printf -- '- payload_file: %s\n' "$payload_file"
    printf -- '- request_file: %s\n' "$request_file"
    printf -- '- result_file: %s\n' "$result_file"
    printf -- '- status_file: %s\n' "$status_file"
    printf '\n## Instruction\n\n'
    printf 'Do not execute the legacy cron payload inline in this long-lived session.\n\n'
    printf '1. Run `agent-bridge cron run-subagent %s`\n' "$run_id"
    printf '2. Wait for the disposable child result artifact\n'
    printf '3. Read `result_file` and decide follow-up from this parent session\n'
    printf '4. Do not let the child deliver directly to users or channels\n'
  } >"$body_file"
}

run_enqueue() {
  local job_ref="${1:-}"
  local slot=""
  local target=""
  local actor=""
  local priority="normal"
  local dry_run=0
  local title=""
  local body_file=""
  local manifest_file=""
  local manifest_rel=""
  local body_rel=""
  local request_file=""
  local request_rel=""
  local result_file=""
  local result_rel=""
  local status_file=""
  local status_rel=""
  local payload_file=""
  local payload_rel=""
  local stdout_log=""
  local stderr_log=""
  local run_id=""
  local target_engine=""
  local target_workdir=""
  local create_output=""
  local task_id=""
  local created_at=""
  local shell_payload=""

  shift || true
  [[ -n "$job_ref" ]] || bridge_die "Usage: $(basename "$0") enqueue <job-name-or-id> [--slot <slot-key>] [--target <bridge-agent>] [--from <actor>] [--priority normal|high] [--dry-run]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --slot|--target|--from|--priority)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        case "$1" in
          --slot) slot="$2" ;;
          --target) target="$2" ;;
          --from) actor="$2" ;;
          --priority) priority="$2" ;;
        esac
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 옵션입니다: $1"
        ;;
    esac
  done

  case "$priority" in
    normal|high) ;;
    *)
      bridge_die "--priority는 normal 또는 high만 지원합니다."
      ;;
  esac

  bridge_require_openclaw_cron_jobs
  bridge_load_roster

  local CRON_JOB_ID=""
  local CRON_JOB_NAME=""
  local CRON_JOB_AGENT=""
  local CRON_JOB_FAMILY=""
  local CRON_JOB_KIND=""
  local CRON_JOB_ENABLED=""
  local CRON_JOB_SCHEDULE_TEXT=""
  local CRON_JOB_PAYLOAD_KIND=""
  local CRON_JOB_PAYLOAD_TEXT=""

  shell_payload="$(bridge_cron_python show --jobs-file "$BRIDGE_OPENCLAW_CRON_JOBS_FILE" --format shell "$job_ref")" || exit $?
  # shellcheck disable=SC1090
  source <(printf '%s\n' "$shell_payload")

  [[ "$CRON_JOB_ENABLED" == "1" ]] || bridge_die "비활성 cron job은 enqueue할 수 없습니다: $CRON_JOB_NAME"
  [[ "$CRON_JOB_KIND" == "recurring" ]] || bridge_die "recurring cron job만 enqueue할 수 있습니다: $CRON_JOB_NAME"

  if [[ -z "$slot" ]]; then
    slot="$(bridge_cron_default_slot "$CRON_JOB_FAMILY")"
  fi

  if [[ -n "$target" ]]; then
    bridge_require_agent "$target"
  else
    target="$(bridge_resolve_openclaw_target "$CRON_JOB_AGENT" || true)"
    [[ -n "$target" ]] || bridge_die "OpenClaw agent에 대응하는 bridge agent를 찾지 못했습니다: $CRON_JOB_AGENT"
  fi

  actor="${actor:-cron:$CRON_JOB_NAME}"
  title="[cron-dispatch] $CRON_JOB_NAME ($slot)"
  run_id="$(bridge_cron_run_id "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  request_file="$(bridge_cron_request_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  result_file="$(bridge_cron_result_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  status_file="$(bridge_cron_status_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  stdout_log="$(bridge_cron_stdout_log "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  stderr_log="$(bridge_cron_stderr_log "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  payload_file="$(bridge_cron_payload_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  body_file="$(bridge_cron_body_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  manifest_file="$(bridge_cron_manifest_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  target_engine="$(bridge_agent_engine "$target")"
  target_workdir="$(bridge_agent_workdir "$target")"
  request_rel="${request_file#$BRIDGE_HOME/}"
  result_rel="${result_file#$BRIDGE_HOME/}"
  status_rel="${status_file#$BRIDGE_HOME/}"
  payload_rel="${payload_file#$BRIDGE_HOME/}"
  body_rel="${body_file#$BRIDGE_HOME/}"
  manifest_rel="${manifest_file#$BRIDGE_HOME/}"

  if [[ -f "$manifest_file" || -f "$request_file" ]]; then
    printf 'status: already_enqueued\n'
    printf 'job: %s\n' "$CRON_JOB_NAME"
    printf 'slot: %s\n' "$slot"
    printf 'target: %s\n' "$target"
    printf 'run_id: %s\n' "$run_id"
    printf 'request_file: %s\n' "$request_rel"
    printf 'manifest: %s\n' "$manifest_rel"
    return 0
  fi

  if [[ $dry_run -eq 1 ]]; then
    printf 'status: dry_run\n'
    printf 'job: %s\n' "$CRON_JOB_NAME"
    printf 'family: %s\n' "$CRON_JOB_FAMILY"
    printf 'slot: %s\n' "$slot"
    printf 'target: %s\n' "$target"
    printf 'engine: %s\n' "$target_engine"
    printf 'actor: %s\n' "$actor"
    printf 'priority: %s\n' "$priority"
    printf 'title: %s\n' "$title"
    printf 'run_id: %s\n' "$run_id"
    printf 'body_file: %s\n' "$body_rel"
    printf 'payload_file: %s\n' "$payload_rel"
    printf 'request_file: %s\n' "$request_rel"
    printf 'result_file: %s\n' "$result_rel"
    printf 'status_file: %s\n' "$status_rel"
    printf 'manifest: %s\n' "$manifest_rel"
    return 0
  fi

  write_materialized_payload "$payload_file" "$slot"
  write_dispatch_body "$body_file" "$slot" "$run_id" "$payload_file" "$request_file" "$result_file" "$status_file" "$target" "$target_engine"
  create_output="$(bridge_queue_cli create --to "$target" --title "$title" --from "$actor" --priority "$priority" --body-file "$body_file")"
  printf '%s\n' "$create_output"

  if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
    task_id="${BASH_REMATCH[1]}"
  else
    bridge_die "생성된 task id를 파싱하지 못했습니다."
  fi

  created_at="$(bridge_now_iso)"
  bridge_cron_write_request "$request_file" "$run_id" "$CRON_JOB_ID" "$CRON_JOB_NAME" "$CRON_JOB_FAMILY" "$CRON_JOB_AGENT" "$target" "$slot" "$task_id" "$created_at" "$body_file" "$payload_file" "$result_file" "$status_file" "$stdout_log" "$stderr_log" "$BRIDGE_OPENCLAW_CRON_JOBS_FILE" "$CRON_JOB_PAYLOAD_KIND" "$target_engine" "$target_workdir"
  bridge_cron_write_status "$status_file" "$run_id" "queued" "$target_engine" "$request_file" "$result_file" "$created_at"
  bridge_cron_write_manifest "$manifest_file" "$CRON_JOB_ID" "$CRON_JOB_NAME" "$CRON_JOB_FAMILY" "$CRON_JOB_AGENT" "$target" "$slot" "$task_id" "$created_at" "$body_file" "$BRIDGE_OPENCLAW_CRON_JOBS_FILE" "$run_id" "$request_file" "$payload_file" "$result_file" "$status_file" "$stdout_log" "$stderr_log"
  printf 'run_id: %s\n' "$run_id"
  printf 'request_file: %s\n' "$request_rel"
  printf 'result_file: %s\n' "$result_rel"
  printf 'status_file: %s\n' "$status_rel"
  printf 'manifest: %s\n' "$manifest_rel"
}

run_subagent() {
  local run_id="${1:-}"
  local dry_run=0
  local request_file=""
  local args=()

  shift || true
  [[ -n "$run_id" ]] || bridge_die "Usage: $(basename "$0") run-subagent <run-id> [--dry-run]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 run-subagent 옵션입니다: $1"
        ;;
    esac
  done

  request_file="$(bridge_cron_request_file_by_id "$run_id")"
  [[ -f "$request_file" ]] || bridge_die "cron run request를 찾지 못했습니다: $run_id"

  args=(run --request-file "$request_file")
  if [[ $dry_run -eq 1 ]]; then
    args+=(--dry-run)
  fi

  bridge_cron_runner_python "${args[@]}"
}

run_sync() {
  local dry_run=0
  local json_output=0
  local since=""
  local now=""
  local state_file
  local args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --json)
        json_output=1
        shift
        ;;
      --since|--now)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        case "$1" in
          --since) since="$2" ;;
          --now) now="$2" ;;
        esac
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 sync 옵션입니다: $1"
        ;;
    esac
  done

  if [[ ! -f "$BRIDGE_OPENCLAW_CRON_JOBS_FILE" ]]; then
    printf 'status: skipped\n'
    printf 'reason: no_openclaw_jobs_file\n'
    printf 'jobs_file: %s\n' "$BRIDGE_OPENCLAW_CRON_JOBS_FILE"
    return 0
  fi
  state_file="$(bridge_cron_scheduler_state_file)"
  args=(
    sync
    --jobs-file "$BRIDGE_OPENCLAW_CRON_JOBS_FILE"
    --state-file "$state_file"
    --bridge-cron "$SCRIPT_DIR/bridge-cron.sh"
    --repo-root "$SCRIPT_DIR"
  )

  if [[ -n "$since" ]]; then
    args+=(--since "$since")
  fi
  if [[ -n "$now" ]]; then
    args+=(--now "$now")
  fi
  if [[ $dry_run -eq 1 ]]; then
    args+=(--dry-run)
  fi
  if [[ $json_output -eq 1 ]]; then
    args+=(--json)
  fi

  bridge_cron_scheduler_python "${args[@]}"
}

run_errors() {
  local errors_cmd="${1:-}"
  shift || true

  bridge_require_openclaw_cron_jobs

  case "$errors_cmd" in
    report)
      local py_args=(
        errors-report
        --jobs-file "$BRIDGE_OPENCLAW_CRON_JOBS_FILE"
      )
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --agent|--family|--limit)
            [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
            py_args+=("$1" "$2")
            shift 2
            ;;
          --json)
            py_args+=("$1")
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            bridge_die "지원하지 않는 errors report 옵션입니다: $1"
            ;;
        esac
      done
      bridge_cron_python "${py_args[@]}"
      ;;
    *)
      bridge_die "지원하지 않는 errors 명령입니다: ${errors_cmd:-<none>}"
      ;;
  esac
}

run_cleanup() {
  local cleanup_cmd="${1:-}"
  shift || true

  bridge_require_openclaw_cron_jobs

  case "$cleanup_cmd" in
    report)
      local py_args=(
        cleanup-report
        --jobs-file "$BRIDGE_OPENCLAW_CRON_JOBS_FILE"
      )
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --mode)
            [[ $# -lt 2 ]] && bridge_die "--mode 뒤에 값을 지정하세요."
            py_args+=("$1" "$2")
            shift 2
            ;;
          --json)
            py_args+=("$1")
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            bridge_die "지원하지 않는 cleanup report 옵션입니다: $1"
            ;;
        esac
      done
      bridge_cron_python "${py_args[@]}"
      ;;
    prune)
      local py_args=(
        cleanup-prune
        --jobs-file "$BRIDGE_OPENCLAW_CRON_JOBS_FILE"
      )
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --mode)
            [[ $# -lt 2 ]] && bridge_die "--mode 뒤에 값을 지정하세요."
            py_args+=("$1" "$2")
            shift 2
            ;;
          --dry-run)
            py_args+=("$1")
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            bridge_die "지원하지 않는 cleanup prune 옵션입니다: $1"
            ;;
        esac
      done
      bridge_cron_python "${py_args[@]}"
      ;;
    *)
      bridge_die "지원하지 않는 cleanup 명령입니다: ${cleanup_cmd:-<none>}"
      ;;
  esac
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  inventory)
    run_inventory "$@"
    ;;
  show)
    run_show "$@"
    ;;
  enqueue)
    run_enqueue "$@"
    ;;
  sync)
    run_sync "$@"
    ;;
  run-subagent)
    run_subagent "$@"
    ;;
  errors)
    run_errors "$@"
    ;;
  cleanup)
    run_cleanup "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 cron 명령입니다: $subcommand"
    ;;
esac
