#!/usr/bin/env bash
# shellcheck shell=bash
#
# Agent Bridge health / hygiene scanners. `agent-bridge diagnose <subcommand>`.
#
# Currently exposes:
#   agent-bridge diagnose acl    — scan `/`, `/home`, the operator's home,
#                                  BRIDGE_HOME and BRIDGE_AGENT_HOME_ROOT for
#                                  stale named-user ACL entries that isolate
#                                  may have left behind (issue #233). Outputs
#                                  the exact `setfacl -x` command the operator
#                                  can run to drain each one.
#
# Everything here is read-only — no ACL mutation, no root sudo — so the
# scanner is safe to run from the same shell the operator uses for
# normal work.

set -euo pipefail

BRIDGE_DIAGNOSE_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bridge-lib.sh
source "$BRIDGE_DIAGNOSE_SCRIPT_DIR/bridge-lib.sh"

bridge_diagnose_usage() {
  cat <<'USAGE'
Usage:
  agent-bridge diagnose acl [--json]

Scan for stale Agent Bridge named-user ACL entries on shared roots.
Reads only — does not modify any ACL. Lists `setfacl -x` commands the
operator can run to drain any entry that shouldn't still be there.

Linux only. macOS installs don't use POSIX ACLs for this path and
always report "[ok]".
USAGE
}

bridge_diagnose_acl_is_suspicious() {
  local entry_user="$1"
  local controller="$2"

  [[ -n "$entry_user" ]] || return 1
  case "$entry_user" in
    agent-bridge-*)
      return 0
      ;;
  esac
  if [[ -n "$controller" && "$entry_user" == "$controller" ]]; then
    return 0
  fi
  return 1
}

bridge_diagnose_acl_scan_path() {
  # Emit one `[<path>]` header + lines per suspicious entry. No output if
  # the path is missing or clean. Writes to stdout; returns 0 unless
  # getfacl itself fails.
  local path="$1"
  local controller="$2"
  local json_mode="${3:-0}"
  local output=""
  local entries=""
  local entry=""
  local entry_user=""
  local kind="access"
  local any=0

  [[ -e "$path" ]] || return 0
  command -v getfacl >/dev/null 2>&1 || return 0
  output="$(getfacl -p "$path" 2>/dev/null)" || return 0
  # `user:<name>:...` lines carry named entries. `user::...` is the base
  # owner entry and is never suspicious. `default:user:<name>:...` is
  # the inherited-default ACL; classify it separately so the operator
  # can see which setfacl -x flag (access vs. default) to use.
  entries="$(printf '%s\n' "$output" \
    | grep -E '^(default:)?user:[^:]+:' \
    | grep -vE '^(default:)?user::' || true)"
  [[ -n "$entries" ]] || return 0

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == default:* ]]; then
      kind="default"
      entry_user="${entry#default:user:}"
    else
      kind="access"
      entry_user="${entry#user:}"
    fi
    entry_user="${entry_user%%:*}"
    bridge_diagnose_acl_is_suspicious "$entry_user" "$controller" || continue
    if (( any == 0 )); then
      if [[ "$json_mode" != "1" ]]; then
        printf '[%s]\n' "$path"
      fi
      any=1
    fi
    if [[ "$json_mode" == "1" ]]; then
      printf '{"path":%s,"user":%s,"kind":%s,"raw":%s}\n' \
        "$(bridge_diagnose_json_str "$path")" \
        "$(bridge_diagnose_json_str "$entry_user")" \
        "$(bridge_diagnose_json_str "$kind")" \
        "$(bridge_diagnose_json_str "$entry")"
    else
      local flag=""
      if [[ "$kind" == "default" ]]; then
        flag="-d "
      fi
      printf '  suspicious (%s): %s\n' "$kind" "$entry"
      printf '  fix: sudo setfacl %s-x u:%s %s\n' "$flag" "$entry_user" "$path"
    fi
  done <<<"$entries"

  return 0
}

bridge_diagnose_json_str() {
  # Emit a JSON-encoded string using python3 so weird paths (spaces,
  # quotes, UTF-8) don't break the output. getfacl output is already
  # UTF-8 in practice.
  bridge_require_python
  python3 - "$1" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1]))
PY
}

bridge_diagnose_acl_targets() {
  # Build the canonical scan target list. `/` and `/home` are always in
  # scope because they're the two paths #233's isolate regression most
  # commonly poisoned. The controller's home is checked separately
  # because named-user entries there also strip operator access. Any
  # agent-bridge-specific roots that exist on the host get scanned too.
  local controller_user="$1"
  local controller_home=""

  printf '/\n'
  printf '/home\n'

  controller_home="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -n "$controller_home" && -d "$controller_home" && "$controller_home" != "/" ]]; then
    printf '%s\n' "$controller_home"
  fi

  if [[ -n "${BRIDGE_HOME:-}" && -d "$BRIDGE_HOME" ]]; then
    printf '%s\n' "$BRIDGE_HOME"
  fi
  if [[ -n "${BRIDGE_AGENT_HOME_ROOT:-}" && -d "$BRIDGE_AGENT_HOME_ROOT" ]]; then
    printf '%s\n' "$BRIDGE_AGENT_HOME_ROOT"
  fi
  if [[ -n "${BRIDGE_STATE_DIR:-}" && -d "$BRIDGE_STATE_DIR" ]]; then
    printf '%s\n' "$BRIDGE_STATE_DIR"
  fi
}

bridge_diagnose_acl_main() {
  local json_mode=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json_mode=1
        shift
        ;;
      -h|--help)
        bridge_diagnose_usage
        return 0
        ;;
      *)
        printf 'unknown argument: %s\n' "$1" >&2
        bridge_diagnose_usage >&2
        return 2
        ;;
    esac
  done

  if [[ "$(uname -s 2>/dev/null || printf '')" != "Linux" ]]; then
    if [[ "$json_mode" == "1" ]]; then
      printf '{"platform":"non-linux","findings":[]}\n'
    else
      printf '[ok] non-linux host — POSIX ACL scanner does not apply\n'
    fi
    return 0
  fi
  if ! command -v getfacl >/dev/null 2>&1; then
    printf '[skip] getfacl not installed — install the acl package to scan\n' >&2
    return 0
  fi

  local controller_user=""
  controller_user="$(bridge_current_user 2>/dev/null || id -un 2>/dev/null || printf '')"

  local targets=()
  while IFS= read -r target; do
    [[ -n "$target" ]] && targets+=("$target")
  done < <(bridge_diagnose_acl_targets "$controller_user")

  local any=0
  local findings=""
  local result=""
  local target=""

  if [[ "$json_mode" == "1" ]]; then
    printf '{"platform":"linux","controller":%s,"findings":[' \
      "$(bridge_diagnose_json_str "$controller_user")"
  fi

  for target in "${targets[@]}"; do
    result="$(bridge_diagnose_acl_scan_path "$target" "$controller_user" "$json_mode" || true)"
    [[ -n "$result" ]] || continue
    if [[ "$json_mode" == "1" ]]; then
      findings+="$result"
    else
      if (( any == 1 )); then
        printf '\n'
      fi
      printf '%s' "$result"
    fi
    any=1
  done

  if [[ "$json_mode" == "1" ]]; then
    if [[ -n "$findings" ]]; then
      # Join on commas; each row already has a trailing newline.
      printf '%s' "$findings" \
        | awk 'NF' \
        | paste -sd, -
    fi
    printf ']}\n'
    return 0
  fi

  if (( any == 0 )); then
    printf '[ok] no suspicious named-user ACL entries found on %s\n' "${targets[*]}"
    return 0
  fi

  cat <<EOF

[note] each "fix:" line above removes exactly one stale entry.
       You can apply them directly, or run:
         agent-bridge unisolate <agent>
       for every previously-isolated agent to let the shipped
       cleanup (PR #235) drain the residue in one shot.
EOF
}

bridge_diagnose_cli() {
  local subcommand="${1:-}"
  shift || true

  case "$subcommand" in
    acl)
      bridge_diagnose_acl_main "$@"
      ;;
    ""|-h|--help|help)
      bridge_diagnose_usage
      ;;
    *)
      printf 'unknown diagnose subcommand: %s\n' "$subcommand" >&2
      bridge_diagnose_usage >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bridge_diagnose_cli "$@"
fi
