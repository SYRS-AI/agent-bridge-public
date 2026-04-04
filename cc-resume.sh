#!/usr/bin/env bash
# cc-resume.sh — 호환용 래퍼

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: bash ~/agent-bridge/cc-resume.sh <agent> [--wait <seconds>]"
  exit 1
fi

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET="$1"
shift

exec bash "$SCRIPT_DIR/bridge-action.sh" "$TARGET" resume "$@"
