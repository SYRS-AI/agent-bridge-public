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

write_materialized_body() {
  local body_file="$1"
  local slot="$2"

  mkdir -p "$(dirname "$body_file")"
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
  local create_output=""
  local task_id=""
  local created_at=""

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

  # shellcheck disable=SC1090
  source <(bridge_cron_python show --jobs-file "$BRIDGE_OPENCLAW_CRON_JOBS_FILE" --format shell "$job_ref")

  [[ "$CRON_JOB_ENABLED" == "1" ]] || bridge_die "비활성 cron job은 enqueue할 수 없습니다: $CRON_JOB_NAME"
  [[ "$CRON_JOB_KIND" == "recurring" ]] || bridge_die "recurring cron job만 enqueue할 수 있습니다: $CRON_JOB_NAME"
  bridge_cron_family_allowed "$CRON_JOB_FAMILY" || bridge_die "허용되지 않은 cron family입니다: $CRON_JOB_FAMILY"

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
  title="[cron] $CRON_JOB_NAME ($slot)"
  body_file="$(bridge_cron_body_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  manifest_file="$(bridge_cron_manifest_file "$CRON_JOB_NAME" "$CRON_JOB_ID" "$slot")"
  body_rel="${body_file#$BRIDGE_HOME/}"
  manifest_rel="${manifest_file#$BRIDGE_HOME/}"

  if [[ -f "$manifest_file" ]]; then
    printf 'status: already_enqueued\n'
    printf 'job: %s\n' "$CRON_JOB_NAME"
    printf 'slot: %s\n' "$slot"
    printf 'target: %s\n' "$target"
    printf 'manifest: %s\n' "$manifest_rel"
    return 0
  fi

  if [[ $dry_run -eq 1 ]]; then
    printf 'status: dry_run\n'
    printf 'job: %s\n' "$CRON_JOB_NAME"
    printf 'family: %s\n' "$CRON_JOB_FAMILY"
    printf 'slot: %s\n' "$slot"
    printf 'target: %s\n' "$target"
    printf 'actor: %s\n' "$actor"
    printf 'priority: %s\n' "$priority"
    printf 'title: %s\n' "$title"
    printf 'body_file: %s\n' "$body_rel"
    printf 'manifest: %s\n' "$manifest_rel"
    return 0
  fi

  write_materialized_body "$body_file" "$slot"
  create_output="$(bridge_queue_cli create --to "$target" --title "$title" --from "$actor" --priority "$priority" --body-file "$body_file")"
  printf '%s\n' "$create_output"

  if [[ "$create_output" =~ created\ task\ \#([0-9]+) ]]; then
    task_id="${BASH_REMATCH[1]}"
  else
    bridge_die "생성된 task id를 파싱하지 못했습니다."
  fi

  created_at="$(bridge_now_iso)"
  bridge_cron_write_manifest "$manifest_file" "$CRON_JOB_ID" "$CRON_JOB_NAME" "$CRON_JOB_FAMILY" "$CRON_JOB_AGENT" "$target" "$slot" "$task_id" "$created_at" "$body_file" "$BRIDGE_OPENCLAW_CRON_JOBS_FILE"
  printf 'manifest: %s\n' "$manifest_rel"
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
  ""|-h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 cron 명령입니다: $subcommand"
    ;;
esac
