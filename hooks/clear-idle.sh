#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BRIDGE_HOME="${BRIDGE_HOME:-$(cd -P "$SCRIPT_DIR/.." && pwd -P)}"
export BRIDGE_HOME
# shellcheck source=/dev/null
source "$BRIDGE_HOME/bridge-lib.sh"

AGENT_ID="${BRIDGE_AGENT_ID:-${1:-}}"
[[ -n "$AGENT_ID" ]] || exit 0

bridge_agent_clear_idle_marker "$AGENT_ID"
