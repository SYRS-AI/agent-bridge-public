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

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--source <repo-dir>] [--target <bridge-home>] [--pull] [--restart-daemon|--no-restart-daemon] [--dry-run] [--json] [--allow-dirty]

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
if [[ $RESTART_DAEMON -eq 1 ]]; then
  deploy_cmd+=(--restart-daemon)
fi

deploy_output="$("${deploy_cmd[@]}")"

if [[ $JSON -eq 1 ]]; then
  python3 - "$SOURCE_ROOT" "$TARGET_ROOT" "$PULL" "$DRY_RUN" "$RESTART_DAEMON" "$deploy_output" <<'PY'
import json, sys
source_root, target_root, pull, dry_run, restart_daemon, deploy_output = sys.argv[1:]
payload = {
    "mode": "upgrade",
    "source_root": source_root,
    "target_root": target_root,
    "pull": pull == "1",
    "dry_run": dry_run == "1",
    "restart_daemon": restart_daemon == "1",
    "preserved_paths": [
        "agent-roster.local.sh",
        "state/",
        "logs/",
        "shared/",
        "backups/",
        "worktrees/",
        "agents/<agent>/",
    ],
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
echo "$deploy_output"
