#!/usr/bin/env bash
# bridge-cron.sh — read-only OpenClaw cron inventory

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") inventory [--agent <openclaw-agent>] [--family <family>] [--mode recurring|one-shot|all] [--enabled yes|no|all] [--limit <count>] [--json]
  $(basename "$0") show <job-name-or-id> [--json]
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

subcommand="${1:-}"
shift || true

case "$subcommand" in
  inventory)
    run_inventory "$@"
    ;;
  show)
    run_show "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 cron 명령입니다: $subcommand"
    ;;
esac
