#!/usr/bin/env bash
# bootstrap-backfill-history smoke — regression guard for issue #322 Track C.
#
# What this asserts (against bootstrap-memory-system.sh):
#
#   1. --backfill-history is exposed in the --help output, the arg parser
#      treats it as a non-negative integer in [1, 90], and rejects every
#      out-of-range form (negative, zero, > 90, non-numeric) with exit 2
#      and a stderr message. Validation must happen before any provisioning
#      side-effect, so a bad N can't half-converge an install.
#
#   2. The bootstrap source contains the harvest-daily invocation that the
#      brief specifies: per-agent loop, --from $(today-N) --to $(today-1)
#      --agent <agent> --missing-only --tz Asia/Seoul. Static parse, not a
#      live run, because the full apply path requires `agb cron create`,
#      agent roster, and the librarian provisioner — none of which are
#      reproducible inside an isolated tempdir without forking the entire
#      daemon. Issue #322 Track A (PR #335) and Track B (PR #340) ship the
#      harvest-daily flags this loop drives, so confirming the exact argv
#      shape is enough to prevent drift.
#
#   3. Without --backfill-history, the bootstrap script never references the
#      backfill code path. Idempotency-in-the-other-direction: a routine
#      apply must NOT trigger a harvest fan-out.
#
# The Python static-parse logic lives in check_invocation.py (sibling). It
# is a separate file because unbalanced parens inside a heredoc body trip
# bash's command-substitution tokenizer (same workaround as
# tests/bootstrap-cron-schedules/parse_specs.py).
#
# Usage:   ./tests/bootstrap-backfill-history/smoke.sh
# Exit 0 if every assertion PASSes; exit 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
BOOTSTRAP="$REPO_ROOT/bootstrap-memory-system.sh"
HELPER="$(dirname "${BASH_SOURCE[0]}")/check_invocation.py"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '[smoke][pass] %s\n' "$*"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '[smoke][fail] %s\n' "$*" >&2
}

if [[ ! -r "$BOOTSTRAP" ]]; then
  printf '[smoke][error] cannot find %s\n' "$BOOTSTRAP" >&2
  exit 1
fi
if [[ ! -r "$HELPER" ]]; then
  printf '[smoke][error] cannot find helper: %s\n' "$HELPER" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Isolated BRIDGE_HOME — the bootstrap script writes its first-run report
# under $BRIDGE_HOME/state/bootstrap-memory/, so a clean tempdir keeps the
# arg-parser-failure cases from polluting the operator's live install.
# ---------------------------------------------------------------------------
SMOKE_ROOT="$(mktemp -d -t bootstrap-backfill-smoke.XXXXXX)"
trap 'rm -rf "$SMOKE_ROOT" 2>/dev/null || true' EXIT
TEST_BRIDGE_HOME="$SMOKE_ROOT/bridge-home"
mkdir -p "$TEST_BRIDGE_HOME/state"
export BRIDGE_HOME="$TEST_BRIDGE_HOME"

# ---------------------------------------------------------------------------
# Assertion 1 — --help advertises --backfill-history.
# ---------------------------------------------------------------------------
HELP_OUT="$(bash "$BOOTSTRAP" --help 2>&1)"
if printf '%s' "$HELP_OUT" | grep -q -- '--backfill-history'; then
  pass "--help mentions --backfill-history"
else
  fail "--help missing --backfill-history flag"
fi

# ---------------------------------------------------------------------------
# Assertion 2 — every invalid value rejects with exit 2 + stderr message.
#
# We pass --apply explicitly so the validator runs the same code path the
# operator hits in production. The fixture deliberately uses an empty
# BRIDGE_HOME with no agb binary; that's fine because validation runs
# before any subprocess is spawned.
# ---------------------------------------------------------------------------
assert_reject() {
  local label="$1" value="$2" expected_substr="$3"
  local out rc
  out="$(bash "$BOOTSTRAP" --backfill-history "$value" --apply 2>&1)"
  rc=$?
  if [[ "$rc" -ne 2 ]]; then
    fail "$label: expected exit 2, got $rc (out=${out:0:120})"
    return
  fi
  if ! printf '%s' "$out" | grep -q -- "$expected_substr"; then
    fail "$label: stderr missing substring '$expected_substr' (out=${out:0:160})"
    return
  fi
  pass "$label rejected with exit 2"
}

assert_reject "non-numeric (abc)" "abc" "non-negative integer"
assert_reject "negative (-5)"     "-5"  "non-negative integer"
assert_reject "zero"              "0"   "must be in \[1, 90\]"
assert_reject "out of range (91)" "91"  "must be in \[1, 90\]"

# ---------------------------------------------------------------------------
# Assertion 3 — the bootstrap source contains the harvest-daily invocation
# the brief specifies. Static parse, because a live `apply --backfill-history`
# requires the full daemon stack.
# ---------------------------------------------------------------------------
INVOCATION_JSON="$("$PYTHON" "$HELPER" invocation "$BOOTSTRAP" 2>&1)" || {
  fail "invocation parse failed: $INVOCATION_JSON"
  printf '\n[smoke] %d pass / %d fail\n' "$PASS" "$FAIL"
  exit 1
}

PARSE_ERR="$(printf '%s' "$INVOCATION_JSON" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read()).get("error",""))')"
if [[ -n "$PARSE_ERR" ]]; then
  fail "source parse: $PARSE_ERR"
else
  MISSING_CSV="$(printf '%s' "$INVOCATION_JSON" | "$PYTHON" -c 'import json,sys; print(",".join(json.loads(sys.stdin.read()).get("missing",[])))')"
  if [[ -z "$MISSING_CSV" ]]; then
    pass "step_backfill_history_one invokes harvest-daily with --agent/--from/--to/--missing-only/--tz"
  else
    fail "step_backfill_history_one missing tokens: $MISSING_CSV"
  fi
fi

# ---------------------------------------------------------------------------
# Assertion 4 — opt-in only. When --backfill-history is omitted, the source
# guards the harvester invocation behind a non-empty BACKFILL_HISTORY_DAYS
# check AND MODE==apply.
# ---------------------------------------------------------------------------
GATE_JSON="$("$PYTHON" "$HELPER" gate "$BOOTSTRAP" 2>&1)" || {
  fail "gate parse failed: $GATE_JSON"
  printf '\n[smoke] %d pass / %d fail\n' "$PASS" "$FAIL"
  exit 1
}

GATE_ERRORS_CSV="$(printf '%s' "$GATE_JSON" | "$PYTHON" -c 'import json,sys; print("|".join(json.loads(sys.stdin.read()).get("errors",[])))')"
if [[ -z "$GATE_ERRORS_CSV" ]]; then
  pass "run_backfill_history is gated on BACKFILL_HISTORY_DAYS + MODE=apply"
else
  fail "opt-in gate broken: $GATE_ERRORS_CSV"
fi

# ---------------------------------------------------------------------------
# Assertion 5 — re-running --backfill-history is documented as a no-op via
# --missing-only. The brief calls this out explicitly: idempotency.
# ---------------------------------------------------------------------------
if grep -qE 'Re-running .*no-op .*--missing-only' "$BOOTSTRAP"; then
  pass "--help documents idempotency via --missing-only"
else
  fail "--help text missing idempotency note for repeated --backfill-history runs"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n[smoke] %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
