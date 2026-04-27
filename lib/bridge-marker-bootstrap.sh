#!/usr/bin/env bash
# bridge-marker-bootstrap.sh — Read v2 layout marker
# (BRIDGE_LAYOUT/BRIDGE_DATA_ROOT) from $BRIDGE_STATE_DIR/layout-marker.sh
# with strict validation, before bridge-isolation-v2.sh snapshots those env
# vars. Sourced from bridge-lib.sh after bridge-core.sh (so bridge_warn is
# available) and before bridge-isolation-v2.sh.
#
# Validation:
#   - regular file, not symlink
#   - owner is root (UID 0) or current controller (caller's UID)
#   - mode has no group/world write bits
#   - content lines match an allowlist of KEY=value assignments
#   - when BRIDGE_LAYOUT=v2, BRIDGE_DATA_ROOT must be absolute non-empty
#
# Failures fall back silently to legacy (BRIDGE_LAYOUT defaults to "legacy"
# in bridge-isolation-v2.sh). bridge_warn surfaces the reason once per
# process so operators can investigate.
# shellcheck shell=bash disable=SC2034

bridge_isolation_v2_marker_path() {
  printf '%s/layout-marker.sh' \
    "${BRIDGE_STATE_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
}

bridge_isolation_v2_marker_validate() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  [[ -f "$path" && ! -L "$path" ]] || return 1

  local owner_uid mode_oct mode_int
  owner_uid="$(stat -c '%u' "$path" 2>/dev/null)"
  if [[ -z "$owner_uid" ]]; then
    return 1
  fi
  if (( owner_uid != 0 )); then
    local controller_uid
    controller_uid="$(id -u 2>/dev/null || true)"
    if [[ -z "$controller_uid" || "$owner_uid" != "$controller_uid" ]]; then
      bridge_warn "layout-marker.sh ignored: owner UID $owner_uid is neither root nor current controller"
      return 1
    fi
  fi

  mode_oct="$(stat -c '%a' "$path" 2>/dev/null)"
  if [[ -z "$mode_oct" ]]; then
    return 1
  fi
  mode_int=$(( 8#$mode_oct ))
  if (( mode_int & 0022 )); then
    bridge_warn "layout-marker.sh ignored: mode $mode_oct has group or world write bit"
    return 1
  fi

  local allowed_re='^(BRIDGE_LAYOUT|BRIDGE_DATA_ROOT|BRIDGE_SHARED_GROUP|BRIDGE_CONTROLLER_GROUP|BRIDGE_AGENT_GROUP_PREFIX)=.+$'
  local line saw_layout=0 layout_value="" data_root_value=""
  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if ! [[ "$line" =~ $allowed_re ]]; then
      bridge_warn "layout-marker.sh ignored: disallowed line '$line'"
      return 1
    fi
    case "$line" in
      BRIDGE_LAYOUT=*)
        saw_layout=1
        layout_value="${line#BRIDGE_LAYOUT=}"
        ;;
      BRIDGE_DATA_ROOT=*)
        data_root_value="${line#BRIDGE_DATA_ROOT=}"
        ;;
    esac
  done < "$path"

  if (( saw_layout == 1 )); then
    local _lv="$layout_value"
    _lv="${_lv#\'}"; _lv="${_lv%\'}"
    _lv="${_lv#\"}"; _lv="${_lv%\"}"
    if [[ "$_lv" == "v2" ]]; then
      local _dr="$data_root_value"
      _dr="${_dr#\'}"; _dr="${_dr%\'}"
      _dr="${_dr#\"}"; _dr="${_dr%\"}"
      if [[ -z "$_dr" || "${_dr:0:1}" != "/" ]]; then
        bridge_warn "layout-marker.sh ignored: BRIDGE_DATA_ROOT must be absolute, got '$data_root_value'"
        return 1
      fi
    fi
  fi

  return 0
}

bridge_isolation_v2_marker_load() {
  local path
  path="$(bridge_isolation_v2_marker_path)"
  [[ -f "$path" ]] || return 0
  if bridge_isolation_v2_marker_validate "$path"; then
    # shellcheck source=/dev/null
    . "$path"
  fi
}

# Auto-load: bridge-lib.sh sources this module after bridge-core.sh and
# before bridge-isolation-v2.sh, so v2 helpers see the marker values when
# they snapshot BRIDGE_LAYOUT/BRIDGE_DATA_ROOT.
bridge_isolation_v2_marker_load
