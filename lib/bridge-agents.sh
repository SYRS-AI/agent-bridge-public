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

  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || return 1

  if [[ -n "${BRIDGE_AGENT_ID:-}" ]] && bridge_agent_exists "$BRIDGE_AGENT_ID"; then
    printf '%s' "$BRIDGE_AGENT_ID"
    return 0
  fi

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

bridge_agent_is_admin() {
  local agent="$1"
  local admin_agent=""

  admin_agent="$(bridge_admin_agent_id)"
  [[ -n "$admin_agent" && "$agent" == "$admin_agent" ]]
}

bridge_agent_exists() {
  local agent="$1"
  declare -p BRIDGE_AGENT_SESSION >/dev/null 2>&1 || return 1
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

bridge_agent_onboarding_state() {
  local agent="$1"
  local path=""
  local line=""

  for path in "$(bridge_agent_workdir "$agent")/SESSION-TYPE.md" "$(bridge_agent_default_home "$agent")/SESSION-TYPE.md"; do
    [[ -f "$path" ]] || continue
    line="$(grep -E 'Onboarding State:[[:space:]]*[A-Za-z0-9._-]+' "$path" 2>/dev/null | head -n 1 || true)"
    if [[ "$line" =~ Onboarding[[:space:]]+State:[[:space:]]*([A-Za-z0-9._-]+) ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done

  printf '%s' "missing"
}

bridge_agent_onboarding_complete() {
  local agent="$1"
  [[ "$(bridge_agent_onboarding_state "$agent")" == "complete" ]]
}

bridge_agent_should_stop_on_attached_clean_exit() {
  local agent="$1"

  bridge_agent_is_admin "$agent" || return 1
  bridge_agent_onboarding_complete "$agent" && return 1
  return 0
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

bridge_agent_default_teams_state_dir() {
  local agent="$1"
  printf '%s/.teams' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_teams_state_dir() {
  local agent="$1"
  bridge_agent_default_teams_state_dir "$agent"
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

bridge_trim_whitespace() {
  local raw="${1-}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  printf '%s' "$raw"
}

bridge_append_csv_unique() {
  local csv="${1-}"
  local value="${2-}"
  local item=""

  value="$(bridge_trim_whitespace "$value")"
  [[ -n "$value" ]] || {
    printf '%s' "$csv"
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if [[ "$item" == "$value" ]]; then
      printf '%s' "$csv"
      return 0
    fi
  done

  if [[ -n "$csv" ]]; then
    printf '%s,%s' "$csv" "$value"
  else
    printf '%s' "$value"
  fi
}

bridge_merge_channels_csv() {
  local base="${1-}"
  local extra="${2-}"
  local merged="$base"
  local item=""
  local -a items=()

  [[ -n "$extra" ]] || {
    printf '%s' "$base"
    return 0
  }

  IFS=',' read -r -a items <<<"$extra"
  for item in "${items[@]}"; do
    merged="$(bridge_append_csv_unique "$merged" "$item")"
  done

  printf '%s' "$merged"
}

bridge_qualify_channel_item() {
  local item="${1-}"
  local plugin_name=""

  item="$(bridge_trim_whitespace "$item")"
  [[ -n "$item" ]] || {
    printf '%s' ""
    return 0
  }

  case "$item" in
    plugin:discord@claude-plugins-official|plugin:telegram@claude-plugins-official)
      printf '%s' "$item"
      return 0
      ;;
  esac

  if [[ "$item" == plugin:* && "$item" != *@* ]]; then
    plugin_name="${item#plugin:}"
    case "$plugin_name" in
      telegram|discord)
        printf 'plugin:%s@claude-plugins-official' "$plugin_name"
        return 0
        ;;
      teams)
        printf 'plugin:%s@agent-bridge' "$plugin_name"
        return 0
        ;;
    esac
  fi

  printf '%s' "$item"
}

bridge_normalize_channels_csv() {
  local raw="${1:-}"
  local normalized=""
  local chunk=""
  local item=""
  local -a chunks=()

  raw="${raw//$'\n'/,}"
  IFS=',' read -r -a chunks <<<"$raw"
  for chunk in "${chunks[@]}"; do
    item="$(bridge_qualify_channel_item "$chunk")"
    normalized="$(bridge_append_csv_unique "$normalized" "$item")"
  done

  printf '%s' "$normalized"
}

bridge_extract_channels_from_command() {
  local command="${1:-}"
  local rest="$command"
  local value=""
  local csv=""

  while [[ "$rest" =~ --channels=([^[:space:]]+) ]]; do
    value="${BASH_REMATCH[1]}"
    csv="$(bridge_merge_channels_csv "$csv" "$(bridge_normalize_channels_csv "$value")")"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done

  rest="$command"
  while [[ "$rest" =~ --channels[[:space:]]+([^[:space:]]+) ]]; do
    value="${BASH_REMATCH[1]}"
    csv="$(bridge_merge_channels_csv "$csv" "$(bridge_normalize_channels_csv "$value")")"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done

  printf '%s' "$csv"
}

bridge_channel_csv_contains() {
  local csv="${1:-}"
  local needle="${2:-}"
  local item=""
  local -a items=()

  [[ -n "$csv" && -n "$needle" ]] || return 1

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if [[ "$item" == "$needle" || "$item" == "$needle@"* ]]; then
      return 0
    fi
  done

  return 1
}

bridge_channel_item_requires_claude_plugin() {
  local item="${1:-}"

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:*|server:*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_filter_claude_plugin_channels_csv() {
  local csv="${1:-}"
  local item=""
  local filtered=""
  local -a items=()

  [[ -n "$csv" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    item="$(bridge_qualify_channel_item "$item")"
    if bridge_channel_item_requires_claude_plugin "$item"; then
      filtered="$(bridge_append_csv_unique "$filtered" "$item")"
    fi
  done

  printf '%s' "$filtered"
}

bridge_channel_csv_is_subset() {
  local required_csv="${1:-}"
  local actual_csv="${2:-}"
  local need=""
  local have=""
  local matched=0

  IFS=',' read -r -a required_items <<<"$required_csv"
  IFS=',' read -r -a actual_items <<<"$actual_csv"

  for need in "${required_items[@]}"; do
    need="$(bridge_trim_whitespace "$need")"
    [[ -n "$need" ]] || continue
    matched=1
    for have in "${actual_items[@]}"; do
      have="$(bridge_trim_whitespace "$have")"
      [[ -n "$have" ]] || continue
      if [[ "$have" == "$need" || "$have" == "$need@"* || "$need" == "$have@"* ]]; then
        matched=0
        break
      fi
    done
    (( matched == 0 )) || return 1
  done

  return 0
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

bridge_agent_uses_teams_plugin() {
  local agent="$1"
  bridge_channel_csv_contains "$(bridge_agent_channels_csv "$agent")" "plugin:teams"
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

bridge_env_file_has_any_nonempty_key() {
  local file="$1"
  shift || true
  local key=""

  [[ -f "$file" ]] || return 1
  for key in "$@"; do
    if grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=[^[:space:]#].*" "$file"; then
      return 0
    fi
  done

  return 1
}

bridge_agent_channel_runtime_ready_for_item() {
  local agent="$1"
  local item="$2"
  local dir=""

  item="$(bridge_trim_whitespace "$item")"
  [[ -n "$item" ]] || return 1

  case "$item" in
    plugin:discord|plugin:discord@*)
      dir="$(bridge_agent_discord_state_dir "$agent")"
      [[ -f "$dir/access.json" ]] || return 1
      bridge_env_file_has_any_nonempty_key "$dir/.env" DISCORD_BOT_TOKEN BOT_TOKEN TOKEN
      ;;
    plugin:telegram|plugin:telegram@*)
      dir="$(bridge_agent_telegram_state_dir "$agent")"
      [[ -f "$dir/access.json" ]] || return 1
      bridge_env_file_has_any_nonempty_key "$dir/.env" TELEGRAM_BOT_TOKEN BOT_TOKEN TOKEN
      ;;
    plugin:teams|plugin:teams@*)
      dir="$(bridge_agent_teams_state_dir "$agent")"
      [[ -f "$dir/access.json" ]] || return 1
      bridge_env_file_has_any_nonempty_key "$dir/.env" TEAMS_APP_ID MicrosoftAppId || return 1
      bridge_env_file_has_any_nonempty_key "$dir/.env" TEAMS_APP_PASSWORD MicrosoftAppPassword
      ;;
    *)
      return 0
      ;;
  esac
}

bridge_channel_provider_for_item() {
  local item="$1"

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:discord|plugin:discord@*)
      printf '%s' "discord"
      ;;
    plugin:telegram|plugin:telegram@*)
      printf '%s' "telegram"
      ;;
    plugin:teams|plugin:teams@*)
      printf '%s' "teams"
      ;;
    plugin:*)
      printf '%s' "${item#plugin:}"
      ;;
    server:*)
      printf '%s' "${item#server:}"
      ;;
    *)
      printf '%s' "unknown"
      ;;
  esac
}

bridge_channel_state_dir_for_item() {
  local agent="$1"
  local item="$2"

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:discord|plugin:discord@*)
      bridge_agent_discord_state_dir "$agent"
      ;;
    plugin:telegram|plugin:telegram@*)
      bridge_agent_telegram_state_dir "$agent"
      ;;
    plugin:teams|plugin:teams@*)
      bridge_agent_teams_state_dir "$agent"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_channel_credentials_status_for_item() {
  local agent="$1"
  local item="$2"
  local dir=""

  item="$(bridge_qualify_channel_item "$item")"
  dir="$(bridge_channel_state_dir_for_item "$agent" "$item")"
  case "$item" in
    plugin:discord|plugin:discord@*)
      bridge_env_file_has_any_nonempty_key "$dir/.env" DISCORD_BOT_TOKEN BOT_TOKEN TOKEN && printf '%s' "present" || printf '%s' "missing"
      ;;
    plugin:telegram|plugin:telegram@*)
      bridge_env_file_has_any_nonempty_key "$dir/.env" TELEGRAM_BOT_TOKEN BOT_TOKEN TOKEN && printf '%s' "present" || printf '%s' "missing"
      ;;
    plugin:teams|plugin:teams@*)
      if bridge_env_file_has_any_nonempty_key "$dir/.env" TEAMS_APP_ID MicrosoftAppId \
        && bridge_env_file_has_any_nonempty_key "$dir/.env" TEAMS_APP_PASSWORD MicrosoftAppPassword; then
        printf '%s' "present"
      else
        printf '%s' "missing"
      fi
      ;;
    *)
      printf '%s' "n/a"
      ;;
  esac
}

bridge_channel_access_status_for_item() {
  local agent="$1"
  local item="$2"
  local provider=""
  local dir=""
  local access_file=""

  item="$(bridge_qualify_channel_item "$item")"
  provider="$(bridge_channel_provider_for_item "$item")"
  dir="$(bridge_channel_state_dir_for_item "$agent" "$item")"
  [[ -n "$dir" ]] || {
    printf '%s' "n/a"
    return 0
  }

  access_file="$dir/access.json"
  [[ -f "$access_file" ]] || {
    printf '%s' "missing"
    return 0
  }

  bridge_require_python
  python3 - "$access_file" "$provider" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
provider = sys.argv[2]

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("invalid")
    raise SystemExit(0)

def nonempty_list(value):
    if not isinstance(value, list):
        return 0
    return sum(1 for item in value if str(item).strip())

def nonempty_groups(value):
    if not isinstance(value, dict):
        return 0
    return sum(1 for key in value.keys() if str(key).strip())

count = 0
if provider == "discord":
    count += nonempty_groups(payload.get("groups"))
    count += nonempty_list(payload.get("allowFrom"))
elif provider == "telegram":
    count += nonempty_list(payload.get("allowFrom"))
    if str(payload.get("defaultChatId") or "").strip():
        count += 1
elif provider == "teams":
    count += nonempty_groups(payload.get("groups"))
    count += nonempty_list(payload.get("allowFrom"))
else:
    count += nonempty_groups(payload.get("groups"))
    count += nonempty_list(payload.get("allowFrom"))

print("present" if count > 0 else "empty")
PY
}

bridge_agent_channel_launch_allowlisted_for_item() {
  local agent="$1"
  local item="$2"
  local generated=""
  local effective=""
  local marketplace=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || {
    printf '%s' "n/a"
    return 0
  }

  item="$(bridge_qualify_channel_item "$item")"
  generated="$(bridge_claude_launch_with_channels "$agent" "$(bridge_agent_launch_cmd_raw "$agent")")"
  effective="$(bridge_extract_channels_from_command "$generated")"
  if bridge_channel_csv_is_subset "$item" "$effective"; then
    if [[ "$item" == plugin:*@* ]]; then
      marketplace="${item#*@}"
      if [[ "$marketplace" != "claude-plugins-official" && "$generated" != *"--dangerously-load-development-channels"* ]]; then
        printf '%s' "no"
        return 0
      fi
    fi
    printf '%s' "yes"
    return 0
  fi

  printf '%s' "no"
}

bridge_agent_channel_diagnostics_tsv() {
  local agent="$1"
  local required=""
  local item=""
  local provider=""
  local plugin_spec=""
  local plugin_status=""
  local plugin_installed=""
  local plugin_enabled=""
  local launch_allowlisted=""
  local access_status=""
  local credentials_status=""
  local runtime_ready=""
  local state_dir_status=""
  local -a items=()

  printf 'channel\tprovider\tplugin_spec\tplugin_status\tplugin_installed\tplugin_enabled\tlaunch_allowlisted\taccess_status\tcredentials_status\truntime_ready\tstate_dir\n'

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || return 0

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_qualify_channel_item "$item")"
    [[ -n "$item" ]] || continue

    provider="$(bridge_channel_provider_for_item "$item")"
    plugin_spec="-"
    plugin_status="n/a"
    plugin_installed="n/a"
    plugin_enabled="n/a"
    if [[ "$item" == plugin:* ]]; then
      plugin_spec="${item#plugin:}"
      plugin_status="$(bridge_claude_plugin_status "$plugin_spec")"
      case "$plugin_status" in
        enabled)
          plugin_installed="yes"
          plugin_enabled="yes"
          ;;
        disabled)
          plugin_installed="yes"
          plugin_enabled="no"
          ;;
        *)
          plugin_installed="no"
          plugin_enabled="no"
          ;;
      esac
    fi

    launch_allowlisted="$(bridge_agent_channel_launch_allowlisted_for_item "$agent" "$item")"
    access_status="$(bridge_channel_access_status_for_item "$agent" "$item")"
    credentials_status="$(bridge_channel_credentials_status_for_item "$agent" "$item")"
    if bridge_agent_channel_runtime_ready_for_item "$agent" "$item"; then
      runtime_ready="yes"
    else
      runtime_ready="no"
    fi
    state_dir_status="n/a"
    if [[ -n "$(bridge_channel_state_dir_for_item "$agent" "$item")" ]]; then
      if [[ -d "$(bridge_channel_state_dir_for_item "$agent" "$item")" ]]; then
        state_dir_status="present"
      else
        state_dir_status="missing"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$item" \
      "$provider" \
      "$plugin_spec" \
      "$plugin_status" \
      "$plugin_installed" \
      "$plugin_enabled" \
      "$launch_allowlisted" \
      "$access_status" \
      "$credentials_status" \
      "$runtime_ready" \
      "$state_dir_status"
  done
}

bridge_agent_channel_diagnostics_json() {
  local agent="$1"
  local tsv=""

  tsv="$(bridge_agent_channel_diagnostics_tsv "$agent")"
  bridge_require_python
  python3 - "$tsv" <<'PY'
import csv
import io
import json
import sys

rows = list(csv.DictReader(io.StringIO(sys.argv[1]), delimiter="\t"))

def yn(value):
    if value == "yes":
        return True
    if value == "no":
        return False
    return None

payload = []
for row in rows:
    payload.append({
        "channel": row["channel"],
        "provider": row["provider"],
        "plugin_spec": None if row["plugin_spec"] == "-" else row["plugin_spec"],
        "plugin_status": row["plugin_status"],
        "plugin_installed": yn(row["plugin_installed"]),
        "plugin_enabled": yn(row["plugin_enabled"]),
        "launch_allowlisted": yn(row["launch_allowlisted"]),
        "access_status": row["access_status"],
        "credentials_status": row["credentials_status"],
        "runtime_ready": yn(row["runtime_ready"]),
        "state_dir": row["state_dir"],
    })

print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
PY
}

bridge_agent_channel_diagnostics_text() {
  local agent="$1"
  local tsv=""
  local row_count=0

  tsv="$(bridge_agent_channel_diagnostics_tsv "$agent")"
  while IFS=$'\t' read -r channel provider plugin_spec plugin_status plugin_installed plugin_enabled launch_allowlisted access_status credentials_status runtime_ready state_dir; do
    [[ "$channel" == "channel" ]] && continue
    [[ -n "$channel" ]] || continue
    row_count=$((row_count + 1))
    printf -- '- channel: %s\n' "$channel"
    printf '  provider: %s\n' "$provider"
    printf '  plugin: installed=%s enabled=%s status=%s spec=%s\n' "$plugin_installed" "$plugin_enabled" "$plugin_status" "$plugin_spec"
    printf '  launch_allowlisted: %s\n' "$launch_allowlisted"
    printf '  runtime: state_dir=%s access=%s credentials=%s ready=%s\n' "$state_dir" "$access_status" "$credentials_status" "$runtime_ready"
  done <<<"$tsv"

  if [[ "$row_count" == "0" ]]; then
    printf '%s\n' "- channels: (none)"
  fi
}

bridge_agent_session_health_json() {
  local agent="$1"
  local session=""
  local active="no"
  local loop_mode=""
  local continue_mode=""
  local onboarding_state=""
  local attached_exit_behavior="exit"
  local restart_readiness="not-looped"

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  onboarding_state="$(bridge_agent_onboarding_state "$agent")"

  if [[ "$loop_mode" == "1" ]]; then
    if bridge_agent_should_stop_on_attached_clean_exit "$agent"; then
      attached_exit_behavior="stop-until-next-admin-command"
      restart_readiness="onboarding-pending"
    else
      attached_exit_behavior="detach-client-and-restart-loop"
      if bridge_agent_channel_setup_complete "$agent"; then
        restart_readiness="ready"
      else
        restart_readiness="channel-setup-incomplete"
      fi
    fi
  fi

  bridge_require_python
  python3 - "$agent" "$session" "$active" "$loop_mode" "$continue_mode" "$onboarding_state" "$attached_exit_behavior" "$restart_readiness" <<'PY'
import json
import sys

agent, session, active, loop_mode, continue_mode, onboarding_state, attached_exit_behavior, restart_readiness = sys.argv[1:]
payload = {
    "session": session or None,
    "tmux_active": active == "yes",
    "loop": loop_mode == "1",
    "continue": continue_mode == "1",
    "onboarding_state": onboarding_state,
    "attached_exit_behavior": attached_exit_behavior,
    "restart_readiness": restart_readiness,
    "detach_hint": "Ctrl-b then d",
    "stop_command": f"agent-bridge kill {agent}",
}
if session:
    payload["attach_command"] = f"tmux attach -t ={session}"
print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
PY
}

bridge_agent_session_guidance_text() {
  local agent="$1"
  local session=""
  local active="no"
  local loop_mode=""
  local continue_mode=""
  local onboarding_state=""
  local exit_behavior=""
  local restart_readiness=""

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  onboarding_state="$(bridge_agent_onboarding_state "$agent")"
  exit_behavior="exit"
  restart_readiness="not-looped"
  if [[ "$loop_mode" == "1" ]]; then
    if bridge_agent_should_stop_on_attached_clean_exit "$agent"; then
      exit_behavior="stop-until-next-admin-command"
      restart_readiness="onboarding-pending"
    else
      exit_behavior="detach-client-and-restart-loop"
      if bridge_agent_channel_setup_complete "$agent"; then
        restart_readiness="ready"
      else
        restart_readiness="channel-setup-incomplete"
      fi
    fi
  fi

  printf -- '- tmux_session: %s\n' "${session:--}"
  printf -- '- tmux_active: %s\n' "$active"
  printf -- '- loop: %s\n' "$loop_mode"
  printf -- '- continue: %s\n' "$continue_mode"
  printf -- '- onboarding_state: %s\n' "$onboarding_state"
  printf -- '- attached_exit_behavior: %s\n' "$exit_behavior"
  printf -- '- restart_readiness: %s\n' "$restart_readiness"
  if [[ -n "$session" ]]; then
    printf -- '- attach: tmux attach -t =%s\n' "$session"
  fi
  printf -- '- detach_to_shell: Ctrl-b then d\n'
  printf -- '- fully_stop: agent-bridge kill %s\n' "$agent"
}

bridge_agent_ready_channels_csv() {
  local agent="$1"
  local required=""
  local item=""
  local ready=""
  local -a items=()

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if bridge_agent_channel_runtime_ready_for_item "$agent" "$item"; then
      ready="$(bridge_append_csv_unique "$ready" "$item")"
    fi
  done

  printf '%s' "$ready"
}

bridge_agent_missing_channels_csv() {
  local agent="$1"
  local required=""
  local item=""
  local missing=""
  local -a items=()

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if ! bridge_agent_channel_runtime_ready_for_item "$agent" "$item"; then
      missing="$(bridge_append_csv_unique "$missing" "$item")"
    fi
  done

  printf '%s' "$missing"
}

bridge_agent_launch_channels_csv() {
  local agent="$1"
  local channels=""

  if [[ "${BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS:-0}" == "1" ]]; then
    channels="$(bridge_agent_ready_channels_csv "$agent")"
  else
    channels="$(bridge_agent_channels_csv "$agent")"
  fi
  bridge_filter_claude_plugin_channels_csv "$channels"
}

bridge_agent_required_launch_channels_csv() {
  local agent="$1"

  bridge_filter_claude_plugin_channels_csv "$(bridge_agent_channels_csv "$agent")"
}

bridge_agent_required_runtime_channels_csv() {
  local agent="$1"

  bridge_agent_channels_csv "$agent"
}

bridge_agent_launch_channel_status_reason() {
  local agent="$1"
  local required=""
  local effective=""
  local generated=""

  required="$(bridge_agent_required_launch_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    printf '%s' ""
    return 0
  }

  generated="$(bridge_claude_launch_with_channels "$agent" "$(bridge_agent_launch_cmd_raw "$agent")")"
  effective="$(bridge_extract_channels_from_command "$generated")"
  if ! bridge_channel_csv_is_subset "$required" "$effective"; then
    printf 'launch command missing required Claude --channels (%s)' "$required"
    return 0
  fi

  printf '%s' ""
}

bridge_agent_runtime_channel_status_reason() {
  local agent="$1"
  local required=""
  local discord_dir=""
  local telegram_dir=""
  local teams_dir=""

  required="$(bridge_agent_required_runtime_channels_csv "$agent")"
  if [[ -z "$required" ]]; then
    printf '%s' ""
    return 0
  fi

  if bridge_channel_csv_contains "$required" "plugin:discord"; then
    discord_dir="$(bridge_agent_discord_state_dir "$agent")"
    if [[ ! -f "$discord_dir/access.json" ]]; then
      printf 'missing Discord access file under %s (access.json required)' "$discord_dir"
      return 0
    fi
    if ! bridge_env_file_has_any_nonempty_key "$discord_dir/.env" DISCORD_BOT_TOKEN BOT_TOKEN TOKEN; then
      printf 'missing Discord bot token under %s (.env with DISCORD_BOT_TOKEN required)' "$discord_dir"
      return 0
    fi
  fi

  if bridge_channel_csv_contains "$required" "plugin:telegram"; then
    telegram_dir="$(bridge_agent_telegram_state_dir "$agent")"
    if [[ ! -f "$telegram_dir/access.json" ]]; then
      printf 'missing Telegram access file under %s (access.json required)' "$telegram_dir"
      return 0
    fi
    if ! bridge_env_file_has_any_nonempty_key "$telegram_dir/.env" TELEGRAM_BOT_TOKEN BOT_TOKEN TOKEN; then
      printf 'missing Telegram bot token under %s (.env with TELEGRAM_BOT_TOKEN required)' "$telegram_dir"
      return 0
    fi
  fi

  if bridge_channel_csv_contains "$required" "plugin:teams"; then
    teams_dir="$(bridge_agent_teams_state_dir "$agent")"
    if [[ ! -f "$teams_dir/access.json" ]]; then
      printf 'missing Teams access file under %s (access.json required)' "$teams_dir"
      return 0
    fi
    if ! bridge_env_file_has_any_nonempty_key "$teams_dir/.env" TEAMS_APP_ID MicrosoftAppId; then
      printf 'missing Teams app id under %s (.env with TEAMS_APP_ID required)' "$teams_dir"
      return 0
    fi
    if ! bridge_env_file_has_any_nonempty_key "$teams_dir/.env" TEAMS_APP_PASSWORD MicrosoftAppPassword; then
      printf 'missing Teams app password under %s (.env with TEAMS_APP_PASSWORD required)' "$teams_dir"
      return 0
    fi
  fi

  printf '%s' ""
}

bridge_agent_channel_setup_guidance() {
  local agent="$1"
  local reason="${2:-$(bridge_agent_channel_status_reason "$agent")}"
  local required=""
  local cli="$BRIDGE_HOME/agent-bridge"

  required="$(bridge_agent_channels_csv "$agent")"
  printf "Channel runtime is not configured for '%s': %s" "$agent" "$reason"
  if bridge_channel_csv_contains "$required" "plugin:discord"; then
    printf "\nRun: %s setup discord %s --token <DISCORD_BOT_TOKEN> --channel <DISCORD_CHANNEL_ID>" "$cli" "$agent"
  fi
  if bridge_channel_csv_contains "$required" "plugin:telegram"; then
    printf "\nRun: %s setup telegram %s --token <TELEGRAM_BOT_TOKEN> --allow-from <TELEGRAM_USER_ID> --default-chat <TELEGRAM_CHAT_ID>" "$cli" "$agent"
  fi
  if bridge_channel_csv_contains "$required" "plugin:teams"; then
    printf "\nRun: %s setup teams %s --app-id <TEAMS_APP_ID> --app-password <TEAMS_APP_PASSWORD> --allow-from <TEAMS_USER_ID>" "$cli" "$agent"
  fi
}

bridge_agent_channel_status_reason() {
  local agent="$1"
  local reason=""

  reason="$(bridge_agent_launch_channel_status_reason "$agent")"
  if [[ -n "$reason" ]]; then
    printf '%s' "$reason"
    return 0
  fi

  reason="$(bridge_agent_runtime_channel_status_reason "$agent")"
  if [[ -n "$reason" ]]; then
    printf '%s' "$reason"
    return 0
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

bridge_claude_plugin_status() {
  local plugin_spec="$1"
  local registry="${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}"
  local output=""

  if [[ -n "$registry" && -f "$registry" ]]; then
    bridge_require_python
    python3 - "$registry" "$plugin_spec" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
spec = sys.argv[2]
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("missing")
    raise SystemExit(0)

plugins = payload.get("plugins") or {}
print("enabled" if spec in plugins else "missing")
PY
    return 0
  fi

  if ! command -v claude >/dev/null 2>&1; then
    printf '%s' "missing"
    return 0
  fi

  output="$(claude plugin list 2>/dev/null || true)"
  bridge_require_python
  BRIDGE_PLUGIN_LIST_OUTPUT="$output" python3 - "$plugin_spec" <<'PY'
import os
import sys

spec = sys.argv[1]
lines = os.environ.get("BRIDGE_PLUGIN_LIST_OUTPUT", "").splitlines()
current = False

for raw in lines:
    line = raw.strip()
    if spec in line:
        current = True
        continue
    if current and line.startswith("Status:"):
        if "enabled" in line:
            print("enabled")
        elif "disabled" in line:
            print("disabled")
        else:
            print("missing")
        raise SystemExit(0)
    if current and line.startswith("❯ "):
        break

print("missing")
PY
}

bridge_claude_plugin_marketplace() {
  local plugin_spec="$1"

  if [[ "$plugin_spec" == *@* ]]; then
    printf '%s' "${plugin_spec#*@}"
  else
    printf '%s' ""
  fi
}

bridge_claude_marketplace_source() {
  local marketplace="$1"

  case "$marketplace" in
    claude-plugins-official)
      printf '%s' "anthropics/claude-plugins-official"
      ;;
    agent-bridge)
      printf '%s' "$BRIDGE_SCRIPT_DIR"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_claude_plugin_install_missing_from_marketplace() {
  local output="$1"

  [[ "$output" == *"not found in marketplace"* || "$output" == *"not found"* ]]
}

bridge_force_refresh_claude_marketplace() {
  local marketplace="$1"
  local source=""

  [[ -n "$marketplace" ]] || return 1
  source="$(bridge_claude_marketplace_source "$marketplace")"
  [[ -n "$source" ]] || return 1

  bridge_info "[info] Refreshing Claude plugin marketplace: $marketplace"
  claude plugin marketplace remove "$marketplace" >/dev/null 2>&1 || true
  claude plugin marketplace add "$source" >/dev/null
}

bridge_ensure_claude_plugin_enabled() {
  local plugin_spec="$1"
  local status=""
  local output=""
  local marketplace=""

  status="$(bridge_claude_plugin_status "$plugin_spec")"
  case "$status" in
    enabled)
      bridge_info "[info] Claude plugin ready: $plugin_spec"
      return 0
      ;;
    disabled)
      if [[ -n "${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}" ]]; then
        bridge_die "Claude plugin registry marks '$plugin_spec' disabled/missing in test mode."
      fi
      bridge_info "[info] Enabling Claude plugin: $plugin_spec"
      claude plugin enable --scope user "$plugin_spec" >/dev/null
      ;;
    missing)
      if [[ -n "${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}" ]]; then
        bridge_die "Claude plugin registry is missing '$plugin_spec' in test mode."
      fi
      bridge_info "[info] Installing Claude plugin: $plugin_spec"
      if ! output="$(claude plugin install --scope user "$plugin_spec" 2>&1)"; then
        marketplace="$(bridge_claude_plugin_marketplace "$plugin_spec")"
        if bridge_claude_plugin_install_missing_from_marketplace "$output" && bridge_force_refresh_claude_marketplace "$marketplace"; then
          bridge_info "[info] Retrying Claude plugin install after marketplace refresh: $plugin_spec"
          claude plugin install --scope user "$plugin_spec" >/dev/null
        else
          printf '%s\n' "$output" >&2
          bridge_die "Claude plugin install failed: $plugin_spec"
        fi
      fi
      ;;
    *)
      bridge_die "Unknown Claude plugin status for '$plugin_spec': $status"
      ;;
  esac

  status="$(bridge_claude_plugin_status "$plugin_spec")"
  [[ "$status" == "enabled" ]] || bridge_die "Claude plugin '$plugin_spec' is not enabled after install/setup (status=$status). Run: claude plugin install --scope user $plugin_spec"
}

bridge_claude_channel_plugins_ready_for_csv() {
  local channels="$1"
  local item=""
  local plugin_spec=""
  local status=""
  local -a items=()

  [[ -n "$channels" ]] || return 0

  IFS=',' read -r -a items <<<"$(bridge_filter_claude_plugin_channels_csv "$channels")"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ "$item" == plugin:* ]] || continue
    plugin_spec="${item#plugin:}"
    status="$(bridge_claude_plugin_status "$plugin_spec")"
    [[ "$status" == "enabled" ]] || return 1
  done

  return 0
}

bridge_agent_channel_setup_complete() {
  local agent="$1"

  [[ "$(bridge_agent_channel_status "$agent")" == "ok" || "$(bridge_agent_channel_status "$agent")" == "-" ]] || return 1
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  bridge_claude_channel_plugins_ready_for_csv "$(bridge_agent_launch_channels_csv "$agent")"
}

bridge_ensure_agent_bridge_claude_marketplace() {
  local output=""

  [[ -z "${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}" ]] || return 0
  command -v claude >/dev/null 2>&1 || return 0

  output="$(claude plugin marketplace list 2>/dev/null || true)"
  if printf '%s\n' "$output" | grep -Fq "agent-bridge"; then
    return 0
  fi

  bridge_info "[info] Adding Claude plugin marketplace: agent-bridge"
  claude plugin marketplace add --scope user "$BRIDGE_SCRIPT_DIR" >/dev/null
}

bridge_ensure_claude_channel_plugins_for_csv() {
  local channels="$1"
  local item=""
  local plugin_spec=""
  local -a items=()

  [[ -n "$channels" ]] || return 0

  IFS=',' read -r -a items <<<"$(bridge_filter_claude_plugin_channels_csv "$channels")"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ "$item" == plugin:* ]] || continue
    plugin_spec="${item#plugin:}"
    if [[ "$plugin_spec" == teams@agent-bridge ]]; then
      bridge_ensure_agent_bridge_claude_marketplace
    fi
    bridge_ensure_claude_plugin_enabled "$plugin_spec"
  done
}

bridge_ensure_claude_channel_plugins() {
  local agent="$1"

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  bridge_ensure_claude_channel_plugins_for_csv "$(bridge_agent_channels_csv "$agent")"
}

bridge_ensure_claude_launch_channel_plugins() {
  local agent="$1"

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  bridge_ensure_claude_channel_plugins_for_csv "$(bridge_agent_launch_channels_csv "$agent")"
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

bridge_agent_memory_daily_refresh_enabled() {
  local agent="$1"
  local configured=""

  [[ "$(bridge_agent_source "$agent")" == "static" ]] || return 1
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 1

  if [[ -v "BRIDGE_AGENT_MEMORY_DAILY_REFRESH[$agent]" ]]; then
    configured="${BRIDGE_AGENT_MEMORY_DAILY_REFRESH[$agent]-}"
    case "$configured" in
      1|true|yes|on)
        return 0
        ;;
      0|false|no|off)
        return 1
        ;;
    esac
  fi

  return 0
}

bridge_agent_inject_timestamp() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_INJECT_TIMESTAMP[$agent]-1}"
}

bridge_agent_skills_csv() {
  local agent="$1"
  local configured="${BRIDGE_AGENT_SKILLS[$agent]-}"
  local normalized=""
  local skill=""

  configured="${configured//,/ }"
  for skill in $configured; do
    skill="$(bridge_trim_whitespace "$skill")"
    [[ -n "$skill" ]] || continue
    normalized+="${normalized:+ }$skill"
  done

  printf '%s' "$normalized"
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

  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || {
    echo "  (등록된 정적 에이전트 없음)"
    return 0
  }

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
  local attempt

  session="$(bridge_agent_session "$agent")"
  if [[ -z "$session" ]]; then
    bridge_warn "tmux 세션 정보가 없습니다: $agent"
    return 1
  fi

  if ! bridge_tmux_session_exists "$session"; then
    bridge_warn "이미 종료된 세션입니다: $agent/$session"
    return 1
  fi

  bridge_tmux_kill_session "$session"
  for attempt in {1..10}; do
    if ! bridge_tmux_session_exists "$session"; then
      break
    fi
    sleep 0.1
  done
  if bridge_tmux_session_exists "$session"; then
    bridge_warn "tmux 세션이 종료되지 않았습니다: $agent/$session"
    return 1
  fi
  sleep 0.2
  bridge_mcp_orphan_cleanup_after_session_stop "$agent" >/dev/null 2>&1 || true
  bridge_agent_clear_idle_marker "$agent"
  bridge_info "[info] killed ${agent}/${session}"
}

bridge_manual_stop_agent_session() {
  local agent="$1"
  local source

  source="$(bridge_agent_source "$agent")"
  if [[ "$source" == "static" ]]; then
    bridge_agent_mark_manual_stop "$agent"
  fi

  if ! bridge_kill_agent_session "$agent"; then
    if [[ "$source" == "static" ]]; then
      bridge_agent_clear_manual_stop "$agent"
    fi
    return 1
  fi

  if [[ "$source" == "static" ]]; then
    bridge_info "[info] manual stop armed for ${agent}; use 'agent-bridge agent start ${agent}' to resume"
  fi
}

bridge_kill_active_agent_by_index() {
  local index="$1"
  local agent

  if ! agent="$(bridge_active_agent_id_by_index "$index")"; then
    bridge_die "활성 에이전트 번호가 올바르지 않습니다: $index"
  fi

  bridge_manual_stop_agent_session "$agent"
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
    bridge_manual_stop_agent_session "$agent" || true
  done

  bridge_refresh_runtime_state
}
