#!/usr/bin/env bash

set -euo pipefail

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.agent-bridge}"
LOG_FILE="$BRIDGE_HOME/logs/legacy-a2a-bridge.log"
mkdir -p "$(dirname "$LOG_FILE")"
printf '[%s] shopify-a2a-bridge deprecated; queue-based A2A is the source of truth\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >>"$LOG_FILE"
