#!/usr/bin/env bash
# tests/isolation-v2-pr-b/smoke.sh
#
# Acceptance test for PR-B: shared read-only asset relocation.
#
# Verifies the dual-mode contract by driving the REAL
# `bridge_linux_share_plugin_catalog` function (not a snapshot copy)
# against a tempdir fixture. Uses the existing
# `BRIDGE_CONTROLLER_HOME_OVERRIDE` test seam plus stubbed
# bridge_linux_sudo_root / bridge_linux_acl_* wrappers so the helper's
# real resolution + manifest-write path runs rootless without
# touching the operator's `/home/ec2-user`.
#
# Test cases:
#   1. populated v2 root + absent legacy controller tree → real
#      share_plugin_catalog writes the per-UID manifest from the v2
#      path. (This is the regression PR-B fixes.)
#   2. v2 mode but unpopulated (dir exists, no installed_plugins.json)
#      → falls back to legacy controller tree.
#   3. legacy mode (BRIDGE_LAYOUT unset) → uses controller tree.
#   4. neither v2 populated nor legacy controller tree → no-op.
#   5. resolved root contains the v2 marketplace mirror.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

log() { printf '[v2-pr-b] %s\n' "$*"; }
die() { printf '[v2-pr-b][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[v2-pr-b][skip] %s\n' "$*"; exit 0; }
ok() { printf '[v2-pr-b] ok: %s\n' "$*"; }

if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required"
fi
command -v python3 >/dev/null 2>&1 || skip "python3 missing"

TMP_ROOT="$(mktemp -d -t isolation-v2-pr-b.XXXXXX)"
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT

# bridge_linux_share_plugin_catalog has a tempdir-prefix gate on
# BRIDGE_CONTROLLER_HOME_OVERRIDE that requires BRIDGE_HOME to be
# under a recognised tempdir prefix. mktemp's default lands under
# /tmp, but the gate also accepts $TMPDIR/* so be explicit.
export TMPDIR="${TMPDIR:-/tmp}"

# ---------------------------------------------------------------------------
# Helper: build a fixture rooted at $1 with v2 shared layout (or empty).
# ---------------------------------------------------------------------------
build_v2_fixture() {
  local data_root="$1"
  local populated="$2"   # 0 or 1
  local v2_plugins="$data_root/shared/plugins-cache"
  mkdir -p "$v2_plugins/marketplaces/test-mkt/plugins/test-plugin"
  if [[ "$populated" == 1 ]]; then
    # Mirror the directory-source marketplace shape used by
    # tests/isolation-plugin-sharing.sh — bridge_resolve_plugin_install_path
    # falls back to source.path/plugins/<id> for directory marketplaces.
    cat >"$v2_plugins/installed_plugins.json" <<JSON
{
  "version": 2,
  "plugins": {
    "test-plugin@test-mkt": [
      {"scope": "user", "version": "0.1.0",
       "installPath": "$v2_plugins/marketplaces/test-mkt/plugins/test-plugin"}
    ]
  }
}
JSON
    cat >"$v2_plugins/known_marketplaces.json" <<JSON
{
  "test-mkt": {
    "source": {"source": "directory", "path": "$v2_plugins/marketplaces/test-mkt"}
  }
}
JSON
    : > "$v2_plugins/marketplaces/test-mkt/plugins/test-plugin/.claude-plugin"
  fi
}

# ---------------------------------------------------------------------------
# Helper: build a legacy controller .claude/plugins tree.
# ---------------------------------------------------------------------------
build_legacy_fixture() {
  local controller_home="$1"
  local plugins="$controller_home/.claude/plugins"
  mkdir -p "$plugins/marketplaces/test-mkt/plugins/test-plugin"
  cat >"$plugins/installed_plugins.json" <<JSON
{
  "version": 2,
  "plugins": {
    "test-plugin@test-mkt": [
      {"scope": "user", "version": "0.1.0",
       "installPath": "$plugins/marketplaces/test-mkt/plugins/test-plugin"}
    ]
  }
}
JSON
  cat >"$plugins/known_marketplaces.json" <<JSON
{
  "test-mkt": {
    "source": {"source": "directory", "path": "$plugins/marketplaces/test-mkt"}
  }
}
JSON
  : > "$plugins/marketplaces/test-mkt/plugins/test-plugin/.claude-plugin"
}

# ---------------------------------------------------------------------------
# Run share_plugin_catalog under a per-test BRIDGE_HOME with a stubbed
# sudo/ACL surface. Echoes the resolved controller_plugins to stdout via
# a probe placed inside bridge_linux_share_plugin_catalog's manifest
# call site. We capture by inspecting the per-UID manifest the helper
# writes and the symlink target of the marketplace mirror.
#
# Returns 0 if helper resolved to a path; 1 if helper hit its no-op
# return-0 (the "no v2, no legacy" case).
# ---------------------------------------------------------------------------
drive_share_helper() {
  local case_name="$1"
  local data_root="$2"     # may be empty for legacy-only / no-op
  local controller_home="$3"  # may be empty for no-op (no legacy tree)
  local v2_active="$4"     # "v2" or "legacy"

  local case_dir="$TMP_ROOT/$case_name"
  mkdir -p "$case_dir"

  local bridge_home="$case_dir/bridge-home"
  mkdir -p "$bridge_home"
  local user_home="$case_dir/agent-home"
  mkdir -p "$user_home"

  # Run the helper inside a subshell so env mutations and stub
  # function definitions don't leak between cases.
  (
    set +u

    export TMPDIR="${TMPDIR:-/tmp}"
    export BRIDGE_HOME="$bridge_home"
    export BRIDGE_AGENT_HOME_ROOT="$bridge_home/agents"
    export BRIDGE_STATE_DIR="$bridge_home/state"
    export BRIDGE_LOG_DIR="$bridge_home/logs"
    export BRIDGE_SHARED_DIR="$bridge_home/shared"
    export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
    export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
    export BRIDGE_ROSTER_FILE="$bridge_home/agent-roster.sh"
    export BRIDGE_ROSTER_LOCAL_FILE="$bridge_home/agent-roster.local.sh"
    export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
    mkdir -p "$BRIDGE_HOME" "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_STATE_DIR" \
             "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR" "$BRIDGE_ACTIVE_AGENT_DIR"
    : > "$BRIDGE_ROSTER_FILE"
    : > "$BRIDGE_ROSTER_LOCAL_FILE"

    # v2 env. Set BEFORE sourcing the lib because the v2 module
    # initializes derived path variables at load time.
    if [[ "$v2_active" == "v2" && -n "$data_root" ]]; then
      export BRIDGE_LAYOUT=v2
      export BRIDGE_DATA_ROOT="$data_root"
    else
      unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT
    fi
    unset BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT

    # Test-only seam for the legacy resolver. The helper requires
    # BRIDGE_HOME to live under a recognised tempdir prefix before
    # accepting the override; mktemp default satisfies that.
    if [[ -n "$controller_home" ]]; then
      export BRIDGE_CONTROLLER_HOME_OVERRIDE="$controller_home"
    else
      unset BRIDGE_CONTROLLER_HOME_OVERRIDE
    fi

    # shellcheck source=/dev/null
    source "$REPO_ROOT/bridge-lib.sh"

    # Stub the sudo/ACL/chown wrappers so the helper's writes land
    # under the caller's UID without root. This keeps the test
    # rootless while still exercising the real function.
    bridge_linux_sudo_root() { "$@"; }
    bridge_linux_acl_add() { :; }
    bridge_linux_acl_add_recursive() { :; }
    bridge_linux_acl_add_default_dirs_recursive() { :; }
    bridge_linux_grant_traverse_chain() { :; }
    bridge_linux_revoke_plugin_channel_grants() { :; }

    # Stub bridge_audit_log so we don't write to the audit jsonl with
    # a lock the test environment may not have.
    bridge_audit_log() { :; }

    # Roster entry the helper expects (declared channel + plugins).
    declare -gA BRIDGE_AGENT_CHANNELS
    declare -gA BRIDGE_AGENT_PLUGINS
    BRIDGE_AGENT_CHANNELS[probe-agent]="plugin:test-plugin@test-mkt"
    BRIDGE_AGENT_PLUGINS[probe-agent]=""

    if bridge_linux_share_plugin_catalog \
        "$(id -un)" "$user_home" "$(id -un)" "probe-agent" 2>"$case_dir/share.err"; then
      printf 'rc=0\n'
    else
      printf 'rc=%s\n' "$?"
    fi

    # Snapshot what the helper wrote.
    if [[ -f "$user_home/.claude/plugins/installed_plugins.json" ]]; then
      printf 'manifest_present=yes\n'
      printf 'manifest_size=%s\n' "$(wc -c <"$user_home/.claude/plugins/installed_plugins.json" | tr -d ' ')"
      python3 - <<PY
import json, os, sys
m_path = "$user_home/.claude/plugins/installed_plugins.json"
with open(m_path) as f:
    data = json.load(f)
plugin = data.get("plugins", {}).get("test-plugin@test-mkt", [])
if plugin:
    install_path = plugin[0].get("installPath", "")
    print(f"manifest_install_path={install_path}")
PY
    else
      printf 'manifest_present=no\n'
    fi

    # Marketplace symlink target.
    local mkt_link="$user_home/.claude/plugins/marketplaces/test-mkt"
    if [[ -L "$mkt_link" ]]; then
      printf 'mkt_symlink_target=%s\n' "$(readlink "$mkt_link")"
    else
      printf 'mkt_symlink_target=(none)\n'
    fi
  )
}

# ---------------------------------------------------------------------------
# Case 1: populated v2 + no legacy controller tree → v2 path used.
# ---------------------------------------------------------------------------
log "case 1: v2 populated, no legacy controller tree"
DATA1="$TMP_ROOT/case1-data"
build_v2_fixture "$DATA1" 1
# Create a fake controller home WITHOUT .claude/plugins so the legacy
# guard would have been hit before PR-B's fix.
CTRL1="$TMP_ROOT/case1-controller-home"
mkdir -p "$CTRL1"

result1="$(drive_share_helper case1 "$DATA1" "$CTRL1" v2)"

case "$result1" in
  *manifest_present=yes*) ok "case 1: manifest written from v2 path" ;;
  *) die "case 1: manifest NOT written (regression: legacy guard would have early-returned)
$result1" ;;
esac
case "$result1" in
  *"manifest_install_path=$DATA1/shared/plugins-cache/marketplaces/test-mkt/plugins/test-plugin"*)
    ok "case 1: manifest installPath rewritten to v2 directory marketplace"
    ;;
  *) die "case 1: manifest installPath did not point to v2 path
$result1" ;;
esac
case "$result1" in
  *"mkt_symlink_target=$DATA1/shared/plugins-cache/marketplaces/test-mkt"*)
    ok "case 1: marketplace symlink targets v2 path"
    ;;
  *) die "case 1: marketplace symlink does not target v2 path
$result1" ;;
esac

# ---------------------------------------------------------------------------
# Case 2: v2 dir exists but installed_plugins.json absent → fallback to legacy.
# ---------------------------------------------------------------------------
log "case 2: v2 unpopulated → legacy fallback"
DATA2="$TMP_ROOT/case2-data"
build_v2_fixture "$DATA2" 0   # creates dir but no installed_plugins.json
CTRL2="$TMP_ROOT/case2-controller-home"
build_legacy_fixture "$CTRL2"

result2="$(drive_share_helper case2 "$DATA2" "$CTRL2" v2)"

case "$result2" in
  *manifest_present=yes*) ok "case 2: manifest written via legacy fallback" ;;
  *) die "case 2: manifest NOT written
$result2" ;;
esac
case "$result2" in
  *"manifest_install_path=$CTRL2/.claude/plugins/marketplaces/test-mkt/plugins/test-plugin"*)
    ok "case 2: manifest installPath uses legacy controller tree"
    ;;
  *) die "case 2: manifest did not fall back to legacy path
$result2" ;;
esac

# ---------------------------------------------------------------------------
# Case 3: legacy mode (BRIDGE_LAYOUT unset) → controller tree used.
# ---------------------------------------------------------------------------
log "case 3: legacy mode"
CTRL3="$TMP_ROOT/case3-controller-home"
build_legacy_fixture "$CTRL3"

result3="$(drive_share_helper case3 "" "$CTRL3" legacy)"

case "$result3" in
  *manifest_present=yes*) ok "case 3: manifest written from legacy controller tree" ;;
  *) die "case 3: manifest NOT written
$result3" ;;
esac
case "$result3" in
  *"manifest_install_path=$CTRL3/.claude/plugins/marketplaces/test-mkt/plugins/test-plugin"*)
    ok "case 3: legacy installPath unchanged"
    ;;
  *) die "case 3: legacy installPath did not match controller tree
$result3" ;;
esac

# ---------------------------------------------------------------------------
# Case 4: neither v2 populated nor legacy tree → helper no-ops cleanly.
# ---------------------------------------------------------------------------
log "case 4: no v2, no legacy → no-op"
DATA4="$TMP_ROOT/case4-data"
mkdir -p "$DATA4/shared"
CTRL4="$TMP_ROOT/case4-controller-home"
mkdir -p "$CTRL4"   # but no .claude/plugins under it

result4="$(drive_share_helper case4 "$DATA4" "$CTRL4" v2)"

# A no-op return-0 leaves no manifest behind.
case "$result4" in
  *manifest_present=no*) ok "case 4: helper no-ops when neither root resolves" ;;
  *) die "case 4: helper unexpectedly produced a manifest
$result4" ;;
esac

log "all PR-B acceptance checks passed (4 cases against real bridge_linux_share_plugin_catalog)"
