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
  bash $SCRIPT_DIR/bridge-migrate.sh runtime inventory [--json] [--report <path>]
  bash $SCRIPT_DIR/bridge-migrate.sh docs audit [--all] [agent...]
  bash $SCRIPT_DIR/bridge-migrate.sh docs apply [--all] [agent...] [--dry-run] [--report <path>]
  bash $SCRIPT_DIR/bridge-migrate.sh workspace plan <agent>
  bash $SCRIPT_DIR/bridge-migrate.sh workspace copy <agent> [--dry-run]
  bash $SCRIPT_DIR/bridge-migrate.sh workspace cutover <agent> --dry-run
EOF
}

run_docs_helper() {
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-docs.py" "$@"
}

run_runtime_helper() {
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-runtime-inventory.py" "$@"
}

MIGRATE_AGENT=""
MIGRATE_CURRENT_WORKDIR=""
MIGRATE_EXPLICIT_PROFILE_HOME=""
MIGRATE_EFFECTIVE_PROFILE_HOME=""
MIGRATE_TARGET_HOME=""
MIGRATE_STATUS=""

resolve_workspace_context() {
  local agent="$1"

  bridge_require_agent "$agent"

  MIGRATE_AGENT="$agent"
  MIGRATE_CURRENT_WORKDIR="$(bridge_agent_workdir "$agent")"
  MIGRATE_EXPLICIT_PROFILE_HOME="$(bridge_agent_profile_home "$agent")"
  if [[ -n "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    MIGRATE_EFFECTIVE_PROFILE_HOME="$MIGRATE_EXPLICIT_PROFILE_HOME"
  else
    MIGRATE_EFFECTIVE_PROFILE_HOME="$(bridge_agent_default_profile_home "$agent")"
  fi
  MIGRATE_TARGET_HOME="$(bridge_agent_default_home "$agent")"
  MIGRATE_STATUS="already_standard"

  if [[ "$MIGRATE_CURRENT_WORKDIR" != "$MIGRATE_TARGET_HOME" || "$MIGRATE_EFFECTIVE_PROFILE_HOME" != "$MIGRATE_TARGET_HOME" ]]; then
    MIGRATE_STATUS="needs_migration"
  fi
}

backup_root_for() {
  local agent="$1"
  local stamp="$2"

  printf '%s/migrations/%s-%s' "$BRIDGE_STATE_DIR" "$agent" "$stamp"
}

path_kind() {
  local path="$1"

  if [[ -L "$path" ]]; then
    printf 'link'
  elif [[ -d "$path" ]]; then
    printf 'dir'
  elif [[ -e "$path" ]]; then
    printf 'file'
  else
    printf 'missing'
  fi
}

remove_path() {
  local path="$1"

  if [[ -L "$path" || -f "$path" ]]; then
    rm -f "$path"
    return 0
  fi
  if [[ -d "$path" ]]; then
    rm -rf "$path"
  fi
}

copy_roots_tsv() {
  if [[ -d "$MIGRATE_CURRENT_WORKDIR" && "$MIGRATE_CURRENT_WORKDIR" != "$MIGRATE_TARGET_HOME" ]]; then
    printf 'workdir\t%s\n' "$MIGRATE_CURRENT_WORKDIR"
  fi

  if [[ -n "$MIGRATE_EXPLICIT_PROFILE_HOME" && "$MIGRATE_EXPLICIT_PROFILE_HOME" != "$MIGRATE_CURRENT_WORKDIR" && "$MIGRATE_EXPLICIT_PROFILE_HOME" != "$MIGRATE_TARGET_HOME" && -d "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    printf 'profile_home\t%s\n' "$MIGRATE_EXPLICIT_PROFILE_HOME"
  fi
}

write_backup_manifest() {
  local backup_root="$1"
  local stamp="$2"

  mkdir -p "$backup_root"
  cat >"$backup_root/manifest.txt" <<EOF
agent=$MIGRATE_AGENT
timestamp=$stamp
current_workdir=$MIGRATE_CURRENT_WORKDIR
current_profile_home=$MIGRATE_EFFECTIVE_PROFILE_HOME
target_home=$MIGRATE_TARGET_HOME
status=$MIGRATE_STATUS
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
  resolve_workspace_context "$agent"

  printf 'agent: %s\n' "$MIGRATE_AGENT"
  printf 'engine: %s\n' "$(bridge_agent_engine "$agent")"
  printf 'status: %s\n' "$MIGRATE_STATUS"
  printf 'current_workdir: %s\n' "$MIGRATE_CURRENT_WORKDIR"
  printf 'current_profile_home: %s\n' "$MIGRATE_EFFECTIVE_PROFILE_HOME"
  printf 'target_home: %s\n' "$MIGRATE_TARGET_HOME"
  printf 'target_profile_home: %s\n' "$MIGRATE_TARGET_HOME"
  printf '\n'

  printf 'recommended_roster_changes:\n'
  if [[ "$MIGRATE_CURRENT_WORKDIR" == "$MIGRATE_TARGET_HOME" ]]; then
    printf '  - workdir already points at the standard home\n'
  else
    printf '  - BRIDGE_AGENT_WORKDIR["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s"\n' "$agent" "$agent"
  fi
  if [[ -z "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    printf '  - BRIDGE_AGENT_PROFILE_HOME["%s"] is not set; default already resolves to target\n' "$agent"
  elif [[ "$MIGRATE_EXPLICIT_PROFILE_HOME" == "$MIGRATE_TARGET_HOME" ]]; then
    printf '  - unset '\''BRIDGE_AGENT_PROFILE_HOME[%s]'\'' to use the default standard home\n' "$agent"
  else
    printf '  - BRIDGE_AGENT_PROFILE_HOME["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s" or unset the override after cutover\n' "$agent" "$agent"
  fi
  printf '\n'

  printf 'copy_sources:\n'
  if [[ -d "$MIGRATE_CURRENT_WORKDIR" ]]; then
    printf '  - workdir: %s\n' "$MIGRATE_CURRENT_WORKDIR"
  else
    printf '  - workdir: %s (missing)\n' "$MIGRATE_CURRENT_WORKDIR"
  fi
  if [[ -n "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    if [[ "$MIGRATE_EXPLICIT_PROFILE_HOME" == "$MIGRATE_CURRENT_WORKDIR" ]]; then
      printf '  - profile home is the same path as workdir\n'
    elif [[ -d "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
      printf '  - profile_home: %s\n' "$MIGRATE_EXPLICIT_PROFILE_HOME"
    else
      printf '  - profile_home: %s (missing)\n' "$MIGRATE_EXPLICIT_PROFILE_HOME"
    fi
  else
    printf '  - profile_home: (default target; no separate legacy override)\n'
  fi
  printf '\n'

  if [[ -d "$MIGRATE_CURRENT_WORKDIR" ]]; then
    printf 'workdir_inventory: %s\n' "$MIGRATE_CURRENT_WORKDIR"
    print_entry_group "$MIGRATE_CURRENT_WORKDIR" "preserve:" "preserve"
    print_entry_group "$MIGRATE_CURRENT_WORKDIR" "live_only:" "live_only"
    print_entry_group "$MIGRATE_CURRENT_WORKDIR" "other:" "other"
    printf '\n'
  fi

  if [[ -n "$MIGRATE_EXPLICIT_PROFILE_HOME" && "$MIGRATE_EXPLICIT_PROFILE_HOME" != "$MIGRATE_CURRENT_WORKDIR" && -d "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    printf 'profile_inventory: %s\n' "$MIGRATE_EXPLICIT_PROFILE_HOME"
    print_entry_group "$MIGRATE_EXPLICIT_PROFILE_HOME" "preserve:" "preserve"
    print_entry_group "$MIGRATE_EXPLICIT_PROFILE_HOME" "live_only:" "live_only"
    print_entry_group "$MIGRATE_EXPLICIT_PROFILE_HOME" "other:" "other"
    printf '\n'
  fi

  printf 'next_steps:\n'
  printf '  1. review this plan and confirm the target root is correct\n'
  printf '  2. copy live-home files into %s without deleting the source\n' "$MIGRATE_TARGET_HOME"
  printf '  3. switch roster paths to the standard home\n'
  printf '  4. deploy tracked profile material into the new live home\n'
}

copy_one_entry() {
  local source_root="$1"
  local name="$2"
  local target_root="$3"
  local backup_root="$4"
  local dry_run="$5"
  local src="$source_root/$name"
  local dst="$target_root/$name"
  local backup_path="$backup_root/target-before/$name"
  local src_kind=""
  local dst_kind=""

  [[ -e "$src" || -L "$src" ]] || return 0

  src_kind="$(path_kind "$src")"
  dst_kind="$(path_kind "$dst")"

  if [[ "$dry_run" == "1" ]]; then
    if [[ "$dst_kind" != "missing" ]]; then
      printf '  - backup existing %s -> %s\n' "$dst" "$backup_path"
    fi
    if [[ "$src_kind" == "dir" ]]; then
      printf '  - merge %s/. -> %s/\n' "$src" "$dst"
    else
      printf '  - copy %s -> %s\n' "$src" "$dst"
    fi
    return 0
  fi

  mkdir -p "$target_root" "$backup_root/target-before"
  if [[ "$dst_kind" != "missing" && ! -e "$backup_path" && ! -L "$backup_path" ]]; then
    mkdir -p "$(dirname "$backup_path")"
    cp -RP "$dst" "$backup_path"
  fi

  if [[ "$src_kind" == "dir" ]]; then
    if [[ "$dst_kind" != "missing" && "$dst_kind" != "dir" ]]; then
      remove_path "$dst"
    fi
    mkdir -p "$dst"
    cp -RP "$src/." "$dst/"
    return 0
  fi

  if [[ "$dst_kind" == "dir" ]]; then
    remove_path "$dst"
  fi
  mkdir -p "$(dirname "$dst")"
  cp -RP "$src" "$dst"
}

cmd_workspace_copy() {
  local agent="$1"
  local dry_run="${2:-0}"
  local stamp=""
  local backup_root=""
  local label=""
  local source_root=""
  local copied_count=0
  local seen_any=0
  local name=""

  resolve_workspace_context "$agent"

  stamp="$(date '+%Y%m%d-%H%M%S')"
  backup_root="$(backup_root_for "$agent" "$stamp")"

  printf 'agent: %s\n' "$MIGRATE_AGENT"
  printf 'mode: %s\n' "$([[ "$dry_run" == "1" ]] && printf 'dry-run' || printf 'copy')"
  printf 'status: %s\n' "$MIGRATE_STATUS"
  printf 'target_home: %s\n' "$MIGRATE_TARGET_HOME"
  printf 'backup_root: %s\n' "$backup_root"
  printf 'source_deleted: no\n'
  printf '\n'

  while IFS=$'\t' read -r label source_root; do
    [[ -n "$label" && -n "$source_root" ]] || continue
    seen_any=1
    printf 'source[%s]: %s\n' "$label" "$source_root"
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      copy_one_entry "$source_root" "$name" "$MIGRATE_TARGET_HOME" "$backup_root" "$dry_run"
      copied_count=$((copied_count + 1))
    done < <(list_top_level_entries "$source_root")
    printf '\n'
  done < <(copy_roots_tsv)

  if [[ $seen_any -eq 0 ]]; then
    printf 'actions:\n'
    printf '  - no legacy source directories need copying\n'
    return 0
  fi

  if [[ "$dry_run" == "0" ]]; then
    write_backup_manifest "$backup_root" "$stamp"
  fi

  printf 'summary:\n'
  printf '  - top_level_entries: %s\n' "$copied_count"
  if [[ "$dry_run" == "1" ]]; then
    printf '  - dry-run only; target was not modified\n'
  else
    printf '  - backup manifest: %s/manifest.txt\n' "$backup_root"
  fi
}

cmd_workspace_cutover() {
  local agent="$1"
  local dry_run="${2:-0}"
  local session=""
  local active="no"

  resolve_workspace_context "$agent"

  if [[ "$dry_run" != "1" ]]; then
    bridge_die "actual cutover is not implemented yet. Use --dry-run."
  fi

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi

  printf 'agent: %s\n' "$MIGRATE_AGENT"
  printf 'mode: dry-run\n'
  printf 'engine: %s\n' "$(bridge_agent_engine "$agent")"
  printf 'session: %s\n' "$session"
  printf 'active: %s\n' "$active"
  printf 'current_workdir: %s\n' "$MIGRATE_CURRENT_WORKDIR"
  printf 'current_profile_home: %s\n' "$MIGRATE_EFFECTIVE_PROFILE_HOME"
  printf 'target_home: %s\n' "$MIGRATE_TARGET_HOME"
  printf '\n'

  printf 'cutover_steps:\n'
  printf '  1. inspect: agent-bridge migrate workspace plan %s\n' "$agent"
  printf '  2. stage data: agent-bridge migrate workspace copy %s\n' "$agent"
  if [[ "$MIGRATE_CURRENT_WORKDIR" == "$MIGRATE_TARGET_HOME" ]]; then
    printf '  3. roster workdir: already at standard home\n'
  else
    printf '  3. roster workdir: set BRIDGE_AGENT_WORKDIR["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s"\n' "$agent" "$agent"
  fi
  if [[ -z "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    printf '  4. roster profile: no explicit override today; keep default or set BRIDGE_AGENT_PROFILE_HOME["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s"\n' "$agent" "$agent"
  elif [[ "$MIGRATE_EXPLICIT_PROFILE_HOME" == "$MIGRATE_TARGET_HOME" ]]; then
    printf '  4. roster profile: already points at standard home; optional cleanup is unset BRIDGE_AGENT_PROFILE_HOME["%s"]\n' "$agent"
  else
    printf '  4. roster profile: set BRIDGE_AGENT_PROFILE_HOME["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s" or unset after cutover\n' "$agent" "$agent"
  fi
  printf '  5. deploy tracked profile: agent-bridge profile deploy %s\n' "$agent"
  printf '  6. restart session: bash %s/bridge-start.sh %s --replace\n' "$BRIDGE_HOME" "$agent"
  printf '  7. sync daemon: bash %s/bridge-daemon.sh sync\n' "$BRIDGE_HOME"
  printf '\n'

  printf 'rollback:\n'
  printf '  - restore BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$MIGRATE_CURRENT_WORKDIR"
  if [[ -n "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    printf '  - restore BRIDGE_AGENT_PROFILE_HOME["%s"]="%s"\n' "$agent" "$MIGRATE_EXPLICIT_PROFILE_HOME"
  else
    printf '  - remove any BRIDGE_AGENT_PROFILE_HOME["%s"] override that was added during cutover\n' "$agent"
  fi
  printf '  - restart from legacy path: bash %s/bridge-start.sh %s --replace\n' "$BRIDGE_HOME" "$agent"
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  runtime)
    action="${1:-}"
    shift || true
    case "$action" in
      inventory)
        run_runtime_helper "$@"
        ;;
      ""|-h|--help|help)
        usage
        ;;
      *)
        bridge_die "지원하지 않는 migrate runtime 명령입니다: $action"
        ;;
    esac
    ;;
  docs)
    action="${1:-}"
    shift || true
    case "$action" in
      audit|apply)
        run_docs_helper "$action" "$@"
        ;;
      ""|-h|--help|help)
        usage
        ;;
      *)
        bridge_die "지원하지 않는 migrate docs 명령입니다: $action"
        ;;
    esac
    ;;
  workspace)
    case "${1:-}" in
      plan)
        shift
        [[ $# -eq 1 ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-migrate.sh workspace plan <agent>"
        cmd_workspace_plan "$1"
        ;;
      copy)
        shift
        dry_run=0
        agent=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dry-run)
              dry_run=1
              shift
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
        [[ -n "$agent" ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-migrate.sh workspace copy <agent> [--dry-run]"
        cmd_workspace_copy "$agent" "$dry_run"
        ;;
      cutover)
        shift
        dry_run=0
        agent=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dry-run)
              dry_run=1
              shift
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
        [[ -n "$agent" ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-migrate.sh workspace cutover <agent> --dry-run"
        cmd_workspace_cutover "$agent" "$dry_run"
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
