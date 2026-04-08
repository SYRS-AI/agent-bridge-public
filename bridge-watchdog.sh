#!/usr/bin/env bash
# bridge-watchdog.sh — scan bridge-owned agent homes for drift and onboarding gaps

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

bridge_require_python
exec python3 "$SCRIPT_DIR/bridge-watchdog.py" "$@"
