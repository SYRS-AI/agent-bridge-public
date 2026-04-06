#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BRIDGE_HOME="${BRIDGE_HOME:-$(cd -P "$SCRIPT_DIR/.." && pwd -P)}"
export BRIDGE_HOME
# shellcheck source=/dev/null
source "$BRIDGE_HOME/bridge-lib.sh"

AGENT_ID="${BRIDGE_AGENT_ID:-${1:-}}"
[[ -n "$AGENT_ID" ]] || exit 0

bridge_agent_mark_idle_now "$AGENT_ID"

summary_row="$(bridge_queue_cli summary --agent "$AGENT_ID" --format tsv 2>/dev/null || true)"
[[ -n "$summary_row" ]] || exit 0

IFS=$'\t' read -r _agent queued claimed blocked _active _idle _last_seen _last_nudge _session _engine _workdir <<<"$summary_row"
queued="${queued:-0}"
claimed="${claimed:-0}"
blocked="${blocked:-0}"

[[ "$queued" =~ ^[0-9]+$ ]] || queued=0
[[ "$claimed" =~ ^[0-9]+$ ]] || claimed=0
[[ "$blocked" =~ ^[0-9]+$ ]] || blocked=0

if (( queued == 0 && blocked == 0 )); then
  exit 0
fi

# Show highest-priority task summary + direct agent to process all via inbox
TASK_ID=""
TASK_TITLE=""
TASK_PRIORITY=""
TASK_BODY_PATH=""
open_task_shell="$(bridge_queue_cli find-open --agent "$AGENT_ID" --format shell 2>/dev/null || true)"
if [[ -n "$open_task_shell" ]]; then
  # shellcheck disable=SC1091
  source /dev/stdin <<<"$open_task_shell"
fi

printf '[Agent Bridge] %s pending task(s) for %s.\n' "$queued" "$AGENT_ID"

if [[ -n "$TASK_ID" && -n "$TASK_TITLE" ]]; then
  printf 'Highest priority: Task #%s [%s] %s\n' "$TASK_ID" "${TASK_PRIORITY:-normal}" "$TASK_TITLE"
fi

printf 'Process all pending tasks now: ~/.agent-bridge/agb inbox %s\n' "$AGENT_ID"
