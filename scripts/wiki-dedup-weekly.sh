#!/usr/bin/env bash
# wiki-dedup-weekly — run dedup-scan, auto-apply the *safe* subset
# (same-stem cluster with 2 paths, same basename, same parent-dir semantics),
# and raise a [wiki-dedup-review] task for anything ambiguous.
#
# Relies on `bridge-wiki dedup-apply --auto-safe` (see
# `stream-a/bridge-wiki.py.diff` for the upstream patch).
# If `--auto-safe` is not yet available in the installed bridge-wiki.py,
# this script falls back to dedup-scan + review-task only (no apply).
#
# Cron: Sunday 04:00 KST ("cron 0 4 * * 0 Asia/Seoul").

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"

JOB="wiki-dedup-weekly"
LOG="$(audit_path "$JOB")"
log_audit "$JOB" "starting $JOB" >/dev/null

trap 'file_failure_task "$JOB" "$LOG"' ERR

PLAN_DIR="$BRIDGE_STATE_ROOT/wiki-dedup"
mkdir -p "$PLAN_DIR"
PLAN_FILE="$PLAN_DIR/plan-$(abs_date).json"

# 1) scan
if ! run_with_timeout 300 "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-wiki.py" dedup-scan \
      --shared-root "$BRIDGE_SHARED_ROOT" \
      --output "$PLAN_FILE" \
      >>"$LOG" 2>&1; then
  rc=$?
  log_audit "$JOB" "dedup-scan FAILED rc=$rc" >/dev/null
  file_failure_task "$JOB" "$LOG"
  exit 1
fi
log_audit "$JOB" "scan written: $PLAN_FILE" >/dev/null

# 2) auto-safe apply — only runs if the installed bridge-wiki.py supports it.
auto_safe_supported=0
if "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-wiki.py" dedup-apply --help 2>&1 | grep -q -- '--auto-safe'; then
  auto_safe_supported=1
fi

applied=0
if (( auto_safe_supported == 1 )); then
  if run_with_timeout 300 "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-wiki.py" dedup-apply \
        --shared-root "$BRIDGE_SHARED_ROOT" \
        --plan "$PLAN_FILE" \
        --auto-safe \
        --json \
        >>"$LOG" 2>&1; then
    applied=1
    log_audit "$JOB" "dedup-apply --auto-safe OK" >/dev/null
  else
    rc=$?
    log_audit "$JOB" "dedup-apply --auto-safe FAILED rc=$rc (continuing to review task)" >/dev/null
  fi
else
  log_audit "$JOB" "dedup-apply --auto-safe NOT YET INSTALLED — scan-only mode" >/dev/null
fi

# 3) raise a review task for ambiguous clusters (candidate_count > 0 always
# benefits from human/LLM review regardless of what was auto-applied).
cand_count=$("$BRIDGE_PYTHON" - "$PLAN_FILE" <<'PY'
import json, sys
try:
    data = json.loads(open(sys.argv[1], encoding="utf-8").read())
    print(int(data.get("candidate_count") or 0))
except Exception:
    print(0)
PY
)
log_audit "$JOB" "ambiguous clusters (pre-filter): $cand_count auto_safe_applied=$applied" >/dev/null

if [[ "$cand_count" -gt 0 ]]; then
  title="[wiki-dedup-review] $cand_count dup clusters — $(abs_date)"
  "$BRIDGE_AGB" task create --to patch --priority normal --from patch \
    --title "$title" \
    --body-file "$PLAN_FILE" >/dev/null 2>&1 || true
fi

log_audit "$JOB" "done" >/dev/null
exit 0
