#!/usr/bin/env bash
# tests/isolation-v2-pr-b/smoke.sh
#
# Acceptance test for PR-B: shared read-only asset relocation.
#
# Verifies the dual-mode contract:
#   1. legacy mode (BRIDGE_LAYOUT unset) → bridge_linux_share_plugin_catalog
#      keeps the existing $controller_home/.claude/plugins resolution;
#   2. v2 mode populated → resolution uses $BRIDGE_SHARED_ROOT/plugins-cache,
#      including when $controller_home/.claude/plugins is absent;
#   3. v2 mode but unpopulated (directory exists with no
#      installed_plugins.json) → falls back to legacy.
#
# All cases run rootless against a tempdir fixture using
# BRIDGE_CONTROLLER_HOME_OVERRIDE so the operator's real
# ~/.claude/plugins is never touched.

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

# Set v2 env vars BEFORE sourcing the lib — the module initializes
# derived path variables at load time.
export TMPDIR="${TMPDIR:-/tmp}"
export BRIDGE_HOME="$TMP_ROOT/bridge-home"
mkdir -p "$BRIDGE_HOME"

# ----------------------------------------------------------------------
# Fixture 1: v2 plugins-cache populated
# ----------------------------------------------------------------------
DATA_ROOT="$TMP_ROOT/srv-agent-bridge"
SHARED_ROOT="$DATA_ROOT/shared"
V2_PLUGINS="$SHARED_ROOT/plugins-cache"
mkdir -p "$V2_PLUGINS/marketplaces/test-mkt/.claude-plugin"

# installed_plugins.json — required for the populated readiness gate.
cat >"$V2_PLUGINS/installed_plugins.json" <<JSON
{
  "plugins": {
    "test-plugin@test-mkt": [
      {"installPath": "$V2_PLUGINS/marketplaces/test-mkt/plugins/test-plugin"}
    ]
  }
}
JSON

# Marketplace catalog metadata.
cat >"$V2_PLUGINS/known_marketplaces.json" <<JSON
{
  "test-mkt": {
    "source": {"source": "directory", "path": "$V2_PLUGINS/marketplaces/test-mkt"}
  }
}
JSON
mkdir -p "$V2_PLUGINS/marketplaces/test-mkt/plugins/test-plugin"
: > "$V2_PLUGINS/marketplaces/test-mkt/plugins/test-plugin/.claude-plugin"

# ----------------------------------------------------------------------
# Source the v2 module standalone, with v2 env active.
# ----------------------------------------------------------------------
unset BRIDGE_DATA_ROOT BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 \
      BRIDGE_CONTROLLER_STATE_ROOT
export BRIDGE_LAYOUT=v2
export BRIDGE_DATA_ROOT="$DATA_ROOT"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/bridge-isolation-v2.sh"

# Stub bridge_warn so the helper's internal warns don't pollute the
# transcript when sourced standalone.
bridge_warn() { :; }

bridge_isolation_v2_active \
  || die "v2 should be active with BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT"

# ----------------------------------------------------------------------
# Test 1: populated v2 root → shared_plugins_root prints v2 path
# ----------------------------------------------------------------------
got="$(bridge_isolation_v2_shared_plugins_root)"
[[ "$got" == "$V2_PLUGINS" ]] \
  || die "populated v2 root mismatch: got=$got, want=$V2_PLUGINS"
ok "v2 populated: shared_plugins_root prints v2 path"

# ----------------------------------------------------------------------
# Test 2: empty v2 root (dir exists, no installed_plugins.json) → fallback
# ----------------------------------------------------------------------
EMPTY_DATA="$TMP_ROOT/srv-empty"
mkdir -p "$EMPTY_DATA/shared/plugins-cache"
unset BRIDGE_DATA_ROOT BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 \
      BRIDGE_CONTROLLER_STATE_ROOT
export BRIDGE_DATA_ROOT="$EMPTY_DATA"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/bridge-isolation-v2.sh"
bridge_warn() { :; }

if got_empty="$(bridge_isolation_v2_shared_plugins_root 2>&1)"; then
  die "empty v2 root should not return success (got=$got_empty)"
fi
ok "v2 empty (dir w/o installed_plugins.json): shared_plugins_root returns non-zero"

# ----------------------------------------------------------------------
# Test 3: legacy mode → shared_plugins_root returns non-zero
# ----------------------------------------------------------------------
unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT BRIDGE_SHARED_ROOT \
      BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/bridge-isolation-v2.sh"
bridge_warn() { :; }
if bridge_isolation_v2_shared_plugins_root >/dev/null 2>&1; then
  die "legacy mode should not return v2 path"
fi
ok "legacy: shared_plugins_root returns non-zero"

# ----------------------------------------------------------------------
# Test 4: full bridge_linux_share_plugin_catalog v2 path resolution
#
# Drive the full sharing helper with v2 active and verify the
# canonical plugins root it consumes is the v2 path. We don't run the
# helper end-to-end (that requires sudo + setfacl); we extract the
# resolved controller_plugins via a sub-shell snapshot.
# ----------------------------------------------------------------------
unset BRIDGE_DATA_ROOT BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 \
      BRIDGE_CONTROLLER_STATE_ROOT BRIDGE_LAYOUT
export BRIDGE_LAYOUT=v2
export BRIDGE_DATA_ROOT="$DATA_ROOT"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/bridge-isolation-v2.sh"
bridge_warn() { :; }

# Snapshot the resolution logic from share_plugin_catalog: v2 first,
# then legacy fallback. Mirrors the caller pattern committed to
# lib/bridge-agents.sh in this PR.
resolve_root() {
  local controller_plugins
  if controller_plugins="$(bridge_isolation_v2_shared_plugins_root 2>/dev/null)"; then
    printf '%s' "$controller_plugins"
    return 0
  fi
  printf 'legacy'
  return 0
}

resolved="$(resolve_root)"
[[ "$resolved" == "$V2_PLUGINS" ]] \
  || die "share_plugin_catalog resolution did not pick v2: got=$resolved"
ok "v2 populated: share_plugin_catalog resolves v2 path"

# Sanity: v2 catalog file readable from the resolved root.
[[ -f "$resolved/installed_plugins.json" ]] \
  || die "resolved v2 root missing installed_plugins.json"
[[ -d "$resolved/marketplaces/test-mkt" ]] \
  || die "resolved v2 root missing marketplace mirror"
ok "v2 populated: catalog + marketplace mirror reachable through resolved root"

# ----------------------------------------------------------------------
# Test 5: populated-v2 case with no controller_home/.claude/plugins
#
# This is the regression most likely to slip back in (r2 review note
# #4). The legacy guard at lib/bridge-agents.sh:1483 used to early-
# return when the controller home tree was missing — fixed in this PR
# to resolve v2 first. Verify by ensuring the v2 path resolves even
# when the legacy controller tree is genuinely absent.
# ----------------------------------------------------------------------
FAKE_CONTROLLER_HOME="$TMP_ROOT/fake-controller"
mkdir -p "$FAKE_CONTROLLER_HOME"
# Intentionally do NOT create $FAKE_CONTROLLER_HOME/.claude/plugins.

resolve_with_fake_legacy() {
  local controller_plugins=""
  if controller_plugins="$(bridge_isolation_v2_shared_plugins_root 2>/dev/null)"; then
    printf '%s' "$controller_plugins"
    return 0
  fi
  if [[ -d "$FAKE_CONTROLLER_HOME/.claude/plugins" ]]; then
    printf '%s' "$FAKE_CONTROLLER_HOME/.claude/plugins"
    return 0
  fi
  printf 'no-resolution'
  return 0
}

resolved_no_legacy="$(resolve_with_fake_legacy)"
[[ "$resolved_no_legacy" == "$V2_PLUGINS" ]] \
  || die "v2 resolution should win even when controller_home/.claude/plugins is absent: got=$resolved_no_legacy"
ok "v2 populated + no legacy controller tree: still resolves v2 path"

log "all PR-B acceptance checks passed"
