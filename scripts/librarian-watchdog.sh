#!/bin/bash
# librarian-watchdog.sh — patch-owned cron (every 10 min).
#
# Wakes the dynamic `librarian` agent ONLY when there's work. Mac mini 8GB
# constraint: librarian must not idle in memory.
#
# Decision tree:
#   1. inspect librarian inbox for open [librarian-ingest] tasks
#   2. if none → exit 0 (no-op)
#   3. if ingest queue depth > 50 → create [librarian-overload] task to patch,
#      do NOT start librarian (patch decides)
#   4. if librarian already running (tmux session) → no-op
#   5. else → `agb agent start librarian --no-attach`
#
# Install (patch runs this, not librarian):
#   agb cron create --agent patch --schedule "*/10 * * * *" \
#     --title "librarian-watchdog" \
#     --payload "bash ~/.agent-bridge/scripts/librarian-watchdog.sh"
#
# Safety: no destructive ops. Exits 0 on any expected condition.

set -u

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.agent-bridge}"
BRIDGE_CLI="$BRIDGE_HOME/agent-bridge"
AGB="$BRIDGE_HOME/agb"
AGENT="librarian"
OVERLOAD_THRESHOLD=50
LOG="$BRIDGE_HOME/state/librarian-watchdog.log"

mkdir -p "$(dirname "$LOG")"

log() { printf '%s [watchdog] %s\n' "$(date +%FT%T%z)" "$*" >>"$LOG"; }

# 1. agent exists?
if ! "$BRIDGE_CLI" agent list 2>/dev/null | awk '{print $1}' | grep -qx "$AGENT"; then
  log "librarian not provisioned — skip"
  exit 0
fi

# 2. count open [librarian-ingest] tasks in librarian inbox
# We grep on title prefix. Both `agb inbox librarian` and `agb inbox --all`
# output tab/space-separated rows; parse safely.
INBOX_RAW="$("$AGB" inbox "$AGENT" 2>/dev/null || true)"
INGEST_OPEN="$(printf '%s\n' "$INBOX_RAW" | grep -cE '\[librarian-ingest\]' || true)"
INGEST_OPEN="${INGEST_OPEN:-0}"

if [[ "$INGEST_OPEN" -eq 0 ]]; then
  log "no [librarian-ingest] tasks open — no-op"
  exit 0
fi

# 3. overload guard — create a single [librarian-overload] task to patch, don't
# flood if one already exists (check patch inbox first).
if [[ "$INGEST_OPEN" -gt "$OVERLOAD_THRESHOLD" ]]; then
  PATCH_OPEN_OVERLOAD="$("$AGB" inbox patch 2>/dev/null | grep -cE '\[librarian-overload\]' || true)"
  PATCH_OPEN_OVERLOAD="${PATCH_OPEN_OVERLOAD:-0}"
  if [[ "$PATCH_OPEN_OVERLOAD" -eq 0 ]]; then
    log "overload: $INGEST_OPEN > $OVERLOAD_THRESHOLD, notifying patch"
    "$BRIDGE_CLI" task create --to patch --priority high --from patch \
      --title "[librarian-overload] queue $INGEST_OPEN > $OVERLOAD_THRESHOLD" \
      --body "librarian-watchdog halted start. Investigate wiki-daily-ingest rate or drain manually." \
      >/dev/null 2>&1 || log "failed to create overload task"
  else
    log "overload: $INGEST_OPEN, patch already notified — skip"
  fi
  exit 0
fi

# 4. already running? Check tmux session.
if tmux has-session -t "$AGENT" 2>/dev/null; then
  log "librarian session already running, $INGEST_OPEN ingest task(s) queued"
  exit 0
fi

# 5. start librarian, no-attach (dynamic spawn)
log "starting librarian ($INGEST_OPEN ingest task(s) queued)"
if "$BRIDGE_CLI" agent start "$AGENT" --no-attach >>"$LOG" 2>&1; then
  log "librarian start ok"
else
  log "librarian start FAILED"
  "$BRIDGE_CLI" task create --to patch --priority high --from patch \
    --title "[librarian-stuck] agent start failed" \
    --body "librarian-watchdog could not start librarian. Check $LOG." \
    >/dev/null 2>&1 || true
fi

exit 0
