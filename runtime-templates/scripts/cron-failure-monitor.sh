#!/usr/bin/env bash

set -euo pipefail

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.agent-bridge}"
AGENT_BRIDGE="$BRIDGE_HOME/agent-bridge"
LOG_DIR="$BRIDGE_HOME/logs"
ERR_LOG="$LOG_DIR/gateway.err.log"
STATE_FILE="$LOG_DIR/cron-failure-monitor-state.txt"
COOLDOWN_FILE="$LOG_DIR/cron-failure-cooldown.txt"
COOLDOWN_SECONDS=600

mkdir -p "$LOG_DIR"
[[ -f "$ERR_LOG" ]] || exit 0

if [[ ! -f "$STATE_FILE" ]]; then
  wc -l <"$ERR_LOG" >"$STATE_FILE"
  exit 0
fi

LAST_LINE="$(cat "$STATE_FILE")"
CURRENT_LINE="$(wc -l <"$ERR_LOG" | tr -d ' ')"

if [[ "$CURRENT_LINE" -le "$LAST_LINE" ]]; then
  echo "$CURRENT_LINE" >"$STATE_FILE"
  exit 0
fi

NEW_LINES="$(tail -n +"$((LAST_LINE + 1))" "$ERR_LOG" | head -n "$((CURRENT_LINE - LAST_LINE))")"
CRON_FAILURES="$(printf '%s\n' "$NEW_LINES" | grep 'isError=true' | grep -v 'announce:' | tail -20 || true)"

if [[ -z "$CRON_FAILURES" ]]; then
  echo "$CURRENT_LINE" >"$STATE_FILE"
  exit 0
fi

UNIQUE_RUNS="$(printf '%s\n' "$CRON_FAILURES" | sed 's/.*runId=//' | sed 's/ .*//' | sort | uniq -c | sort -rn)"
NOTIFY_RUNS=""
FAIL_COUNT=0

while IFS= read -r line; do
  COUNT="$(printf '%s\n' "$line" | awk '{print $1}')"
  RUNID="$(printf '%s\n' "$line" | awk '{print $2}')"
  [[ -n "$RUNID" ]] || continue
  if [[ "$COUNT" -lt 3 ]]; then
    continue
  fi
  if [[ -f "$COOLDOWN_FILE" ]] && grep -q "$RUNID" "$COOLDOWN_FILE" 2>/dev/null; then
    continue
  fi

  ERR_MSG="$(printf '%s\n' "$CRON_FAILURES" | grep "$RUNID" | tail -1 | sed 's/.*error=//')"
  NOTIFY_RUNS="${NOTIFY_RUNS}\n- ${RUNID:0:8}... (${COUNT} failures) ${ERR_MSG:0:120}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "$RUNID $(date +%s)" >>"$COOLDOWN_FILE"
done <<<"$UNIQUE_RUNS"

if [[ -f "$COOLDOWN_FILE" ]]; then
  NOW="$(date +%s)"
  TMP="$(mktemp)"
  while IFS= read -r line; do
    TS="$(printf '%s\n' "$line" | awk '{print $2}')"
    if [[ -n "$TS" && "$((NOW - TS))" -lt "$COOLDOWN_SECONDS" ]]; then
      printf '%s\n' "$line" >>"$TMP"
    fi
  done <"$COOLDOWN_FILE"
  mv "$TMP" "$COOLDOWN_FILE"
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  BODY_FILE="$(mktemp)"
  {
    printf 'Recurring cron failures detected: %s\n' "$FAIL_COUNT"
    printf '%b\n' "$NOTIFY_RUNS"
    printf '\nInspect: %s\n' "$ERR_LOG"
  } >"$BODY_FILE"
  "$AGENT_BRIDGE" task create \
    --to huchu \
    --from bridge \
    --priority high \
    --title "[cron-failure] recurring failures detected" \
    --body-file "$BODY_FILE" >/dev/null 2>&1 || true
  rm -f "$BODY_FILE"
fi

echo "$CURRENT_LINE" >"$STATE_FILE"
