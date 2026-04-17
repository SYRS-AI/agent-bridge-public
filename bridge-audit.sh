#!/usr/bin/env bash
# bridge-audit.sh — query Agent Bridge audit logs

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster
bridge_require_python

mode="list"
if [[ $# -gt 0 ]]; then
  case "$1" in
    list|follow|verify)
      mode="$1"
      shift
      ;;
  esac
fi

agent=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      [[ $# -lt 2 ]] && bridge_die "--agent 뒤에 agent를 지정하세요."
      agent="$2"
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

files=("$BRIDGE_HOME/logs/audit.jsonl")
if [[ -n "$agent" ]]; then
  files+=("$(bridge_agent_audit_log_file "$agent")")
else
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    files+=("$candidate")
  done < <(find "$BRIDGE_HOME/logs/agents" -type f -name audit.jsonl 2>/dev/null | LC_ALL=C sort)
fi

cmd=(python3 "$SCRIPT_DIR/bridge-audit.py" "$mode")
for file in "${files[@]}"; do
  cmd+=(--file "$file")
done
cmd+=("${args[@]}")
exec "${cmd[@]}"
