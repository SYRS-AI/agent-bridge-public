#!/usr/bin/env bash
# wiki-hub-audit — weekly L2 candidacy sweep.
#
# Reads shared/wiki/_index/mentions.db, identifies entities with
# cross-agent reach but no shared canonical hub, writes a human-readable
# candidate report to shared/wiki/_audit/hub-candidates-<date>.md, and
# emits a [wiki-hub-candidates] task for the admin agent.
#
# Cron: "cron 0 23 * * 4 Asia/Seoul" (every Thursday 23:00 KST).
# This gives the admin a full workday Friday and the weekend to review
# and author hubs before the Sunday weekly rollup reflects new content.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"

# Admin agent resolves from env (default: patch). Per-install operators
# that renamed the admin role set BRIDGE_ADMIN_AGENT in the roster or
# at cron-creation time.
: "${BRIDGE_ADMIN_AGENT:=patch}"

JOB="wiki-hub-audit"
LOG="$(audit_path "$JOB")"
log_audit "$JOB" "starting $JOB" >/dev/null

REPORT_PATH="$BRIDGE_WIKI_ROOT/_audit/hub-candidates-$(abs_date).md"

# Capture the underlying Python exit code directly. `if ! cmd; then rc=$?; fi`
# is unsafe here because the `!` inversion resets `$?` to 0 inside the
# then-branch, masking a non-zero emit-task failure (exit 3). We also
# intentionally do NOT install an ERR trap here — the combination of an
# ERR trap + an explicit "if rc != 0" block fires `file_failure_task`
# twice on the same failure (noted in Codex R3). The explicit block is
# the only path that surfaces a failure to patch.
set +e
run_with_timeout 120 "$BRIDGE_PYTHON" "$HERE/wiki-hub-audit.py" \
  --wiki-root "$BRIDGE_WIKI_ROOT" \
  --emit-task \
  --admin-agent "$BRIDGE_ADMIN_AGENT" \
  --bridge-bin "$BRIDGE_AGB" \
  --out "$REPORT_PATH" \
  >>"$LOG" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  log_audit "$JOB" "wiki-hub-audit.py FAILED rc=$rc" >/dev/null
  file_failure_task "$JOB" "$LOG"
  exit "$rc"
fi

trap - ERR
log_audit "$JOB" "finished $JOB report=$REPORT_PATH" >/dev/null
