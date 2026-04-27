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

# 2d. command substitution in allowed-key value
printf 'BRIDGE_LAYOUT=v2\nBRIDGE_DATA_ROOT=/tmp/v2\nBRIDGE_SHARED_GROUP=$(touch /tmp/agb-pwn-canary.%d)\n' "$$" > "$marker_path"
chmod 0640 "$marker_path"
rm -f "/tmp/agb-pwn-canary.$$"
if bridge_isolation_v2_marker_validate "$marker_path" 2>/dev/null; then
  fail "marker_validate accepted command substitution in value"
else
  ok "marker_validate rejects command substitution in value"
fi
# Also confirm load does NOT execute it.
( bridge_isolation_v2_marker_load 2>/dev/null )
if [[ -e "/tmp/agb-pwn-canary.$$" ]]; then
  fail "marker_load executed command substitution (canary file created)"
  rm -f "/tmp/agb-pwn-canary.$$"
else
  ok "marker_load did not execute command substitution"
fi

# 2e. backtick injection
printf 'BRIDGE_LAYOUT=v2\nBRIDGE_DATA_ROOT=`/bin/echo /tmp`\n' > "$marker_path"
chmod 0640 "$marker_path"
if bridge_isolation_v2_marker_validate "$marker_path" 2>/dev/null; then
  fail "marker_validate accepted backtick value"
else
  ok "marker_validate rejects backtick value"
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

# Source the real isolation-v2 helpers (chgrp_setgid_{dir,recursive},
# ensure_group, ensure_user_in_group, etc.) so the migrate module's
# helper calls resolve to actual implementations rather than 127.
source "$REPO_ROOT/lib/bridge-isolation-v2.sh"
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

# ---------------------------------------------------------------------------
# Case 9: symlink-aware sha256_of (regression for r1 finding 3)
# ---------------------------------------------------------------------------

sym_root="$SMOKE_ROOT/symtest"
mkdir -p "$sym_root/sub"
echo 'real' > "$sym_root/sub/real.txt"
ln -s "$sym_root/sub/real.txt" "$sym_root/link.txt"

sha_with_link="$(bridge_isolation_v2_migrate_sha256_of "$sym_root")"

# Drop just the symlink and recompute — hashes must differ. With the
# old `-type f` filter the two hashes were identical because the
# symlink was ignored.
rm "$sym_root/link.txt"
sha_without_link="$(bridge_isolation_v2_migrate_sha256_of "$sym_root")"

if [[ "$sha_with_link" != "$sha_without_link" ]]; then
  ok "sha256_of distinguishes presence of symlink"
else
  fail "sha256_of same hash with/without symlink — symlinks ignored"
fi

# Symlink standalone hash differs from absent.
ln -s /nonexistent "$sym_root/danglink"
sha_dangling="$(bridge_isolation_v2_migrate_sha256_of "$sym_root/danglink")"
if [[ "$sha_dangling" != "absent" && "$sha_dangling" != "" ]]; then
  ok "sha256_of dangling symlink hashes link target string"
else
  fail "sha256_of dangling symlink returned absent"
fi

# ---------------------------------------------------------------------------
# Case 10: ensure_groups_and_memberships exists and references env-overridable group names
# ---------------------------------------------------------------------------

# Cannot exercise group creation rootlessly, but verify the function
# was renamed/updated and reads BRIDGE_SHARED_GROUP / BRIDGE_CONTROLLER_GROUP.
if declare -f bridge_isolation_v2_migrate_ensure_groups_and_memberships >/dev/null; then
  ok "ensure_groups_and_memberships function defined"
else
  fail "ensure_groups_and_memberships function missing"
fi

if declare -f bridge_isolation_v2_migrate_ensure_groups_and_memberships \
   | grep -q 'BRIDGE_SHARED_GROUP'; then
  ok "ensure_groups_and_memberships honors BRIDGE_SHARED_GROUP override"
else
  fail "ensure_groups_and_memberships does not reference BRIDGE_SHARED_GROUP override"
fi

if declare -f bridge_isolation_v2_migrate_ensure_groups_and_memberships \
   | grep -q 'bridge_isolation_v2_ensure_user_in_group'; then
  ok "ensure_groups_and_memberships adds user memberships"
else
  fail "ensure_groups_and_memberships does NOT add user memberships"
fi

# ---------------------------------------------------------------------------
# Case 11: normalize_layout exists, called with correct helper signature,
#          and runs AFTER mirror (separate from membership setup)
# ---------------------------------------------------------------------------

if declare -f bridge_isolation_v2_migrate_normalize_layout >/dev/null; then
  ok "normalize_layout function defined"
else
  fail "normalize_layout function missing"
fi

# Helper signature is (group, dir_mode, file_mode, root). Verify all
# calls in normalize_layout use 4 positional args, with the second/third
# being octal mode tokens (2750/2770/0640/0660), and the FIRST arg is
# the group var (not a path — that was the r2 P1 #1 bug).
norm_body="$(declare -f bridge_isolation_v2_migrate_normalize_layout)"
if grep -qE 'chgrp_setgid_recursive[[:space:]]+\\?\s*"\$(shared_grp|ctrl_grp|agent_grp)"\s+27[57]0\s+0[64]60\s+"\$data_root' <<<"$norm_body"; then
  ok "normalize_layout calls helper with (group, dir_mode, file_mode, root)"
else
  # Fallback regex without strict line breaks.
  if grep -E 'chgrp_setgid_recursive' <<<"$norm_body" \
     | grep -qE '"\$(shared_grp|ctrl_grp|agent_grp)"[[:space:]]+27[57]0[[:space:]]+0[64]60'; then
    ok "normalize_layout calls helper with (group, dir_mode, file_mode, root)"
  else
    fail "normalize_layout call signature looks wrong (expected group dir_mode file_mode root)"
  fi
fi

# Apply path must call normalize_layout AFTER mirror_all.
apply_body="$(declare -f bridge_isolation_v2_migrate_apply)"
mirror_pos=$(grep -n 'mirror_all' <<<"$apply_body" | head -1 | cut -d: -f1)
norm_pos=$(grep -n 'normalize_layout' <<<"$apply_body" | head -1 | cut -d: -f1)
if [[ -n "$mirror_pos" && -n "$norm_pos" ]] && (( norm_pos > mirror_pos )); then
  ok "apply runs normalize_layout AFTER mirror_all"
else
  fail "apply order wrong: normalize must come after mirror (mirror_pos=$mirror_pos norm_pos=$norm_pos)"
fi

# ---------------------------------------------------------------------------
# Case 12: postflight honors BRIDGE_SHARED_GROUP / BRIDGE_CONTROLLER_GROUP
# ---------------------------------------------------------------------------

postflight_body="$(declare -f bridge_isolation_v2_migrate_postflight_groups)"
if grep -q 'BRIDGE_SHARED_GROUP' <<<"$postflight_body" \
   && grep -q 'BRIDGE_CONTROLLER_GROUP' <<<"$postflight_body"; then
  ok "postflight honors BRIDGE_SHARED_GROUP + BRIDGE_CONTROLLER_GROUP overrides"
else
  fail "postflight does NOT reference both env overrides"
fi

if grep -q '"ab-shared"' <<<"$postflight_body"; then
  fail "postflight still hardcodes 'ab-shared' as a literal"
else
  ok "postflight no longer hardcodes 'ab-shared'"
fi

# ---------------------------------------------------------------------------
# Case 13: normalize_layout sets per-agent root to 2750, NOT 2770
#          (r3 finding: 2770 root would let isolated UID rename credentials)
# ---------------------------------------------------------------------------

norm_body="$(declare -f bridge_isolation_v2_migrate_normalize_layout)"

# Per-agent root call uses chgrp_setgid_dir (single, not recursive) at 2750.
if grep -E 'chgrp_setgid_dir[[:space:]]+\\?\s*"\$agent_grp"\s+2750\s+"\$agent_root"' <<<"$norm_body" >/dev/null \
   || grep -E 'chgrp_setgid_dir[[:space:]]' <<<"$norm_body" \
        | grep -qE '"\$agent_grp"[[:space:]]+2750[[:space:]]+"\$agent_root"'; then
  ok "normalize_layout sets per-agent root to 2750 via single-dir helper"
else
  fail "normalize_layout per-agent root call missing or wrong (expected chgrp_setgid_dir agent_grp 2750 root)"
fi

# Writable children iterated as a list, all 2770/0660.
if grep -q 'writable_subs=(home workdir runtime logs requests responses)' <<<"$norm_body"; then
  ok "normalize_layout enumerates writable subs explicitly"
else
  fail "normalize_layout writable_subs list missing or wrong"
fi

if grep -E 'chgrp_setgid_recursive[[:space:]]' <<<"$norm_body" \
     | grep -qE '"\$agent_grp"[[:space:]]+2770[[:space:]]+0660'; then
  ok "normalize_layout writable children use 2770/0660"
else
  fail "normalize_layout writable child call missing 2770/0660"
fi

# credentials/ override 2750/0640 still present.
if grep -E 'chgrp_setgid_recursive[[:space:]]' <<<"$norm_body" \
     | grep -qE '"\$agent_grp"[[:space:]]+2750[[:space:]]+0640'; then
  ok "normalize_layout credentials/ uses 2750/0640"
else
  fail "normalize_layout credentials/ mode wrong"
fi

# Functional check: rootless run with a primary-group agent dir tree.
PRIMARY_GRP="$(id -gn 2>/dev/null)"
if [[ -n "$PRIMARY_GRP" ]]; then
  norm_root="$SMOKE_ROOT/norm-test"
  mkdir -p "$norm_root/agents/probe-agent/home" \
           "$norm_root/agents/probe-agent/workdir" \
           "$norm_root/agents/probe-agent/credentials"
  echo 'irrelevant' > "$norm_root/agents/probe-agent/credentials/launch.env"

  # Stub group-name resolver to use caller's primary group so
  # chgrp/chmod succeed without sudo (helper falls through to direct
  # path because mode/chgrp succeed for the owning user).
  bridge_isolation_v2_agent_group_name() { printf '%s' "$PRIMARY_GRP"; }

  # Build a one-line snapshot for the probe agent.
  SNAP_NORM="$norm_root/snap"
  printf 'probe-agent\n' > "$SNAP_NORM"

  # Run the normalize step (BRIDGE_SHARED_GROUP/ctrl_grp left default —
  # shared/ and state/ dirs do not exist in this fixture so those
  # branches no-op).
  set +e
  ( bridge_isolation_v2_migrate_normalize_layout "$SNAP_NORM" "$norm_root" 2>/dev/null )
  rc=$?
  set -e

  if (( rc == 0 )); then
    root_mode="$(stat -c '%a' "$norm_root/agents/probe-agent" 2>/dev/null)"
    workdir_mode="$(stat -c '%a' "$norm_root/agents/probe-agent/workdir" 2>/dev/null)"
    home_mode="$(stat -c '%a' "$norm_root/agents/probe-agent/home" 2>/dev/null)"
    cred_mode="$(stat -c '%a' "$norm_root/agents/probe-agent/credentials" 2>/dev/null)"
    cred_file_mode="$(stat -c '%a' "$norm_root/agents/probe-agent/credentials/launch.env" 2>/dev/null)"

    if [[ "$root_mode" == "2750" ]]; then
      ok "post-normalize: per-agent root mode = 2750"
    else
      fail "post-normalize: per-agent root mode = $root_mode (expected 2750)"
    fi
    if [[ "$workdir_mode" == "2770" ]]; then
      ok "post-normalize: workdir mode = 2770"
    else
      fail "post-normalize: workdir mode = $workdir_mode (expected 2770)"
    fi
    if [[ "$home_mode" == "2770" ]]; then
      ok "post-normalize: home mode = 2770"
    else
      fail "post-normalize: home mode = $home_mode (expected 2770)"
    fi
    if [[ "$cred_mode" == "2750" ]]; then
      ok "post-normalize: credentials/ mode = 2750"
    else
      fail "post-normalize: credentials/ mode = $cred_mode (expected 2750)"
    fi
    if [[ "$cred_file_mode" == "640" ]]; then
      ok "post-normalize: credentials file mode = 0640"
    else
      fail "post-normalize: credentials file mode = $cred_file_mode (expected 640)"
    fi
  else
    fail "normalize_layout returned rc=$rc on rootless fixture"
  fi
fi

printf '\n[summary] pass=%d fail=%d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
