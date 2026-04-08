#!/usr/bin/env bash
# bridge-upgrade.sh — update a live Agent Bridge install from a repo checkout

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

SOURCE_ROOT="$SCRIPT_DIR"
TARGET_ROOT="$HOME/.agent-bridge"
PULL=0
DRY_RUN=0
RESTART_DAEMON=1
JSON=0
ALLOW_DIRTY=0
BACKUP=1
MIGRATE_AGENTS=1

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--source <repo-dir>] [--target <bridge-home>] [--pull] [--restart-daemon|--no-restart-daemon] [--dry-run] [--json] [--allow-dirty] [--no-backup] [--no-migrate-agents]

Updates a live Agent Bridge install from a repo checkout while preserving user-owned
customizations such as:
- agent-roster.local.sh
- state/, logs/, shared/
- backups/, worktrees/
- live agent homes under agents/<agent>/

The repo checkout remains source of truth for core code. Live-only operator changes are preserved.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -lt 2 ]] && bridge_die "--source 뒤에 값을 지정하세요."
      SOURCE_ROOT="$2"
      shift 2
      ;;
    --target)
      [[ $# -lt 2 ]] && bridge_die "--target 뒤에 값을 지정하세요."
      TARGET_ROOT="$2"
      shift 2
      ;;
    --pull)
      PULL=1
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

SOURCE_ROOT="$(cd -P "$SOURCE_ROOT" && pwd -P)"
TARGET_ROOT="$(cd -P "$(dirname "$TARGET_ROOT")" && pwd -P)/$(basename "$TARGET_ROOT")"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_ROOT="$TARGET_ROOT/backups/upgrade-$TIMESTAMP"
ADMIN_AGENT_ID=""
BACKUP_JSON='{}'
MIGRATION_JSON='{}'
DEPLOY_OUTPUT=""

git -C "$SOURCE_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || bridge_die "git repo가 아닙니다: $SOURCE_ROOT"

if [[ $ALLOW_DIRTY -eq 0 && $DRY_RUN -eq 0 ]]; then
  if [[ -n "$(git -C "$SOURCE_ROOT" status --short)" ]]; then
    bridge_die "working tree가 dirty 합니다. 먼저 커밋/정리하거나 --allow-dirty 를 사용하세요."
  fi
fi

if [[ $PULL -eq 1 && $DRY_RUN -eq 0 ]]; then
  git -C "$SOURCE_ROOT" pull --ff-only
fi

deploy_cmd=("$BRIDGE_BASH_BIN" "$SOURCE_ROOT/scripts/deploy-live-install.sh" --target "$TARGET_ROOT")
if [[ $DRY_RUN -eq 1 ]]; then
  deploy_cmd+=(--dry-run)
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

if [[ $BACKUP -eq 1 ]]; then
  BACKUP_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" backup-live --target-root "$TARGET_ROOT" --backup-root "$BACKUP_ROOT" $([[ $DRY_RUN -eq 1 ]] && printf '%s' '--dry-run'))"
fi

DEPLOY_OUTPUT="$("${deploy_cmd[@]}")"

if [[ $MIGRATE_AGENTS -eq 1 ]]; then
  MIGRATION_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" migrate-agents --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT" --admin-agent "$ADMIN_AGENT_ID" $([[ $DRY_RUN -eq 1 ]] && printf '%s' '--dry-run'))"
fi

if [[ $RESTART_DAEMON -eq 1 && $DRY_RUN -eq 0 ]]; then
  bash "$TARGET_ROOT/bridge-daemon.sh" stop >/dev/null 2>&1 || true
  bash "$TARGET_ROOT/bridge-daemon.sh" ensure >/dev/null
fi

if [[ $JSON -eq 1 ]]; then
  python3 - "$SOURCE_ROOT" "$TARGET_ROOT" "$PULL" "$DRY_RUN" "$RESTART_DAEMON" "$BACKUP" "$MIGRATE_AGENTS" "$BACKUP_ROOT" "$BACKUP_JSON" "$MIGRATION_JSON" "$DEPLOY_OUTPUT" <<'PY'
import json, sys
source_root, target_root, pull, dry_run, restart_daemon, backup_enabled, migrate_agents, backup_root, backup_json, migration_json, deploy_output = sys.argv[1:]
backup_payload = json.loads(backup_json)
migration_payload = json.loads(migration_json)
payload = {
    "mode": "upgrade",
    "source_root": source_root,
    "target_root": target_root,
    "pull": pull == "1",
    "dry_run": dry_run == "1",
    "restart_daemon": restart_daemon == "1",
    "backup_enabled": backup_enabled == "1",
    "migrate_agents": migrate_agents == "1",
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
    "agent_migration": migration_payload,
    "deploy_output": deploy_output.splitlines(),
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  exit 0
fi

echo "== Agent Bridge upgrade =="
echo "source_root: $SOURCE_ROOT"
echo "target_root: $TARGET_ROOT"
echo "preserved_customizations: agent-roster.local.sh, state/, logs/, shared/, backups/, worktrees/, agents/<agent>/"
if [[ $BACKUP -eq 1 ]]; then
  echo "backup_root: $BACKUP_ROOT"
  printf '%s' "$BACKUP_JSON" | python3 - <<'PY'
import json, sys
payload = json.load(sys.stdin)
print(f"backup_created: {'yes' if payload.get('created') else 'no'}")
PY
fi
if [[ $MIGRATE_AGENTS -eq 1 ]]; then
  printf '%s' "$MIGRATION_JSON" | python3 - <<'PY'
import json, sys
payload = json.load(sys.stdin)
print(f"agents_migrated: {payload.get('agents_with_additions', 0)}")
print(f"migrated_files: {payload.get('added_files', 0)}")
PY
fi
echo "$DEPLOY_OUTPUT"
