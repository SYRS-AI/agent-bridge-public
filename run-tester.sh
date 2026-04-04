#!/bin/bash
# run-tester.sh — 호환용 래퍼

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$SCRIPT_DIR/bridge-run.sh" tester "$@"
