#!/usr/bin/env bash
# wiki-daily-ingest smoke — isolated BRIDGE_HOME proof that the Lane A
# watermark closes the strand-recovery gap from issue #321.
#
# What this asserts:
#
#   1. First-ever run (no watermark) — falls through to the YESTERDAY
#      default, copies notes within the 2-day window, and writes the
#      watermark file containing today's --until date.
#
#   2. Strand recovery — a daily note authored *after* a previous Lane A
#      run, dated within the last 14 days, is picked up by the next run
#      because the persisted watermark is used as --since instead of
#      "yesterday". This is the bug #321 was filed for.
#
#   3. wiki-daily-copy.py idempotency — re-running with overlapping
#      --since/--until does not re-copy an unchanged source. Hash-based
#      skip path stays correct under multi-day windows.
#
#   4. 14-day clamp — a stale watermark older than 14 days does not cause
#      an unbounded backfill. Effective --since is the floor, not the
#      stale watermark. Notes outside the floor are intentionally not
#      recovered (matches the documented contract).
#
#   5. Lane A failure does not advance the watermark — when Lane A reports
#      a non-zero error count the previous watermark stays, so the next
#      run retries the same window.
#
# Lane B (librarian-ingest task creation) is intentionally not exercised
# here — it requires a real $BRIDGE_AGB binary. We populate only daily
# notes under memory/, so the find(1) over research/projects/shared/
# decisions returns zero and Lane B is a no-op. That matches the issue
# scope (Lane A is the watermark consumer).
#
# Usage:   ./tests/wiki-daily-ingest/smoke.sh
# Exit 0 if every scenario PASSes; exit 1 otherwise.

set -uo pipefail
# Note: -e (errexit) intentionally NOT set. The PASS/FAIL aggregator below
# needs to continue past individual scenario failures so the summary reports
# every failing case, not just the first. Each scenario uses explicit
# `|| fail ...` predicates, so missed errors cannot escape silently.

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"
INGEST_SH="$REPO_ROOT/scripts/wiki-daily-ingest.sh"
COPY_PY="$REPO_ROOT/scripts/wiki-daily-copy.py"

if [[ ! -x "$INGEST_SH" && ! -r "$INGEST_SH" ]]; then
  printf '[smoke][error] cannot find %s\n' "$INGEST_SH" >&2
  exit 2
fi

PASS=0
FAIL=0
declare -a FAIL_IDS=()

pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_IDS+=("$1"); printf '  [FAIL] %s — %s\n' "$1" "$2"; }
banner() { printf '\n=== scenario %s ===\n' "$1"; }

# -----------------------------------------------------------------------------
# isolated BRIDGE_HOME setup
# -----------------------------------------------------------------------------
SMOKE_ROOT="$(mktemp -d -t wiki-daily-ingest-smoke.XXXXXX)"
trap 'rm -rf "$SMOKE_ROOT" 2>/dev/null || true' EXIT

BRIDGE_HOME="$SMOKE_ROOT/bridge-home"
BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
BRIDGE_AGENTS_ROOT="$BRIDGE_HOME/agents"
BRIDGE_SHARED_ROOT="$BRIDGE_HOME/shared"
BRIDGE_WIKI_ROOT="$BRIDGE_SHARED_ROOT/wiki"
BRIDGE_SCRIPTS_ROOT="$REPO_ROOT/scripts"
# Stub $BRIDGE_AGB to /bin/true so Lane B's "agent show librarian" probe
# returns non-zero (no librarian) and the task-create call short-circuits
# under `|| true`. With zero non-daily files we never reach that branch
# anyway, but defense-in-depth keeps the test hermetic.
BRIDGE_AGB="/bin/true"
WIKI_WATERMARK_FILE="$BRIDGE_STATE_DIR/wiki/last-ingest.txt"
mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_AGENTS_ROOT" "$BRIDGE_WIKI_ROOT/_audit"

export BRIDGE_HOME BRIDGE_STATE_DIR BRIDGE_AGENTS_ROOT \
       BRIDGE_SHARED_ROOT BRIDGE_WIKI_ROOT BRIDGE_SCRIPTS_ROOT BRIDGE_AGB

AGENT="smoke-claude"
AGENT_HOME="$BRIDGE_AGENTS_ROOT/$AGENT"
mkdir -p "$AGENT_HOME/memory"

# Date helper — works on macOS (BSD date) and Linux (GNU date).
days_ago() {
  local n="$1"
  date -v-"${n}"d +%Y-%m-%d 2>/dev/null || date -d "${n} days ago" +%Y-%m-%d
}

TODAY="$(date +%Y-%m-%d)"
D_MINUS_1="$(days_ago 1)"
D_MINUS_2="$(days_ago 2)"
D_MINUS_3="$(days_ago 3)"
D_MINUS_20="$(days_ago 20)"

write_note() {
  local date_str="$1"
  local body="$2"
  printf '%s\n' "$body" >"$AGENT_HOME/memory/$date_str.md"
}

wiki_replica_path() {
  printf '%s\n' "$BRIDGE_WIKI_ROOT/agents/$AGENT/daily/$AGENT-$1.md"
}

reset_runtime() {
  rm -rf "$BRIDGE_WIKI_ROOT/agents" 2>/dev/null || true
  rm -rf "$BRIDGE_WIKI_ROOT/_audit" 2>/dev/null || true
  rm -f "$WIKI_WATERMARK_FILE" 2>/dev/null || true
  rm -rf "$AGENT_HOME/memory" 2>/dev/null || true
  mkdir -p "$BRIDGE_WIKI_ROOT/_audit" "$AGENT_HOME/memory"
}

read_watermark() {
  [ -f "$WIKI_WATERMARK_FILE" ] || { printf 'absent\n'; return 0; }
  head -n1 "$WIKI_WATERMARK_FILE" | tr -d '[:space:]'
}

# Run wiki-daily-ingest.sh under the isolated BRIDGE_HOME. Captures
# stdout into a per-run file and returns the script's exit code.
run_ingest() {
  local label="$1"
  local out="$SMOKE_ROOT/$label.out"
  local rc=0
  bash "$INGEST_SH" >"$out" 2>>"$SMOKE_ROOT/$label.err" || rc=$?
  printf '%s' "$out"
  return "$rc"
}

# =============================================================================
# Scenario 1 — first-ever run, no watermark, falls through to YESTERDAY default.
# =============================================================================
banner "1 — first-ever run uses YESTERDAY default and writes watermark"
reset_runtime
write_note "$D_MINUS_1" "# $D_MINUS_1 note"
write_note "$TODAY"     "# $TODAY note"

out_file="$(run_ingest s1)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "1" "exit rc=$rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/s1.err" | head -c 200)"
elif ! grep -q "since=$D_MINUS_1" "$out_file"; then
  fail "1" "expected since=$D_MINUS_1 in: $(head -c 200 "$out_file")"
elif [[ ! -f "$(wiki_replica_path "$D_MINUS_1")" ]]; then
  fail "1" "expected replica for $D_MINUS_1 to exist"
elif [[ ! -f "$(wiki_replica_path "$TODAY")" ]]; then
  fail "1" "expected replica for $TODAY to exist"
elif [[ "$(read_watermark)" != "$TODAY" ]]; then
  fail "1" "watermark=$(read_watermark) expected=$TODAY"
else
  pass "1"
fi

# =============================================================================
# Scenario 2 — STRAND RECOVERY (the bug #321 was filed for).
# A note dated D-2 is written *after* the s1 run already completed. The next
# Lane A run must use the persisted watermark (=$TODAY from s1) ... wait —
# the watermark is "today's --until", so re-running on the same calendar day
# produces since=today=until. To exercise strand recovery realistically we
# rewind the watermark to D_MINUS_1 (simulating "yesterday's run finished
# at D-1"), strand a D-2 note, and assert the next run picks up D-2 because
# since=watermark=D-1 reaches back to it (window is [D-1, today], which
# excludes D-2 — that's why the recovery actually requires a watermark from
# a date *prior* to the strand). So we set watermark=D-3 to match the real
# "agent wrote yesterday's note this morning, ingest's previous successful
# run was three days ago" scenario.
# =============================================================================
banner "2 — strand-recovery: watermark older than YESTERDAY catches stranded note"
reset_runtime
# Simulate "previous successful Lane A run completed at D-3" by running
# ingest with no inputs at D-3 first — this is what would have happened
# in production three days ago. The natural-flow run produces a watermark
# of $TODAY (the script's --until is always "today"), so we then backdate
# the watermark file to D-3 to model the calendar gap. This separates
# "did the watermark mechanism work?" (Scenario 1) from "does an existing
# watermark of D-3 actually catch a D-2 strand?" (this scenario).
mkdir -p "$(dirname "$WIKI_WATERMARK_FILE")"
out_file_prelude="$(run_ingest s2-prelude)"   # creates watermark via natural path
[[ -s "$WIKI_WATERMARK_FILE" ]] || fail "2-prelude" "natural-path watermark not written: $(head -c 200 "$out_file_prelude" 2>/dev/null || true)"
# Backdate watermark to model "last successful run was D-3, agent has been
# offline since". Same-calendar-day re-runs cannot otherwise simulate strand
# recovery because the script writes watermark=today on every successful run.
printf '%s\n' "$D_MINUS_3" >"$WIKI_WATERMARK_FILE"
# Strand a D-2 note (within the 14-day clamp window, outside the default
# 2-day rolling window the bug describes).
write_note "$D_MINUS_2" "# $D_MINUS_2 stranded note"
write_note "$TODAY"     "# $TODAY note"

out_file="$(run_ingest s2)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "2" "exit rc=$rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/s2.err" | head -c 200)"
elif ! grep -q "since=$D_MINUS_3" "$out_file"; then
  fail "2" "expected since=$D_MINUS_3 (watermark) in: $(head -c 200 "$out_file")"
elif [[ ! -f "$(wiki_replica_path "$D_MINUS_2")" ]]; then
  fail "2" "stranded $D_MINUS_2 note was NOT recovered (regression of issue #321)"
elif [[ "$(read_watermark)" != "$TODAY" ]]; then
  fail "2" "watermark after recovery=$(read_watermark) expected=$TODAY"
else
  pass "2"
fi

# =============================================================================
# Scenario 3 — wiki-daily-copy.py idempotency under overlapping --since.
# Re-running with the same source bytes must not re-copy.
# =============================================================================
banner "3 — idempotent re-run does not re-copy unchanged sources"
# Don't reset; reuse s2's wiki state. A second call with the same source
# bytes should report unchanged>=1, created=0, replaced=0 for those notes.
copy_json="$SMOKE_ROOT/s3-copy.json"
"$PYTHON" "$COPY_PY" --since "$D_MINUS_3" --until "$TODAY" --json >"$copy_json" 2>"$SMOKE_ROOT/s3.err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "3" "wiki-daily-copy rc=$rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/s3.err" | head -c 200)"
else
  created="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("created",0))' "$copy_json")"
  replaced="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("replaced",0))' "$copy_json")"
  unchanged="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("unchanged",0))' "$copy_json")"
  if [[ "$created" != "0" || "$replaced" != "0" ]]; then
    fail "3" "idempotency violated: created=$created replaced=$replaced unchanged=$unchanged"
  elif [[ "$unchanged" -lt 1 ]]; then
    fail "3" "expected unchanged>=1 got $unchanged"
  else
    pass "3"
  fi
fi

# =============================================================================
# Scenario 4 — 14-day clamp: stale watermark older than the floor is clamped.
# Notes between [stale-watermark, floor) are intentionally not recovered.
# =============================================================================
banner "4 — stale watermark older than 14 days is clamped to the floor"
reset_runtime
mkdir -p "$(dirname "$WIKI_WATERMARK_FILE")"
# Stale watermark from 20 days ago — outside the default 14-day floor.
printf '%s\n' "$D_MINUS_20" >"$WIKI_WATERMARK_FILE"
FLOOR="$(days_ago 14)"
# A note within the floor (e.g. 3 days ago) must be picked up.
write_note "$D_MINUS_3" "# $D_MINUS_3 within-floor note"
write_note "$TODAY"     "# $TODAY note"

out_file="$(run_ingest s4)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "4" "exit rc=$rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/s4.err" | head -c 200)"
elif ! grep -q "since=$FLOOR" "$out_file"; then
  fail "4" "expected since=$FLOOR (clamped) in: $(head -c 200 "$out_file")"
elif [[ ! -f "$(wiki_replica_path "$D_MINUS_3")" ]]; then
  fail "4" "expected $D_MINUS_3 (within floor) to be copied"
elif [[ "$(read_watermark)" != "$TODAY" ]]; then
  fail "4" "watermark=$(read_watermark) expected=$TODAY"
else
  pass "4"
fi

# =============================================================================
# Scenario 5 — Lane A failure does NOT advance the watermark.
# We force errors=1 by making the wiki target dir non-writable, then assert
# the previous watermark (D_MINUS_3) survives the failed run.
# =============================================================================
banner "5 — Lane A failure leaves the watermark untouched"
reset_runtime
mkdir -p "$(dirname "$WIKI_WATERMARK_FILE")"
printf '%s\n' "$D_MINUS_3" >"$WIKI_WATERMARK_FILE"
write_note "$D_MINUS_2" "# $D_MINUS_2 note"
write_note "$TODAY"     "# $TODAY note"

# Pre-create the per-agent destination dir as a regular file so
# wiki-daily-copy.py's `dest.parent.mkdir(...)` raises an OSError on the
# first copy attempt → errors counter increments → watermark gate fails.
# This is portable across macOS and Linux without needing chmod magic.
dest_parent="$BRIDGE_WIKI_ROOT/agents/$AGENT/daily"
mkdir -p "$BRIDGE_WIKI_ROOT/agents/$AGENT"
: >"$dest_parent"   # collide: a file where a directory should exist

out_file="$(run_ingest s5 || true)"
# Don't fail on rc — Lane A may exit 0 with errors>0 inside the JSON. We
# only care that the watermark is unchanged.
post_watermark="$(read_watermark)"
if [[ "$post_watermark" != "$D_MINUS_3" ]]; then
  fail "5" "watermark advanced on failure: pre=$D_MINUS_3 post=$post_watermark"
else
  # Confirm the run actually produced a non-zero copy_errors / copy_rc; if
  # not, the test assumption is wrong and the assertion above passed
  # vacuously.
  if grep -q "errors=" "$out_file" && ! grep -q "errors=0" "$out_file"; then
    pass "5"
  elif grep -qi "lane a exit code" "$BRIDGE_WIKI_ROOT/_audit/ingest-$TODAY.md" 2>/dev/null; then
    pass "5"
  else
    fail "5" "could not confirm Lane A failure path was exercised; out=$(head -c 200 "$out_file")"
  fi
fi

# Cleanup the deliberate collision so EXIT trap removes things cleanly.
rm -f "$dest_parent" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\n=== summary ===\n'
printf 'pass=%d fail=%d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'failed: %s\n' "${FAIL_IDS[*]}"
  exit 1
fi
exit 0
