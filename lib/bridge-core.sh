#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034

bridge_die() {
  echo -e "${RED}[오류] $*${NC}" >&2
  exit 1
}

bridge_warn() {
  echo -e "${YELLOW}[경고] $*${NC}" >&2
}

bridge_info() {
  echo -e "${CYAN}$*${NC}"
}

bridge_init_dirs() {
  mkdir -p \
    "$BRIDGE_HOME" \
    "$BRIDGE_STATE_DIR" \
    "$BRIDGE_CRON_HOME_DIR" \
    "$BRIDGE_PROFILE_STATE_DIR" \
    "$BRIDGE_ACTIVE_AGENT_DIR" \
    "$BRIDGE_HISTORY_DIR" \
    "$BRIDGE_WORKTREE_META_DIR" \
    "$BRIDGE_WORKTREE_ROOT" \
    "$BRIDGE_LOG_DIR" \
    "$BRIDGE_SHARED_DIR" \
    "$BRIDGE_TASK_NOTE_DIR" \
    "$BRIDGE_RUNTIME_ROOT" \
    "$BRIDGE_RUNTIME_SCRIPTS_DIR" \
    "$BRIDGE_RUNTIME_SKILLS_DIR" \
    "$BRIDGE_RUNTIME_SHARED_TOOLS_DIR" \
    "$BRIDGE_RUNTIME_SHARED_REFERENCES_DIR" \
    "$BRIDGE_RUNTIME_MEMORY_DIR"
}

bridge_require_python() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  bridge_die "python3가 필요합니다."
}

bridge_now_iso() {
  bridge_require_python
  python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"))
PY
}

bridge_nonce() {
  bridge_require_python
  python3 - <<'PY'
import secrets

print(secrets.token_hex(8))
PY
}

bridge_sha1() {
  local text="$1"

  bridge_require_python
  python3 - "$text" <<'PY'
import hashlib
import sys

print(hashlib.sha1(sys.argv[1].encode("utf-8")).hexdigest())
PY
}

bridge_queue_cli() {
  bridge_require_python
  python3 "$BRIDGE_SCRIPT_DIR/bridge-queue.py" "$@"
}

bridge_reset_roster_maps() {
  unset BRIDGE_ADMIN_AGENT_ID
  unset BRIDGE_AGENT_IDS BRIDGE_AGENT_DESC BRIDGE_AGENT_ENGINE BRIDGE_AGENT_SESSION
  unset BRIDGE_AGENT_WORKDIR BRIDGE_AGENT_PROFILE_HOME BRIDGE_AGENT_LAUNCH_CMD BRIDGE_AGENT_ACTION
  unset BRIDGE_AGENT_SOURCE BRIDGE_AGENT_META_FILE BRIDGE_AGENT_LOOP
  unset BRIDGE_AGENT_CONTINUE BRIDGE_AGENT_SESSION_ID BRIDGE_AGENT_HISTORY_KEY
  unset BRIDGE_AGENT_CREATED_AT BRIDGE_AGENT_UPDATED_AT BRIDGE_AGENT_IDLE_TIMEOUT
  unset BRIDGE_AGENT_NOTIFY_KIND BRIDGE_AGENT_NOTIFY_TARGET BRIDGE_AGENT_NOTIFY_ACCOUNT
  unset BRIDGE_AGENT_WEBHOOK_PORT BRIDGE_OPENCLAW_AGENT_TARGET BRIDGE_AGENT_DISCORD_CHANNEL_ID BRIDGE_CRON_ENQUEUE_FAMILIES

  declare -g -a BRIDGE_AGENT_IDS=()
  declare -g -A BRIDGE_AGENT_DESC=()
  declare -g -A BRIDGE_AGENT_ENGINE=()
  declare -g -A BRIDGE_AGENT_SESSION=()
  declare -g -A BRIDGE_AGENT_WORKDIR=()
  declare -g -A BRIDGE_AGENT_PROFILE_HOME=()
  declare -g -A BRIDGE_AGENT_LAUNCH_CMD=()
  declare -g -A BRIDGE_AGENT_ACTION=()
  declare -g -A BRIDGE_AGENT_SOURCE=()
  declare -g -A BRIDGE_AGENT_META_FILE=()
  declare -g -A BRIDGE_AGENT_LOOP=()
  declare -g -A BRIDGE_AGENT_CONTINUE=()
  declare -g -A BRIDGE_AGENT_SESSION_ID=()
  declare -g -A BRIDGE_AGENT_HISTORY_KEY=()
  declare -g -A BRIDGE_AGENT_CREATED_AT=()
  declare -g -A BRIDGE_AGENT_UPDATED_AT=()
  declare -g -A BRIDGE_AGENT_IDLE_TIMEOUT=()
  declare -g -A BRIDGE_AGENT_NOTIFY_KIND=()
  declare -g -A BRIDGE_AGENT_NOTIFY_TARGET=()
  declare -g -A BRIDGE_AGENT_NOTIFY_ACCOUNT=()
  declare -g -A BRIDGE_AGENT_WEBHOOK_PORT=()
  declare -g -A BRIDGE_OPENCLAW_AGENT_TARGET=()
  declare -g -A BRIDGE_AGENT_DISCORD_CHANNEL_ID=()
  declare -g -a BRIDGE_CRON_ENQUEUE_FAMILIES=()
}

bridge_add_agent_id_if_missing() {
  local agent="$1"
  local existing

  for existing in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$existing" == "$agent" ]]; then
      return 0
    fi
  done

  BRIDGE_AGENT_IDS+=("$agent")
}

bridge_validate_agent_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]
}

bridge_join_quoted() {
  local out=""
  local arg
  local quoted

  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    out+="${out:+ }${quoted}"
  done

  printf '%s' "$out"
}

bridge_export_env_prefix() {
  local out=""
  local name
  local value
  local quoted
  local names=(
    BRIDGE_BASH_BIN
    BRIDGE_HOME
    BRIDGE_ROSTER_FILE
    BRIDGE_ROSTER_LOCAL_FILE
    BRIDGE_STATE_DIR
    BRIDGE_ACTIVE_AGENT_DIR
    BRIDGE_HISTORY_DIR
    BRIDGE_WORKTREE_META_DIR
    BRIDGE_ACTIVE_ROSTER_TSV
    BRIDGE_ACTIVE_ROSTER_MD
    BRIDGE_DAEMON_PID_FILE
    BRIDGE_DAEMON_LOG
    BRIDGE_DAEMON_INTERVAL
    BRIDGE_TASK_DB
    BRIDGE_PROFILE_STATE_DIR
    BRIDGE_DISCORD_RELAY_STATE_FILE
    BRIDGE_WORKTREE_ROOT
    BRIDGE_RUNTIME_ROOT
    BRIDGE_RUNTIME_SCRIPTS_DIR
    BRIDGE_RUNTIME_SKILLS_DIR
    BRIDGE_RUNTIME_SHARED_DIR
    BRIDGE_RUNTIME_SHARED_TOOLS_DIR
    BRIDGE_RUNTIME_SHARED_REFERENCES_DIR
    BRIDGE_RUNTIME_MEMORY_DIR
    BRIDGE_LOG_DIR
    BRIDGE_SHARED_DIR
    BRIDGE_TASK_NOTE_DIR
    BRIDGE_TASK_LEASE_SECONDS
    BRIDGE_TASK_IDLE_NUDGE_SECONDS
    BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS
    BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS
    BRIDGE_ON_DEMAND_IDLE_SECONDS
    BRIDGE_DISCORD_RELAY_ENABLED
    BRIDGE_DISCORD_RELAY_ACCOUNT
    BRIDGE_DISCORD_RELAY_POLL_LIMIT
    BRIDGE_DISCORD_RELAY_COOLDOWN_SECONDS
  )

  for name in "${names[@]}"; do
    [[ -n "${!name+x}" ]] || continue
    value="${!name}"
    printf -v quoted '%q' "$value"
    out+="${out:+ }${name}=${quoted}"
  done

  printf '%s' "$out"
}

bridge_project_root_for_path() {
  local path="$1"

  if git -C "$path" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$path" rev-parse --show-toplevel | sed 's#/*$##'
    return 0
  fi

  (cd "$path" && pwd -P)
}

bridge_path_relative_to_root() {
  local path="$1"
  local root="$2"

  bridge_require_python
  python3 - "$path" "$root" <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
root = os.path.realpath(sys.argv[2])

try:
    rel = os.path.relpath(path, root)
except Exception:
    rel = "."

print(rel)
PY
}

bridge_path_is_within_root() {
  local path="$1"
  local root="$2"

  bridge_require_python
  python3 - "$path" "$root" <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
root = os.path.realpath(sys.argv[2])

try:
    common = os.path.commonpath([path, root])
except ValueError:
    print("0")
    raise SystemExit(0)

print("1" if common == root else "0")
PY
}

bridge_history_key_for() {
  local engine="$1"
  local name="$2"
  local workdir="$3"
  bridge_sha1 "${engine}|${name}|${workdir}"
}

bridge_history_file_for() {
  local engine="$1"
  local name="$2"
  local workdir="$3"
  local key

  key="$(bridge_history_key_for "$engine" "$name" "$workdir")"
  printf '%s/%s--%s--%s.env' "$BRIDGE_HISTORY_DIR" "$name" "$engine" "$key"
}

bridge_dynamic_agent_file_for() {
  local name="$1"
  printf '%s/%s.env' "$BRIDGE_ACTIVE_AGENT_DIR" "$name"
}
