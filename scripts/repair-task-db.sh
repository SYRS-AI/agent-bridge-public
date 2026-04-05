#!/usr/bin/env bash

set -euo pipefail

SOURCE_DB="${HOME}/agent-bridge/state/tasks.db"
TARGET_DB="${HOME}/.agent-bridge/state/tasks.db"
DAEMON_HOME="${HOME}/.agent-bridge"
RESTART_DAEMON=0
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--source <db>] [--target <db>] [--daemon-home <dir>] [--restart-daemon] [--dry-run]

Safely replaces the target Agent Bridge task DB with a backup from the source DB.
The current target DB is backed up first as:
  <target>.bak-YYYYMMDD-HHMMSS

Use this only when you have confirmed that the source DB is the canonical runtime history.
EOF
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || { echo "--source requires a path" >&2; exit 1; }
      SOURCE_DB="$2"
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || { echo "--target requires a path" >&2; exit 1; }
      TARGET_DB="$2"
      shift 2
      ;;
    --daemon-home)
      [[ $# -ge 2 ]] || { echo "--daemon-home requires a path" >&2; exit 1; }
      DAEMON_HOME="$2"
      shift 2
      ;;
    --restart-daemon)
      RESTART_DAEMON=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

SOURCE_DB="$(python3 - "$SOURCE_DB" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).expanduser().resolve())
PY
)"
TARGET_DB="$(python3 - "$TARGET_DB" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]).expanduser()
if path.parent.exists():
    parent = path.parent.resolve()
else:
    parent = path.parent
print(parent / path.name)
PY
)"

[[ -f "$SOURCE_DB" ]] || { echo "[error] source DB not found: $SOURCE_DB" >&2; exit 1; }
mkdir -p "$(dirname "$TARGET_DB")"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TARGET_BACKUP="${TARGET_DB}.bak-${TIMESTAMP}"
RESTORE_TMP="${TARGET_DB}.restore-${TIMESTAMP}"
SOURCE_BACKUP="${SOURCE_DB}.snapshot-${TIMESTAMP}"

if [[ "$RESTART_DAEMON" == "1" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] bash %s/bridge-daemon.sh stop\n' "$DAEMON_HOME"
  else
    bash "$DAEMON_HOME/bridge-daemon.sh" stop >/dev/null 2>&1 || true
  fi
fi

if [[ -f "$TARGET_DB" ]]; then
  run_cmd sqlite3 "$TARGET_DB" ".backup '$TARGET_BACKUP'"
fi
run_cmd sqlite3 "$SOURCE_DB" ".backup '$SOURCE_BACKUP'"
run_cmd sqlite3 "$SOURCE_DB" ".backup '$RESTORE_TMP'"
if [[ "$DRY_RUN" == "0" ]]; then
  mv "$RESTORE_TMP" "$TARGET_DB"
  rm -f "${TARGET_DB}-wal" "${TARGET_DB}-shm"
fi

if [[ "$RESTART_DAEMON" == "1" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] bash %s/bridge-daemon.sh ensure\n' "$DAEMON_HOME"
  else
    bash "$DAEMON_HOME/bridge-daemon.sh" ensure >/dev/null
  fi
fi

printf 'source_db: %s\n' "$SOURCE_DB"
printf 'target_db: %s\n' "$TARGET_DB"
printf 'source_snapshot: %s\n' "$SOURCE_BACKUP"
if [[ -f "$TARGET_BACKUP" || "$DRY_RUN" == "1" ]]; then
  printf 'target_backup: %s\n' "$TARGET_BACKUP"
fi
printf 'daemon_restarted: %s\n' "$([[ "$RESTART_DAEMON" == "1" ]] && printf yes || printf no)"
