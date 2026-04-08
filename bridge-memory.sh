#!/usr/bin/env bash
# bridge-memory.sh — bridge-native memory wiki helpers

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  $(basename "$0") init --agent <agent> [--user <id[:display-name]>]... [--dry-run] [--json]
  $(basename "$0") capture --agent <agent> [--user <id>] --source <source> [--author <name>] [--channel <id>] [--title <text>] (--text <text> | --text-file <path>) [--dry-run] [--json]
  $(basename "$0") ingest --agent <agent> (--capture <id> | --latest | --all) [--dry-run] [--json]
EOF
}

run_python() {
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-memory.py" "$@"
}

resolve_agent_home() {
  local agent="$1"
  bridge_require_agent "$agent"
  printf '%s' "$(bridge_agent_workdir "$agent")"
}

command="${1:-}"
[[ -n "$command" ]] || { usage; exit 1; }
shift || true

agent=""
users=()
dry_run=0
json_mode=0

case "$command" in
  init)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --user)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          users+=("$2")
          shift 2
          ;;
        --dry-run)
          dry_run=1
          shift
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory init 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    args=(init --agent "$agent" --home "$(resolve_agent_home "$agent")" --template-root "$SCRIPT_DIR/agents/_template")
    for item in "${users[@]}"; do
      args+=(--user "$item")
    done
    [[ $dry_run -eq 1 ]] && args+=(--dry-run)
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  capture)
    user_id="default"
    source_name=""
    author=""
    channel=""
    title=""
    text=""
    text_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --user)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          user_id="$2"
          shift 2
          ;;
        --source)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          source_name="$2"
          shift 2
          ;;
        --author)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          author="$2"
          shift 2
          ;;
        --channel)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          channel="$2"
          shift 2
          ;;
        --title)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          title="$2"
          shift 2
          ;;
        --text)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          text="$2"
          shift 2
          ;;
        --text-file)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          text_file="$2"
          shift 2
          ;;
        --dry-run)
          dry_run=1
          shift
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory capture 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    [[ -n "$source_name" ]] || bridge_die "--source is required"
    if [[ -z "$text" && -z "$text_file" ]]; then
      bridge_die "--text or --text-file is required"
    fi
    args=(capture --agent "$agent" --home "$(resolve_agent_home "$agent")" --template-root "$SCRIPT_DIR/agents/_template" --user "$user_id" --source "$source_name")
    [[ -n "$author" ]] && args+=(--author "$author")
    [[ -n "$channel" ]] && args+=(--channel "$channel")
    [[ -n "$title" ]] && args+=(--title "$title")
    [[ -n "$text" ]] && args+=(--text "$text")
    [[ -n "$text_file" ]] && args+=(--text-file "$text_file")
    [[ $dry_run -eq 1 ]] && args+=(--dry-run)
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  ingest)
    capture_id=""
    latest=0
    all_items=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --agent)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          agent="$2"
          shift 2
          ;;
        --capture)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          capture_id="$2"
          shift 2
          ;;
        --latest)
          latest=1
          shift
          ;;
        --all)
          all_items=1
          shift
          ;;
        --dry-run)
          dry_run=1
          shift
          ;;
        --json)
          json_mode=1
          shift
          ;;
        -h|--help|help)
          usage
          exit 0
          ;;
        *)
          bridge_die "지원하지 않는 memory ingest 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$agent" ]] || bridge_die "--agent is required"
    args=(ingest --agent "$agent" --home "$(resolve_agent_home "$agent")" --template-root "$SCRIPT_DIR/agents/_template")
    [[ -n "$capture_id" ]] && args+=(--capture "$capture_id")
    [[ $latest -eq 1 ]] && args+=(--latest)
    [[ $all_items -eq 1 ]] && args+=(--all)
    [[ $dry_run -eq 1 ]] && args+=(--dry-run)
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
esac
