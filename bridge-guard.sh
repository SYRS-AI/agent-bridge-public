#!/usr/bin/env bash
# bridge-guard.sh — prompt guard CLI wrapper

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") status [--agent <agent>] [--surface <name>] [--json]
  $(basename "$0") scan [--agent <agent>] [--surface <name>] [--threshold <severity>] [--json|--shell] [text]
  $(basename "$0") sanitize [--agent <agent>] [--surface <name>] [--json|--shell] [text]
EOF
}

bridge_require_python
exec python3 "$SCRIPT_DIR/bridge-guard.py" "$@"
