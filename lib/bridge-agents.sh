#!/usr/bin/env bash
# shellcheck shell=bash

bridge_agent_project_root() {
  local agent="$1"
  bridge_project_root_for_path "$(bridge_agent_workdir "$agent")"
}

bridge_history_file_for_agent() {
  local agent="$1"
  bridge_history_file_for "$(bridge_agent_engine "$agent")" "$agent" "$(bridge_agent_workdir "$agent")"
}

bridge_agent_history_exists() {
  local agent="$1"
  local file

  file="$(bridge_history_file_for_agent "$agent")"
  [[ -f "$file" ]]
}

bridge_worktree_slug_for_project() {
  local project_root="$1"
  local base
  local hash

  base="$(basename "$project_root")"
  base="${base//[^A-Za-z0-9._-]/-}"
  hash="$(bridge_sha1 "$project_root")"
  printf '%s-%s' "$base" "${hash:0:8}"
}

bridge_worktree_branch_for_agent() {
  local agent="$1"
  local branch

  branch="$agent"
  branch="${branch//[^A-Za-z0-9._-]/-}"
  printf 'agent-bridge/%s' "$branch"
}

bridge_worktree_root_for() {
  local project_root="$1"
  local agent="$2"
  local slug

  slug="$(bridge_worktree_slug_for_project "$project_root")"
  printf '%s/%s/%s' "$BRIDGE_WORKTREE_ROOT" "$slug" "$agent"
}

bridge_worktree_launch_dir_for() {
  local source_workdir="$1"
  local agent="$2"
  local project_root relpath worktree_root

  project_root="$(bridge_project_root_for_path "$source_workdir")"
  relpath="$(bridge_path_relative_to_root "$source_workdir" "$project_root")"
  worktree_root="$(bridge_worktree_root_for "$project_root" "$agent")"

  if [[ "$relpath" == "." ]]; then
    printf '%s' "$worktree_root"
  else
    printf '%s/%s' "$worktree_root" "$relpath"
  fi
}

bridge_worktree_meta_key() {
  local project_root="$1"
  local agent="$2"
  bridge_sha1 "${project_root}|${agent}"
}

bridge_worktree_meta_file_for() {
  local project_root="$1"
  local agent="$2"
  local key

  key="$(bridge_worktree_meta_key "$project_root" "$agent")"
  printf '%s/%s--%s.env' "$BRIDGE_WORKTREE_META_DIR" "$agent" "${key:0:12}"
}

bridge_write_worktree_metadata() {
  local engine="$1"
  local agent="$2"
  local source_workdir="$3"
  local project_root="$4"
  local worktree_root="$5"
  local worktree_workdir="$6"
  local branch="$7"
  local meta_file
  local relpath
  local created_at
  local updated_at

  meta_file="$(bridge_worktree_meta_file_for "$project_root" "$agent")"
  relpath="$(bridge_path_relative_to_root "$source_workdir" "$project_root")"
  created_at="$(date +%s)"
  updated_at="$(bridge_now_iso)"

  mkdir -p "$(dirname "$meta_file")"
  cat >"$meta_file" <<EOF
WORKTREE_AGENT=$(printf '%q' "$agent")
WORKTREE_ENGINE=$(printf '%q' "$engine")
WORKTREE_SOURCE_WORKDIR=$(printf '%q' "$source_workdir")
WORKTREE_PROJECT_ROOT=$(printf '%q' "$project_root")
WORKTREE_RELATIVE_DIR=$(printf '%q' "$relpath")
WORKTREE_ROOT=$(printf '%q' "$worktree_root")
WORKTREE_WORKDIR=$(printf '%q' "$worktree_workdir")
WORKTREE_BRANCH=$(printf '%q' "$branch")
WORKTREE_CREATED_AT=$(printf '%q' "$created_at")
WORKTREE_UPDATED_AT=$(printf '%q' "$updated_at")
EOF
}

bridge_list_worktrees() {
  local file
  local WORKTREE_AGENT=""
  local WORKTREE_ENGINE=""
  local WORKTREE_PROJECT_ROOT=""
  local WORKTREE_ROOT=""
  local WORKTREE_WORKDIR=""
  local WORKTREE_BRANCH=""
  local active
  local printed=0

  shopt -s nullglob
  for file in "$BRIDGE_WORKTREE_META_DIR"/*.env; do
    WORKTREE_AGENT=""
    WORKTREE_ENGINE=""
    WORKTREE_PROJECT_ROOT=""
    WORKTREE_ROOT=""
    WORKTREE_WORKDIR=""
    WORKTREE_BRANCH=""
    # shellcheck source=/dev/null
    source "$file"
    [[ -z "$WORKTREE_AGENT" ]] && continue
    printed=1
    active="no"
    if bridge_agent_exists "$WORKTREE_AGENT" && bridge_agent_is_active "$WORKTREE_AGENT"; then
      active="yes"
    fi
    printf '%s | engine=%s | active=%s | branch=%s | repo=%s | root=%s | workdir=%s\n' \
      "$WORKTREE_AGENT" \
      "${WORKTREE_ENGINE:-unknown}" \
      "$active" \
      "${WORKTREE_BRANCH:--}" \
      "${WORKTREE_PROJECT_ROOT:--}" \
      "${WORKTREE_ROOT:--}" \
      "${WORKTREE_WORKDIR:--}"
  done
  shopt -u nullglob

  if [[ "$printed" == "0" ]]; then
    echo "(등록된 agent-bridge worktree 없음)"
  fi
}

bridge_static_agents_for_project_engine() {
  local project_root="$1"
  local engine="$2"
  local agent
  local agent_root

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    [[ "$(bridge_agent_engine "$agent")" == "$engine" ]] || continue
    agent_root="$(bridge_agent_project_root "$agent")"
    [[ "$agent_root" == "$project_root" ]] || continue
    printf '%s\n' "$agent"
  done
}

bridge_source_repo_is_dirty() {
  local project_root="$1"
  [[ -n "$(git -C "$project_root" status --short 2>/dev/null || true)" ]]
}

bridge_prepare_isolated_worktree() {
  local engine="$1"
  local agent="$2"
  local source_workdir="$3"
  local project_root worktree_root worktree_workdir branch

  project_root="$(bridge_project_root_for_path "$source_workdir")"
  if ! git -C "$project_root" rev-parse --show-toplevel >/dev/null 2>&1; then
    bridge_die "git 프로젝트에서만 isolated worktree를 만들 수 있습니다: $source_workdir"
  fi

  worktree_root="$(bridge_worktree_root_for "$project_root" "$agent")"
  worktree_workdir="$(bridge_worktree_launch_dir_for "$source_workdir" "$agent")"
  branch="$(bridge_worktree_branch_for_agent "$agent")"

  if [[ -d "$worktree_root/.git" || -f "$worktree_root/.git" ]]; then
    bridge_write_worktree_metadata "$engine" "$agent" "$source_workdir" "$project_root" "$worktree_root" "$worktree_workdir" "$branch"
    printf '%s' "$worktree_workdir"
    return 0
  fi

  mkdir -p "$(dirname "$worktree_root")"
  if bridge_source_repo_is_dirty "$project_root"; then
    bridge_warn "원본 작업트리에 미커밋 변경이 있습니다. 새 worktree는 현재 HEAD 기준으로 생성됩니다: $project_root"
  fi

  if git -C "$project_root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$project_root" worktree add "$worktree_root" "$branch" >/dev/null
  else
    git -C "$project_root" worktree add -b "$branch" "$worktree_root" HEAD >/dev/null
  fi

  bridge_write_worktree_metadata "$engine" "$agent" "$source_workdir" "$project_root" "$worktree_root" "$worktree_workdir" "$branch"
  printf '%s' "$worktree_workdir"
}

bridge_infer_current_agent() {
  local session=""
  local current_dir
  local agent
  local match=""

  if [[ -n "${TMUX:-}" ]]; then
    session="$(tmux display-message -p '#S' 2>/dev/null || true)"
    if [[ -n "$session" ]] && bridge_agent_exists "$session"; then
      printf '%s' "$session"
      return 0
    fi
  fi

  current_dir="$(pwd -P)"
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$(bridge_agent_workdir "$agent")" == "$current_dir" ]]; then
      if [[ -n "$match" ]]; then
        return 1
      fi
      match="$agent"
    fi
  done

  if [[ -n "$match" ]]; then
    printf '%s' "$match"
    return 0
  fi

  return 1
}

bridge_resolve_agent() {
  local requested="${1:-}"
  local resolved=""

  if [[ -n "$requested" ]]; then
    bridge_require_agent "$requested"
    printf '%s' "$requested"
    return 0
  fi

  if resolved="$(bridge_infer_current_agent)"; then
    printf '%s' "$resolved"
    return 0
  fi

  bridge_die "에이전트를 자동 추론할 수 없습니다. --agent 또는 명시적 agent 인자를 사용하세요."
}

bridge_admin_agent_id() {
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-}"
}

bridge_agent_exists() {
  local agent="$1"
  [[ -n "${BRIDGE_AGENT_SESSION[$agent]+x}" ]]
}

bridge_agent_is_static() {
  local agent="$1"
  [[ "$(bridge_agent_source "$agent")" == "static" ]]
}

bridge_agent_is_launchable_static() {
  local agent="$1"
  bridge_agent_exists "$agent" && bridge_agent_is_static "$agent"
}

bridge_agent_is_cron_delivery_target() {
  local agent="$1"

  bridge_agent_exists "$agent" || return 1
  if bridge_agent_is_static "$agent"; then
    return 0
  fi
  bridge_profile_has_source "$agent"
}

bridge_require_agent() {
  local agent="$1"

  if bridge_agent_exists "$agent"; then
    return 0
  fi

  echo "등록된 에이전트:"
  bridge_list_agents >&2
  bridge_die "'$agent'은(는) 등록된 에이전트가 아닙니다."
}

bridge_require_static_agent() {
  local agent="$1"

  bridge_require_agent "$agent"
  if ! bridge_agent_is_static "$agent"; then
    bridge_die "'$agent'은(는) 정적 역할이 아닙니다. 관리자 에이전트는 정적 역할로 설정하세요."
  fi
}

bridge_require_launchable_static_agent() {
  local agent="$1"

  bridge_require_agent "$agent"
  if ! bridge_agent_is_launchable_static "$agent"; then
    bridge_die "'$agent'은(는) cron delivery 대상이 될 수 있는 정적 역할이 아닙니다."
  fi
}

bridge_require_cron_delivery_target() {
  local agent="$1"

  bridge_require_agent "$agent"
  if ! bridge_agent_is_cron_delivery_target "$agent"; then
    bridge_die "'$agent'은(는) cron delivery 대상이 될 수 있는 등록된 장기 역할이 아닙니다."
  fi
}

bridge_require_admin_agent() {
  local agent

  agent="$(bridge_admin_agent_id)"
  if [[ -z "$agent" ]]; then
    bridge_die "관리자 에이전트가 설정되지 않았습니다. 'agent-bridge setup admin <agent>' 또는 BRIDGE_ADMIN_AGENT_ID를 설정하세요."
  fi

  bridge_require_static_agent "$agent"
  printf '%s' "$agent"
}

bridge_agent_id_for_session() {
  local requested_session="$1"
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$(bridge_agent_session "$agent")" == "$requested_session" ]]; then
      printf '%s' "$agent"
      return 0
    fi
  done

  return 1
}

bridge_agent_desc() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_DESC[$agent]-}"
}

bridge_agent_engine() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_ENGINE[$agent]-unknown}"
}

bridge_agent_source() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_SOURCE[$agent]-static}"
}

bridge_agent_session() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_SESSION[$agent]-}"
}

bridge_agent_default_home() {
  local agent="$1"
  printf '%s/%s' "$BRIDGE_AGENT_HOME_ROOT" "$agent"
}

bridge_agent_default_profile_home() {
  local agent="$1"
  bridge_agent_default_home "$agent"
}

bridge_agent_default_discord_state_dir() {
  local agent="$1"
  printf '%s/.discord' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_discord_state_dir() {
  local agent="$1"
  bridge_agent_default_discord_state_dir "$agent"
}

bridge_agent_default_telegram_state_dir() {
  local agent="$1"
  printf '%s/.telegram' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_telegram_state_dir() {
  local agent="$1"
  bridge_agent_default_telegram_state_dir "$agent"
}

bridge_agent_workdir() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_WORKDIR[$agent]-}"

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  bridge_agent_default_home "$agent"
}

bridge_agent_profile_home() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_PROFILE_HOME[$agent]-}"
}

bridge_agent_launch_cmd_raw() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
}

bridge_normalize_channels_csv() {
  local raw="${1:-}"

  bridge_require_python
  python3 - "$raw" <<'PY'
import sys

raw = sys.argv[1]
values = []
seen = set()
for chunk in str(raw).replace("\n", ",").split(","):
    item = chunk.strip()
    if not item or item in seen:
        continue
    seen.add(item)
    values.append(item)
print(",".join(values))
PY
}

bridge_extract_channels_from_command() {
  local command="${1:-}"

  bridge_require_python
  python3 - "$command" <<'PY'
import shlex
import sys

command = sys.argv[1]
try:
    args = shlex.split(command)
except Exception:
    print("")
    raise SystemExit(0)

values = []
seen = set()
i = 0
while i < len(args):
    token = args[i]
    value = None
    if token == "--channels" and i + 1 < len(args):
        value = args[i + 1]
        i += 2
    elif token.startswith("--channels="):
        value = token.split("=", 1)[1]
        i += 1
    else:
        i += 1
    if value is None:
        continue
    for chunk in str(value).split(","):
        item = chunk.strip()
        if not item or item in seen:
            continue
        seen.add(item)
        values.append(item)

print(",".join(values))
PY
}

bridge_channel_csv_contains() {
  local csv="${1:-}"
  local needle="${2:-}"

  [[ -n "$csv" && -n "$needle" ]] || return 1

  bridge_require_python
  python3 - "$csv" "$needle" <<'PY'
import sys

values = [item.strip() for item in sys.argv[1].split(",") if item.strip()]
needle = sys.argv[2]
for value in values:
    if value == needle or value.startswith(f"{needle}@"):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

bridge_channel_csv_is_subset() {
  local required_csv="${1:-}"
  local actual_csv="${2:-}"

  bridge_require_python
  python3 - "$required_csv" "$actual_csv" <<'PY'
import sys

def parse(raw: str) -> list[str]:
    return [item.strip() for item in raw.split(",") if item.strip()]

required = parse(sys.argv[1])
actual = parse(sys.argv[2])

for need in required:
    matched = False
    for have in actual:
        if have == need or have.startswith(f"{need}@") or need.startswith(f"{have}@"):
            matched = True
            break
    if not matched:
        raise SystemExit(1)

raise SystemExit(0)
PY
}

bridge_agent_channels_csv() {
  local agent="$1"
  local explicit=""
  local inferred=""

  explicit="${BRIDGE_AGENT_CHANNELS[$agent]-}"
  if [[ -n "$explicit" ]]; then
    bridge_normalize_channels_csv "$explicit"
    return 0
  fi

  inferred="$(bridge_extract_channels_from_command "$(bridge_agent_launch_cmd_raw "$agent")")"
  if [[ -n "$inferred" ]]; then
    printf '%s' "$inferred"
    return 0
  fi

  printf '%s' ""
}

bridge_agent_uses_discord_plugin() {
  local agent="$1"
  bridge_channel_csv_contains "$(bridge_agent_channels_csv "$agent")" "plugin:discord"
}

bridge_agent_discord_channel_from_access() {
  local agent="$1"
  local access_file=""

  access_file="$(bridge_agent_workdir "$agent")/.discord/access.json"
  [[ -f "$access_file" ]] || return 1

  bridge_require_python
  python3 - "$access_file" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

groups = payload.get("groups") or {}
for key in groups.keys():
    if key:
        print(str(key))
        raise SystemExit(0)

raise SystemExit(1)
PY
}

bridge_agent_discord_channel_id() {
  local agent="$1"
  local explicit=""
  local inferred=""

  explicit="${BRIDGE_AGENT_DISCORD_CHANNEL_ID[$agent]-}"
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  if bridge_agent_uses_discord_plugin "$agent"; then
    inferred="$(bridge_agent_discord_channel_from_access "$agent" 2>/dev/null || true)"
    if [[ -n "$inferred" ]]; then
      printf '%s' "$inferred"
      return 0
    fi
  fi

  printf '%s' ""
}

bridge_agent_channel_status_reason() {
  local agent="$1"
  local required=""
  local effective=""
  local discord_dir=""

  required="$(bridge_agent_channels_csv "$agent")"
  if [[ -z "$required" ]]; then
    printf '%s' ""
    return 0
  fi

  effective="$(bridge_extract_channels_from_command "$(bridge_agent_launch_cmd "$agent")")"
  if ! bridge_channel_csv_is_subset "$required" "$effective"; then
    printf 'launch command missing required --channels (%s)' "$required"
    return 0
  fi

  if bridge_channel_csv_contains "$required" "plugin:discord"; then
    discord_dir="$(bridge_agent_discord_state_dir "$agent")"
    if [[ ! -f "$discord_dir/.env" || ! -f "$discord_dir/access.json" ]]; then
      printf 'missing Discord runtime files under %s (.env and access.json required)' "$discord_dir"
      return 0
    fi
  fi

  if bridge_channel_csv_contains "$required" "plugin:telegram"; then
    local telegram_dir=""
    telegram_dir="$(bridge_agent_telegram_state_dir "$agent")"
    if [[ ! -f "$telegram_dir/.env" || ! -f "$telegram_dir/access.json" ]]; then
      printf 'missing Telegram runtime files under %s (.env and access.json required)' "$telegram_dir"
      return 0
    fi
  fi

  printf '%s' ""
}

bridge_agent_channel_status() {
  local agent="$1"
  local required=""
  local reason=""

  required="$(bridge_agent_channels_csv "$agent")"
  if [[ -z "$required" ]]; then
    printf '%s' "-"
    return 0
  fi

  reason="$(bridge_agent_channel_status_reason "$agent")"
  if [[ -n "$reason" ]]; then
    printf '%s' "miss"
    return 0
  fi

  printf '%s' "ok"
}

bridge_agent_notify_kind() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_NOTIFY_KIND[$agent]-}"

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  if [[ -n "$(bridge_agent_discord_channel_id "$agent")" ]]; then
    printf 'discord'
    return 0
  fi

  printf '%s' ""
}

bridge_agent_notify_target() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_NOTIFY_TARGET[$agent]-}"

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  printf '%s' "$(bridge_agent_discord_channel_id "$agent")"
}

bridge_agent_notify_account() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_NOTIFY_ACCOUNT[$agent]-}"
  local kind

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  kind="$(bridge_agent_notify_kind "$agent")"
  case "$kind" in
    discord)
      printf '%s' "${BRIDGE_DISCORD_RELAY_ACCOUNT:-default}"
      ;;
    telegram)
      printf 'default'
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_agent_requires_notify_transport() {
  local agent="$1"
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]]
}

bridge_agent_has_notify_transport() {
  local agent="$1"
  local kind
  local target

  kind="$(bridge_agent_notify_kind "$agent")"
  target="$(bridge_agent_notify_target "$agent")"
  [[ -n "$kind" && -n "$target" ]]
}

bridge_agent_notify_status() {
  local agent="$1"

  if ! bridge_agent_requires_notify_transport "$agent"; then
    printf '%s' "-"
    return 0
  fi

  if bridge_agent_has_notify_transport "$agent"; then
    printf '%s' "ok"
    return 0
  fi

  printf '%s' "miss"
}

bridge_agent_requires_wake_channel() {
  local agent="$1"
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]]
}

bridge_agent_has_wake_channel() {
  local agent="$1"

  if ! bridge_agent_requires_wake_channel "$agent"; then
    return 1
  fi

  [[ -n "$(bridge_agent_session "$agent")" ]]
}

bridge_agent_wake_status() {
  local agent="$1"
  local session=""

  if ! bridge_agent_requires_wake_channel "$agent"; then
    printf '%s' "-"
    return 0
  fi

  session="$(bridge_agent_session "$agent")"
  if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
    case "$(bridge_tmux_claude_blocker_state "$session" 2>/dev/null || true)" in
      trust|summary)
        printf '%s' "block"
        return 0
        ;;
    esac
  fi

  if bridge_agent_has_wake_channel "$agent"; then
    printf '%s' "ok"
    return 0
  fi

  printf '%s' "miss"
}

bridge_agent_loop() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_LOOP[$agent]-1}"
}

bridge_agent_continue() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_CONTINUE[$agent]-1}"
}

bridge_agent_session_id() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_SESSION_ID[$agent]-}"
}

bridge_agent_meta_file() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_META_FILE[$agent]-}"
}

bridge_agent_history_key() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_HISTORY_KEY[$agent]-}"
}

bridge_agent_action() {
  local agent="$1"
  local action="$2"
  printf '%s' "${BRIDGE_AGENT_ACTION["$agent:$action"]-}"
}

bridge_agent_idle_timeout() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_IDLE_TIMEOUT[$agent]-0}"
}

bridge_agent_idle_timeout_configured() {
  local agent="$1"
  [[ -v "BRIDGE_AGENT_IDLE_TIMEOUT[$agent]" ]]
}

bridge_agent_is_always_on() {
  local agent="$1"
  local timeout

  bridge_agent_idle_timeout_configured "$agent" || return 1
  timeout="$(bridge_agent_idle_timeout "$agent")"
  [[ "$timeout" =~ ^[0-9]+$ ]] || return 1
  (( timeout == 0 ))
}

bridge_list_actions() {
  local agent="$1"
  local key

  for key in "${!BRIDGE_AGENT_ACTION[@]}"; do
    if [[ "$key" == "$agent:"* ]]; then
      printf '%s\n' "${key#*:}"
    fi
  done | sort -u
}

bridge_agent_is_active() {
  local agent="$1"
  local session

  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] && bridge_tmux_session_exists "$session"
}

bridge_list_agents() {
  local agent
  local actions
  local active

  if [[ ${#BRIDGE_AGENT_IDS[@]} -eq 0 ]]; then
    echo "  (등록된 정적 에이전트 없음)"
    return 0
  fi

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    actions=$(bridge_list_actions "$agent" | paste -sd ',' -)
    if [[ -z "$actions" ]]; then
      actions="-"
    fi

    if bridge_agent_is_active "$agent"; then
      active="yes"
    else
      active="no"
    fi

    printf '  %s — %s\n' "$agent" "$(bridge_agent_desc "$agent")"
    printf '    engine=%s | session=%s | workdir=%s | source=%s | active=%s | loop=%s | actions=%s\n' \
      "$(bridge_agent_engine "$agent")" \
      "$(bridge_agent_session "$agent")" \
      "$(bridge_agent_workdir "$agent")" \
      "$(bridge_agent_source "$agent")" \
      "$active" \
      "$(bridge_agent_loop "$agent")" \
      "$actions"
  done
}

bridge_active_agent_ids() {
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if bridge_agent_is_active "$agent"; then
      printf '%s\n' "$agent"
    fi
  done
}

bridge_active_agent_id_by_index() {
  local target_index="$1"
  local current_index=0
  local agent

  [[ "$target_index" =~ ^[0-9]+$ ]] || return 1
  (( target_index >= 1 )) || return 1

  while IFS= read -r agent; do
    [[ -z "$agent" ]] && continue
    current_index=$((current_index + 1))
    if [[ "$current_index" == "$target_index" ]]; then
      printf '%s' "$agent"
      return 0
    fi
  done < <(bridge_active_agent_ids)

  return 1
}

bridge_list_active_agents_numbered() {
  local index=0
  local agent
  local session_id
  local printed=0
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

  while IFS= read -r agent; do
    [[ -z "$agent" ]] && continue
    index=$((index + 1))
    printed=1
    session_id="$(bridge_agent_session_id "$agent")"
    if [[ -z "$session_id" ]]; then
      session_id="-"
    fi

    printf '%d. %s | engine=%s | tmux=%s | cwd=%s | source=%s | loop=%s | inbox=%s | claimed=%s | session_id=%s\n' \
      "$index" \
      "$agent" \
      "$(bridge_agent_engine "$agent")" \
      "$(bridge_agent_session "$agent")" \
      "$(bridge_agent_workdir "$agent")" \
      "$(bridge_agent_source "$agent")" \
      "$(bridge_agent_loop "$agent")" \
      "${queue_counts[$agent]-0}" \
      "${claimed_counts[$agent]-0}" \
      "$session_id"
  done < <(bridge_active_agent_ids)

  if [[ "$printed" == "0" ]]; then
    echo "(활성 bridge 에이전트 세션 없음)"
  fi
}

bridge_refresh_runtime_state() {
  if [[ -f "$BRIDGE_HOME/bridge-sync.sh" ]]; then
    "$BRIDGE_BASH_BIN" "$BRIDGE_HOME/bridge-sync.sh" >/dev/null 2>&1 || true
  else
    bridge_render_active_roster
  fi
}

bridge_kill_agent_session() {
  local agent="$1"
  local session

  session="$(bridge_agent_session "$agent")"
  if [[ -z "$session" ]]; then
    bridge_warn "tmux 세션 정보가 없습니다: $agent"
    return 1
  fi

  if ! bridge_tmux_session_exists "$session"; then
    bridge_warn "이미 종료된 세션입니다: $agent/$session"
    return 1
  fi

  tmux kill-session -t "$session"
  bridge_agent_clear_idle_marker "$agent"
  bridge_info "[info] killed ${agent}/${session}"
}

bridge_kill_active_agent_by_index() {
  local index="$1"
  local agent

  if ! agent="$(bridge_active_agent_id_by_index "$index")"; then
    bridge_die "활성 에이전트 번호가 올바르지 않습니다: $index"
  fi

  bridge_kill_agent_session "$agent"
  bridge_refresh_runtime_state
}

bridge_kill_all_active_agents() {
  local -a agents=()
  local agent

  mapfile -t agents < <(bridge_active_agent_ids)
  if [[ ${#agents[@]} -eq 0 ]]; then
    echo "[info] 종료할 활성 bridge 에이전트 세션이 없습니다."
    return 0
  fi

  for agent in "${agents[@]}"; do
    bridge_kill_agent_session "$agent" || true
  done

  bridge_refresh_runtime_state
}
