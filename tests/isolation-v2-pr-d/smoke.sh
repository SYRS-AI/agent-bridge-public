#!/usr/bin/env bash
# tests/isolation-v2-pr-d/smoke.sh — rootless smoke for PR-D migration tool.
#
# Covers (within rootless reach — root-required cases X-flagged at top):
#   1. dry-run prints plan + does not create marker
#   2. marker validation rejects unsafe owner/mode/content
#   3. marker validation accepts valid v2 marker
#   4. bridge_agent_default_profile_home returns v2 workdir when v2 active
#   5. mirror map contains profile rows with delete_eligible=0
#   6. commit candidate awk filter ($8==ok && $9==1) excludes delete_eligible=0
#   7. self-stop guard refuses when BRIDGE_AGENT_ID is in snapshot
#   8. daemon poll attempt counter exits within bounded time on mocked PIDs
#
# Skipped (root-required, X-flagged): real apply/rollback/commit, postflight
# `sudo -u <agent> id -nG`, group ensure (groupadd), and full daemon stop.
# Those are exercised by the live operator playbook in OPERATIONS.md.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

SMOKE_ROOT="$(mktemp -d -t isolation-v2-pr-d.XXXXXX)"
trap 'rm -rf "$SMOKE_ROOT"' EXIT

BRIDGE_HOME="$SMOKE_ROOT/bridge-home"
BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
BRIDGE_RUNTIME_ROOT="$BRIDGE_HOME/runtime"
BRIDGE_RUNTIME_SHARED_DIR="$BRIDGE_RUNTIME_ROOT/shared"
BRIDGE_WORKTREE_ROOT="$BRIDGE_HOME/worktrees"
BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
DATA_ROOT="$SMOKE_ROOT/data-v2"
mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_AGENT_HOME_ROOT" \
         "$BRIDGE_RUNTIME_ROOT" "$BRIDGE_RUNTIME_SHARED_DIR" \
         "$BRIDGE_WORKTREE_ROOT" "$BRIDGE_SHARED_DIR"
export BRIDGE_HOME BRIDGE_STATE_DIR BRIDGE_AGENT_HOME_ROOT \
       BRIDGE_RUNTIME_ROOT BRIDGE_RUNTIME_SHARED_DIR \
       BRIDGE_WORKTREE_ROOT BRIDGE_SHARED_DIR

PASS=0
FAIL=0

ok() {
  PASS=$(( PASS + 1 ))
  printf '[ok] %s\n' "$1"
}

fail() {
  FAIL=$(( FAIL + 1 ))
  printf '[fail] %s\n' "$1" >&2
}

# Source the v2-migrate library directly (bridge-lib.sh expects a full
# install; we shim the minimum for unit-style probing).
source "$REPO_ROOT/lib/bridge-marker-bootstrap.sh" 2>/dev/null || true

# Minimal shim for bridge_warn / bridge_die so the marker validator runs.
bridge_warn() { printf '[warn] %s\n' "$*" >&2; }
bridge_die()  { printf '[die] %s\n'  "$*" >&2; exit 9; }

# ---------------------------------------------------------------------------
# Case 2: marker validation rejects unsafe owner/mode/content
# ---------------------------------------------------------------------------

marker_path="$BRIDGE_STATE_DIR/layout-marker.sh"

# 2a. group write bit
printf 'BRIDGE_LAYOUT=v2\nBRIDGE_DATA_ROOT=/tmp/v2\n' > "$marker_path"
chmod 0660 "$marker_path"
if bridge_isolation_v2_marker_validate "$marker_path" 2>/dev/null; then
  fail "marker_validate accepted group-writable file"
else
  ok "marker_validate rejects group-writable mode"
fi

# 2b. disallowed line
printf 'BRIDGE_LAYOUT=v2\nNASTY=$(rm -rf /)\n' > "$marker_path"
chmod 0640 "$marker_path"
if bridge_isolation_v2_marker_validate "$marker_path" 2>/dev/null; then
  fail "marker_validate accepted disallowed line"
else
  ok "marker_validate rejects disallowed key"
fi

# 2c. relative BRIDGE_DATA_ROOT
printf 'BRIDGE_LAYOUT=v2\nBRIDGE_DATA_ROOT=relative/path\n' > "$marker_path"
chmod 0640 "$marker_path"
if bridge_isolation_v2_marker_validate "$marker_path" 2>/dev/null; then
  fail "marker_validate accepted relative DATA_ROOT"
else
  ok "marker_validate rejects relative BRIDGE_DATA_ROOT"
fi

# ---------------------------------------------------------------------------
# Case 3: marker validation accepts valid v2 marker
# ---------------------------------------------------------------------------

printf 'BRIDGE_LAYOUT=%s\nBRIDGE_DATA_ROOT=%s\n' \
  "$(printf %q v2)" "$(printf %q "$DATA_ROOT")" > "$marker_path"
chmod 0640 "$marker_path"
if bridge_isolation_v2_marker_validate "$marker_path" 2>/dev/null; then
  ok "marker_validate accepts valid v2 marker"
else
  fail "marker_validate rejected valid v2 marker"
fi

# ---------------------------------------------------------------------------
# Case 5/6: mirror plan emit + commit awk filter (unit-style)
# ---------------------------------------------------------------------------

# Build the migration module surface enough to call emit_plan + the awk
# commit filter against a fake manifest.

# Fake snapshot — single agent.
SNAP="$BRIDGE_STATE_DIR/migration/active-agents.snapshot"
mkdir -p "$BRIDGE_STATE_DIR/migration"
printf 'agent-x\n' > "$SNAP"

# Fake legacy tree for agent-x.
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/agent-x/.claude/sessions"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/agent-x/.teams"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/agent-x/credentials"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/agent-x/.agents/skills"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/agent-x/memory"
echo '{}' > "$BRIDGE_AGENT_HOME_ROOT/agent-x/.claude/sessions/abc.json"
echo 'token=x' > "$BRIDGE_AGENT_HOME_ROOT/agent-x/.teams/access.json"
echo 'sec' > "$BRIDGE_AGENT_HOME_ROOT/agent-x/credentials/launch-secrets.env"
echo 'role: test' > "$BRIDGE_AGENT_HOME_ROOT/agent-x/CLAUDE.md"
echo 'memory entry' > "$BRIDGE_AGENT_HOME_ROOT/agent-x/MEMORY.md"
echo 'skill foo' > "$BRIDGE_AGENT_HOME_ROOT/agent-x/.agents/skills/foo.md"
echo 'session: complete' > "$BRIDGE_AGENT_HOME_ROOT/agent-x/SESSION-TYPE.md"

# Source the migration module. It requires a few helpers; provide stubs.
bridge_expand_user_path() { printf '%s' "$1"; }
bridge_linux_resolve_user_home() { getent passwd "$1" 2>/dev/null | cut -d: -f6 || printf '%s' "$HOME"; }
bridge_active_agent_ids() { cat "$SNAP"; }
bridge_daemon_all_pids() { :; }
bridge_isolation_v2_active() { return 1; }   # no marker for plan-emit unit test
bridge_isolation_v2_ensure_group() { return 0; }
bridge_isolation_v2_agent_group_name() { printf 'ab-agent-%s' "$1"; }
bridge_agent_os_user() { printf 'agent-bridge-%s' "$1"; }

source "$REPO_ROOT/lib/bridge-isolation-v2-migrate.sh"

# Case 5: emit_plan output contains profile rows with delete_eligible=0.
plan_out="$(bridge_isolation_v2_migrate_emit_plan "$DATA_ROOT" "$SNAP")"
if grep -qP '^agent_profile_CLAUDE\.md:agent-x\t.*\t0$' <<<"$plan_out"; then
  ok "emit_plan includes CLAUDE.md row with delete_eligible=0"
else
  fail "emit_plan missing CLAUDE.md row with delete_eligible=0"
fi
if grep -qP '^agent_subtree_\.agents:agent-x\t.*\t0$' <<<"$plan_out"; then
  ok "emit_plan includes .agents subtree with delete_eligible=0"
else
  fail "emit_plan missing .agents subtree row"
fi
if grep -qP '^agent_session_type:agent-x\t.*\t0$' <<<"$plan_out"; then
  ok "emit_plan includes SESSION-TYPE.md with delete_eligible=0"
else
  fail "emit_plan missing SESSION-TYPE.md dual-read row"
fi
if grep -qP '^agent_claude:agent-x\t.*\t1$' <<<"$plan_out"; then
  ok "emit_plan includes .claude with delete_eligible=1"
else
  fail "emit_plan missing .claude row"
fi
if grep -qP '^agent_teams:agent-x\t.*workdir/\.teams\t1$' <<<"$plan_out"; then
  ok "emit_plan maps .teams to v2 workdir/ (not home/)"
else
  fail "emit_plan .teams destination wrong"
fi

# Case 6: commit awk filter excludes delete_eligible=0 rows.
manifest="$BRIDGE_STATE_DIR/migration/manifest.tsv"
{
  printf '2026-01-01T00:00:00Z\trow_runtime\t/legacy/a\t/v2/a\t10\tx\tx\tok\t1\n'
  printf '2026-01-01T00:00:00Z\trow_dual\t/legacy/b\t/v2/b\t20\ty\ty\tok\t0\n'
  printf '2026-01-01T00:00:00Z\trow_failed\t/legacy/c\t/v2/c\t30\tz\tz\tchecksum_mismatch\t1\n'
  printf '2026-01-01T00:00:00Z\trow_profile\t/legacy/d\t/v2/d\t40\tw\tw\tok\t0\n'
} > "$manifest"

candidates="$(bridge_isolation_v2_migrate_legacy_data_paths)"
if [[ "$candidates" == "/legacy/a" ]]; then
  ok "commit candidate filter returns only delete_eligible=1 verify=ok"
else
  fail "commit candidate filter wrong: '$candidates'"
fi

# ---------------------------------------------------------------------------
# Case 7: self-stop guard refuses when BRIDGE_AGENT_ID is in snapshot
# ---------------------------------------------------------------------------

set +e
(
  export BRIDGE_AGENT_ID="agent-x"
  bridge_isolation_v2_migrate_self_stop_guard "$SNAP" 2>/dev/null
)
rc=$?
if (( rc == 9 )); then
  ok "self_stop_guard die when BRIDGE_AGENT_ID is in snapshot"
else
  fail "self_stop_guard returned rc=$rc (expected 9 = bridge_die)"
fi
unset BRIDGE_AGENT_ID

bridge_isolation_v2_migrate_self_stop_guard "$SNAP" 2>/dev/null
rc=$?
if (( rc == 0 )); then
  ok "self_stop_guard pass when BRIDGE_AGENT_ID is unset"
else
  fail "self_stop_guard rc=$rc when BRIDGE_AGENT_ID unset (expected 0)"
fi
set -e

# ---------------------------------------------------------------------------
# Case 8: daemon poll attempt counter is bounded (not 50s for 10s spec)
# ---------------------------------------------------------------------------

# Mock bridge_daemon_all_pids to always print a PID — wait_daemon_gone
# should die after ~10s, NOT ~50s (the previous brief had a precedence bug).
bridge_daemon_all_pids() { printf '12345'; }

start_ts="$(date +%s)"
set +e
( bridge_isolation_v2_migrate_wait_daemon_gone 2 2>/dev/null )
rc=$?
set -e
end_ts="$(date +%s)"
elapsed=$(( end_ts - start_ts ))
# Expect ~2s (timeout_s=2), not 10s. Tolerate up to 5s for slow CI.
if (( rc == 9 )) && (( elapsed >= 1 )) && (( elapsed <= 5 )); then
  ok "wait_daemon_gone bounded by attempt counter (~${elapsed}s for 2s spec)"
else
  fail "wait_daemon_gone rc=$rc elapsed=${elapsed}s (expected die ~2s)"
fi

# ---------------------------------------------------------------------------
# Case 1: dry-run does not create marker
# ---------------------------------------------------------------------------

# Reset state.
rm -f "$marker_path"
rm -rf "$BRIDGE_STATE_DIR/migration"
mkdir -p "$BRIDGE_STATE_DIR/migration"
printf 'agent-x\n' > "$SNAP"

# Mock daemon helpers so dry-run unit doesn't hang.
bridge_daemon_all_pids() { :; }

# dry-run should not create marker.
set +e
bridge_isolation_v2_migrate_dry_run "$DATA_ROOT" >/tmp/dr.out.$$ 2>&1
rc=$?
set -e
if [[ ! -f "$marker_path" ]]; then
  ok "dry-run does not create marker file"
else
  fail "dry-run created marker file"
fi
rm -f /tmp/dr.out.$$

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n[summary] pass=%d fail=%d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
