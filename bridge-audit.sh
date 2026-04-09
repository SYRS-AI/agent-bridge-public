#!/usr/bin/env bash
# bridge-audit.sh — query Agent Bridge audit logs

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster
bridge_require_python

python3 "$SCRIPT_DIR/bridge-audit.py" list --file "$BRIDGE_AUDIT_LOG" "$@"
