#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
#
# bridge-isolation-v2.sh — POSIX group/setgid based isolation primitives.
#
# This module is part of the v2 isolation rewrite that replaces the
# named-ACL based contract (bridge_linux_prepare_agent_isolation) with a
# pure POSIX group + setgid model. It only provides primitives:
# path variables, group ensure helpers, chgrp/setgid helpers, and umask
# helpers. It does NOT change BRIDGE_HOME default behavior, does NOT
# delete or replace any current ACL helper, and does NOT alter any
# resolver or runtime path. Those changes belong to PR-B/C/D/E.
#
# The opt-in flag is `BRIDGE_LAYOUT=v2`. When unset (default), all helpers
# either no-op or keep legacy semantics; nothing in here breaks legacy
# installs.
#
# Design references:
# - design-review r3 plan-ok at task #1132/#1137
# - operator (Sean) directive: "공유는 group + setgid. ACL 안 씀. 개인은 700"
# - dev-codex review notes:
#     r1: per-agent private group (ab-agent-<name>) + shared write policy
#         + secret placement
#     r2: umask 077 incompatibility, shared/runtime secrets, mode 2750/0640
#     r3: per-agent v2 private umask 007, runtime secrets out of shared,
#         shared as group access boundary
#
# Group model (final):
#   ab-shared            — read-only public assets. Members: controller user
#                          and every isolated UID. Only the controller writes.
#   ab-controller        — controller-only state. Members: controller user.
#   ab-agent-<name>      — per-agent private root. Members: controller +
#                          agent-bridge-<name>. Other isolated UIDs are NOT
#                          members.
#
# Layout (final, when BRIDGE_LAYOUT=v2 and BRIDGE_DATA_ROOT is set):
#   $BRIDGE_DATA_ROOT/                      mode 755 (others traverse)
#   ├── shared/                             owner=controller, group=ab-shared,    mode 2750
#   │   ├── plugins/, plugins-cache/, marketplaces/, skills/, docs/
#   ├── agents/                             owner=root,       group=root,         mode 755
#   │   └── <agent>/                        owner=agent-bridge-<name>,
#   │                                       group=ab-agent-<name>,                mode 2770
#   ├── state/                              owner=controller, group=ab-controller, mode 2750
#   │   └── runtime/                        bridge-config.json + secrets here
#   ├── agent-roster.sh                     owner=controller, group=ab-controller, mode 0640
#   └── agent-roster.local.sh               owner=controller, group=ab-controller, mode 0640
#
# Default group names are env-overridable so this can be exercised in
# tempdir-based tests without root.

# ---------------------------------------------------------------------------
# 1. opt-in flag and path variables
# ---------------------------------------------------------------------------

# Layout selector. Legacy installs leave this empty/unset. New installs and
# migrated installs set BRIDGE_LAYOUT=v2. Tests may set it to "v2" via env.
BRIDGE_LAYOUT="${BRIDGE_LAYOUT:-legacy}"

# Data root for v2 layout. When unset, v2 helpers no-op (legacy mode).
# Default suggestion when an operator opts in: /srv/agent-bridge.
BRIDGE_DATA_ROOT="${BRIDGE_DATA_ROOT:-}"

# Derived path variables. Empty when BRIDGE_DATA_ROOT is unset.
BRIDGE_SHARED_ROOT="${BRIDGE_SHARED_ROOT:-${BRIDGE_DATA_ROOT:+$BRIDGE_DATA_ROOT/shared}}"
BRIDGE_AGENT_ROOT_V2="${BRIDGE_AGENT_ROOT_V2:-${BRIDGE_DATA_ROOT:+$BRIDGE_DATA_ROOT/agents}}"
BRIDGE_CONTROLLER_STATE_ROOT="${BRIDGE_CONTROLLER_STATE_ROOT:-${BRIDGE_DATA_ROOT:+$BRIDGE_DATA_ROOT/state}}"

# Group names. Operator may override via env to fit local naming policy.
BRIDGE_SHARED_GROUP="${BRIDGE_SHARED_GROUP:-ab-shared}"
BRIDGE_CONTROLLER_GROUP="${BRIDGE_CONTROLLER_GROUP:-ab-controller}"
BRIDGE_AGENT_GROUP_PREFIX="${BRIDGE_AGENT_GROUP_PREFIX:-ab-agent-}"

# ---------------------------------------------------------------------------
# 2. helpers — environment / dispatch
# ---------------------------------------------------------------------------

bridge_isolation_v2_active() {
  # Returns 0 (active) when BRIDGE_LAYOUT=v2 and BRIDGE_DATA_ROOT is set.
  # All v2 helpers should gate on this so they no-op for legacy installs.
  [[ "$BRIDGE_LAYOUT" == "v2" ]] || return 1
  [[ -n "$BRIDGE_DATA_ROOT" ]] || return 1
  return 0
}

bridge_isolation_v2_agent_group_name() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  printf '%s%s' "$BRIDGE_AGENT_GROUP_PREFIX" "$agent"
}

# ---------------------------------------------------------------------------
# 3. group / membership ensure helpers
# ---------------------------------------------------------------------------

bridge_isolation_v2_group_exists() {
  # Returns 0 if the named group exists in nss. Works without root.
  local name="$1"
  [[ -n "$name" ]] || return 1
  getent group "$name" >/dev/null 2>&1
}

bridge_isolation_v2_user_in_group() {
  # Returns 0 if the named user is a member of the named group. Reads
  # the static nss view (does NOT see supplementary groups picked up by
  # already-running processes; for that, run `id -nG <user>` from a
  # fresh shell).
  local user="$1"
  local group="$2"
  [[ -n "$user" && -n "$group" ]] || return 1
  id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$group"
}

bridge_isolation_v2_ensure_group() {
  # Idempotent: create the group if it does not exist. Requires root or
  # passwordless `sudo groupadd`. Returns 0 on success or pre-existing.
  local name="$1"
  [[ -n "$name" ]] || {
    bridge_warn "bridge_isolation_v2_ensure_group: name required"
    return 1
  }
  if bridge_isolation_v2_group_exists "$name"; then
    return 0
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    groupadd -r "$name"
  else
    sudo -n groupadd -r "$name" 2>/dev/null || {
      bridge_warn "ensure_group: cannot create '$name' (need root or passwordless sudo)"
      return 1
    }
  fi
}

bridge_isolation_v2_ensure_user_in_group() {
  # Idempotent: add user to group as a supplementary member if not
  # already present. WARNING: already-running shells/daemons do NOT
  # pick up new supplementary groups. Caller must restart the relevant
  # process trees for the new membership to take effect.
  local user="$1"
  local group="$2"
  [[ -n "$user" && -n "$group" ]] || {
    bridge_warn "ensure_user_in_group: user and group required"
    return 1
  }
  if bridge_isolation_v2_user_in_group "$user" "$group"; then
    return 0
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    usermod -aG "$group" "$user"
  else
    sudo -n usermod -aG "$group" "$user" 2>/dev/null || {
      bridge_warn "ensure_user_in_group: cannot add '$user' to '$group' (need root or passwordless sudo)"
      return 1
    }
  fi
}

# ---------------------------------------------------------------------------
# 4. mode / chgrp / setgid helpers
# ---------------------------------------------------------------------------

_bridge_isolation_v2_run_root_or_sudo() {
  # Run the given command directly when permitted (root, or POSIX
  # permits the operation for the caller — e.g. owner changing to
  # their own primary group), otherwise fall back to passwordless
  # sudo.
  #
  # Direct-first matters for rootless cases: a non-root user can
  # `chgrp` to one of their own groups and `chmod` files they own
  # without sudo. Forcing `sudo -n` would block both the regression
  # smoke (caller's primary group on a tempdir tree) and any
  # non-root operator workflow when sudo is intentionally absent.
  if "$@" 2>/dev/null; then
    return 0
  fi
  if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    sudo -n "$@" 2>/dev/null && return 0
  fi
  return 1
}

bridge_isolation_v2_chgrp_setgid_dir() {
  # Apply group ownership + setgid bit + mode to a single directory.
  # Idempotent. Honors mode argument (e.g. 2750 for shared, 2770 for
  # per-agent private). Direct-first (POSIX-permitted operation by
  # caller) before falling back to sudo, so the rootless primary-
  # group regression path works without sudo.
  local group="$1"
  local mode="$2"
  local dir="$3"
  [[ -n "$group" && -n "$mode" && -n "$dir" ]] || {
    bridge_warn "chgrp_setgid_dir: group, mode, and dir required"
    return 1
  }
  [[ -d "$dir" ]] || {
    bridge_warn "chgrp_setgid_dir: not a directory: $dir"
    return 1
  }
  _bridge_isolation_v2_run_root_or_sudo chgrp "$group" "$dir" || return 1
  _bridge_isolation_v2_run_root_or_sudo chmod "$mode" "$dir" || return 1
}

bridge_isolation_v2_chgrp_setgid_recursive() {
  # Apply group + mode to a tree. Directories get the dir-mode (with
  # setgid bit), files get the file-mode (without setgid). The dir-mode
  # MUST include the setgid bit (e.g. 2750, 2770) so newly-created
  # children inherit the group automatically.
  #
  # Direct-first like chgrp_setgid_dir; the regression smoke validates
  # the rootless primary-group path without sudo.
  local group="$1"
  local dir_mode="$2"
  local file_mode="$3"
  local root="$4"
  [[ -n "$group" && -n "$dir_mode" && -n "$file_mode" && -n "$root" ]] || {
    bridge_warn "chgrp_setgid_recursive: group, dir_mode, file_mode, root required"
    return 1
  }
  [[ -d "$root" ]] || {
    bridge_warn "chgrp_setgid_recursive: not a directory: $root"
    return 1
  }
  _bridge_isolation_v2_run_root_or_sudo chgrp -R "$group" "$root" || return 1
  _bridge_isolation_v2_run_root_or_sudo find "$root" -type d -exec chmod "$dir_mode" {} + || return 1
  _bridge_isolation_v2_run_root_or_sudo find "$root" -type f -exec chmod "$file_mode" {} + || return 1
}

# ---------------------------------------------------------------------------
# 5. umask helpers — restore on every path
# ---------------------------------------------------------------------------

bridge_with_private_umask() {
  # Run a command under umask 007 so newly-created files are 0660 and
  # directories are 2770 (setgid bit applied separately by chmod). The
  # umask is restored even if the wrapped command fails.
  local saved rc
  saved="$(umask)"
  umask 007
  "$@"
  rc=$?
  umask "$saved"
  return "$rc"
}

bridge_with_shared_umask() {
  # Run a command under umask 027 so newly-created files are 0640 and
  # directories are 2750. Restore on every path, including failure.
  local saved rc
  saved="$(umask)"
  umask 027
  "$@"
  rc=$?
  umask "$saved"
  return "$rc"
}

# ---------------------------------------------------------------------------
# 6. inventory helpers — for migration tool / docs / acceptance tests
# ---------------------------------------------------------------------------

bridge_isolation_v2_layout_summary() {
  # Print one-line key=value pairs describing the active v2 layout, or
  # `layout=legacy` when the v2 mode is not active. Useful for CLI/audit.
  if ! bridge_isolation_v2_active; then
    printf 'layout=legacy\n'
    return 0
  fi
  printf 'layout=v2\n'
  printf 'data_root=%s\n' "$BRIDGE_DATA_ROOT"
  printf 'shared_root=%s\n' "$BRIDGE_SHARED_ROOT"
  printf 'agent_root=%s\n' "$BRIDGE_AGENT_ROOT_V2"
  printf 'controller_state_root=%s\n' "$BRIDGE_CONTROLLER_STATE_ROOT"
  printf 'shared_group=%s\n' "$BRIDGE_SHARED_GROUP"
  printf 'controller_group=%s\n' "$BRIDGE_CONTROLLER_GROUP"
  printf 'agent_group_prefix=%s\n' "$BRIDGE_AGENT_GROUP_PREFIX"
}

# ---------------------------------------------------------------------------
# 7. exports
# ---------------------------------------------------------------------------

export BRIDGE_LAYOUT BRIDGE_DATA_ROOT BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2
export BRIDGE_CONTROLLER_STATE_ROOT BRIDGE_SHARED_GROUP BRIDGE_CONTROLLER_GROUP
export BRIDGE_AGENT_GROUP_PREFIX
