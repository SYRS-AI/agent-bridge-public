#!/usr/bin/env bash
# shellcheck shell=bash
#
# Migration helpers for transitioning a static agent between shared and
# linux-user isolation modes on an existing install. See issue #85.
#
# Exposes two entry points used by the `agent-bridge` dispatcher:
#   bridge_migration_isolate_cli
#   bridge_migration_unisolate_cli
#
# Both accept `<agent> [--dry-run]`. The helper is intentionally conservative:
# all destructive operations (useradd, chown, symlink rewrites, roster edits)
# are gated behind an explicit live run; `--dry-run` only prints the planned
# steps. Re-running on an already-converged agent is a no-op.

bridge_migration_platform() {
  uname -s 2>/dev/null || printf 'unknown'
}

bridge_migration_require_linux() {
  local plat
  plat="$(bridge_migration_platform)"
  if [[ "$plat" != "Linux" ]]; then
    bridge_die "per-UID isolation migration is only supported on Linux hosts (current: $plat). macOS scope is tracked in #89; use shared mode + hook hardening there."
  fi
}

bridge_migration_block_if_active() {
  local agent="$1"
  if bridge_agent_is_active "$agent"; then
    bridge_die "'$agent' has a live tmux session. Stop it first with 'agent-bridge agent stop $agent' before migrating."
  fi
}

bridge_migration_user_home() {
  local os_user="$1"
  printf '%s/%s' "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT" "$os_user"
}

bridge_migration_print_step() {
  local dry_run="$1"
  shift
  if [[ "$dry_run" == "1" ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    printf '  [apply]   %s\n' "$*"
  fi
}

bridge_migration_run_step() {
  local dry_run="$1"
  shift
  bridge_migration_print_step "$dry_run" "$*"
  if [[ "$dry_run" != "1" ]]; then
    "$@"
  fi
}

bridge_migration_roster_upsert() {
  # Idempotently append/update isolation metadata lines in the local roster.
  # Uses `BRIDGE_ROSTER_LOCAL_FILE` as the edit target.
  local dry_run="$1"
  local agent="$2"
  local isolation_mode="$3"
  local os_user="$4"
  local file="$BRIDGE_ROSTER_LOCAL_FILE"

  bridge_migration_print_step "$dry_run" "upsert roster metadata in $file: isolation_mode=$isolation_mode os_user=${os_user:-<unset>}"
  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi

  bridge_require_python
  python3 - "$file" "$agent" "$isolation_mode" "$os_user" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
agent = sys.argv[2]
isolation_mode = sys.argv[3]
os_user = sys.argv[4]

text = path.read_text(encoding="utf-8") if path.exists() else ""

def upsert(source: str, key: str, value: str) -> str:
    rendered = f'BRIDGE_AGENT_{key}["{agent}"]="{value}"'
    pattern = re.compile(
        rf'^BRIDGE_AGENT_{re.escape(key)}\[\"{re.escape(agent)}\"\]=.*$',
        flags=re.MULTILINE,
    )
    if pattern.search(source):
        return pattern.sub(rendered, source)
    if source and not source.endswith("\n"):
        source += "\n"
    return source + rendered + "\n"

text = upsert(text, "ISOLATION_MODE", isolation_mode)
text = upsert(text, "OS_USER", os_user)
path.write_text(text, encoding="utf-8")
PY
}

bridge_migration_isolate() {
  local agent="$1"
  local dry_run="$2"
  local install_sudoers="${3:-0}"
  local os_user current_mode workdir user_home runtime_state_dir log_dir

  bridge_migration_require_linux
  bridge_require_agent "$agent"

  if ! bridge_agent_is_static "$agent"; then
    bridge_die "'$agent' is a dynamic agent; only static agents can be migrated."
  fi

  current_mode="$(bridge_agent_isolation_mode "$agent")"
  os_user="$(bridge_agent_os_user "$agent")"

  if [[ "$current_mode" == "linux-user" && -n "$os_user" ]]; then
    printf '[info] %s is already linux-user isolated (os_user=%s); nothing to do.\n' "$agent" "$os_user"
    return 0
  fi

  bridge_migration_block_if_active "$agent"

  [[ -n "$os_user" ]] || os_user="$(bridge_agent_default_os_user "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"
  user_home="$(bridge_migration_user_home "$os_user")"
  runtime_state_dir="$(bridge_agent_runtime_state_dir "$agent")"
  log_dir="$(bridge_agent_log_dir "$agent")"

  printf '[plan] isolate %s -> linux-user mode\n' "$agent"
  printf '       os_user=%s user_home=%s workdir=%s\n' "$os_user" "$user_home" "$workdir"

  # Write the roster metadata FIRST so a mid-run failure leaves unisolate with
  # enough state to roll back; the upsert is idempotent.
  bridge_migration_roster_upsert "$dry_run" "$agent" "linux-user" "$os_user"

  if ! id -u "$os_user" >/dev/null 2>&1; then
    bridge_migration_print_step "$dry_run" "useradd --system --home-dir $user_home --shell /usr/sbin/nologin $os_user"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root useradd --system --home-dir "$user_home" --shell /usr/sbin/nologin "$os_user"
    fi
  else
    printf '  [skip]    os user %s already exists\n' "$os_user"
  fi

  bridge_migration_print_step "$dry_run" "mkdir -p $user_home && chown $os_user:$os_user $user_home && chmod 0700 $user_home"
  if [[ "$dry_run" != "1" ]]; then
    bridge_linux_sudo_root mkdir -p "$user_home"
    bridge_linux_sudo_root chown "$os_user:$os_user" "$user_home"
    bridge_linux_sudo_root chmod 0700 "$user_home"
  fi

  bridge_migration_print_step "$dry_run" "install symlink $user_home/.agent-bridge -> $BRIDGE_HOME"
  if [[ "$dry_run" != "1" ]]; then
    bridge_linux_install_agent_bridge_symlink "$os_user" "$user_home" "$BRIDGE_HOME"
  fi

  if [[ -d "$workdir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $os_user $workdir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$os_user" "$workdir"
    fi
  else
    printf '  [warn]    workdir missing: %s (skipping chown)\n' "$workdir"
  fi

  if [[ -n "$runtime_state_dir" && -d "$runtime_state_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $os_user $runtime_state_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$os_user" "$runtime_state_dir"
    fi
  else
    printf '  [warn]    runtime state dir missing: %s (skipping chown; will be created on first start)\n' "${runtime_state_dir:-<unset>}"
  fi
  if [[ -n "$log_dir" && -d "$log_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $os_user $log_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$os_user" "$log_dir"
    fi
  else
    printf '  [warn]    log dir missing: %s (skipping chown; will be created on first start)\n' "${log_dir:-<unset>}"
  fi

  # Install the ACL / queue-gateway / hidden-path-strip plumbing that the
  # create-time path (bridge_linux_prepare_agent_isolation) would have set up.
  # Without this the acceptance runbook's §2.1/§2.4 cannot pass on migrated
  # agents.
  bridge_migration_print_step "$dry_run" "install per-agent ACLs + queue-gateway dirs + hidden-path strips (bridge_linux_prepare_agent_isolation)"
  if [[ "$dry_run" != "1" ]]; then
    bridge_linux_prepare_agent_isolation "$agent" "$os_user" "$workdir" "$(bridge_current_user)" || \
      bridge_warn "bridge_linux_prepare_agent_isolation returned non-zero for $agent; re-run isolate or check acceptance runbook §2"
  fi

  if [[ "$install_sudoers" == "1" ]]; then
    bridge_migration_install_sudoers "$dry_run" "$os_user" || true
  else
    bridge_migration_print_sudoers_hint "$os_user"
  fi

  if [[ "$dry_run" == "1" ]]; then
    printf '[done] isolation plan printed (dry-run) for %s\n' "$agent"
    printf '[note] re-run without --dry-run to apply. You may need to re-provision channel tokens since old per-agent secrets stay owned by the controller user.\n'
  else
    printf '[done] isolation applied for %s\n' "$agent"
    printf '[note] re-provision channel tokens if the agent consumed secrets under its old UID; old files are now owned by %s.\n' "$os_user"
  fi
}

bridge_migration_unisolate() {
  local agent="$1"
  local dry_run="$2"
  local current_mode os_user workdir controller_user runtime_state_dir log_dir

  bridge_migration_require_linux
  bridge_require_agent "$agent"

  if ! bridge_agent_is_static "$agent"; then
    bridge_die "'$agent' is a dynamic agent; only static agents can be migrated."
  fi

  current_mode="$(bridge_agent_isolation_mode "$agent")"
  os_user="$(bridge_agent_os_user "$agent")"

  if [[ "$current_mode" != "linux-user" || -z "$os_user" ]]; then
    printf '[info] %s is already in shared mode; nothing to do.\n' "$agent"
    return 0
  fi

  bridge_migration_block_if_active "$agent"

  workdir="$(bridge_agent_workdir "$agent")"
  controller_user="$(bridge_current_user)"

  printf '[plan] unisolate %s -> shared mode\n' "$agent"
  printf '       reverting ownership from os_user=%s back to controller=%s\n' "$os_user" "$controller_user"

  if [[ -d "$workdir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $controller_user $workdir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$controller_user" "$workdir"
    fi
  fi

  runtime_state_dir="$(bridge_agent_runtime_state_dir "$agent")"
  log_dir="$(bridge_agent_log_dir "$agent")"
  if [[ -n "$runtime_state_dir" && -d "$runtime_state_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $controller_user $runtime_state_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$controller_user" "$runtime_state_dir"
    fi
  fi
  if [[ -n "$log_dir" && -d "$log_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $controller_user $log_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$controller_user" "$log_dir"
    fi
  fi

  # Restore ownership of per-agent sibling files that prepare_agent_isolation
  # chowns to the os_user: history file, audit log, queue-gateway
  # request/response dirs. These live outside $runtime_state_dir and
  # $log_dir, so the chown -R above misses them, leaving the operator
  # unable to start the agent post-rollback (issue #112).
  local audit_file history_file request_dir response_dir
  audit_file="$(bridge_agent_audit_log_file "$agent" 2>/dev/null || true)"
  history_file="$(bridge_history_file_for_agent "$agent" 2>/dev/null || true)"
  request_dir="$(bridge_queue_gateway_requests_dir "$agent" 2>/dev/null || true)"
  response_dir="$(bridge_queue_gateway_responses_dir "$agent" 2>/dev/null || true)"

  if [[ -n "$audit_file" && -e "$audit_file" ]]; then
    bridge_migration_print_step "$dry_run" "chown $controller_user $audit_file"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown "$controller_user" "$audit_file" || true
    fi
  fi
  if [[ -n "$history_file" && -e "$history_file" ]]; then
    bridge_migration_print_step "$dry_run" "chown $controller_user $history_file"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown "$controller_user" "$history_file" || true
    fi
  fi
  if [[ -n "$request_dir" && -d "$request_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $controller_user $request_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$controller_user" "$request_dir" || true
    fi
  fi
  if [[ -n "$response_dir" && -d "$response_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $controller_user $response_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$controller_user" "$response_dir" || true
    fi
  fi

  bridge_migration_roster_upsert "$dry_run" "$agent" "shared" ""

  if [[ "$dry_run" == "1" ]]; then
    printf '[done] unisolate plan printed (dry-run) for %s\n' "$agent"
  else
    printf '[done] unisolate applied for %s\n' "$agent"
  fi
  printf '[note] the OS user %s is intentionally preserved (it may still own unrelated files). To delete it run: sudo userdel %s && sudo rm -rf %s\n' \
    "$os_user" "$os_user" "$(bridge_migration_user_home "$os_user")"
}

bridge_migration_parse_args() {
  BRIDGE_MIGRATION_AGENT=""
  BRIDGE_MIGRATION_DRY_RUN=0
  BRIDGE_MIGRATION_SHOW_HELP=0
  BRIDGE_MIGRATION_INSTALL_SUDOERS=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        BRIDGE_MIGRATION_DRY_RUN=1
        shift
        ;;
      --install-sudoers)
        BRIDGE_MIGRATION_INSTALL_SUDOERS=1
        shift
        ;;
      -h|--help)
        BRIDGE_MIGRATION_SHOW_HELP=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        bridge_die "unknown option: $1"
        ;;
      *)
        if [[ -z "$BRIDGE_MIGRATION_AGENT" ]]; then
          BRIDGE_MIGRATION_AGENT="$1"
        else
          bridge_die "unexpected extra argument: $1"
        fi
        shift
        ;;
    esac
  done
}

bridge_migration_sudoers_entry() {
  local operator="$1"
  local os_user="$2"
  local tmux_bin bash_bin
  tmux_bin="$(command -v tmux 2>/dev/null || printf '/usr/bin/tmux')"
  bash_bin="$(command -v bash 2>/dev/null || printf '/bin/bash')"
  printf '%s ALL=(%s) NOPASSWD: %s, %s\n' "$operator" "$os_user" "$tmux_bin" "$bash_bin"
}

bridge_migration_install_sudoers() {
  local dry_run="$1"
  local os_user="$2"
  local operator="${3:-$(bridge_current_user)}"
  local entry target tmpfile

  [[ -n "$os_user" ]] || return 0
  target="/etc/sudoers.d/agent-bridge-${os_user}"
  entry="$(bridge_migration_sudoers_entry "$operator" "$os_user")"

  printf '[sudoers] planned entry for %s:\n' "$target"
  printf '          %s' "$entry"
  if [[ "$dry_run" == "1" ]]; then
    printf '[dry-run] skipping sudoers install; re-run without --dry-run to apply.\n'
    return 0
  fi

  if ! command -v visudo >/dev/null 2>&1; then
    bridge_warn "visudo not found; skipping sudoers install. Add this entry manually to $target:"
    printf '  %s' "$entry" >&2
    return 1
  fi

  tmpfile="$(mktemp)" || bridge_die "failed to create temp file for sudoers validation"
  printf '%s' "$entry" >"$tmpfile"
  if ! visudo -cf "$tmpfile" >/dev/null 2>&1; then
    rm -f "$tmpfile"
    bridge_die "generated sudoers entry failed visudo -cf validation (operator=$operator os_user=$os_user)"
  fi

  bridge_linux_sudo_root install -m 0440 -o root -g root "$tmpfile" "$target"
  rm -f "$tmpfile"
  printf '[sudoers] installed %s (mode 0440)\n' "$target"
}

bridge_migration_print_sudoers_hint() {
  local os_user="$1"
  local operator="${2:-$(bridge_current_user)}"
  local entry
  entry="$(bridge_migration_sudoers_entry "$operator" "$os_user")"
  printf '[hint] To enable UID switch on agent launch, install a sudoers drop-in at /etc/sudoers.d/agent-bridge-%s containing:\n' "$os_user"
  printf '         %s' "$entry"
  printf '       Re-run this command with --install-sudoers to apply it automatically (after visudo validation).\n'
  printf '       See docs/linux-host-acceptance.md for the full migration runbook.\n'
}

bridge_migration_isolate_cli() {
  bridge_migration_parse_args "$@"
  if [[ "${BRIDGE_MIGRATION_SHOW_HELP:-0}" == "1" ]]; then
    cat <<'EOF'
Usage: agent-bridge isolate <agent> [--dry-run] [--install-sudoers]

Migrate a static agent from shared isolation to linux-user isolation.
On macOS this command refuses with a pointer to #89 for scope.

Steps (planned; --dry-run prints without executing):
  1. Verify agent is declared and currently in shared mode.
  2. Verify no live tmux session is running (operator must stop first).
  3. useradd --system --home-dir <bridge_isolated_user_home_root>/<os_user> --shell /usr/sbin/nologin
  4. Chown the agent workdir, runtime state dir, and log dir to the new OS user.
  5. Install $user_home/.agent-bridge symlink into $BRIDGE_HOME.
  6. Write isolation_mode=linux-user + os_user=<slug> to the local roster.

Options:
  --install-sudoers  Also install /etc/sudoers.d/agent-bridge-<os_user> so
                     'agent-bridge agent start <agent>' can sudo -u the
                     dedicated OS user without a password prompt. The entry
                     is validated with visudo -cf before install. When
                     omitted, the exact required entry is printed so the
                     operator can install it manually (see
                     docs/linux-host-acceptance.md).

Re-running on an already-isolated agent is a no-op.
EOF
    return 0
  fi
  [[ -n "$BRIDGE_MIGRATION_AGENT" ]] || bridge_die "Usage: agent-bridge isolate <agent> [--dry-run] [--install-sudoers]"
  bridge_migration_isolate "$BRIDGE_MIGRATION_AGENT" "$BRIDGE_MIGRATION_DRY_RUN" "$BRIDGE_MIGRATION_INSTALL_SUDOERS"
}

bridge_migration_unisolate_cli() {
  bridge_migration_parse_args "$@"
  if [[ "${BRIDGE_MIGRATION_SHOW_HELP:-0}" == "1" ]]; then
    cat <<'EOF'
Usage: agent-bridge unisolate <agent> [--dry-run]

Revert a static agent from linux-user isolation back to shared mode.

Steps (planned; --dry-run prints without executing):
  1. Verify agent is declared and currently in linux-user mode.
  2. Verify no live tmux session is running (operator must stop first).
  3. Chown workdir, runtime state dir, and log dir back to the controller user.
  4. Clear isolation_mode + os_user from the local roster.

The dedicated OS user is preserved; a cleanup command is printed so the
operator can delete it manually once they have confirmed nothing else
depends on it.
EOF
    return 0
  fi
  [[ -n "$BRIDGE_MIGRATION_AGENT" ]] || bridge_die "Usage: agent-bridge unisolate <agent> [--dry-run]"
  bridge_migration_unisolate "$BRIDGE_MIGRATION_AGENT" "$BRIDGE_MIGRATION_DRY_RUN"
}
