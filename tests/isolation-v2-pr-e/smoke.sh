#!/usr/bin/env bash
# tests/isolation-v2-pr-e/smoke.sh
#
# Acceptance test for PR-E. See top of file in PR-E plan-review r5/r6
# for the full case list. The smoke drives the REAL helpers from
# `lib/bridge-agents.sh`, `lib/bridge-isolation-v2.sh`, and
# `bridge-run.sh` (helper definition copied inline because the smoke
# cannot run the full bridge-run.sh entrypoint).
#
# Each case is a function; a small dispatcher sets up the v2 (or
# legacy) subshell, sources bridge-lib.sh, installs a sudo-wrapper
# stub that logs argv, and invokes the case body. Subshell isolation
# is via `( ... )` parens, which inherit functions defined in the
# parent.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

log()  { printf '[v2-pr-e] %s\n' "$*"; }
die()  { printf '[v2-pr-e][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[v2-pr-e][skip] %s\n' "$*"; exit 0; }
ok()   { printf '[v2-pr-e] ok: %s\n' "$*"; }

if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required"
fi
command -v python3 >/dev/null 2>&1 || skip "python3 missing"

TMP_ROOT="$(mktemp -d -t isolation-v2-pr-e.XXXXXX)"
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT
export TMPDIR="${TMPDIR:-/tmp}"

# ---------------------------------------------------------------------------
# Subshell helpers — caller passes a function NAME (defined in this
# script) and we invoke it after wiring up the lib + sudo stub.
# ---------------------------------------------------------------------------

# Stub bridge_linux_sudo_root — log argv to $_BRIDGE_LINUX_SUDO_LOG_FILE,
# pass through benign filesystem ops, swallow setfacl. The log path is
# stored in a non-local variable because bash binds variable references
# at call time, not at function-definition time, so a `local log` would
# be out of scope when the stub is invoked later.
make_sudo_stub() {
  _BRIDGE_LINUX_SUDO_LOG_FILE="$1"
  bridge_linux_sudo_root() {
    printf '%s\n' "$*" >>"$_BRIDGE_LINUX_SUDO_LOG_FILE"
    case "${1:-}" in
      # Filesystem state ops we want to exercise — the case body asserts
      # post-conditions like mode/existence after these run.
      test) shift; test "$@" ;;
      mkdir|chmod|touch|ln|rm|mv|find|mktemp|python3) "$@" ;;
      # chown/chgrp need root in real life. The smoke is rootless, so
      # we only want them in the sudo log (for grep-on-log assertions).
      # Skip the actual call. Failure of a real chgrp to a non-existent
      # group would otherwise wipe out the v2 fail-fast we validate.
      chown|chgrp) return 0 ;;
      setfacl) return 0 ;;
      bash) shift; bash "$@" ;;  # pass-through for `bash -lc 'command -v setfacl'`
      *) return 0 ;;
    esac
  }
}

run_in_v2() {
  local case_dir="$1"; shift
  local sudo_log="$1"; shift
  local fn="$1"; shift
  (
    set -e
    export BRIDGE_HOME="$case_dir/bridge-home"
    export BRIDGE_LAYOUT="v2"
    export BRIDGE_DATA_ROOT="$case_dir/data"
    mkdir -p "$BRIDGE_HOME" "$BRIDGE_DATA_ROOT/agents" \
             "$BRIDGE_DATA_ROOT/shared" "$BRIDGE_DATA_ROOT/state"
    unset BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT
    # shellcheck source=/dev/null
    source "$REPO_ROOT/bridge-lib.sh"
    make_sudo_stub "$sudo_log"
    "$fn" "$@"
  )
}

run_in_legacy() {
  local case_dir="$1"; shift
  local sudo_log="$1"; shift
  local fn="$1"; shift
  (
    set -e
    export BRIDGE_HOME="$case_dir/bridge-home"
    unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT BRIDGE_SHARED_ROOT \
          BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT
    mkdir -p "$BRIDGE_HOME"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/bridge-lib.sh"
    make_sudo_stub "$sudo_log"
    "$fn" "$@"
  )
}

assert_no_setfacl() {
  local sudo_log="$1"
  local context="${2:-}"
  if grep -qE '(^|find .* -exec )setfacl' "$sudo_log"; then
    printf '[v2-pr-e][error] %s: expected zero setfacl calls but found:\n' "$context" >&2
    grep -nE 'setfacl' "$sudo_log" >&2 || true
    return 1
  fi
}

assert_some_setfacl() {
  local sudo_log="$1"
  local context="${2:-}"
  if ! grep -qE '(^|find .* -exec )setfacl' "$sudo_log"; then
    printf '[v2-pr-e][error] %s: expected at least one setfacl call but found none\n' "$context" >&2
    return 1
  fi
}

# Inline copy of bridge_run_apply_v2_umask_if_needed — keeps the smoke
# self-contained without sourcing bridge-run.sh (which has top-level
# argv parsing). Drift between this copy and the real helper is itself
# something the smoke catches, because the underlying contract
# (`bridge_isolation_v2_active && bridge_agent_linux_user_isolation_effective`
# → umask 007) is what gets tested.
smoke_bridge_run_apply_v2_umask_if_needed() {
  local agent="$1"
  if bridge_isolation_v2_active 2>/dev/null \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    umask 007
  fi
  if [[ -n "${BRIDGE_RUN_UMASK_PROBE_FILE:-}" ]]; then
    umask >"$BRIDGE_RUN_UMASK_PROBE_FILE" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# P1: ACL primitive helpers no-op in v2 mode
# ---------------------------------------------------------------------------
case_p1() {
  bridge_linux_acl_add "u:foo:r--" /tmp/x
  bridge_linux_acl_add_recursive "u:foo:rwX" /tmp/x
  bridge_linux_acl_add_default_dirs_recursive "u:foo:rwX" /tmp/x
  bridge_linux_acl_remove_recursive "u:foo" /tmp/x
}
log "case: P1 ACL primitive helpers no-op in v2"
P1_DIR="$TMP_ROOT/p1"
P1_LOG="$P1_DIR/sudo.log"
mkdir -p "$P1_DIR"
: >"$P1_LOG"
run_in_v2 "$P1_DIR" "$P1_LOG" case_p1
assert_no_setfacl "$P1_LOG" "P1 v2 primitives" || die "P1 leaked setfacl"
ok "P1 v2 ACL primitives all no-op"

# ---------------------------------------------------------------------------
# P2: Direct-setfacl helpers no-op in v2 mode
# ---------------------------------------------------------------------------
case_p2() {
  bridge_linux_revoke_traverse_chain "foo" "/tmp/some/dir" "/tmp"
  bridge_linux_revoke_plugin_channel_grants "foo" "fake-plugin" "/tmp/plugins" "/tmp"
  bridge_linux_acl_repair_channel_env_files "smoke-agent" >/dev/null 2>&1 || true
}
log "case: P2 direct-setfacl helpers no-op in v2"
P2_DIR="$TMP_ROOT/p2"
P2_LOG="$P2_DIR/sudo.log"
mkdir -p "$P2_DIR"
: >"$P2_LOG"
run_in_v2 "$P2_DIR" "$P2_LOG" case_p2
assert_no_setfacl "$P2_LOG" "P2 v2 direct setfacl helpers" || die "P2 leaked setfacl"
ok "P2 v2 direct-setfacl helpers all no-op"

# ---------------------------------------------------------------------------
# P3: grant_traverse_chain v2-noop via bridge_linux_acl_add
# ---------------------------------------------------------------------------
case_p3() {
  local base="$1"
  bridge_linux_grant_traverse_chain "foo" "$base/a/b/c" "$base"
}
log "case: P3 grant_traverse_chain v2-noop"
P3_DIR="$TMP_ROOT/p3"
P3_LOG="$P3_DIR/sudo.log"
mkdir -p "$P3_DIR/a/b/c"
: >"$P3_LOG"
run_in_v2 "$P3_DIR" "$P3_LOG" case_p3 "$P3_DIR"
assert_no_setfacl "$P3_LOG" "P3 v2 grant_traverse_chain" || die "P3 leaked setfacl"
ok "P3 v2 grant_traverse_chain no-op"

# ---------------------------------------------------------------------------
# P4: _bridge_linux_grant_traverse_paths refactor parity + safety
# ---------------------------------------------------------------------------
case_p4_emit() {
  local target="$1"
  local stop="$2"
  _bridge_linux_grant_traverse_paths "$target" "$stop"
}
log "case: P4 _bridge_linux_grant_traverse_paths parity"
P4_DIR="$TMP_ROOT/p4"
P4_LOG="$P4_DIR/sudo.log"
mkdir -p "$P4_DIR/x/y/z"
: >"$P4_LOG"
v2_paths="$(run_in_v2 "$P4_DIR" "$P4_LOG" case_p4_emit "$P4_DIR/x/y/z" "$P4_DIR")"
legacy_paths="$(run_in_legacy "$P4_DIR" "$P4_LOG" case_p4_emit "$P4_DIR/x/y/z" "$P4_DIR")"
[[ "$v2_paths" == "$legacy_paths" ]] \
  || die "P4 path emitter parity failed: v2='$v2_paths' legacy='$legacy_paths'"
empty_out="$(run_in_v2 "$P4_DIR" "$P4_LOG" case_p4_emit "$P4_DIR/x" "" 2>/dev/null)"
[[ -z "$empty_out" ]] || die "P4 missing-stop should emit no paths, got: $empty_out"
slash_out="$(run_in_v2 "$P4_DIR" "$P4_LOG" case_p4_emit "$P4_DIR/x" "/" 2>/dev/null)"
[[ -z "$slash_out" ]] || die "P4 stop=/ should emit no paths, got: $slash_out"
ok "P4 path emitter parity + safety guards intact"

# ---------------------------------------------------------------------------
# E1: bridge_write_linux_agent_env_file in v2 — chgrp + 0640, no setfacl
# ---------------------------------------------------------------------------
case_e1() {
  local env_file="$1"
  bridge_load_roster
  BRIDGE_AGENT_IDS=("smoke-e1")
  BRIDGE_AGENT_ENGINE["smoke-e1"]="codex"
  BRIDGE_AGENT_WORKDIR["smoke-e1"]="/tmp/wd"
  BRIDGE_AGENT_ISOLATION_MODE["smoke-e1"]="linux-user"
  BRIDGE_AGENT_OS_USER["smoke-e1"]="ec2-user"
  bridge_write_linux_agent_env_file "smoke-e1" "$env_file"
  local mode
  mode=$(stat -c "%a" "$env_file")
  [[ "$mode" == "640" ]] || { echo "expected mode 640, got $mode" >&2; return 30; }
}
log "case: E1 env file v2 group-mode"
E1_DIR="$TMP_ROOT/e1"
E1_LOG="$E1_DIR/sudo.log"
mkdir -p "$E1_DIR"
: >"$E1_LOG"
run_in_v2 "$E1_DIR" "$E1_LOG" case_e1 "$E1_DIR/env.sh" \
  || die "E1 env file v2 path failed"
assert_no_setfacl "$E1_LOG" "E1 v2 env file" || die "E1 leaked setfacl"
grep -q "^chmod 0640 .*env\.sh" "$E1_LOG" || die "E1 missing chmod 0640 in sudo log"
grep -q "^chgrp ab-agent-smoke-e1 .*env\.sh" "$E1_LOG" || die "E1 missing chgrp ab-agent-smoke-e1"
ok "E1 env file v2 group-mode (chgrp + chmod 0640, no setfacl)"

# ---------------------------------------------------------------------------
# M1: manifest writer in v2 with agent arg
# ---------------------------------------------------------------------------
case_m1() {
  local iso="$1"
  local ctrl="$2"
  bridge_write_isolated_installed_plugins_manifest \
    "ec2-user" "$iso" "$ctrl" "" "" "smoke-m1"
  [[ -f "$iso/installed_plugins.json" ]] || { echo "manifest missing" >&2; return 31; }
}
log "case: M1 manifest writer v2 group-mode"
M1_DIR="$TMP_ROOT/m1"
M1_LOG="$M1_DIR/sudo.log"
mkdir -p "$M1_DIR/iso-plugins" "$M1_DIR/ctrl-plugins"
echo '{"plugins":{}}' > "$M1_DIR/ctrl-plugins/installed_plugins.json"
: >"$M1_LOG"
run_in_v2 "$M1_DIR" "$M1_LOG" case_m1 "$M1_DIR/iso-plugins" "$M1_DIR/ctrl-plugins"
assert_no_setfacl "$M1_LOG" "M1 v2 manifest" || die "M1 leaked setfacl"
grep -q "^chmod 0640 .*\.tmp\." "$M1_LOG" || die "M1 missing chmod 0640 on tmp"
grep -q "^chgrp ab-agent-smoke-m1" "$M1_LOG" || die "M1 missing chgrp ab-agent-smoke-m1"
ok "M1 manifest writer v2 group-mode"

# ---------------------------------------------------------------------------
# M2: manifest writer dies in v2 without agent arg
# ---------------------------------------------------------------------------
case_m2() {
  local iso="$1"
  local ctrl="$2"
  bridge_write_isolated_installed_plugins_manifest \
    "ec2-user" "$iso" "$ctrl" "" ""  # intentional: no agent arg
}
log "case: M2 manifest writer requires agent arg in v2"
M2_DIR="$TMP_ROOT/m2"
M2_LOG="$M2_DIR/sudo.log"
mkdir -p "$M2_DIR/iso-plugins" "$M2_DIR/ctrl-plugins"
echo '{"plugins":{}}' > "$M2_DIR/ctrl-plugins/installed_plugins.json"
: >"$M2_LOG"
m2_rc=0
run_in_v2 "$M2_DIR" "$M2_LOG" case_m2 "$M2_DIR/iso-plugins" "$M2_DIR/ctrl-plugins" \
  2>/dev/null || m2_rc=$?
[[ $m2_rc -ne 0 ]] || die "M2 manifest writer should die without agent arg in v2"
ok "M2 manifest writer requires agent arg in v2 (rc=$m2_rc)"

# ---------------------------------------------------------------------------
# PC1: bridge_linux_share_plugin_catalog plugin root in v2
# ---------------------------------------------------------------------------
case_pc1() {
  local iso_root="$1"
  local ctrl_home="$2"
  local user_home="$3"
  bridge_load_roster
  BRIDGE_AGENT_IDS=("smoke-pc1")
  BRIDGE_AGENT_ENGINE["smoke-pc1"]="claude"
  BRIDGE_AGENT_WORKDIR["smoke-pc1"]="/tmp/wd-pc1"
  BRIDGE_AGENT_CHANNELS["smoke-pc1"]=""
  BRIDGE_AGENT_PLUGINS["smoke-pc1"]=""
  # Override controller home resolution so the helper does not walk into
  # the real operator home. The helper's tempdir guard restricts the
  # override to BRIDGE_HOME under /tmp/ or $TMPDIR/, which our run_in_v2
  # fixture already places. The helper expects controller HOME (not the
  # plugins dir); it appends `/.claude/plugins` itself.
  export BRIDGE_CONTROLLER_HOME_OVERRIDE="$ctrl_home"
  bridge_linux_share_plugin_catalog "ec2-user" "$user_home" "ec2-user" "smoke-pc1"
  [[ -d "$iso_root" ]] || { echo "iso plugins root missing" >&2; return 32; }
}
log "case: PC1 plugin catalog root v2 group-mode"
PC1_DIR="$TMP_ROOT/pc1"
PC1_LOG="$PC1_DIR/sudo.log"
mkdir -p "$PC1_DIR/iso-home/.claude" \
         "$PC1_DIR/ctrl-home/.claude/plugins"
echo '{"plugins":{}}' > "$PC1_DIR/ctrl-home/.claude/plugins/installed_plugins.json"
: >"$PC1_LOG"
ISO_PLUGIN_ROOT="$PC1_DIR/iso-home/.claude/plugins"
run_in_v2 "$PC1_DIR" "$PC1_LOG" case_pc1 \
  "$ISO_PLUGIN_ROOT" "$PC1_DIR/ctrl-home" "$PC1_DIR/iso-home"
assert_no_setfacl "$PC1_LOG" "PC1 v2 plugin catalog" || die "PC1 leaked setfacl"
grep -q "^chmod 2750 .*\.claude/plugins" "$PC1_LOG" \
  || die "PC1 missing chmod 2750 on plugins root"
grep -q "^chown root:ab-agent-smoke-pc1 .*\.claude/plugins" "$PC1_LOG" \
  || die "PC1 missing chown root:ab-agent-smoke-pc1 on plugins root"
ok "PC1 plugin catalog root v2 group-mode (2750 + group-correct, no setfacl)"

# ---------------------------------------------------------------------------
# UM1: bridge-run.sh v2 umask helper sets 0007
# ---------------------------------------------------------------------------
case_um1() {
  bridge_load_roster
  BRIDGE_AGENT_IDS=("smoke-um1")
  BRIDGE_AGENT_ENGINE["smoke-um1"]="codex"
  BRIDGE_AGENT_WORKDIR["smoke-um1"]="/tmp/wd"
  BRIDGE_AGENT_ISOLATION_MODE["smoke-um1"]="linux-user"
  BRIDGE_AGENT_OS_USER["smoke-um1"]="ec2-user"
  smoke_bridge_run_apply_v2_umask_if_needed "smoke-um1"
}
log "case: UM1 bridge_run_apply_v2_umask_if_needed in v2"
UM1_DIR="$TMP_ROOT/um1"
UM1_LOG="$UM1_DIR/sudo.log"
UM1_PROBE="$UM1_DIR/umask.probe"
mkdir -p "$UM1_DIR"
: >"$UM1_PROBE"
BRIDGE_RUN_UMASK_PROBE_FILE="$UM1_PROBE" run_in_v2 "$UM1_DIR" "$UM1_LOG" case_um1
um1_recorded="$(cat "$UM1_PROBE" 2>/dev/null || true)"
[[ "$um1_recorded" == "0007" ]] || die "UM1 expected probe=0007, got: '$um1_recorded'"
ok "UM1 v2 + linux-user → bridge-run.sh helper sets umask 0007"

# ---------------------------------------------------------------------------
# UM2: helper inert in legacy mode
# ---------------------------------------------------------------------------
case_um2() {
  bridge_load_roster
  BRIDGE_AGENT_IDS=("smoke-um2")
  BRIDGE_AGENT_ENGINE["smoke-um2"]="codex"
  BRIDGE_AGENT_ISOLATION_MODE["smoke-um2"]="shared"
  smoke_bridge_run_apply_v2_umask_if_needed "smoke-um2"
}
log "case: UM2 bridge_run_apply_v2_umask_if_needed inert in legacy"
UM2_DIR="$TMP_ROOT/um2"
UM2_LOG="$UM2_DIR/sudo.log"
UM2_PROBE="$UM2_DIR/umask.probe"
mkdir -p "$UM2_DIR"
: >"$UM2_PROBE"
BRIDGE_RUN_UMASK_PROBE_FILE="$UM2_PROBE" run_in_legacy "$UM2_DIR" "$UM2_LOG" case_um2
um2_recorded="$(cat "$UM2_PROBE" 2>/dev/null || true)"
[[ "$um2_recorded" == "0077" ]] || die "UM2 expected probe=0077 (bridge-lib default), got: '$um2_recorded'"
ok "UM2 legacy mode → helper inert (umask stays 0077)"

# ---------------------------------------------------------------------------
# EC1/EC2/EC3: engine CLI v2 fail-fast vs system-path pass-through
# ---------------------------------------------------------------------------
case_ec1() {
  local home_path="$1"
  bridge_resolve_engine_cli() { printf "%s" "$home_path/fake-home/.local/bin/claude"; }
  bridge_linux_traverse_stop_for() { printf "%s" "$home_path/fake-home"; }
  bridge_linux_grant_engine_cli_access "ec2-user" "claude"
}
case_ec2() {
  local home_path="$1"
  bridge_resolve_engine_cli() { printf "%s" "$home_path/fake-system/claude-symlink"; }
  bridge_linux_traverse_stop_for() {
    case "$1" in
      *fake-home/.local/bin/claude) printf "%s" "$home_path/fake-home" ;;
      *) printf "" ;;
    esac
  }
  bridge_linux_grant_engine_cli_access "ec2-user" "claude"
}
case_ec3() {
  local home_path="$1"
  bridge_resolve_engine_cli() { printf "%s" "$home_path/fake-system/claude"; }
  bridge_linux_traverse_stop_for() { printf ""; }
  bridge_linux_can_sudo_to() { return 1; }  # skip optional probe
  bridge_linux_grant_engine_cli_access "ec2-user" "claude"
}
log "case: EC1/EC2/EC3 engine CLI v2 controller-home reject + system-path pass"
EC_DIR="$TMP_ROOT/ec"
EC_LOG="$EC_DIR/sudo.log"
mkdir -p "$EC_DIR/fake-home/.local/bin" "$EC_DIR/fake-system"
touch "$EC_DIR/fake-home/.local/bin/claude"
chmod 0755 "$EC_DIR/fake-home/.local/bin/claude"
touch "$EC_DIR/fake-system/claude"
chmod 0755 "$EC_DIR/fake-system/claude"
ln -sf "$EC_DIR/fake-home/.local/bin/claude" "$EC_DIR/fake-system/claude-symlink"
: >"$EC_LOG"

ec1_rc=0
run_in_v2 "$EC_DIR" "$EC_LOG" case_ec1 "$EC_DIR" 2>/dev/null || ec1_rc=$?
[[ $ec1_rc -ne 0 ]] || die "EC1 expected die for controller-home cli_path, got rc=0"
ok "EC1 v2 engine CLI controller-home reject (rc=$ec1_rc)"

ec2_rc=0
run_in_v2 "$EC_DIR" "$EC_LOG" case_ec2 "$EC_DIR" 2>/dev/null || ec2_rc=$?
[[ $ec2_rc -ne 0 ]] || die "EC2 expected die for controller-home cli_real (symlink), got rc=0"
ok "EC2 v2 engine CLI controller-home cli_real reject (rc=$ec2_rc)"

: >"$EC_LOG"
run_in_v2 "$EC_DIR" "$EC_LOG" case_ec3 "$EC_DIR"
assert_no_setfacl "$EC_LOG" "EC3 v2 engine CLI system path" || die "EC3 leaked setfacl on system path"
ok "EC3 v2 engine CLI system path pass-through (no setfacl)"

# ---------------------------------------------------------------------------
# CR1: credentials helper in v2 → setfacl ≥ 1 (transitional exception)
# ---------------------------------------------------------------------------
case_cr1() {
  local cr_dir="$1"
  bridge_linux_require_setfacl() { return 0; }
  getent() {
    if [[ "$1" == "passwd" && "$2" == "ec2-user" ]]; then
      printf "ec2-user:x:1000:1000::%s:/bin/bash\n" "$cr_dir/ctrl-home"
    fi
  }
  bridge_linux_grant_claude_credentials_access \
    "ec2-user" "$cr_dir/iso-home" "ec2-user" "claude"
}
log "case: CR1 credentials helper v2 transitional exception"
CR_DIR="$TMP_ROOT/cr"
CR_LOG="$CR_DIR/sudo.log"
mkdir -p "$CR_DIR/ctrl-home/.claude" "$CR_DIR/iso-home"
echo '{"token":"redacted"}' > "$CR_DIR/ctrl-home/.claude/.credentials.json"
chmod 0600 "$CR_DIR/ctrl-home/.claude/.credentials.json"
: >"$CR_LOG"
run_in_v2 "$CR_DIR" "$CR_LOG" case_cr1 "$CR_DIR"
assert_some_setfacl "$CR_LOG" "CR1 v2 credentials helper" \
  || die "CR1 expected setfacl ≥ 1 for v2 cred exception"
ok "CR1 v2 credentials helper transitional exception (setfacl ≥ 1)"

# ---------------------------------------------------------------------------
# CR2: credentials helper in v2 + missing setfacl → die before symlink plant
# ---------------------------------------------------------------------------
case_cr2() {
  local cr_dir="$1"
  bridge_linux_require_setfacl() { bridge_die "smoke: setfacl missing in v2+claude"; }
  getent() {
    if [[ "$1" == "passwd" && "$2" == "ec2-user" ]]; then
      printf "ec2-user:x:1000:1000::%s:/bin/bash\n" "$cr_dir/ctrl-home"
    fi
  }
  bridge_linux_grant_claude_credentials_access \
    "ec2-user" "$cr_dir/iso-home" "ec2-user" "claude"
}
log "case: CR2 credentials helper v2 fails loud when setfacl missing"
CR2_DIR="$TMP_ROOT/cr2"
CR2_LOG="$CR2_DIR/sudo.log"
mkdir -p "$CR2_DIR/ctrl-home/.claude" "$CR2_DIR/iso-home"
echo '{"token":"redacted"}' > "$CR2_DIR/ctrl-home/.claude/.credentials.json"
: >"$CR2_LOG"
cr2_rc=0
run_in_v2 "$CR2_DIR" "$CR2_LOG" case_cr2 "$CR2_DIR" 2>/dev/null || cr2_rc=$?
[[ $cr2_rc -ne 0 ]] || die "CR2 expected die when setfacl missing in v2+claude, got rc=0"
[[ ! -e "$CR2_DIR/iso-home/.claude/.credentials.json" ]] \
  || die "CR2 expected no symlink plant on early die, but found one"
ok "CR2 v2+claude+missing-setfacl fails loud before symlink plant (rc=$cr2_rc)"

# ---------------------------------------------------------------------------
# LP1: legacy parity — same helpers emit setfacl in legacy mode
# ---------------------------------------------------------------------------
case_lp1() {
  local base="$1"
  bridge_linux_acl_add "u:foo:r--" "$base/a"
  bridge_linux_acl_add_recursive "u:foo:rwX" "$base/a"
  bridge_linux_grant_traverse_chain "foo" "$base/a/b" "$base"
}
log "case: LP1 legacy parity (setfacl ≥ 1)"
LP_DIR="$TMP_ROOT/lp"
LP_LOG="$LP_DIR/sudo.log"
mkdir -p "$LP_DIR/a/b"
: >"$LP_LOG"
run_in_legacy "$LP_DIR" "$LP_LOG" case_lp1 "$LP_DIR"
assert_some_setfacl "$LP_LOG" "LP1 legacy primitives" \
  || die "LP1 legacy mode produced no setfacl (regression)"
ok "LP1 legacy parity preserved (setfacl ≥ 1)"

# ---------------------------------------------------------------------------
# CT1/CT2/CT3 — channel symlink target group-mode + TOCTOU + symlink reject
# ---------------------------------------------------------------------------
case_ct() {
  local iso_home="$1"
  local target="$2"
  local agent="$3"
  bridge_linux_install_isolated_channel_symlink \
    "ec2-user" "$iso_home" "ec2-user" "discord" "$target" "$agent"
}
log "case: CT1/CT2/CT3 channel symlink target group-mode + TOCTOU"
CT_DIR="$TMP_ROOT/ct"
CT_LOG="$CT_DIR/sudo.log"
mkdir -p "$CT_DIR/iso-home/.claude/channels" "$CT_DIR/state"
TARGET_NEW="$CT_DIR/state/discord-new"
TARGET_EXISTING="$CT_DIR/state/discord-existing"
mkdir -p "$TARGET_EXISTING"
TARGET_SYMLINK="$CT_DIR/state/discord-symlink"
ln -s "$TARGET_EXISTING" "$TARGET_SYMLINK"

# CT1: new target.
: >"$CT_LOG"
run_in_v2 "$CT_DIR" "$CT_LOG" case_ct "$CT_DIR/iso-home" "$TARGET_NEW" "smoke-ct1"
assert_no_setfacl "$CT_LOG" "CT1 v2 channel symlink (new)" || die "CT1 leaked setfacl"
grep -q "^chmod 2770 .*discord-new" "$CT_LOG" || die "CT1 missing chmod 2770"
grep -q "^chgrp ab-agent-smoke-ct1 .*discord-new" "$CT_LOG" || die "CT1 missing chgrp ab-agent-smoke-ct1"
ok "CT1 v2 channel symlink target (new) → 2770/group-correct, no setfacl"

# CT2: existing target.
: >"$CT_LOG"
run_in_v2 "$CT_DIR" "$CT_LOG" case_ct "$CT_DIR/iso-home" "$TARGET_EXISTING" "smoke-ct2"
assert_no_setfacl "$CT_LOG" "CT2 v2 channel symlink (existing)" || die "CT2 leaked setfacl"
grep -q "^chmod 2770 .*discord-existing" "$CT_LOG" || die "CT2 missing chmod 2770 on existing"
grep -q "^chgrp ab-agent-smoke-ct2 .*discord-existing" "$CT_LOG" || die "CT2 missing chgrp on existing"
ok "CT2 v2 channel symlink target (existing) → idempotent normalize"

# CT3: target is a symlink — refuse.
: >"$CT_LOG"
ct3_rc=0
run_in_v2 "$CT_DIR" "$CT_LOG" case_ct "$CT_DIR/iso-home" "$TARGET_SYMLINK" "smoke-ct3" \
  2>/dev/null || ct3_rc=$?
[[ $ct3_rc -ne 0 ]] || die "CT3 expected non-zero rc when target is symlink, got 0"
if grep -qE "^(chgrp|chmod 2770) .*discord-symlink" "$CT_LOG"; then
  die "CT3 unexpectedly mutated symlink target: $(grep -E 'discord-symlink' "$CT_LOG")"
fi
ok "CT3 v2 channel symlink target (symlink) → reject without mutation (rc=$ct3_rc)"

# ---------------------------------------------------------------------------
# X1-X4: root-required (opt-in via BRIDGE_TEST_V2_PRE_ROOT=1)
# ---------------------------------------------------------------------------
if [[ "${BRIDGE_TEST_V2_PRE_ROOT:-0}" != "1" ]]; then
  log "skip: X1-X4 (set BRIDGE_TEST_V2_PRE_ROOT=1 + provide sudo to enable)"
else
  if ! sudo -n true 2>/dev/null; then
    log "skip: X1-X4 (BRIDGE_TEST_V2_PRE_ROOT=1 set but sudo -n unavailable)"
  else
    log "case: X1-X4 root-required (operator opt-in)"
    cat <<'OPERATOR_NOTE'
[v2-pr-e] X1-X4 operator probes (run against live install with at least two ab-agent groups):
  X1. # Cross-agent EACCES — agent A's UID cannot read agent B's root.
      sudo -u agent-bridge-<A> test -r $BRIDGE_AGENT_ROOT_V2/<B>
                                                                  -> fails (group separation)
      sudo -u agent-bridge-<A> ls    $BRIDGE_AGENT_ROOT_V2/<B>
                                                                  -> fails
  X2. # Self-agent — A's UID can read its own resources.
      sudo -u agent-bridge-<A> cat $BRIDGE_AGENT_ROOT_V2/<A>/runtime/agent-env.sh
                                                                  -> ok (group r--)
      sudo -u agent-bridge-<A> cat $BRIDGE_AGENT_ROOT_V2/<A>/.claude/plugins/installed_plugins.json
                                                                  -> ok (group r--)
      sudo -u agent-bridge-<A> test -x $BRIDGE_AGENT_ROOT_V2/<A>/.claude/plugins
                                                                  -> ok (group r-x)
      sudo -u agent-bridge-<A> test -d $BRIDGE_AGENT_ROOT_V2/<A>/workdir/.discord
                                                                  -> ok (group r-x via 2770)
  X3. # Engine CLI exec via isolated UID.
      sudo -u agent-bridge-<A> test -x $(command -v claude)        -> ok (system path)
  X4. # Channel target file inheritance — setgid + umask 007 composition.
      sudo -u agent-bridge-<A> bash -c 'umask 007; touch $BRIDGE_AGENT_ROOT_V2/<A>/workdir/.discord/state.env'
      stat -c '%G %a' $BRIDGE_AGENT_ROOT_V2/<A>/workdir/.discord/state.env
                                                                  -> "ab-agent-<A> 660"
OPERATOR_NOTE
    ok "X1-X4 operator probes documented (manual run against live install)"
  fi
fi

log "PR-E smoke complete"
