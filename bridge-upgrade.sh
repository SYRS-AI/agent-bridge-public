#!/usr/bin/env bash
# bridge-upgrade.sh — update a live Agent Bridge install from a repo checkout

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

SOURCE_ROOT="$SCRIPT_DIR"
TARGET_ROOT="$HOME/.agent-bridge"
SUBCOMMAND="apply"
PULL=0
PULL_EXPLICIT=0
SOURCE_EXPLICIT=0
DRY_RUN=0
RESTART_DAEMON=1
JSON=0
ALLOW_DIRTY=0
STRICT_MERGE=0
BACKUP=1
MIGRATE_AGENTS=1
BACKUP_ROOT=""
ANALYSIS_JSON='{}'

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--source <repo-dir>] [--target <bridge-home>] [--pull|--no-pull] [--restart-daemon|--no-restart-daemon] [--dry-run] [--json] [--allow-dirty] [--strict-merge] [--no-backup] [--no-migrate-agents]
  $(basename "$0") analyze [--source <repo-dir>] [--target <bridge-home>] [--json]
  $(basename "$0") rollback [--target <bridge-home>] [--backup-root <dir>] [--restart-daemon|--no-restart-daemon] [--dry-run] [--json]

Updates a live Agent Bridge install from a repo checkout while preserving user-owned
customizations such as:
- agent-roster.local.sh
- state/, logs/, shared/
- backups/, worktrees/
- live agent homes under agents/<agent>/

The repo checkout remains source of truth for core code. Live-only operator changes are preserved.
When run from an installed live copy without --source, the last recorded source checkout is reused and pulled automatically.
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    analyze|rollback)
      SUBCOMMAND="$1"
      shift
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -lt 2 ]] && bridge_die "--source 뒤에 값을 지정하세요."
      SOURCE_ROOT="$2"
      SOURCE_EXPLICIT=1
      shift 2
      ;;
    --target)
      [[ $# -lt 2 ]] && bridge_die "--target 뒤에 값을 지정하세요."
      TARGET_ROOT="$2"
      shift 2
      ;;
    --backup-root)
      [[ $# -lt 2 ]] && bridge_die "--backup-root 뒤에 값을 지정하세요."
      BACKUP_ROOT="$2"
      shift 2
      ;;
    --pull)
      PULL=1
      PULL_EXPLICIT=1
      shift
      ;;
    --no-pull)
      PULL=0
      PULL_EXPLICIT=1
      shift
      ;;
    --restart-daemon)
      RESTART_DAEMON=1
      shift
      ;;
    --no-restart-daemon)
      RESTART_DAEMON=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --strict-merge)
      STRICT_MERGE=1
      shift
      ;;
    --no-backup)
      BACKUP=0
      shift
      ;;
    --backup)
      BACKUP=1
      shift
      ;;
    --no-migrate-agents)
      MIGRATE_AGENTS=0
      shift
      ;;
    --migrate-agents)
      MIGRATE_AGENTS=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      bridge_die "지원하지 않는 upgrade 옵션입니다: $1"
      ;;
  esac
done

TARGET_ROOT="$(cd -P "$(dirname "$TARGET_ROOT")" && pwd -P)/$(basename "$TARGET_ROOT")"
SOURCE_ROOT="$(cd -P "$SOURCE_ROOT" && pwd -P)"

if [[ $SOURCE_EXPLICIT -eq 0 && "$SOURCE_ROOT" == "$TARGET_ROOT" ]]; then
  RECORDED_SOURCE_ROOT="$(
    python3 - "$TARGET_ROOT/state/upgrade/last-upgrade.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except (FileNotFoundError, json.JSONDecodeError):
    print("")
    raise SystemExit(0)

source = str(payload.get("source_root") or "").strip()
print(source)
PY
  )"
  if [[ -n "$RECORDED_SOURCE_ROOT" && -d "$RECORDED_SOURCE_ROOT/.git" ]]; then
    SOURCE_ROOT="$(cd -P "$RECORDED_SOURCE_ROOT" && pwd -P)"
    if [[ "$SUBCOMMAND" == "apply" && $PULL_EXPLICIT -eq 0 ]]; then
      PULL=1
    fi
  else
    for CANDIDATE_SOURCE_ROOT in \
      "$HOME/agent-bridge-public" \
      "$HOME/agent-bridge"
    do
      if [[ -d "$CANDIDATE_SOURCE_ROOT/.git" ]]; then
        SOURCE_ROOT="$(cd -P "$CANDIDATE_SOURCE_ROOT" && pwd -P)"
        if [[ "$SUBCOMMAND" == "apply" && $PULL_EXPLICIT -eq 0 ]]; then
          PULL=1
        fi
        break
      fi
    done
  fi
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
if [[ -z "$BACKUP_ROOT" && "$SUBCOMMAND" != "rollback" ]]; then
  BACKUP_ROOT="$TARGET_ROOT/backups/upgrade-$TIMESTAMP"
fi
ADMIN_AGENT_ID=""
BACKUP_JSON='{}'
MIGRATION_JSON='{}'
MIGRATION_PREVIEW_JSON='{}'
APPLY_JSON='{}'

if ! git -C "$SOURCE_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  if [[ $SOURCE_EXPLICIT -eq 0 && "$SOURCE_ROOT" == "$TARGET_ROOT" ]]; then
    bridge_die "live install은 git repo가 아니고 source checkout 기록도 없습니다: $TARGET_ROOT
복구: git clone https://github.com/SYRS-AI/agent-bridge-public \"\$HOME/agent-bridge-public\" 후 다시 실행하거나,
명시적으로 실행하세요: $TARGET_ROOT/agent-bridge upgrade --source \"\$HOME/agent-bridge-public\""
  fi
  bridge_die "git repo가 아닙니다: $SOURCE_ROOT"
fi

if [[ "$SUBCOMMAND" == "apply" && $ALLOW_DIRTY -eq 0 && $DRY_RUN -eq 0 ]]; then
  if [[ -n "$(git -C "$SOURCE_ROOT" status --short)" ]]; then
    bridge_die "working tree가 dirty 합니다. 먼저 커밋/정리하거나 --allow-dirty 를 사용하세요."
  fi
fi

if [[ $PULL -eq 1 && $DRY_RUN -eq 0 ]]; then
  git -C "$SOURCE_ROOT" pull --ff-only
fi

ANALYSIS_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" analyze-live --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT")"

if [[ "$SUBCOMMAND" == "analyze" ]]; then
  if [[ $JSON -eq 1 ]]; then
    printf '%s\n' "$ANALYSIS_JSON"
  else
    python3 - "$ANALYSIS_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
counts = payload.get("counts", {})
print("== Agent Bridge upgrade analyze ==")
print(f"source_root: {payload.get('source_root')}")
print(f"target_root: {payload.get('target_root')}")
print(f"base_ref: {payload.get('base_ref') or '-'}")
for key in ("missing_live", "upstream_only", "live_only", "merge_required", "unknown_base_live_diff"):
    print(f"{key}: {counts.get(key, 0)}")
PY
  fi
  exit 0
fi

if [[ "$SUBCOMMAND" == "rollback" ]]; then
  rollback_args=(rollback-live --target-root "$TARGET_ROOT")
  if [[ -n "$BACKUP_ROOT" ]]; then
    rollback_args+=(--backup-root "$BACKUP_ROOT")
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    rollback_args+=(--dry-run)
  fi
  ROLLBACK_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" "${rollback_args[@]}")"
  if [[ $RESTART_DAEMON -eq 1 && $DRY_RUN -eq 0 ]]; then
    bash "$TARGET_ROOT/bridge-daemon.sh" stop >/dev/null 2>&1 || true
    bash "$TARGET_ROOT/bridge-daemon.sh" ensure >/dev/null
  fi
  if [[ $JSON -eq 1 ]]; then
    printf '%s\n' "$ROLLBACK_JSON"
  else
    python3 - "$ROLLBACK_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print("== Agent Bridge rollback ==")
print(f"target_root: {payload.get('target_root')}")
print(f"backup_root: {payload.get('backup_root')}")
print(f"restored: {'yes' if payload.get('restored') else 'no'}")
print(f"removed_entries: {payload.get('removed_entries', 0)}")
PY
  fi
  exit 0
fi

if [[ -f "$TARGET_ROOT/agent-roster.local.sh" ]]; then
  if ADMIN_AGENT_ID="$("$BRIDGE_BASH_BIN" -lc '
    set -euo pipefail
    export BRIDGE_HOME="$1"
    source "$2/bridge-lib.sh"
    bridge_load_roster
    printf "%s" "${BRIDGE_ADMIN_AGENT_ID:-}"
  ' -- "$TARGET_ROOT" "$SOURCE_ROOT" 2>/dev/null)"; then
    :
  else
    ADMIN_AGENT_ID=""
  fi
fi

if [[ $MIGRATE_AGENTS -eq 1 ]]; then
  MIGRATION_PREVIEW_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" migrate-agents --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT" --admin-agent "$ADMIN_AGENT_ID" --dry-run)"
fi

if [[ $BACKUP -eq 1 ]]; then
  backup_args=(backup-live --target-root "$TARGET_ROOT" --backup-root "$BACKUP_ROOT" --source-root "$SOURCE_ROOT")
  if [[ "$ANALYSIS_JSON" != "{}" ]]; then
    backup_args+=(--analysis-json "$ANALYSIS_JSON")
  fi
  if [[ "$MIGRATION_PREVIEW_JSON" != "{}" ]]; then
    backup_args+=(--migration-json "$MIGRATION_PREVIEW_JSON")
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    backup_args+=(--dry-run)
  fi
  BACKUP_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" "${backup_args[@]}")"
fi

BASE_REF="$(python3 - "$ANALYSIS_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(payload.get("base_ref", ""))
PY
)"

apply_args=(apply-live --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT")
if [[ -n "$BASE_REF" ]]; then
  apply_args+=(--base-ref "$BASE_REF")
fi
if [[ $DRY_RUN -eq 1 ]]; then
  apply_args+=(--dry-run)
fi
if [[ $STRICT_MERGE -eq 1 ]]; then
  apply_args+=(--strict-merge)
fi
APPLY_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" "${apply_args[@]}")"

if [[ $MIGRATE_AGENTS -eq 1 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    MIGRATION_JSON="$MIGRATION_PREVIEW_JSON"
  else
    MIGRATION_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" migrate-agents --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT" --admin-agent "$ADMIN_AGENT_ID")"
  fi
  "$BRIDGE_BASH_BIN" -lc '
    set -euo pipefail
    export BRIDGE_HOME="$1"
    source "$2/bridge-lib.sh"
    bridge_load_roster
    dry_run="$3"
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
      bridge_sync_claude_runtime_skills "$agent" "$(bridge_agent_workdir "$agent")" "$dry_run" >/dev/null 2>&1 || true
    done
  ' -- "$TARGET_ROOT" "$SOURCE_ROOT" "$DRY_RUN"
fi

if [[ $RESTART_DAEMON -eq 1 && $DRY_RUN -eq 0 ]]; then
  bash "$TARGET_ROOT/bridge-daemon.sh" stop >/dev/null 2>&1 || true
  bash "$TARGET_ROOT/bridge-daemon.sh" ensure >/dev/null
fi

if [[ $DRY_RUN -eq 0 ]]; then
  python3 "$SOURCE_ROOT/bridge-upgrade.py" write-state --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT" --backup-root "$BACKUP_ROOT" --analysis-json "$ANALYSIS_JSON" >/dev/null
fi

if [[ $JSON -eq 1 ]]; then
  python3 - "$SOURCE_ROOT" "$TARGET_ROOT" "$PULL" "$DRY_RUN" "$RESTART_DAEMON" "$BACKUP" "$MIGRATE_AGENTS" "$BACKUP_ROOT" "$BACKUP_JSON" "$MIGRATION_JSON" "$APPLY_JSON" "$ANALYSIS_JSON" "$STRICT_MERGE" <<'PY'
import json, sys
source_root, target_root, pull, dry_run, restart_daemon, backup_enabled, migrate_agents, backup_root, backup_json, migration_json, apply_json, analysis_json, strict_merge = sys.argv[1:]
backup_payload = json.loads(backup_json)
migration_payload = json.loads(migration_json)
apply_payload = json.loads(apply_json)
analysis_payload = json.loads(analysis_json)
payload = {
    "mode": "upgrade",
    "source_root": source_root,
    "target_root": target_root,
    "pull": pull == "1",
    "dry_run": dry_run == "1",
    "restart_daemon": restart_daemon == "1",
    "backup_enabled": backup_enabled == "1",
    "migrate_agents": migrate_agents == "1",
    "strict_merge": strict_merge == "1",
    "backup_root": backup_root,
    "preserved_paths": [
        "agent-roster.local.sh",
        "state/",
        "logs/",
        "shared/",
        "backups/",
        "worktrees/",
        "agents/<agent>/",
    ],
    "backup": backup_payload,
    "apply": apply_payload,
    "analysis": analysis_payload,
    "agent_migration": migration_payload,
  }
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  exit 0
fi

echo "== Agent Bridge upgrade =="
echo "source_root: $SOURCE_ROOT"
echo "target_root: $TARGET_ROOT"
echo "preserved_customizations: agent-roster.local.sh, state/, logs/, shared/, backups/, worktrees/, agents/<agent>/"
echo "strict_merge: $([[ $STRICT_MERGE -eq 1 ]] && printf yes || printf no)"
if [[ $BACKUP -eq 1 ]]; then
  echo "backup_root: $BACKUP_ROOT"
  python3 - "$BACKUP_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(f"backup_created: {'yes' if payload.get('created') else 'no'}")
PY
fi
python3 - "$ANALYSIS_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
counts = payload.get("counts", {})
print(f"analysis_base_ref: {payload.get('base_ref') or '-'}")
print(f"analysis_missing_live: {counts.get('missing_live', 0)}")
print(f"analysis_upstream_only: {counts.get('upstream_only', 0)}")
print(f"analysis_live_only: {counts.get('live_only', 0)}")
print(f"analysis_merge_required: {counts.get('merge_required', 0)}")
print(f"analysis_unknown_base_live_diff: {counts.get('unknown_base_live_diff', 0)}")
PY
python3 - "$APPLY_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
counts = payload.get("counts", {})
print(f"files_copied: {counts.get('files_copied', 0)}")
print(f"files_merged_clean: {counts.get('files_merged_clean', 0)}")
print(f"files_merged_conflict: {counts.get('files_merged_conflict', 0)}")
print(f"files_preserved_live: {counts.get('files_preserved_live', 0)}")
PY
if [[ $MIGRATE_AGENTS -eq 1 ]]; then
  python3 - "$MIGRATION_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(f"agents_migrated: {payload.get('agents_with_additions', 0)}")
print(f"migrated_files: {payload.get('added_files', 0)}")
PY
fi
