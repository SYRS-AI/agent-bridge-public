#!/usr/bin/env bash
# bridge-knowledge.sh — bridge-level team knowledge SSOT helpers

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  $(basename "$0") init [--team-name <name>] [--dry-run] [--json]
  $(basename "$0") capture --source <source> [--author <name>] [--channel <id>] [--title <text>] (--text <text> | --text-file <path>) [--dry-run] [--json]
  $(basename "$0") promote --kind people|agents|operating-rules|data-source|data-sources|tools|decision|project|playbook [--capture <id>] [--page <slug>] [--title <text>] [--summary <text>] [--dry-run] [--json]
  $(basename "$0") operator set [--user <id>] --name <name> [--preferred-address <text>] [--alias <text>]... [--handle <surface=value>]... [--communication-preferences <text>] [--decision-scope <text>] [--escalation-relevance <text>] [--dry-run] [--json]
  $(basename "$0") operator show [--json]
  $(basename "$0") search --query <text> [--scope wiki|raw|all] [--limit <count>] [--json]
  $(basename "$0") lint [--stale-days <days>] [--llm-review] [--llm-model <model>] [--json]

Examples:
  $(basename "$0") init --team-name "Acme"
  $(basename "$0") operator set --user owner --name "Sean" --decision-scope "Final release approval"
  $(basename "$0") capture --source telegram --author Alice --text "Alice owns billing approvals."
  $(basename "$0") search --query "billing approvals"
EOF
}

run_python() {
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-knowledge.py" "$@"
}

command="${1:-}"
[[ -n "$command" ]] || { usage; exit 1; }
shift || true

shared_root="${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}"
template_root="$SCRIPT_DIR/runtime-templates"
team_name="Team"
dry_run=0
json_mode=0

add_common_args() {
  args+=(--shared-root "$shared_root" --template-root "$template_root" --team-name "$team_name")
  [[ $dry_run -eq 1 ]] && args+=(--dry-run)
  [[ $json_mode -eq 1 ]] && args+=(--json)
  return 0
}

parse_common_flag() {
  case "$1" in
    --team-name)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      team_name="$2"
      return 2
      ;;
    --shared-root)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      shared_root="$2"
      return 2
      ;;
    --template-root)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      template_root="$2"
      return 2
      ;;
    --dry-run)
      dry_run=1
      return 1
      ;;
    --json)
      json_mode=1
      return 1
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
  esac
  return 0
}

case "$command" in
  init)
    while [[ $# -gt 0 ]]; do
      parse_common_flag "$@" || consumed=$?
      consumed="${consumed:-0}"
      if [[ "$consumed" -gt 0 ]]; then
        shift "$consumed"
        unset consumed
        continue
      fi
      bridge_die "지원하지 않는 knowledge init 옵션입니다: $1"
    done
    args=(init)
    add_common_args
    run_python "${args[@]}"
    ;;
  capture)
    source_name=""
    author=""
    channel=""
    title=""
    text=""
    text_file=""
    while [[ $# -gt 0 ]]; do
      parse_common_flag "$@" || consumed=$?
      consumed="${consumed:-0}"
      if [[ "$consumed" -gt 0 ]]; then
        shift "$consumed"
        unset consumed
        continue
      fi
      case "$1" in
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
        *)
          bridge_die "지원하지 않는 knowledge capture 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$source_name" ]] || bridge_die "--source is required"
    if [[ -z "$text" && -z "$text_file" ]]; then
      bridge_die "--text or --text-file is required"
    fi
    args=(capture)
    add_common_args
    args+=(--source "$source_name")
    [[ -n "$author" ]] && args+=(--author "$author")
    [[ -n "$channel" ]] && args+=(--channel "$channel")
    [[ -n "$title" ]] && args+=(--title "$title")
    [[ -n "$text" ]] && args+=(--text "$text")
    [[ -n "$text_file" ]] && args+=(--text-file "$text_file")
    run_python "${args[@]}"
    ;;
  promote)
    kind=""
    capture_id=""
    page=""
    title=""
    summary=""
    while [[ $# -gt 0 ]]; do
      parse_common_flag "$@" || consumed=$?
      consumed="${consumed:-0}"
      if [[ "$consumed" -gt 0 ]]; then
        shift "$consumed"
        unset consumed
        continue
      fi
      case "$1" in
        --kind)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          kind="$2"
          shift 2
          ;;
        --capture)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          capture_id="$2"
          shift 2
          ;;
        --page)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          page="$2"
          shift 2
          ;;
        --title)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          title="$2"
          shift 2
          ;;
        --summary)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          summary="$2"
          shift 2
          ;;
        *)
          bridge_die "지원하지 않는 knowledge promote 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$kind" ]] || bridge_die "--kind is required"
    args=(promote)
    add_common_args
    args+=(--kind "$kind")
    [[ -n "$capture_id" ]] && args+=(--capture "$capture_id")
    [[ -n "$page" ]] && args+=(--page "$page")
    [[ -n "$title" ]] && args+=(--title "$title")
    [[ -n "$summary" ]] && args+=(--summary "$summary")
    run_python "${args[@]}"
    ;;
  operator)
    mode="${1:-}"
    [[ -n "$mode" ]] || bridge_die "knowledge operator 하위 명령이 필요합니다: set|show"
    shift || true
    case "$mode" in
      set)
        user_id=""
        name=""
        preferred_address=""
        communication_preferences=""
        decision_scope=""
        escalation_relevance=""
        aliases=()
        handles=()
        while [[ $# -gt 0 ]]; do
          parse_common_flag "$@" || consumed=$?
          consumed="${consumed:-0}"
          if [[ "$consumed" -gt 0 ]]; then
            shift "$consumed"
            unset consumed
            continue
          fi
          case "$1" in
            --user)
              [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
              user_id="$2"
              shift 2
              ;;
            --name)
              [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
              name="$2"
              shift 2
              ;;
            --preferred-address)
              [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
              preferred_address="$2"
              shift 2
              ;;
            --alias)
              [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
              aliases+=("$2")
              shift 2
              ;;
            --handle)
              [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
              handles+=("$2")
              shift 2
              ;;
            --communication-preferences)
              [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
              communication_preferences="$2"
              shift 2
              ;;
            --decision-scope)
              [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
              decision_scope="$2"
              shift 2
              ;;
            --escalation-relevance)
              [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
              escalation_relevance="$2"
              shift 2
              ;;
            *)
              bridge_die "지원하지 않는 knowledge operator set 옵션입니다: $1"
              ;;
          esac
        done
        [[ -n "$name" ]] || bridge_die "--name is required"
        args=(operator-set)
        add_common_args
        [[ -n "$user_id" ]] && args+=(--user "$user_id")
        args+=(--name "$name")
        [[ -n "$preferred_address" ]] && args+=(--preferred-address "$preferred_address")
        for alias in "${aliases[@]}"; do
          args+=(--alias "$alias")
        done
        for handle in "${handles[@]}"; do
          args+=(--handle "$handle")
        done
        [[ -n "$communication_preferences" ]] && args+=(--communication-preferences "$communication_preferences")
        [[ -n "$decision_scope" ]] && args+=(--decision-scope "$decision_scope")
        [[ -n "$escalation_relevance" ]] && args+=(--escalation-relevance "$escalation_relevance")
        run_python "${args[@]}"
        ;;
      show)
        while [[ $# -gt 0 ]]; do
          parse_common_flag "$@" || consumed=$?
          consumed="${consumed:-0}"
          if [[ "$consumed" -gt 0 ]]; then
            shift "$consumed"
            unset consumed
            continue
          fi
          bridge_die "지원하지 않는 knowledge operator show 옵션입니다: $1"
        done
        args=(operator-show)
        add_common_args
        run_python "${args[@]}"
        ;;
      *)
        bridge_die "지원하지 않는 knowledge operator 하위 명령입니다: $mode"
        ;;
    esac
    ;;
  search)
    query=""
    scope="wiki"
    limit="10"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --query)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          query="$2"
          shift 2
          ;;
        --scope)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          scope="$2"
          shift 2
          ;;
        --limit)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          limit="$2"
          shift 2
          ;;
        --shared-root)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          shared_root="$2"
          shift 2
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
          bridge_die "지원하지 않는 knowledge search 옵션입니다: $1"
          ;;
      esac
    done
    [[ -n "$query" ]] || bridge_die "--query is required"
    args=(search --shared-root "$shared_root" --query "$query" --scope "$scope" --limit "$limit")
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    ;;
  lint)
    stale_days=""
    llm_review=0
    llm_model=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --shared-root)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          shared_root="$2"
          shift 2
          ;;
        --stale-days)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          stale_days="$2"
          shift 2
          ;;
        --llm-review)
          llm_review=1
          shift
          ;;
        --llm-model)
          [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
          llm_model="$2"
          shift 2
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
          bridge_die "지원하지 않는 knowledge lint 옵션입니다: $1"
          ;;
      esac
    done
    args=(lint --shared-root "$shared_root")
    [[ -n "$stale_days" ]] && args+=(--stale-days "$stale_days")
    [[ $llm_review -eq 1 ]] && args+=(--llm-review)
    [[ -n "$llm_model" ]] && args+=(--llm-model "$llm_model")
    [[ $json_mode -eq 1 ]] && args+=(--json)
    run_python "${args[@]}"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 knowledge 명령입니다: $command"
    ;;
esac
