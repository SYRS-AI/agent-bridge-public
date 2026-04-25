#!/usr/bin/env bash
# tests/isolation-plugin-sharing.sh
#
# Regression test for the channel-ownership-aware plugin sharing fix.
#
# Verifies, against a fully synthetic controller plugin tree (driven via
# the BRIDGE_CONTROLLER_HOME_OVERRIDE seam in
# bridge_linux_share_plugin_catalog) so the operator's real
# ~/.claude/plugins/ is never touched:
#
#   1. After isolate, the per-UID installed_plugins.json contains only
#      the plugin declared in BRIDGE_AGENT_CHANNELS, with installPath
#      rewritten to the actually-existing on-disk location.
#   2. Per-UID installed_plugins.json is root-owned 0640 and the
#      isolated UID has u:<uid>:r--; the agent cannot tamper with it.
#   3. plugins/ root is root-owned 0750 with isolated UID r-x;
#      plugins/data/ is isolated UID-owned 0700 and writable.
#   4. The declared plugin's directory-source install path receives a
#      u:<os_user>:r-X recursive ACL (r-- on files, r-x on directories);
#      the undeclared plugin's install path has NO u:<os_user> ACL
#      entry — the isolated UID cannot read sources for plugins it did
#      not declare in its channel set.
#   5. Catalog symlinks (known_marketplaces.json, install-counts-cache.json,
#      blocklist.json) under <isolated>/.claude/plugins/ exist and resolve
#      to the controller's copies.
#   6. After bridge_migration_unisolate, every u:<os_user> ACL on the
#      controller-side plugin tree is gone, the per-UID manifest is
#      removed, the catalog symlinks under the isolated home are gone,
#      and the legacy $BRIDGE_HOME/plugins recursive ACL strip leaves no
#      residue (regression guard for the backward-compat cleanup).
#
# Skip preconditions: Linux, passwordless sudo, setfacl, useradd available.
# Creates a temporary system user and tears it down at the end.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

log() { printf '[isolate-plugin] %s\n' "$*"; }
die() { printf '[isolate-plugin][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[isolate-plugin][skip] %s\n' "$*"; exit 0; }

[[ "$(uname -s)" == "Linux" ]] || skip "Linux-only test"
command -v sudo >/dev/null 2>&1 || skip "sudo required"
sudo -n true >/dev/null 2>&1 || skip "passwordless sudo required"
command -v setfacl >/dev/null 2>&1 || skip "setfacl (acl package) required"
command -v getfacl >/dev/null 2>&1 || skip "getfacl (acl package) required"
command -v useradd >/dev/null 2>&1 || skip "useradd required"
command -v userdel >/dev/null 2>&1 || skip "userdel required"

TMP_ROOT="$(mktemp -d -t isolate-plugin-test.XXXXXX)"
SAFE_TMP_PREFIX=""
for _candidate in "${TMPDIR%/}" "/tmp" "/var/tmp"; do
  [[ -n "$_candidate" ]] || continue
  case "$TMP_ROOT" in
    "$_candidate"|"$_candidate"/*) SAFE_TMP_PREFIX="$_candidate"; break ;;
  esac
done
[[ -n "$SAFE_TMP_PREFIX" ]] || die "TMP_ROOT did not land under a recognised tempdir prefix: $TMP_ROOT"

# Temp BRIDGE_HOME with a tiny directory marketplace ("td-mkt") containing
# both a declared plugin (declared-plugin) and an undeclared plugin
# (undeclared-plugin). BRIDGE_HOME must live under SAFE_TMP_PREFIX so the
# bridge_linux_share_plugin_catalog seam guard accepts our override.
export BRIDGE_HOME="$TMP_ROOT/bridge-home"
export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
mkdir -p "$BRIDGE_HOME" "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR" "$BRIDGE_ACTIVE_AGENT_DIR"
: > "$BRIDGE_ROSTER_FILE"
: > "$BRIDGE_ROSTER_LOCAL_FILE"

# Set up a fake controller .claude/plugins/ tree so the helper has a
# realistic surface to share. This stays under a fake controller home
# that the helper picks up via BRIDGE_CONTROLLER_HOME_OVERRIDE — the
# operator's real $HOME is never touched.
CONTROLLER_HOME_FAKE="$TMP_ROOT/controller-home"
CONTROLLER_PLUGINS="$CONTROLLER_HOME_FAKE/.claude/plugins"
mkdir -p "$CONTROLLER_PLUGINS/cache/td-mkt/declared-plugin/0.1.0" \
         "$CONTROLLER_PLUGINS/cache/td-mkt/undeclared-plugin/0.1.0" \
         "$CONTROLLER_PLUGINS/data" \
         "$CONTROLLER_PLUGINS/marketplaces"
echo 'declared plugin source' > "$CONTROLLER_PLUGINS/cache/td-mkt/declared-plugin/0.1.0/index.js"
echo 'undeclared plugin source' > "$CONTROLLER_PLUGINS/cache/td-mkt/undeclared-plugin/0.1.0/index.js"
cat > "$CONTROLLER_PLUGINS/installed_plugins.json" <<JSON
{
  "version": 2,
  "plugins": {
    "declared-plugin@td-mkt": [
      {"scope": "user", "version": "0.1.0",
       "installPath": "$BRIDGE_HOME/plugins/declared-plugin"}
    ],
    "undeclared-plugin@td-mkt": [
      {"scope": "user", "version": "0.1.0",
       "installPath": "$BRIDGE_HOME/plugins/undeclared-plugin"}
    ]
  }
}
JSON
cat > "$CONTROLLER_PLUGINS/known_marketplaces.json" <<JSON
{
  "td-mkt": {
    "source": {"source": "directory", "path": "$BRIDGE_HOME"},
    "installLocation": "$BRIDGE_HOME"
  }
}
JSON
echo '{}' > "$CONTROLLER_PLUGINS/install-counts-cache.json"
echo '{}' > "$CONTROLLER_PLUGINS/blocklist.json"

# Directory-marketplace shape: $BRIDGE_HOME/plugins/{declared,undeclared}.
# These are the actual install paths bridge_resolve_plugin_install_path
# will land on for the directory-source marketplace.
mkdir -p "$BRIDGE_HOME/plugins/declared-plugin" "$BRIDGE_HOME/plugins/undeclared-plugin"
echo 'declared plugin (dir-marketplace)' > "$BRIDGE_HOME/plugins/declared-plugin/server.ts"
echo 'undeclared plugin (dir-marketplace)' > "$BRIDGE_HOME/plugins/undeclared-plugin/server.ts"

# Make the controller-side plugin tree readable by everyone so the
# isolated UID can actually traverse it once we grant the per-UID ACLs.
# (The traverse chain stamps `--x` on parents up to controller_home;
#  base mode bits also need to allow read on files we explicitly grant.)
chmod -R o+rX "$CONTROLLER_HOME_FAKE" "$BRIDGE_HOME/plugins"

TEST_AGENT="qpa-test"
TEST_OS_USER="agent-bridge-${TEST_AGENT}"
TEST_OS_HOME="/home/${TEST_OS_USER}"

cleanup_test_user_locked=0
cleanup() {
  set +e
  # Belt-and-suspenders: strip every u:<TEST_OS_USER> ACL we might have
  # left on the controller plugin tree so the host doesn't end up with
  # poisoned ACLs if a step blew up between grant and revoke.
  if id "$TEST_OS_USER" >/dev/null 2>&1; then
    sudo -n setfacl -Rx "u:${TEST_OS_USER}" "$CONTROLLER_HOME_FAKE" >/dev/null 2>&1 || true
    sudo -n setfacl -Rx "u:${TEST_OS_USER}" "$BRIDGE_HOME/plugins" >/dev/null 2>&1 || true
  fi
  if [[ "$cleanup_test_user_locked" -eq 0 ]] && id "$TEST_OS_USER" >/dev/null 2>&1; then
    sudo -n userdel "$TEST_OS_USER" >/dev/null 2>&1 || true
    sudo -n rm -rf "$TEST_OS_HOME" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if id "$TEST_OS_USER" >/dev/null 2>&1; then
  cleanup_test_user_locked=1
  log "reusing existing OS user $TEST_OS_USER"
else
  sudo -n useradd --system --home-dir "$TEST_OS_HOME" --shell /usr/sbin/nologin "$TEST_OS_USER" >/dev/null \
    || die "useradd failed for $TEST_OS_USER"
fi
sudo -n mkdir -p "$TEST_OS_HOME"
sudo -n chown "$TEST_OS_USER:$TEST_OS_USER" "$TEST_OS_HOME"
sudo -n chmod 0700 "$TEST_OS_HOME"

TEST_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$TEST_AGENT"
mkdir -p "$TEST_WORKDIR"

# Roster declares declared-plugin@td-mkt only.
cat > "$BRIDGE_ROSTER_LOCAL_FILE" <<ROSTER
#!/usr/bin/env bash
bridge_add_agent_id_if_missing() { :; }
declare -gA BRIDGE_AGENT_ENGINE BRIDGE_AGENT_SESSION BRIDGE_AGENT_WORKDIR BRIDGE_AGENT_LAUNCH_CMD
declare -gA BRIDGE_AGENT_ISOLATION_MODE BRIDGE_AGENT_OS_USER BRIDGE_AGENT_CHANNELS
BRIDGE_AGENT_IDS=("$TEST_AGENT")
BRIDGE_AGENT_ENGINE[$TEST_AGENT]=claude
BRIDGE_AGENT_SESSION[$TEST_AGENT]=$TEST_AGENT
BRIDGE_AGENT_WORKDIR[$TEST_AGENT]=$TEST_WORKDIR
BRIDGE_AGENT_LAUNCH_CMD[$TEST_AGENT]='true'
BRIDGE_AGENT_CHANNELS[$TEST_AGENT]='plugin:declared-plugin@td-mkt'
BRIDGE_AGENT_ISOLATION_MODE[$TEST_AGENT]=linux-user
BRIDGE_AGENT_OS_USER[$TEST_AGENT]=$TEST_OS_USER
ROSTER

# shellcheck source=../bridge-lib.sh
source "$REPO_ROOT/bridge-lib.sh"
bridge_load_roster

# Drive the helper against the fake controller home via the test seam
# (BRIDGE_CONTROLLER_HOME_OVERRIDE). The seam refuses to honor the
# override unless BRIDGE_HOME is under a tempdir prefix; we asserted that
# above. The controller_user passed in is unused once the override is
# active, but we still pass the operator's name so the call-shape
# matches production.
log "running bridge_linux_share_plugin_catalog against fake controller home $CONTROLLER_HOME_FAKE"
CONTROLLER_USER="$(id -un)"
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

ISOLATED_PLUGINS="$TEST_OS_HOME/.claude/plugins"

log "verifying plugins/ root is root-owned with isolated UID r-x"
sudo -n stat -c '%U:%G %a' "$ISOLATED_PLUGINS" | grep -Fq "root:root 750" \
  || die "expected $ISOLATED_PLUGINS to be root:root 0750"
sudo -n getfacl --no-effective "$ISOLATED_PLUGINS" 2>/dev/null | grep -Fq "user:${TEST_OS_USER}:r-x" \
  || die "expected u:${TEST_OS_USER}:r-x ACL on $ISOLATED_PLUGINS"

log "verifying plugins/data is isolated UID-owned and writable"
sudo -n stat -c '%U:%G %a' "$ISOLATED_PLUGINS/data" | grep -Fq "${TEST_OS_USER}:${TEST_OS_USER} 700" \
  || die "expected $ISOLATED_PLUGINS/data to be ${TEST_OS_USER}:${TEST_OS_USER} 0700"
sudo -n -u "$TEST_OS_USER" bash -c "echo probe > '$ISOLATED_PLUGINS/data/x' && cat '$ISOLATED_PLUGINS/data/x' >/dev/null" \
  || die "isolated UID should be able to write+read its own plugins/data/"
sudo -n -u "$TEST_OS_USER" rm -f "$ISOLATED_PLUGINS/data/x"

log "verifying per-UID installed_plugins.json is root-owned r-- to isolated UID"
sudo -n stat -c '%U:%G %a' "$ISOLATED_PLUGINS/installed_plugins.json" | grep -Fq "root:root 640" \
  || die "expected per-UID installed_plugins.json to be root:root 0640"
sudo -n getfacl --no-effective "$ISOLATED_PLUGINS/installed_plugins.json" 2>/dev/null | grep -Fq "user:${TEST_OS_USER}:r--" \
  || die "expected u:${TEST_OS_USER}:r-- ACL on per-UID installed_plugins.json"

log "verifying isolated UID cannot tamper with its own manifest"
if sudo -n -u "$TEST_OS_USER" bash -c "echo broken > '$ISOLATED_PLUGINS/installed_plugins.json'" 2>/dev/null; then
  die "isolated UID should not be able to write its own installed_plugins.json"
fi
if sudo -n -u "$TEST_OS_USER" rm -f "$ISOLATED_PLUGINS/installed_plugins.json" 2>/dev/null; then
  if [[ ! -e "$ISOLATED_PLUGINS/installed_plugins.json" ]]; then
    die "isolated UID was able to unlink its own installed_plugins.json"
  fi
fi

log "verifying per-UID manifest contents only list the declared plugin"
manifest_dump="$(sudo -n cat "$ISOLATED_PLUGINS/installed_plugins.json")"
echo "$manifest_dump" | python3 -c '
import json, sys
m = json.load(sys.stdin)
plugins = list(m.get("plugins", {}).keys())
assert plugins == ["declared-plugin@td-mkt"], f"unexpected manifest plugins: {plugins!r}"
entry = m["plugins"]["declared-plugin@td-mkt"][0]
assert "installPath" in entry and entry["installPath"], "missing installPath"
' || die "per-UID manifest contents do not match the channel boundary"

log "verifying catalog symlinks resolve to controller copies"
for catalog in known_marketplaces.json install-counts-cache.json blocklist.json; do
  link="$ISOLATED_PLUGINS/$catalog"
  [[ -L "$link" ]] || die "expected $link to be a symlink"
  resolved="$(sudo -n readlink -f "$link" 2>/dev/null || true)"
  expected="$CONTROLLER_PLUGINS/$catalog"
  [[ "$resolved" == "$expected" ]] || die "catalog symlink $link resolved to $resolved (expected $expected)"
done

log "verifying declared plugin's install path has u:${TEST_OS_USER}:r-X recursively"
declared_path="$BRIDGE_HOME/plugins/declared-plugin"
sudo -n getfacl --no-effective "$declared_path" 2>/dev/null \
  | grep -Eq "^user:${TEST_OS_USER}:r(-x|wx)" \
  || die "declared plugin dir missing u:${TEST_OS_USER}:r-x ACL ($declared_path)"
sudo -n getfacl --no-effective "$declared_path/server.ts" 2>/dev/null \
  | grep -Eq "^user:${TEST_OS_USER}:r--" \
  || die "declared plugin file missing u:${TEST_OS_USER}:r-- ACL"

log "verifying isolated UID can read declared plugin sources"
sudo -n -u "$TEST_OS_USER" cat "$declared_path/server.ts" >/dev/null \
  || die "isolated UID should be able to read declared plugin source"

log "verifying undeclared plugin's install path has NO u:${TEST_OS_USER} ACL entry"
undeclared_path="$BRIDGE_HOME/plugins/undeclared-plugin"
undeclared_acl_count="$(sudo -n getfacl --no-effective "$undeclared_path" 2>/dev/null \
  | grep -cE "^user:${TEST_OS_USER}:" || true)"
[[ "$undeclared_acl_count" == "0" ]] \
  || die "undeclared plugin dir has $undeclared_acl_count u:${TEST_OS_USER} ACL entr(ies); expected 0"
undeclared_file_acl_count="$(sudo -n getfacl --no-effective "$undeclared_path/server.ts" 2>/dev/null \
  | grep -cE "^user:${TEST_OS_USER}:" || true)"
[[ "$undeclared_file_acl_count" == "0" ]] \
  || die "undeclared plugin file has $undeclared_file_acl_count u:${TEST_OS_USER} ACL entr(ies); expected 0"

log "verifying isolated UID is denied access to undeclared plugin sources"
if sudo -n -u "$TEST_OS_USER" cat "$undeclared_path/server.ts" >/dev/null 2>&1; then
  die "isolated UID should NOT be able to read undeclared plugin source"
fi

log "verifying persisted grant-set state file recorded the channel"
state_file="$BRIDGE_ACTIVE_AGENT_DIR/$TEST_AGENT/isolated-plugin-grants.json"
sudo -n test -e "$state_file" || die "expected persisted grant-set at $state_file"
sudo -n cat "$state_file" | python3 -c '
import json, sys
data = json.load(sys.stdin)
chans = data.get("channels", [])
assert chans == ["plugin:declared-plugin@td-mkt"], f"unexpected persisted channels: {chans!r}"
' || die "persisted grant-set contents do not match"

log "stale-ACL revoke on channel change (Blocking 1 regression)"

# At this point declared-plugin@td-mkt has been granted (line ~195 above).
# Confirm the grant landed on the original install path before flipping
# channels — without this baseline we can't tell a true revoke from a
# never-granted state.
sudo -n getfacl --no-effective "$BRIDGE_HOME/plugins/declared-plugin" 2>/dev/null \
  | grep -Eq "^user:${TEST_OS_USER}:r(-x|wx)" \
  || die "expected u:${TEST_OS_USER}:r-x on declared-plugin before channel flip"

# Add a fresh plugin (replacement-plugin) to both the directory marketplace
# tree and the controller's installed_plugins.json, then flip the agent's
# channel to it — drops declared-plugin, adds replacement-plugin.
mkdir -p "$CONTROLLER_PLUGINS/cache/td-mkt/replacement-plugin/0.1.0"
echo 'replacement plugin source (cache)' \
  > "$CONTROLLER_PLUGINS/cache/td-mkt/replacement-plugin/0.1.0/index.js"
mkdir -p "$BRIDGE_HOME/plugins/replacement-plugin"
echo 'replacement plugin (dir-marketplace)' \
  > "$BRIDGE_HOME/plugins/replacement-plugin/server.ts"
chmod -R o+rX "$CONTROLLER_HOME_FAKE" "$BRIDGE_HOME/plugins"

python3 - "$CONTROLLER_PLUGINS/installed_plugins.json" "$BRIDGE_HOME/plugins/replacement-plugin" <<'PY'
import json, sys
manifest_path, install_path = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    data = json.load(f)
data.setdefault("plugins", {})["replacement-plugin@td-mkt"] = [
    {"scope": "user", "version": "0.1.0", "installPath": install_path}
]
with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2)
PY

BRIDGE_AGENT_CHANNELS["$TEST_AGENT"]='plugin:replacement-plugin@td-mkt'

# Re-apply with the new channel set. This is the call shape that
# triggers the stale-revoke path on declared-plugin (prior set) and the
# grant path on replacement-plugin (current set).
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_linux_share_plugin_catalog "$TEST_OS_USER" "$TEST_OS_HOME" "$CONTROLLER_USER" "$TEST_AGENT"

log "verifying old plugin's u:${TEST_OS_USER} ACL is gone after channel flip"
stale_count="$(sudo -n getfacl --no-effective "$BRIDGE_HOME/plugins/declared-plugin" 2>/dev/null \
  | grep -cE "^user:${TEST_OS_USER}:" || true)"
[[ "$stale_count" == "0" ]] \
  || die "expected u:${TEST_OS_USER} ACL gone from declared-plugin after channel flip; still has $stale_count entr(ies)"

log "verifying new plugin's u:${TEST_OS_USER}:r-x ACL is present after channel flip"
sudo -n getfacl --no-effective "$BRIDGE_HOME/plugins/replacement-plugin" 2>/dev/null \
  | grep -Eq "^user:${TEST_OS_USER}:r(-x|wx)" \
  || die "expected u:${TEST_OS_USER}:r-x on replacement-plugin after channel flip"

log "verifying persisted grant-set reflects the new channel set, not the old"
sudo -n cat "$state_file" | python3 -c '
import json, sys
data = json.load(sys.stdin)
chans = data.get("channels", [])
assert chans == ["plugin:replacement-plugin@td-mkt"], f"unexpected persisted channels after flip: {chans!r}"
' || die "persisted grant-set did not reflect channel flip (expected only replacement-plugin)"

# After the channel flip the saved grant-set persists replacement-plugin
# only, so the upcoming unisolate-cleanup assertions need to target that
# path. Reassign declared_path here rather than introducing a parallel
# variable so the existing assertion loop below stays intact.
declared_path="$BRIDGE_HOME/plugins/replacement-plugin"

log "running bridge_migration_unisolate (dry_run=0) and verifying full ACL strip"
BRIDGE_CONTROLLER_HOME_OVERRIDE="$CONTROLLER_HOME_FAKE" \
  bridge_migration_unisolate "$TEST_AGENT" 0 \
  || die "bridge_migration_unisolate failed"

log "verifying every controller-side u:${TEST_OS_USER} ACL is gone"
for path in \
  "$declared_path" \
  "$declared_path/server.ts" \
  "$CONTROLLER_PLUGINS/known_marketplaces.json" \
  "$CONTROLLER_PLUGINS/install-counts-cache.json" \
  "$CONTROLLER_PLUGINS/blocklist.json"; do
  [[ -e "$path" ]] || continue
  count="$(sudo -n getfacl --no-effective "$path" 2>/dev/null \
    | grep -cE "^user:${TEST_OS_USER}:" || true)"
  [[ "$count" == "0" ]] \
    || die "post-unisolate u:${TEST_OS_USER} ACL still present on $path ($count entr(ies))"
done

log "verifying legacy \$BRIDGE_HOME/plugins ACL strip leaves no u:${TEST_OS_USER} residue"
residue="$(sudo -n getfacl --no-effective -R "$BRIDGE_HOME/plugins" 2>/dev/null \
  | grep -cE "^user:${TEST_OS_USER}:" || true)"
[[ "$residue" == "0" ]] \
  || die "legacy \$BRIDGE_HOME/plugins still has $residue u:${TEST_OS_USER} ACL entr(ies)"

log "verifying isolated-side cleanup removed catalog symlinks + per-UID manifest"
for catalog in known_marketplaces.json install-counts-cache.json blocklist.json installed_plugins.json; do
  link="$ISOLATED_PLUGINS/$catalog"
  if sudo -n test -e "$link" 2>/dev/null || sudo -n test -L "$link" 2>/dev/null; then
    die "post-unisolate $link still exists; expected isolated-side cleanup to remove it"
  fi
done

log "verifying persisted grant-set state file was removed"
if sudo -n test -e "$state_file" 2>/dev/null; then
  die "post-unisolate $state_file still exists; expected grant-set teardown"
fi

log "isolation plugin sharing test passed"
