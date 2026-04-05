#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034

bridge_build_dynamic_launch_cmd() {
  local agent="$1"
  local engine continue_mode session_id

  engine="$(bridge_agent_engine "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  session_id="$(bridge_agent_session_id "$agent")"

  case "$engine" in
    codex)
      if [[ "$continue_mode" == "1" && -n "$session_id" ]]; then
        bridge_join_quoted codex resume "$session_id" --dangerously-bypass-approvals-and-sandbox --no-alt-screen
      else
        bridge_join_quoted codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen
      fi
      ;;
    claude)
      if [[ "$continue_mode" == "1" && -n "$session_id" ]]; then
        bridge_join_quoted claude --resume "$session_id" --dangerously-skip-permissions --name "$agent"
      elif [[ "$continue_mode" == "1" ]]; then
        bridge_join_quoted claude --continue --dangerously-skip-permissions --name "$agent"
      else
        bridge_join_quoted claude --dangerously-skip-permissions --name "$agent"
      fi
      ;;
    *)
      printf '%s' "${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
      ;;
  esac
}

bridge_build_resume_launch_cmd() {
  local agent="$1"
  local engine continue_mode session_id
  local original_cmd=""
  local env_prefix=""
  local channels_flag=""
  local resume_cmd=""

  engine="$(bridge_agent_engine "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  session_id="$(bridge_agent_session_id "$agent")"

  if [[ "$continue_mode" != "1" || -z "$session_id" ]]; then
    return 1
  fi

  case "$engine" in
    codex)
      bridge_join_quoted codex resume "$session_id" --dangerously-bypass-approvals-and-sandbox --no-alt-screen
      ;;
    claude)
      original_cmd="${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
      if [[ "$original_cmd" =~ ^([A-Z_]+=[^ ]+[[:space:]]+)+ ]]; then
        env_prefix="${BASH_REMATCH[0]}"
      fi
      if [[ "$original_cmd" == *"--channels "* ]]; then
        channels_flag="$(printf '%s' "$original_cmd" | grep -oE -- '--channels [^ ]+' || true)"
      fi
      resume_cmd="$(bridge_join_quoted claude --resume "$session_id" --dangerously-skip-permissions --name "$agent")"
      if [[ -n "$channels_flag" ]]; then
        resume_cmd="${resume_cmd} ${channels_flag//$'\n'/ }"
      fi
      if [[ -n "$env_prefix" ]]; then
        printf '%s%s' "$env_prefix" "$resume_cmd"
      else
        printf '%s' "$resume_cmd"
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_build_static_claude_launch_cmd() {
  local agent="$1"
  local fallback=""
  local continue_mode=""
  local session_id=""

  fallback="${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
  [[ -n "$fallback" ]] || return 1

  continue_mode="$(bridge_agent_continue "$agent")"
  session_id="$(bridge_agent_session_id "$agent")"

  bridge_require_python
  python3 - "$agent" "$continue_mode" "$session_id" "$fallback" <<'PY'
import re
import shlex
import sys

agent, continue_mode, session_id, original = sys.argv[1:]
match = re.match(r"^(?P<prefix>.*?)(?P<command>claude(?:\s|$).*)$", original)
if not match:
    print(original)
    raise SystemExit(0)

env_prefix = match.group("prefix")
args = shlex.split(match.group("command"))
if not args or args[0] != "claude":
    print(original)
    raise SystemExit(0)

rest = args[1:]
extras = []
j = 0
while j < len(rest):
    token = rest[j]
    if token in {"-c", "--continue", "--dangerously-skip-permissions"}:
        j += 1
        continue
    if token in {"--resume", "--name"}:
        j += 2 if j + 1 < len(rest) else 1
        continue
    extras.append(token)
    if token.startswith("--") and j + 1 < len(rest) and not rest[j + 1].startswith("-"):
        extras.append(rest[j + 1])
        j += 2
        continue
    j += 1

base = ["claude"]
if continue_mode == "1":
    if session_id:
        base.extend(["--resume", session_id])
base.extend(["--dangerously-skip-permissions", "--name", agent])
base.extend(extras)

quoted = " ".join(shlex.quote(token) for token in base)
if env_prefix:
    print(f"{env_prefix}{quoted}")
else:
    print(quoted)
PY
}

bridge_agent_launch_cmd() {
  local agent="$1"
  local fallback=""
  local launch_cmd=""

  if [[ "$(bridge_agent_source "$agent")" == "dynamic" ]]; then
    if launch_cmd="$(bridge_build_resume_launch_cmd "$agent")"; then
      launch_cmd="$(bridge_claude_launch_with_webhook "$agent" "$launch_cmd")"
      printf '%s' "$launch_cmd"
      return 0
    fi
    launch_cmd="$(bridge_build_dynamic_launch_cmd "$agent")"
    launch_cmd="$(bridge_claude_launch_with_webhook "$agent" "$launch_cmd")"
    printf '%s' "$launch_cmd"
    return 0
  fi

  fallback="${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
  if [[ "$(bridge_agent_engine "$agent")" == "claude" ]] && launch_cmd="$(bridge_build_static_claude_launch_cmd "$agent")"; then
    launch_cmd="$(bridge_claude_launch_with_webhook "$agent" "$launch_cmd")"
    printf '%s' "$launch_cmd"
    return 0
  fi
  if launch_cmd="$(bridge_build_resume_launch_cmd "$agent")"; then
    launch_cmd="$(bridge_claude_launch_with_webhook "$agent" "$launch_cmd")"
    printf '%s' "$launch_cmd"
    return 0
  fi

  launch_cmd="$(bridge_claude_launch_with_webhook "$agent" "$fallback")"
  printf '%s' "$launch_cmd"
}

bridge_load_dynamic_agent_file() {
  local file="$1"
  local AGENT_ID=""
  local AGENT_DESC=""
  local AGENT_ENGINE=""
  local AGENT_SESSION=""
  local AGENT_WORKDIR=""
  local AGENT_LOOP=""
  local AGENT_CONTINUE=""
  local AGENT_SESSION_ID=""
  local AGENT_HISTORY_KEY=""
  local AGENT_CREATED_AT=""
  local AGENT_UPDATED_AT=""

  # shellcheck source=/dev/null
  source "$file"

  if [[ -z "$AGENT_ID" || -z "$AGENT_ENGINE" || -z "$AGENT_SESSION" || -z "$AGENT_WORKDIR" ]]; then
    return 0
  fi

  if bridge_agent_exists "$AGENT_ID" && [[ "$(bridge_agent_source "$AGENT_ID")" == "static" ]]; then
    BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="${AGENT_SESSION_ID:-${BRIDGE_AGENT_SESSION_ID[$AGENT_ID]-}}"
    BRIDGE_AGENT_HISTORY_KEY["$AGENT_ID"]="${AGENT_HISTORY_KEY:-${BRIDGE_AGENT_HISTORY_KEY[$AGENT_ID]-}}"
    BRIDGE_AGENT_CREATED_AT["$AGENT_ID"]="${AGENT_CREATED_AT:-${BRIDGE_AGENT_CREATED_AT[$AGENT_ID]-}}"
    BRIDGE_AGENT_UPDATED_AT["$AGENT_ID"]="${AGENT_UPDATED_AT:-${BRIDGE_AGENT_UPDATED_AT[$AGENT_ID]-}}"
    return 0
  fi

  bridge_add_agent_id_if_missing "$AGENT_ID"
  BRIDGE_AGENT_DESC["$AGENT_ID"]="${AGENT_DESC:-$AGENT_ID}"
  BRIDGE_AGENT_ENGINE["$AGENT_ID"]="$AGENT_ENGINE"
  BRIDGE_AGENT_SESSION["$AGENT_ID"]="$AGENT_SESSION"
  BRIDGE_AGENT_WORKDIR["$AGENT_ID"]="$AGENT_WORKDIR"
  BRIDGE_AGENT_SOURCE["$AGENT_ID"]="dynamic"
  BRIDGE_AGENT_META_FILE["$AGENT_ID"]="$file"
  BRIDGE_AGENT_LOOP["$AGENT_ID"]="${AGENT_LOOP:-1}"
  BRIDGE_AGENT_CONTINUE["$AGENT_ID"]="${AGENT_CONTINUE:-1}"
  BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="${AGENT_SESSION_ID:-}"
  BRIDGE_AGENT_HISTORY_KEY["$AGENT_ID"]="${AGENT_HISTORY_KEY:-}"
  BRIDGE_AGENT_CREATED_AT["$AGENT_ID"]="${AGENT_CREATED_AT:-}"
  BRIDGE_AGENT_UPDATED_AT["$AGENT_ID"]="${AGENT_UPDATED_AT:-}"
}

bridge_load_dynamic_agents() {
  local file

  shopt -s nullglob
  for file in "$BRIDGE_ACTIVE_AGENT_DIR"/*.env; do
    bridge_load_dynamic_agent_file "$file"
  done
  shopt -u nullglob
}

bridge_restore_dynamic_agents_from_history() {
  local file active_file
  local AGENT_ID=""
  local AGENT_DESC=""
  local AGENT_ENGINE=""
  local AGENT_SESSION=""
  local AGENT_WORKDIR=""
  local AGENT_LOOP=""
  local AGENT_CONTINUE=""
  local AGENT_SESSION_ID=""
  local AGENT_HISTORY_KEY=""
  local AGENT_CREATED_AT=""
  local AGENT_UPDATED_AT=""

  shopt -s nullglob
  for file in "$BRIDGE_HISTORY_DIR"/*.env; do
    AGENT_ID=""
    AGENT_DESC=""
    AGENT_ENGINE=""
    AGENT_SESSION=""
    AGENT_WORKDIR=""
    AGENT_LOOP=""
    AGENT_CONTINUE=""
    AGENT_SESSION_ID=""
    AGENT_HISTORY_KEY=""
    AGENT_CREATED_AT=""
    AGENT_UPDATED_AT=""

    # shellcheck source=/dev/null
    source "$file"

    if [[ -z "$AGENT_ID" || -z "$AGENT_ENGINE" || -z "$AGENT_SESSION" || -z "$AGENT_WORKDIR" ]]; then
      continue
    fi
    if bridge_agent_exists "$AGENT_ID"; then
      continue
    fi
    if ! bridge_tmux_session_exists "$AGENT_SESSION"; then
      continue
    fi

    bridge_add_agent_id_if_missing "$AGENT_ID"
    BRIDGE_AGENT_DESC["$AGENT_ID"]="${AGENT_DESC:-$AGENT_ID}"
    BRIDGE_AGENT_ENGINE["$AGENT_ID"]="$AGENT_ENGINE"
    BRIDGE_AGENT_SESSION["$AGENT_ID"]="$AGENT_SESSION"
    BRIDGE_AGENT_WORKDIR["$AGENT_ID"]="$AGENT_WORKDIR"
    BRIDGE_AGENT_SOURCE["$AGENT_ID"]="dynamic"
    BRIDGE_AGENT_LOOP["$AGENT_ID"]="${AGENT_LOOP:-1}"
    BRIDGE_AGENT_CONTINUE["$AGENT_ID"]="${AGENT_CONTINUE:-1}"
    BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="${AGENT_SESSION_ID:-}"
    BRIDGE_AGENT_HISTORY_KEY["$AGENT_ID"]="${AGENT_HISTORY_KEY:-}"
    BRIDGE_AGENT_CREATED_AT["$AGENT_ID"]="${AGENT_CREATED_AT:-}"
    BRIDGE_AGENT_UPDATED_AT["$AGENT_ID"]="${AGENT_UPDATED_AT:-}"

    active_file="$(bridge_dynamic_agent_file_for "$AGENT_ID")"
    BRIDGE_AGENT_META_FILE["$AGENT_ID"]="$active_file"
    bridge_write_dynamic_agent_file "$AGENT_ID" "$active_file"
  done
  shopt -u nullglob
}

bridge_load_static_agent_history() {
  local agent="$1"
  local file
  local AGENT_ID=""
  local AGENT_ENGINE=""
  local AGENT_WORKDIR=""
  local AGENT_SESSION_ID=""
  local AGENT_HISTORY_KEY=""
  local AGENT_CREATED_AT=""
  local AGENT_UPDATED_AT=""

  file="$(bridge_history_file_for_agent "$agent")"
  [[ -f "$file" ]] || return 0

  # shellcheck source=/dev/null
  source "$file"

  if [[ -n "$AGENT_ID" && "$AGENT_ID" != "$agent" ]]; then
    return 0
  fi

  if [[ -n "$AGENT_SESSION_ID" ]]; then
    AGENT_ENGINE="${AGENT_ENGINE:-$(bridge_agent_engine "$agent")}"
    AGENT_WORKDIR="${AGENT_WORKDIR:-$(bridge_agent_workdir "$agent")}"
    if [[ "$AGENT_ENGINE" != "claude" ]] || bridge_claude_session_id_exists "$AGENT_SESSION_ID" "$AGENT_WORKDIR"; then
      BRIDGE_AGENT_SESSION_ID["$agent"]="$AGENT_SESSION_ID"
    fi
  fi
  if [[ -n "$AGENT_HISTORY_KEY" ]]; then
    BRIDGE_AGENT_HISTORY_KEY["$agent"]="$AGENT_HISTORY_KEY"
  fi
  if [[ -n "$AGENT_CREATED_AT" ]]; then
    BRIDGE_AGENT_CREATED_AT["$agent"]="$AGENT_CREATED_AT"
  fi
  if [[ -n "$AGENT_UPDATED_AT" ]]; then
    BRIDGE_AGENT_UPDATED_AT["$agent"]="$AGENT_UPDATED_AT"
  fi
}

bridge_load_static_histories() {
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    bridge_load_static_agent_history "$agent"
  done
}

bridge_load_roster() {
  local agent

  bridge_reset_roster_maps

  if [[ -f "$BRIDGE_ROSTER_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$BRIDGE_ROSTER_FILE"
  fi

  if [[ -f "$BRIDGE_ROSTER_LOCAL_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$BRIDGE_ROSTER_LOCAL_FILE"
  fi

  : "${BRIDGE_LOG_DIR:=$BRIDGE_HOME/logs}"
  : "${BRIDGE_SHARED_DIR:=$BRIDGE_HOME/shared}"
  : "${BRIDGE_MAX_MESSAGE_LEN:=500}"
  : "${BRIDGE_TASK_NOTE_DIR:=$BRIDGE_SHARED_DIR/tasks}"
  : "${BRIDGE_TASK_LEASE_SECONDS:=900}"
  : "${BRIDGE_TASK_IDLE_NUDGE_SECONDS:=120}"
  : "${BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS:=300}"
  : "${BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS:=300}"
  : "${BRIDGE_HEALTH_WARN_SECONDS:=3600}"
  : "${BRIDGE_HEALTH_CRITICAL_SECONDS:=14400}"
  : "${BRIDGE_ON_DEMAND_IDLE_SECONDS:=0}"
  : "${BRIDGE_ADMIN_AGENT_ID:=}"
  : "${BRIDGE_OPENCLAW_CRON_SYNC_ENABLED:=0}"
  : "${BRIDGE_DISCORD_RELAY_ENABLED:=1}"
  : "${BRIDGE_DISCORD_RELAY_ACCOUNT:=default}"
  : "${BRIDGE_DISCORD_RELAY_POLL_LIMIT:=5}"
  : "${BRIDGE_DISCORD_RELAY_COOLDOWN_SECONDS:=60}"

  bridge_init_dirs

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    BRIDGE_AGENT_SOURCE["$agent"]="${BRIDGE_AGENT_SOURCE[$agent]-static}"
    BRIDGE_AGENT_LOOP["$agent"]="${BRIDGE_AGENT_LOOP[$agent]-1}"
    BRIDGE_AGENT_CONTINUE["$agent"]="${BRIDGE_AGENT_CONTINUE[$agent]-1}"
    BRIDGE_AGENT_HISTORY_KEY["$agent"]="${BRIDGE_AGENT_HISTORY_KEY[$agent]-$(bridge_history_key_for "$(bridge_agent_engine "$agent")" "$agent" "$(bridge_agent_workdir "$agent")")}"
    BRIDGE_AGENT_IDLE_TIMEOUT["$agent"]="${BRIDGE_AGENT_IDLE_TIMEOUT[$agent]-$BRIDGE_ON_DEMAND_IDLE_SECONDS}"
  done

  bridge_load_static_histories
  bridge_load_dynamic_agents
  bridge_restore_dynamic_agents_from_history
}

bridge_dynamic_agent_ids() {
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$(bridge_agent_source "$agent")" == "dynamic" ]]; then
      printf '%s\n' "$agent"
    fi
  done
}

bridge_write_agent_state_file() {
  local agent="$1"
  local file="$2"
  local desc engine session workdir loop_mode continue_mode session_id history_key created_at updated_at

  desc="$(bridge_agent_desc "$agent")"
  engine="$(bridge_agent_engine "$agent")"
  session="$(bridge_agent_session "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  session_id="$(bridge_agent_session_id "$agent")"
  history_key="$(bridge_agent_history_key "$agent")"
  created_at="${BRIDGE_AGENT_CREATED_AT[$agent]-$(date +%s)}"
  updated_at="$(bridge_now_iso)"

  BRIDGE_AGENT_UPDATED_AT["$agent"]="$updated_at"

  mkdir -p "$(dirname "$file")"
  cat >"$file" <<EOF
AGENT_ID=$(printf '%q' "$agent")
AGENT_DESC=$(printf '%q' "$desc")
AGENT_ENGINE=$(printf '%q' "$engine")
AGENT_SESSION=$(printf '%q' "$session")
AGENT_WORKDIR=$(printf '%q' "$workdir")
AGENT_LOOP=$(printf '%q' "$loop_mode")
AGENT_CONTINUE=$(printf '%q' "$continue_mode")
AGENT_SESSION_ID=$(printf '%q' "$session_id")
AGENT_HISTORY_KEY=$(printf '%q' "$history_key")
AGENT_CREATED_AT=$(printf '%q' "$created_at")
AGENT_UPDATED_AT=$(printf '%q' "$updated_at")
EOF
}

bridge_write_dynamic_agent_file() {
  local agent="$1"
  local file="${2:-$(bridge_dynamic_agent_file_for "$agent")}"
  bridge_write_agent_state_file "$agent" "$file"
}

bridge_agent_idle_marker_dir() {
  local agent="$1"
  printf '%s/%s' "$BRIDGE_ACTIVE_AGENT_DIR" "$agent"
}

bridge_agent_idle_since_file() {
  local agent="$1"
  printf '%s/idle-since' "$(bridge_agent_idle_marker_dir "$agent")"
}

bridge_agent_idle_since_epoch() {
  local agent="$1"
  local file
  local value

  file="$(bridge_agent_idle_since_file "$agent")"
  [[ -f "$file" ]] || return 1
  value="$(<"$file")"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$value"
}

bridge_agent_idle_marker_exists() {
  local agent="$1"
  [[ -f "$(bridge_agent_idle_since_file "$agent")" ]]
}

bridge_agent_mark_idle_now() {
  local agent="$1"
  local dir
  local file

  dir="$(bridge_agent_idle_marker_dir "$agent")"
  file="$(bridge_agent_idle_since_file "$agent")"
  mkdir -p "$dir"
  printf '%s\n' "$(date +%s)" >"$file"
}

bridge_agent_clear_idle_marker() {
  local agent="$1"
  local file
  local dir

  file="$(bridge_agent_idle_since_file "$agent")"
  dir="$(bridge_agent_idle_marker_dir "$agent")"
  rm -f "$file"
  rmdir "$dir" >/dev/null 2>&1 || true
}

bridge_reconcile_idle_markers() {
  local agent
  local file
  local value

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    file="$(bridge_agent_idle_since_file "$agent")"
    [[ -f "$file" ]] || continue

    if ! bridge_agent_is_active "$agent"; then
      bridge_agent_clear_idle_marker "$agent"
      continue
    fi

    value="$(<"$file")"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
      bridge_agent_clear_idle_marker "$agent"
    fi
  done
}

bridge_archive_dynamic_agent() {
  local agent="$1"
  local history_file

  history_file="$(bridge_history_file_for_agent "$agent")"
  bridge_write_agent_state_file "$agent" "$history_file"
}

bridge_remove_dynamic_agent_file() {
  local agent="$1"
  local file

  file="$(bridge_agent_meta_file "$agent")"
  if [[ -n "$file" && -f "$file" ]]; then
    rm -f "$file"
  fi
}

bridge_persist_agent_state() {
  local agent="$1"

  if [[ "$(bridge_agent_source "$agent")" == "dynamic" ]]; then
    bridge_write_dynamic_agent_file "$agent"
  fi
  bridge_write_agent_state_file "$agent" "$(bridge_history_file_for_agent "$agent")"
}

bridge_detect_claude_session_id() {
  local workdir="$1"
  local since_ms="${2:-0}"
  local exclude_csv="${3:-}"

  python3 - "$workdir" "$since_ms" "$exclude_csv" <<'PY'
import glob
import json
import os
import sys

workdir = sys.argv[1]
since_ms = int(sys.argv[2] or "0")
if 0 < since_ms < 10**11:
    since_ms *= 1000
exclude = {x for x in sys.argv[3].split(",") if x}
best = None

for path in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        continue
    sid = data.get("sessionId")
    cwd = data.get("cwd")
    started = int(data.get("startedAt") or 0)
    if cwd != workdir or not sid or sid in exclude:
        continue
    if since_ms and started < max(0, since_ms - 300000):
        continue
    if best is None or started > best[0]:
        best = (started, sid)

print(best[1] if best else "")
PY
}

bridge_claude_session_id_exists() {
  local session_id="$1"
  local workdir="$2"

  [[ -n "$session_id" && -n "$workdir" ]] || return 1

  python3 - "$session_id" "$workdir" <<'PY'
import glob
import json
import os
import sys

session_id = sys.argv[1]
workdir = os.path.realpath(sys.argv[2])

for path in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        continue
    if data.get("sessionId") != session_id:
        continue
    if os.path.realpath(str(data.get("cwd") or "")) != workdir:
        continue
    raise SystemExit(0)

raise SystemExit(1)
PY
}

bridge_detect_codex_session_id() {
  local workdir="$1"
  local since_epoch="${2:-0}"
  local exclude_csv="${3:-}"

  python3 - "$workdir" "$since_epoch" "$exclude_csv" <<'PY'
import datetime as dt
import glob
import json
import os
import sys

workdir = sys.argv[1]
since_epoch = float(sys.argv[2] or "0")
if since_epoch > 10**11:
    since_epoch /= 1000.0
exclude = {x for x in sys.argv[3].split(",") if x}
paths = sorted(
    glob.glob(os.path.expanduser("~/.codex/sessions/**/*.jsonl"), recursive=True),
    key=lambda p: os.path.getmtime(p),
    reverse=True,
)[:500]
best = None

def parse_iso(value: str) -> float:
    if not value:
        return 0.0
    value = value.replace("Z", "+00:00")
    try:
        return dt.datetime.fromisoformat(value).timestamp()
    except Exception:
        return 0.0

for path in paths:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if obj.get("type") != "session_meta":
                    continue
                payload = obj.get("payload", {})
                sid = payload.get("id")
                cwd = payload.get("cwd")
                ts = parse_iso(payload.get("timestamp"))
                if cwd != workdir or not sid or sid in exclude:
                    break
                if since_epoch and ts < max(0.0, since_epoch - 300.0):
                    break
                if best is None or ts > best[0]:
                    best = (ts, sid)
                break
    except Exception:
        continue

print(best[1] if best else "")
PY
}

bridge_detect_session_id() {
  local engine="$1"
  local workdir="$2"
  local since_hint="$3"
  local exclude_csv="${4:-}"

  case "$engine" in
    codex)
      bridge_detect_codex_session_id "$workdir" "$since_hint" "$exclude_csv"
      ;;
    claude)
      bridge_detect_claude_session_id "$workdir" "$since_hint" "$exclude_csv"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_refresh_agent_session_id() {
  local agent="$1"
  local attempts="${2:-8}"
  local sleep_seconds="${3:-0.25}"
  local since_hint sid detected exclude_csv
  local -a excluded=()
  local other try_index

  sid="$(bridge_agent_session_id "$agent")"
  if [[ -n "$sid" ]]; then
    printf '%s' "$sid"
    return 0
  fi

  since_hint="${BRIDGE_AGENT_CREATED_AT[$agent]-$(date +%s)}"
  for ((try_index = 0; try_index < attempts; try_index += 1)); do
    excluded=()
    for other in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$other" == "$agent" ]] && continue
      sid="$(bridge_agent_session_id "$other")"
      if [[ -n "$sid" ]]; then
        excluded+=("$sid")
      fi
    done
    exclude_csv="$(IFS=,; echo "${excluded[*]}")"

    detected="$(bridge_detect_session_id \
      "$(bridge_agent_engine "$agent")" \
      "$(bridge_agent_workdir "$agent")" \
      "$since_hint" \
      "$exclude_csv")"

    if [[ -n "$detected" ]]; then
      BRIDGE_AGENT_SESSION_ID["$agent"]="$detected"
      bridge_persist_agent_state "$agent"
      printf '%s' "$detected"
      return 0
    fi

    sleep "$sleep_seconds"
  done

  return 1
}

bridge_daemon_pid() {
  if [[ -f "$BRIDGE_DAEMON_PID_FILE" ]]; then
    cat "$BRIDGE_DAEMON_PID_FILE"
  fi
}

bridge_daemon_is_running() {
  local pid

  pid="$(bridge_daemon_pid)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

bridge_write_agent_snapshot() {
  local file="$1"
  local agent
  local active
  local session
  local activity

  {
    echo -e "agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts"
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      active=0
      session="$(bridge_agent_session "$agent")"
      activity=""
      if bridge_agent_is_active "$agent"; then
        active=1
        activity="$(bridge_tmux_session_activity_ts "$session")"
      fi

      echo -e "${agent}\t$(bridge_agent_engine "$agent")\t${session}\t$(bridge_agent_workdir "$agent")\t${active}\t${activity}"
    done
  } >"$file"
}

bridge_write_roster_status_snapshot() {
  local file="$1"
  local agent
  local active
  local wake
  local session

  {
    echo -e "agent\tengine\tsession\tworkdir\tsource\tactive\twake"
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      active=0
      wake="-"
      session="$(bridge_agent_session "$agent")"
      if bridge_agent_is_active "$agent"; then
        active=1
        wake="$(bridge_agent_wake_status "$agent")"
      fi

      echo -e "${agent}\t$(bridge_agent_engine "$agent")\t${session}\t$(bridge_agent_workdir "$agent")\t$(bridge_agent_source "$agent")\t${active}\t${wake}"
    done
  } >"$file"
}

bridge_task_daemon_step() {
  local snapshot_file="$1"
  local ready_agents_file="${2:-}"
  local args=(
    daemon-step
    --snapshot "$snapshot_file"
    --lease-seconds "$BRIDGE_TASK_LEASE_SECONDS"
    --heartbeat-window "$BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS"
    --idle-threshold "$BRIDGE_TASK_IDLE_NUDGE_SECONDS"
    --nudge-cooldown "$BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS"
  )

  if [[ -n "$ready_agents_file" && -f "$ready_agents_file" ]]; then
    args+=(--ready-agents-file "$ready_agents_file")
  fi

  bridge_queue_cli "${args[@]}"
}

bridge_task_note_nudge() {
  local agent="$1"
  local key="${2:-}"
  local args=(note-nudge --agent "$agent")

  if [[ -n "$key" ]]; then
    args+=(--key "$key")
  fi

  bridge_queue_cli "${args[@]}" >/dev/null
}

bridge_render_active_roster() {
  local tmp_tsv tmp_md updated session_id
  local agent
  local summary_output=""
  local -A queue_counts=()
  local -A claimed_counts=()

  if summary_output="$(bridge_queue_cli summary --format tsv 2>/dev/null)"; then
    while IFS=$'\t' read -r agent_name queued claimed _blocked _active _idle _last_seen _last_nudge _session _engine _workdir; do
      [[ -z "$agent_name" ]] && continue
      queue_counts["$agent_name"]="$queued"
      claimed_counts["$agent_name"]="$claimed"
    done <<<"$summary_output"
  fi

  tmp_tsv="$(mktemp)"
  tmp_md="$(mktemp)"
  updated="$(bridge_now_iso)"

  {
    echo -e "agent\tengine\tsession\tcwd\tsource\tloop\tcontinue\tqueued\tclaimed\tsession_id\tupdated_at"
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      if ! bridge_agent_is_active "$agent"; then
        continue
      fi

      session_id="$(bridge_agent_session_id "$agent")"
      echo -e "${agent}\t$(bridge_agent_engine "$agent")\t$(bridge_agent_session "$agent")\t$(bridge_agent_workdir "$agent")\t$(bridge_agent_source "$agent")\t$(bridge_agent_loop "$agent")\t$(bridge_agent_continue "$agent")\t${queue_counts[$agent]-0}\t${claimed_counts[$agent]-0}\t${session_id}\t${updated}"
    done
  } >"$tmp_tsv"

  {
    echo "# Active Agent Roster"
    echo
    echo "updated_at: ${updated}"
    echo
    echo "| agent | engine | session | source | loop | inbox | claimed | cwd | session_id |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      if ! bridge_agent_is_active "$agent"; then
        continue
      fi

      session_id="$(bridge_agent_session_id "$agent")"
      echo "| ${agent} | $(bridge_agent_engine "$agent") | $(bridge_agent_session "$agent") | $(bridge_agent_source "$agent") | $(bridge_agent_loop "$agent") | ${queue_counts[$agent]-0} | ${claimed_counts[$agent]-0} | $(bridge_agent_workdir "$agent") | ${session_id} |"
    done
  } >"$tmp_md"

  mv "$tmp_tsv" "$BRIDGE_ACTIVE_ROSTER_TSV"
  mv "$tmp_md" "$BRIDGE_ACTIVE_ROSTER_MD"
}
