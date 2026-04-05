#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034

if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for bridge_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [[ -n "$bridge_candidate_bash" && -x "$bridge_candidate_bash" ]] || continue
    if "$bridge_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$bridge_candidate_bash" "$0" "$@"
    fi
  done

  echo "[bridge-lib] Agent Bridge requires Bash 4+ (current: ${BASH_VERSION:-unknown})." >&2
  exit 1
fi

BRIDGE_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "${BRIDGE_HOME:-}" ]]; then
  BRIDGE_HOME="$BRIDGE_SCRIPT_DIR"
  bridge_installed_cli="$(type -P agent-bridge 2>/dev/null || true)"
  if [[ -n "$bridge_installed_cli" ]]; then
    bridge_installed_home="$(cd -P "$(dirname "$bridge_installed_cli")" && pwd -P)"
    if [[ -f "$bridge_installed_home/bridge-lib.sh" && "$bridge_installed_home" != "$BRIDGE_SCRIPT_DIR" ]]; then
      BRIDGE_HOME="$bridge_installed_home"
    fi
  fi
fi
BRIDGE_ROSTER_FILE="${BRIDGE_ROSTER_FILE:-$BRIDGE_HOME/agent-roster.sh}"
BRIDGE_ROSTER_LOCAL_FILE="${BRIDGE_ROSTER_LOCAL_FILE:-$BRIDGE_HOME/agent-roster.local.sh}"
BRIDGE_STATE_DIR="${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}"
BRIDGE_ACTIVE_AGENT_DIR="${BRIDGE_ACTIVE_AGENT_DIR:-$BRIDGE_STATE_DIR/agents}"
BRIDGE_HISTORY_DIR="${BRIDGE_HISTORY_DIR:-$BRIDGE_STATE_DIR/history}"
BRIDGE_WORKTREE_META_DIR="${BRIDGE_WORKTREE_META_DIR:-$BRIDGE_STATE_DIR/worktrees}"
BRIDGE_ACTIVE_ROSTER_TSV="${BRIDGE_ACTIVE_ROSTER_TSV:-$BRIDGE_STATE_DIR/active-roster.tsv}"
BRIDGE_ACTIVE_ROSTER_MD="${BRIDGE_ACTIVE_ROSTER_MD:-$BRIDGE_STATE_DIR/active-roster.md}"
BRIDGE_DAEMON_PID_FILE="${BRIDGE_DAEMON_PID_FILE:-$BRIDGE_STATE_DIR/daemon.pid}"
BRIDGE_DAEMON_LOG="${BRIDGE_DAEMON_LOG:-$BRIDGE_STATE_DIR/daemon.log}"
BRIDGE_DAEMON_CRASH_LOG="${BRIDGE_DAEMON_CRASH_LOG:-$BRIDGE_STATE_DIR/daemon-crash.log}"
BRIDGE_DAEMON_INTERVAL="${BRIDGE_DAEMON_INTERVAL:-5}"
BRIDGE_DAEMON_START_WAIT_SECONDS="${BRIDGE_DAEMON_START_WAIT_SECONDS:-3}"
BRIDGE_TASK_DB="${BRIDGE_TASK_DB:-$BRIDGE_STATE_DIR/tasks.db}"
BRIDGE_PROFILE_STATE_DIR="${BRIDGE_PROFILE_STATE_DIR:-$BRIDGE_STATE_DIR/profiles}"
BRIDGE_CRON_STATE_DIR="${BRIDGE_CRON_STATE_DIR:-$BRIDGE_STATE_DIR/cron}"
BRIDGE_CRON_HOME_DIR="${BRIDGE_CRON_HOME_DIR:-$BRIDGE_HOME/cron}"
BRIDGE_NATIVE_CRON_JOBS_FILE="${BRIDGE_NATIVE_CRON_JOBS_FILE:-$BRIDGE_CRON_HOME_DIR/jobs.json}"
BRIDGE_CRON_DISPATCH_WORKER_DIR="${BRIDGE_CRON_DISPATCH_WORKER_DIR:-$BRIDGE_CRON_STATE_DIR/workers}"
BRIDGE_CRON_DISPATCH_MAX_PARALLEL="${BRIDGE_CRON_DISPATCH_MAX_PARALLEL:-2}"
BRIDGE_CRON_DISPATCH_LEASE_SECONDS="${BRIDGE_CRON_DISPATCH_LEASE_SECONDS:-7200}"
BRIDGE_WORKTREE_ROOT="${BRIDGE_WORKTREE_ROOT:-$HOME/.agent-bridge/worktrees}"
BRIDGE_AGENT_HOME_ROOT="${BRIDGE_AGENT_HOME_ROOT:-$BRIDGE_HOME/agents}"
BRIDGE_RUNTIME_ROOT="${BRIDGE_RUNTIME_ROOT:-$BRIDGE_HOME/runtime}"
BRIDGE_RUNTIME_SCRIPTS_DIR="${BRIDGE_RUNTIME_SCRIPTS_DIR:-$BRIDGE_RUNTIME_ROOT/scripts}"
BRIDGE_RUNTIME_SKILLS_DIR="${BRIDGE_RUNTIME_SKILLS_DIR:-$BRIDGE_RUNTIME_ROOT/skills}"
BRIDGE_RUNTIME_SHARED_DIR="${BRIDGE_RUNTIME_SHARED_DIR:-$BRIDGE_RUNTIME_ROOT/shared}"
BRIDGE_RUNTIME_SHARED_TOOLS_DIR="${BRIDGE_RUNTIME_SHARED_TOOLS_DIR:-$BRIDGE_RUNTIME_SHARED_DIR/tools}"
BRIDGE_RUNTIME_SHARED_REFERENCES_DIR="${BRIDGE_RUNTIME_SHARED_REFERENCES_DIR:-$BRIDGE_RUNTIME_SHARED_DIR/references}"
BRIDGE_RUNTIME_MEMORY_DIR="${BRIDGE_RUNTIME_MEMORY_DIR:-$BRIDGE_RUNTIME_ROOT/memory}"
BRIDGE_HOOKS_DIR="${BRIDGE_HOOKS_DIR:-$BRIDGE_HOME/hooks}"
BRIDGE_CHANNEL_SERVER_NAME="${BRIDGE_CHANNEL_SERVER_NAME:-bridge-webhook}"
BRIDGE_WEBHOOK_PORT_RANGE_START="${BRIDGE_WEBHOOK_PORT_RANGE_START:-9101}"
BRIDGE_WEBHOOK_PORT_RANGE_END="${BRIDGE_WEBHOOK_PORT_RANGE_END:-9199}"
BRIDGE_CLAUDE_IDLE_FALLBACK_SECONDS="${BRIDGE_CLAUDE_IDLE_FALLBACK_SECONDS:-300}"
BRIDGE_OPENCLAW_HOME="${BRIDGE_OPENCLAW_HOME:-$HOME/.openclaw}"
BRIDGE_OPENCLAW_CRON_JOBS_FILE="${BRIDGE_OPENCLAW_CRON_JOBS_FILE:-$BRIDGE_OPENCLAW_HOME/cron/jobs.json}"
BRIDGE_DISCORD_RELAY_STATE_FILE="${BRIDGE_DISCORD_RELAY_STATE_FILE:-$BRIDGE_STATE_DIR/discord-relay.json}"
BRIDGE_DAEMON_LAUNCHAGENT_LABEL="${BRIDGE_DAEMON_LAUNCHAGENT_LABEL:-ai.agent-bridge.daemon}"
BRIDGE_DAEMON_LAUNCHAGENT_PLIST="${BRIDGE_DAEMON_LAUNCHAGENT_PLIST:-$HOME/Library/LaunchAgents/$BRIDGE_DAEMON_LAUNCHAGENT_LABEL.plist}"
BRIDGE_TMUX_PROMPT_WAIT_SECONDS="${BRIDGE_TMUX_PROMPT_WAIT_SECONDS:-2}"
BRIDGE_BASH_BIN="${BRIDGE_BASH_BIN:-${BASH:-$(command -v bash)}}"
export BRIDGE_BASH_BIN
export BRIDGE_HOME BRIDGE_ROSTER_FILE BRIDGE_ROSTER_LOCAL_FILE
export BRIDGE_STATE_DIR BRIDGE_ACTIVE_AGENT_DIR BRIDGE_HISTORY_DIR BRIDGE_WORKTREE_META_DIR
export BRIDGE_ACTIVE_ROSTER_TSV BRIDGE_ACTIVE_ROSTER_MD
export BRIDGE_DAEMON_PID_FILE BRIDGE_DAEMON_LOG BRIDGE_DAEMON_CRASH_LOG
export BRIDGE_DAEMON_INTERVAL BRIDGE_DAEMON_START_WAIT_SECONDS
export BRIDGE_TASK_DB BRIDGE_PROFILE_STATE_DIR BRIDGE_CRON_STATE_DIR BRIDGE_CRON_HOME_DIR BRIDGE_NATIVE_CRON_JOBS_FILE
export BRIDGE_CRON_DISPATCH_WORKER_DIR BRIDGE_CRON_DISPATCH_MAX_PARALLEL BRIDGE_CRON_DISPATCH_LEASE_SECONDS
export BRIDGE_WORKTREE_ROOT BRIDGE_AGENT_HOME_ROOT
export BRIDGE_RUNTIME_ROOT BRIDGE_RUNTIME_SCRIPTS_DIR BRIDGE_RUNTIME_SKILLS_DIR
export BRIDGE_RUNTIME_SHARED_DIR BRIDGE_RUNTIME_SHARED_TOOLS_DIR BRIDGE_RUNTIME_SHARED_REFERENCES_DIR BRIDGE_RUNTIME_MEMORY_DIR
export BRIDGE_HOOKS_DIR
export BRIDGE_CHANNEL_SERVER_NAME BRIDGE_WEBHOOK_PORT_RANGE_START BRIDGE_WEBHOOK_PORT_RANGE_END
export BRIDGE_CLAUDE_IDLE_FALLBACK_SECONDS
export BRIDGE_OPENCLAW_HOME BRIDGE_OPENCLAW_CRON_JOBS_FILE
export BRIDGE_DISCORD_RELAY_STATE_FILE BRIDGE_DAEMON_LAUNCHAGENT_LABEL BRIDGE_DAEMON_LAUNCHAGENT_PLIST
export BRIDGE_TMUX_PROMPT_WAIT_SECONDS

bridge_prepend_path_entry() {
  local entry="$1"
  [[ -n "$entry" ]] || return 0
  [[ -d "$entry" ]] || return 0
  case ":$PATH:" in
    *":$entry:"*) ;;
    *) PATH="$entry${PATH:+:$PATH}" ;;
  esac
}

bridge_prepend_path_entry "$HOME/.local/bin"
bridge_prepend_path_entry "$HOME/.nix-profile/bin"
bridge_prepend_path_entry "$HOME/bin"
bridge_prepend_path_entry "/opt/homebrew/bin"
bridge_prepend_path_entry "/usr/local/bin"
export PATH

RED='\033[0;31m'
# shellcheck disable=SC2034
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BRIDGE_MANAGED_MARKER="Managed by agent-bridge. Regenerated by agent-bridge."

bridge_source_module() {
  local module="$1"
  local path="$BRIDGE_SCRIPT_DIR/lib/$module"

  if [[ ! -f "$path" ]]; then
    echo "[bridge-lib] missing module: $path" >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$path"
}

bridge_source_module "bridge-core.sh"
bridge_source_module "bridge-agents.sh"
bridge_source_module "bridge-tmux.sh"
bridge_source_module "bridge-skills.sh"
bridge_source_module "bridge-hooks.sh"
bridge_source_module "bridge-channels.sh"
bridge_source_module "bridge-state.sh"
bridge_source_module "bridge-profiles.sh"
bridge_source_module "bridge-cron.sh"
bridge_source_module "bridge-discord.sh"
bridge_source_module "bridge-notify.sh"
