#!/usr/bin/env bash
# wiki-hub-audit — weekly L2 candidacy sweep.
#
# Reads shared/wiki/_index/mentions.db, identifies entities with
# cross-agent reach but no shared canonical hub, writes a human-readable
# candidate report to shared/wiki/_audit/hub-candidates-<date>.md, and
# emits a [wiki-hub-candidates] task for the admin agent.
#
# Cron: "cron 0 23 * * 4 Asia/Seoul" (every Thursday 23:00 KST).
# Ths gives the admin a full workday Friday and the weekend to review
# and author hubs before the Sunday weekly rollup reflects new content.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"

JOB="wiki-hub-audit"
LOG="$(audit_path "$JOB")"
log_audit "$JOB" "starting $JOB" >/dev/null

trap 'file_failure_task "$JOB" "$LOG"' ERR

REPORT_PATH="$BRIDGE_WIKI_ROOT/_audit/hub-candidates-$(abs_date).md"

if ! run_with_timeout 120 "$BRIDGE_PYTHON" "$HERE/wiki-hub-audit.py" \
      --wiki-root "$BRIDGE_WIKI_ROOT" \
      --emit-task \
      --admin-agent patch \
      --bridge-bin "$BRIDGE_AGB" \
      --out "$REPORT_PATH" \
      >>"$LOG" 2>&1; then
  rc=$?
  log_audit "$JOB" "wiki-hub-audit.py FAILED rc=$rc" >/dev/null
  file_failure_task "$JOB" "$LOG"
  exit "$rc"
fi

trap - ERR
log_audit "$JOB" "finished $JOB report=$REPORT_PATH" >/dev/null
