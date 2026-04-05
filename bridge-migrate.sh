#!/usr/bin/env bash
# bridge-migrate.sh — workspace migration planning helpers

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-migrate.sh workspace plan <agent>
EOF
}

list_top_level_entries() {
  local dir="$1"
  local entry=""
  local name=""

  [[ -d "$dir" ]] || return 0

  shopt -s nullglob dotglob
  for entry in "$dir"/* "$dir"/.*; do
    [[ "$entry" == "$dir/." || "$entry" == "$dir/.." ]] && continue
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    printf '%s\n' "$name"
  done | LC_ALL=C sort -u
  shopt -u nullglob dotglob
}

classify_entry() {
  local name="$1"

  case "$name" in
    MEMORY.md|memory|compound|.discord|.openclaw|STATUS.md|WORKFLOW.md|HEARTBEAT.md|CLAUDE.md)
      printf 'preserve'
      ;;
    tmp|output|.cache|preview|previews)
      printf 'live_only'
      ;;
    *)
      printf 'other'
      ;;
  esac
}

print_entry_group() {
  local dir="$1"
  local label="$2"
  local wanted="$3"
  local name=""
  local printed=0

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$(classify_entry "$name")" != "$wanted" ]]; then
      continue
    fi
    if [[ $printed -eq 0 ]]; then
      printf '%s\n' "$label"
      printed=1
    fi
    printf '  - %s\n' "$name"
  done < <(list_top_level_entries "$dir")

  if [[ $printed -eq 0 ]]; then
    printf '%s\n' "$label"
    printf '  - (none)\n'
  fi
}

cmd_workspace_plan() {
  local agent="$1"
  local current_workdir=""
  local explicit_profile_home=""
  local effective_profile_home=""
  local target_home=""
  local status="already_standard"

  bridge_require_agent "$agent"

  current_workdir="$(bridge_agent_workdir "$agent")"
  explicit_profile_home="$(bridge_agent_profile_home "$agent")"
  if [[ -n "$explicit_profile_home" ]]; then
    effective_profile_home="$explicit_profile_home"
  else
    effective_profile_home="$(bridge_agent_default_profile_home "$agent")"
  fi
  target_home="$(bridge_agent_default_home "$agent")"

  if [[ "$current_workdir" != "$target_home" || "$effective_profile_home" != "$target_home" ]]; then
    status="needs_migration"
  fi

  printf 'agent: %s\n' "$agent"
  printf 'engine: %s\n' "$(bridge_agent_engine "$agent")"
  printf 'status: %s\n' "$status"
  printf 'current_workdir: %s\n' "$current_workdir"
  printf 'current_profile_home: %s\n' "$effective_profile_home"
  printf 'target_home: %s\n' "$target_home"
  printf 'target_profile_home: %s\n' "$target_home"
  printf '\n'

  printf 'recommended_roster_changes:\n'
  if [[ "$current_workdir" == "$target_home" ]]; then
    printf '  - workdir already points at the standard home\n'
  else
    printf '  - BRIDGE_AGENT_WORKDIR["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s"\n' "$agent" "$agent"
  fi
  if [[ -z "$explicit_profile_home" ]]; then
    printf '  - BRIDGE_AGENT_PROFILE_HOME["%s"] is not set; default already resolves to target\n' "$agent"
  elif [[ "$explicit_profile_home" == "$target_home" ]]; then
    printf '  - unset '\''BRIDGE_AGENT_PROFILE_HOME[%s]'\'' to use the default standard home\n' "$agent"
  else
    printf '  - BRIDGE_AGENT_PROFILE_HOME["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s" or unset the override after cutover\n' "$agent" "$agent"
  fi
  printf '\n'

  printf 'copy_sources:\n'
  if [[ -d "$current_workdir" ]]; then
    printf '  - workdir: %s\n' "$current_workdir"
  else
    printf '  - workdir: %s (missing)\n' "$current_workdir"
  fi
  if [[ -n "$explicit_profile_home" ]]; then
    if [[ "$explicit_profile_home" == "$current_workdir" ]]; then
      printf '  - profile home is the same path as workdir\n'
    elif [[ -d "$explicit_profile_home" ]]; then
      printf '  - profile_home: %s\n' "$explicit_profile_home"
    else
      printf '  - profile_home: %s (missing)\n' "$explicit_profile_home"
    fi
  else
    printf '  - profile_home: (default target; no separate legacy override)\n'
  fi
  printf '\n'

  if [[ -d "$current_workdir" ]]; then
    printf 'workdir_inventory: %s\n' "$current_workdir"
    print_entry_group "$current_workdir" "preserve:" "preserve"
    print_entry_group "$current_workdir" "live_only:" "live_only"
    print_entry_group "$current_workdir" "other:" "other"
    printf '\n'
  fi

  if [[ -n "$explicit_profile_home" && "$explicit_profile_home" != "$current_workdir" && -d "$explicit_profile_home" ]]; then
    printf 'profile_inventory: %s\n' "$explicit_profile_home"
    print_entry_group "$explicit_profile_home" "preserve:" "preserve"
    print_entry_group "$explicit_profile_home" "live_only:" "live_only"
    print_entry_group "$explicit_profile_home" "other:" "other"
    printf '\n'
  fi

  printf 'next_steps:\n'
  printf '  1. review this plan and confirm the target root is correct\n'
  printf '  2. copy live-home files into %s without deleting the source\n' "$target_home"
  printf '  3. switch roster paths to the standard home\n'
  printf '  4. deploy tracked profile material into the new live home\n'
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  workspace)
    case "${1:-}" in
      plan)
        shift
        [[ $# -eq 1 ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-migrate.sh workspace plan <agent>"
        cmd_workspace_plan "$1"
        ;;
      ""|-h|--help|help)
        usage
        ;;
      *)
        bridge_die "지원하지 않는 migrate workspace 명령입니다: $1"
        ;;
    esac
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 migrate 명령입니다: $subcommand"
    ;;
esac
