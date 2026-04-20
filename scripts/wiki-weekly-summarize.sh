#!/usr/bin/env bash
# wiki-weekly-summarize — iterate active claude agents, run
# `bridge-memory summarize weekly` for each. Sequential; Mac mini 8GB.
#
# Cron: Sunday 22:00 KST ("cron 0 22 * * 0 Asia/Seoul").

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"

JOB="wiki-weekly-summarize"
LOG="$(audit_path "$JOB")"
log_audit "$JOB" "starting $JOB" >/dev/null

trap 'file_failure_task "$JOB" "$LOG"' ERR

ok=0
fail=0
skipped=0
while IFS=$'\t' read -r agent home; do
  [[ -z "$agent" || -z "$home" ]] && continue
  log_audit "$JOB" "== agent=$agent home=$home ==" >/dev/null
  if [[ ! -d "$home/memory" ]]; then
    log_audit "$JOB" "skip: no memory dir" >/dev/null
    skipped=$((skipped + 1))
    continue
  fi
  if run_with_timeout 600 "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" summarize weekly \
        --agent "$agent" --home "$home" --json \
        >>"$LOG" 2>&1; then
    log_audit "$JOB" "ok: $agent" >/dev/null
    ok=$((ok + 1))
  else
    rc=$?
    log_audit "$JOB" "FAIL($rc): $agent" >/dev/null
    fail=$((fail + 1))
  fi
done < <(list_active_claude_agents)

log_audit "$JOB" "done ok=$ok fail=$fail skipped=$skipped" >/dev/null

# Non-zero exit only when at least one hard failure *and* no successes.
# Per-agent failures alone don't fail the whole cron — they surface via the
# failure task.
if (( fail > 0 && ok == 0 )); then
  file_failure_task "$JOB" "$LOG"
  exit 1
fi
exit 0
