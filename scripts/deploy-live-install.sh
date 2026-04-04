#!/usr/bin/env bash
# Copy the tracked working tree into the live ~/.agent-bridge install.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
TARGET_ROOT="${HOME}/.agent-bridge"
DRY_RUN=0
RESTART_DAEMON=0
COPIED_COUNT=0
VERIFIED_COUNT=0

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--target <dir>] [--dry-run] [--restart-daemon]

Copies every tracked file from the current working tree into the live install.
Target-only files such as agent-roster.local.sh, state/, logs/, and shared/ are preserved.
EOF
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

copy_tracked_file() {
  local relpath="$1"
  local src="$SOURCE_ROOT/$relpath"
  local dst="$TARGET_ROOT/$relpath"

  [[ -f "$src" ]] || return 0

  run_cmd mkdir -p "$(dirname "$dst")"
  run_cmd cp -p "$src" "$dst"
  COPIED_COUNT=$((COPIED_COUNT + 1))
}

verify_tracked_file() {
  local relpath="$1"
  local src="$SOURCE_ROOT/$relpath"
  local dst="$TARGET_ROOT/$relpath"

  [[ -f "$src" ]] || return 0
  [[ -f "$dst" ]] || {
    echo "[error] missing deployed file: $dst" >&2
    exit 1
  }

  if ! cmp -s "$src" "$dst"; then
    echo "[error] deployed file differs: $relpath" >&2
    exit 1
  fi

  VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || {
        echo "--target requires a directory" >&2
        exit 1
      }
      TARGET_ROOT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --restart-daemon)
      RESTART_DAEMON=1
      shift
      ;;
    -h|--help|help)
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

if ! git -C "$SOURCE_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "[error] source root is not a git working tree: $SOURCE_ROOT" >&2
  exit 1
fi

mkdir -p "$TARGET_ROOT"

while IFS= read -r -d '' relpath; do
  copy_tracked_file "$relpath"
done < <(git -C "$SOURCE_ROOT" ls-files -z)

if [[ "$DRY_RUN" == "0" ]]; then
  while IFS= read -r -d '' relpath; do
    verify_tracked_file "$relpath"
  done < <(git -C "$SOURCE_ROOT" ls-files -z)
fi

if [[ "$RESTART_DAEMON" == "1" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] bash %s/bridge-daemon.sh stop\n' "$TARGET_ROOT"
    printf '[dry-run] bash %s/bridge-daemon.sh ensure\n' "$TARGET_ROOT"
  else
    bash "$TARGET_ROOT/bridge-daemon.sh" stop >/dev/null 2>&1 || true
    bash "$TARGET_ROOT/bridge-daemon.sh" ensure >/dev/null
  fi
fi

printf 'source_root: %s\n' "$SOURCE_ROOT"
printf 'target_root: %s\n' "$TARGET_ROOT"
printf 'copied_files: %s\n' "$COPIED_COUNT"
if [[ "$DRY_RUN" == "0" ]]; then
  printf 'verified_files: %s\n' "$VERIFIED_COUNT"
fi
printf 'daemon_restarted: %s\n' "$([[ "$RESTART_DAEMON" == "1" ]] && printf yes || printf no)"

