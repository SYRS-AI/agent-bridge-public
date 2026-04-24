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

bridge_agent_isolation_mode() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_ISOLATION_MODE[$agent]-shared}"
}

bridge_agent_os_user() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_OS_USER[$agent]-}"
}

bridge_agent_default_os_user() {
  local agent="$1"

  bridge_require_python
  python3 - "$agent" <<'PY'
import re
import sys

agent = sys.argv[1].strip().lower()
slug = re.sub(r"[^a-z0-9_-]+", "-", agent).strip("-")
slug = slug or "agent"
prefix = "agent-bridge-"
max_len = 32
keep = max_len - len(prefix)
if keep < 1:
    keep = 1
print(prefix + slug[:keep])
PY
}

bridge_agent_linux_user_isolation_requested() {
  local agent="$1"
  [[ "$(bridge_agent_isolation_mode "$agent")" == "linux-user" ]]
}

bridge_host_platform() {
  if [[ -n "${BRIDGE_HOST_PLATFORM_OVERRIDE:-}" ]]; then
    printf '%s' "$BRIDGE_HOST_PLATFORM_OVERRIDE"
    return 0
  fi
  uname -s 2>/dev/null || printf 'unknown'
}

bridge_agent_linux_user_isolation_effective() {
  local agent="$1"

  bridge_agent_linux_user_isolation_requested "$agent" || return 1
  [[ "$(bridge_host_platform)" == "Linux" ]] || return 1
  [[ -n "$(bridge_agent_os_user "$agent")" ]] || return 1
  return 0
}

bridge_current_user() {
  id -un
}

bridge_agent_linux_user_home() {
  local os_user="$1"
  printf '%s/%s' "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT" "$os_user"
}

bridge_agent_linux_env_file() {
  local agent="$1"
  # Scoped per-agent roster snapshot at a stable controller-owned path.
  # Must NOT live under the workdir — workdir is chowned to $os_user, which
  # would make the file writable by the isolated UID. Placing it under
  # $runtime_state_dir keeps controller ownership while still letting the
  # isolated UID read it (via u:$os_user:r-- ACL). The path is derivable
  # from BRIDGE_AGENT_ID alone, so bridge_load_roster can find it without
  # a roster lookup — closes issue #116.
  printf '%s/agent-env.sh' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_linux_sudo_root() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
    return $?
  fi

  command -v sudo >/dev/null 2>&1 || bridge_die "linux-user isolation requires sudo"
  sudo -n "$@"
}

bridge_linux_can_sudo_to() {
  local os_user="$1"

  [[ -n "$os_user" ]] || return 1
  if [[ "$(id -u)" == "0" ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || return 1
  # Probe via `bash -c 'exit 0'` — matches the sudoers entry installed by
  # bridge_migration_sudoers_entry (which whitelists tmux + bash only, not
  # /usr/bin/true). Using the canonical BRIDGE_BASH_BIN when available so
  # the path also matches the entry's `command -v bash`.
  local bash_bin="${BRIDGE_BASH_BIN:-$(command -v bash 2>/dev/null || printf '/bin/bash')}"
  sudo -n -u "$os_user" -- "$bash_bin" -c 'exit 0' 2>/dev/null
}

bridge_agent_preserved_env_vars() {
  # Intentionally conservative: the ENV_PREFIX inlined in the SESSION_CMD
  # re-exports all BRIDGE_* runtime paths inside the bash -c child, so sudo
  # only needs to pass through the terminal/locale bits and the two
  # launch-time markers that are not in ENV_PREFIX.
  printf '%s' "TERM,LANG,LC_ALL,BRIDGE_AGENT_ENV_FILE,BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS"
}

bridge_linux_require_setfacl() {
  if command -v setfacl >/dev/null 2>&1; then
    return 0
  fi
  bridge_linux_sudo_root bash -lc 'command -v setfacl >/dev/null 2>&1' || bridge_die "linux-user isolation requires setfacl"
}

bridge_linux_user_exists() {
  local os_user="$1"
  id -u "$os_user" >/dev/null 2>&1
}

bridge_linux_ensure_os_user() {
  local os_user="$1"
  local user_home="$2"

  bridge_linux_user_exists "$os_user" && return 0
  bridge_linux_sudo_root useradd -r -d "$user_home" -s /bin/bash "$os_user"
}

bridge_linux_ensure_user_home() {
  local os_user="$1"
  local user_home="$2"

  bridge_linux_sudo_root mkdir -p "$user_home"
  bridge_linux_sudo_root chown "$os_user" "$user_home"
  bridge_linux_sudo_root chmod 700 "$user_home"
}

bridge_linux_install_agent_bridge_symlink() {
  local os_user="$1"
  local user_home="$2"
  local bridge_home="$3"
  local target="$user_home/.agent-bridge"
  local current=""

  current="$(bridge_linux_sudo_root python3 - "$target" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
if not path.exists() and not path.is_symlink():
    print("")
elif path.is_symlink():
    print(os.readlink(path))
else:
    print("__nonlink__")
PY
)"

  if [[ "$current" == "$bridge_home" ]]; then
    return 0
  fi

  bridge_linux_sudo_root rm -rf "$target"
  bridge_linux_sudo_root ln -s "$bridge_home" "$target"
  bridge_linux_sudo_root chown -h "$os_user" "$target" >/dev/null 2>&1 || true
}

bridge_linux_acl_add() {
  local spec="$1"
  shift || true
  (($# > 0)) || return 0
  bridge_linux_sudo_root setfacl -m "$spec" "$@"
}

# Resolve the absolute path of an engine CLI (claude/codex) on the
# controller's PATH. Returns empty string if not found.
bridge_resolve_engine_cli() {
  local engine="$1"
  case "$engine" in
    claude|codex) command -v "$engine" 2>/dev/null || true ;;
    *) printf '' ;;
  esac
}

# Engine binaries are typically installed under the operator's home
# (e.g. ~/.local/bin/claude -> ~/.local/share/claude/versions/X). The
# isolated UID has no PATH entry pointing there and no traverse/read
# perms on the chain, so `claude --continue` fails with "command not
# found" inside the sudo wrap. Grant the isolated UID exec on both the
# symlink path and its realpath, plus traverse on every parent dir of
# both. PATH injection happens in bridge_write_linux_agent_env_file.
bridge_linux_grant_engine_cli_access() {
  local os_user="$1"
  local engine="$2"
  local cli_path=""
  local cli_real=""
  local stop_path=""

  cli_path="$(bridge_resolve_engine_cli "$engine")"
  [[ -n "$cli_path" ]] || return 0
  cli_real="$(readlink -f "$cli_path" 2>/dev/null || printf '%s' "$cli_path")"

  # Only chain-grant when the CLI lives inside the operator's home
  # (chmod 0700 blocks base-perm traversal there). System paths like
  # /usr/bin/claude already have `r-x` for `other` so the isolated UID
  # can open them without any ACL help. Walking all the way to `/` for
  # those was pure noise and the trigger for issue #233's ACL residue.
  stop_path="$(bridge_linux_traverse_stop_for "$cli_path")"
  if [[ -n "$stop_path" ]]; then
    bridge_linux_grant_traverse_chain "$os_user" "$cli_path" "$stop_path"
  fi
  bridge_linux_acl_add "u:${os_user}:r-x" "$cli_path" >/dev/null 2>&1 || true
  if [[ -n "$cli_real" && "$cli_real" != "$cli_path" ]]; then
    stop_path="$(bridge_linux_traverse_stop_for "$cli_real")"
    if [[ -n "$stop_path" ]]; then
      bridge_linux_grant_traverse_chain "$os_user" "$cli_real" "$stop_path"
    fi
    bridge_linux_acl_add "u:${os_user}:r-x" "$cli_real" >/dev/null 2>&1 || true
  fi
}

bridge_linux_traverse_stop_for() {
  # Return a safe stop_path for traversing ancestors of $target. Prefers
  # the operator's home when $target sits under it (that's the case that
  # actually needs traversal help — chmod 0700 on the controller home
  # blocks base-perm search for everyone else). Returns empty for system
  # paths (/usr/bin/..., /opt/..., etc.) so callers can skip the grant
  # entirely — `other::r-x` already covers those.
  local target="$1"
  local controller_user="${2:-$(bridge_current_user)}"
  local controller_home=""
  controller_home="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -n "$controller_home" && "$target" == "$controller_home"/* ]]; then
    printf '%s' "$controller_home"
    return 0
  fi
  # No safe stop_path — caller must skip the grant. Never return '/',
  # '/home', or similar shared roots (issue #233).
  return 0
}

# Claude Code reads its auth from $CLAUDE_CONFIG_DIR/.credentials.json
# (default $HOME/.claude/.credentials.json). Under linux-user isolation
# the agent runs as a dedicated UID whose $HOME is /home/<os_user>/,
# and the operator's `.credentials.json` is not present there — Claude
# falls back to the first-launch login picker and the agent cannot
# process work. Fix (#125):
#
# - Symlink /home/<os_user>/.claude/.credentials.json to the
#   controller's credentials file so Claude on the isolated UID resolves
#   `$HOME/.claude/.credentials.json` to the operator's file.
# - Grant the isolated UID traverse + read-exec ACL on the controller's
#   `.claude/` and r-- on the file itself.
# - Set a default ACL (u:<os_user>:r--) on the controller's `.claude/`
#   so a re-auth — which Claude performs via atomic rename, producing a
#   new inode — still inherits the grant without another `isolate` run.
#
# Intentionally does NOT share the whole `.claude/` via
# `CLAUDE_CONFIG_DIR`: projects/, sessions/, plugins/, and
# settings.json benefit from per-agent write isolation. Only the
# credentials file is shared across the controller's agents, matching
# the reality that there is one Claude account per controller.
bridge_linux_grant_claude_credentials_access() {
  local os_user="$1"
  local user_home="$2"
  local controller_user="$3"
  local engine="$4"
  local controller_home=""
  local controller_claude_dir=""
  local controller_cred_file=""
  local isolated_claude_dir=""
  local isolated_cred_link=""
  local current_target=""

  [[ "$engine" == "claude" ]] || return 0
  [[ -n "$os_user" && -n "$user_home" && -n "$controller_user" ]] || return 0

  controller_home="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "$controller_home" && -d "$controller_home" ]] || return 0

  controller_claude_dir="$controller_home/.claude"
  controller_cred_file="$controller_claude_dir/.credentials.json"
  isolated_claude_dir="$user_home/.claude"
  isolated_cred_link="$isolated_claude_dir/.credentials.json"

  if [[ ! -f "$controller_cred_file" ]]; then
    bridge_warn "claude credentials not found at $controller_cred_file — run 'claude login' as the operator, then re-run 'agent-bridge isolate <agent>' to wire them into the isolated UID"
    return 0
  fi

  bridge_linux_sudo_root mkdir -p "$isolated_claude_dir"
  bridge_linux_sudo_root chown "$os_user" "$isolated_claude_dir"
  bridge_linux_sudo_root chmod 0700 "$isolated_claude_dir"

  bridge_linux_grant_traverse_chain "$os_user" "$controller_claude_dir" "$controller_home"
  bridge_linux_acl_add "u:${os_user}:r-x" "$controller_claude_dir" >/dev/null 2>&1 || true
  bridge_linux_acl_add "u:${os_user}:r--" "$controller_cred_file" >/dev/null 2>&1 || true
  bridge_linux_sudo_root setfacl -d -m "u:${os_user}:r--" "$controller_claude_dir" >/dev/null 2>&1 || true

  if [[ -L "$isolated_cred_link" ]]; then
    current_target="$(readlink "$isolated_cred_link" 2>/dev/null || printf '')"
    if [[ "$current_target" == "$controller_cred_file" ]]; then
      return 0
    fi
    bridge_linux_sudo_root rm -f "$isolated_cred_link"
  elif [[ -e "$isolated_cred_link" ]]; then
    bridge_linux_sudo_root rm -f "$isolated_cred_link"
  fi
  bridge_linux_sudo_root ln -s "$controller_cred_file" "$isolated_cred_link"
  bridge_linux_sudo_root chown -h "$os_user" "$isolated_cred_link" >/dev/null 2>&1 || true
}

bridge_linux_acl_add_recursive() {
  local spec="$1"
  shift || true
  (($# > 0)) || return 0
  bridge_linux_sudo_root setfacl -R -m "$spec" "$@"
}

bridge_linux_acl_remove_recursive() {
  local spec="$1"
  shift || true
  (($# > 0)) || return 0
  bridge_linux_sudo_root setfacl -R -x "$spec" "$@" >/dev/null 2>&1 || true
}

bridge_linux_acl_add_default_dirs_recursive() {
  local spec="$1"
  shift || true
  local path=""

  for path in "$@"; do
    [[ -d "$path" ]] || continue
    bridge_linux_sudo_root find "$path" -type d -exec setfacl -d -m "$spec" {} +
  done
}

bridge_linux_grant_traverse_chain() {
  # Grant `u:${os_user}:--x` on every directory from $target up to
  # (and including) $stop_path. Callers must pass an explicit stop_path
  # — it used to default to `/`, which is how issue #233 happened:
  # every isolate grant walked all the way up and left
  # `user:agent-bridge-<agent>:--x` entries on `/`, `/home`, and the
  # operator's home. A default-to-root API was a loaded footgun.
  #
  # The stop_path gets normalised to a real directory. If the caller
  # passes a file (e.g. a credentials file path), we stop at its parent
  # directory and still grant execute on the file's containing dir,
  # because that's the access the isolated UID actually needs to open
  # the file. `/` is always rejected as a stop_path so an accidental
  # empty-string or regressed caller cannot reinstate the bug.
  local os_user="$1"
  local target="$2"
  local stop_path="${3:-}"
  local path=""

  if [[ -z "$stop_path" ]]; then
    bridge_warn "bridge_linux_grant_traverse_chain: missing stop_path for target=$target (skipping grant to avoid ancestor poisoning)"
    return 0
  fi
  case "$stop_path" in
    "/"|"")
      bridge_warn "bridge_linux_grant_traverse_chain: refusing stop_path=\"$stop_path\" for target=$target (would poison filesystem root)"
      return 0
      ;;
  esac

  while IFS= read -r path; do
    [[ -d "$path" ]] || continue
    bridge_linux_acl_add "u:${os_user}:--x" "$path"
  done < <(python3 - "$target" "$stop_path" <<'PY'
from pathlib import Path
import sys

target = Path(sys.argv[1]).expanduser().resolve()
stop_raw = Path(sys.argv[2]).expanduser().resolve()

# Stop can be a file — walk terminates at its parent directory.
stop = stop_raw if stop_raw.is_dir() else stop_raw.parent

if target != stop and stop not in target.parents:
    sys.exit(0)

items = []
current = target
while True:
    items.append(str(current))
    if current == stop:
        break
    if current.parent == current:
        break
    current = current.parent

for item in reversed(items):
    print(item)
PY
)
}

bridge_write_linux_agent_env_file() {
  local agent="$1"
  local file="${2:-$(bridge_agent_linux_env_file "$agent")}"
  local description=""
  local engine=""
  local session=""
  local workdir=""
  local profile_home=""
  local launch_cmd=""
  local channels=""
  local discord_channel=""
  local notify_kind=""
  local notify_target=""
  local notify_account=""
  local loop_mode=""
  local continue_mode=""
  local idle_timeout=""
  local session_id=""
  local history_key=""
  local created_at=""
  local updated_at=""
  local isolation_mode=""
  local os_user=""
  local admin_agent=""
  local agent_log_dir=""
  local agent_audit_log=""

  description="$(bridge_agent_desc "$agent")"
  engine="$(bridge_agent_engine "$agent")"
  session="$(bridge_agent_session "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"
  profile_home="$(bridge_agent_profile_home "$agent")"
  launch_cmd="$(bridge_agent_launch_cmd_raw "$agent")"
  channels="$(bridge_agent_channels_csv "$agent")"
  discord_channel="$(bridge_agent_discord_channel_id "$agent")"
  notify_kind="$(bridge_agent_notify_kind "$agent")"
  notify_target="$(bridge_agent_notify_target "$agent")"
  notify_account="$(bridge_agent_notify_account "$agent")"
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  idle_timeout="$(bridge_agent_idle_timeout "$agent")"
  session_id="$(bridge_agent_session_id "$agent")"
  history_key="${BRIDGE_AGENT_HISTORY_KEY[$agent]-}"
  created_at="${BRIDGE_AGENT_CREATED_AT[$agent]-}"
  updated_at="${BRIDGE_AGENT_UPDATED_AT[$agent]-}"
  isolation_mode="$(bridge_agent_isolation_mode "$agent")"
  os_user="$(bridge_agent_os_user "$agent")"
  admin_agent="$(bridge_admin_agent_id)"
  agent_log_dir="$(bridge_agent_log_dir "$agent")"
  agent_audit_log="$(bridge_agent_audit_log_file "$agent")"

  mkdir -p "$(dirname "$file")"
  # Self-heal ownership: when an earlier isolate cycle chowned the file to the
  # isolated os_user, `cat >` preserves ownership and the trailing `chmod 600`
  # fails with EPERM for the operator. Drop the stale inode (via sudo when
  # linux-user isolation is active) so the redirect creates a fresh one owned
  # by the current UID. See issue #112 retest.
  if [[ -e "$file" && ! -O "$file" ]]; then
    if [[ "$(bridge_host_platform 2>/dev/null || printf '')" == "Linux" ]] \
        && command -v bridge_linux_sudo_root >/dev/null 2>&1; then
      bridge_linux_sudo_root rm -f "$file" 2>/dev/null || rm -f "$file"
    else
      rm -f "$file"
    fi
  fi
  cat >"$file" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_HOME=$(printf '%q' "$BRIDGE_HOME")
BRIDGE_STATE_DIR=$(printf '%q' "$BRIDGE_STATE_DIR")
BRIDGE_ACTIVE_AGENT_DIR=$(printf '%q' "$BRIDGE_ACTIVE_AGENT_DIR")
BRIDGE_HISTORY_DIR=$(printf '%q' "$BRIDGE_HISTORY_DIR")
BRIDGE_WORKTREE_META_DIR=$(printf '%q' "$BRIDGE_WORKTREE_META_DIR")
BRIDGE_ACTIVE_ROSTER_TSV=$(printf '%q' "$BRIDGE_ACTIVE_ROSTER_TSV")
BRIDGE_ACTIVE_ROSTER_MD=$(printf '%q' "$BRIDGE_ACTIVE_ROSTER_MD")
BRIDGE_DAEMON_PID_FILE=$(printf '%q' "$BRIDGE_DAEMON_PID_FILE")
BRIDGE_DAEMON_LOG=$(printf '%q' "$BRIDGE_DAEMON_LOG")
BRIDGE_DAEMON_CRASH_LOG=$(printf '%q' "$BRIDGE_DAEMON_CRASH_LOG")
BRIDGE_TASK_DB=$(printf '%q' "$BRIDGE_TASK_DB")
BRIDGE_PROFILE_STATE_DIR=$(printf '%q' "$BRIDGE_PROFILE_STATE_DIR")
BRIDGE_CRON_STATE_DIR=$(printf '%q' "$BRIDGE_CRON_STATE_DIR")
BRIDGE_CRON_HOME_DIR=$(printf '%q' "$BRIDGE_CRON_HOME_DIR")
BRIDGE_WORKTREE_ROOT=$(printf '%q' "$BRIDGE_WORKTREE_ROOT")
BRIDGE_AGENT_HOME_ROOT=$(printf '%q' "$BRIDGE_AGENT_HOME_ROOT")
BRIDGE_RUNTIME_ROOT=$(printf '%q' "$BRIDGE_RUNTIME_ROOT")
BRIDGE_RUNTIME_SCRIPTS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SCRIPTS_DIR")
BRIDGE_RUNTIME_SKILLS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SKILLS_DIR")
BRIDGE_RUNTIME_SHARED_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SHARED_DIR")
BRIDGE_RUNTIME_SHARED_TOOLS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SHARED_TOOLS_DIR")
BRIDGE_RUNTIME_SHARED_REFERENCES_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SHARED_REFERENCES_DIR")
BRIDGE_RUNTIME_MEMORY_DIR=$(printf '%q' "$BRIDGE_RUNTIME_MEMORY_DIR")
BRIDGE_RUNTIME_CREDENTIALS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_CREDENTIALS_DIR")
BRIDGE_RUNTIME_SECRETS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SECRETS_DIR")
BRIDGE_RUNTIME_CONFIG_FILE=$(printf '%q' "$BRIDGE_RUNTIME_CONFIG_FILE")
BRIDGE_HOOKS_DIR=$(printf '%q' "$BRIDGE_HOOKS_DIR")
BRIDGE_SHARED_DIR=$(printf '%q' "$BRIDGE_SHARED_DIR")
BRIDGE_LOG_DIR=$(printf '%q' "$agent_log_dir")
BRIDGE_AUDIT_LOG=$(printf '%q' "$agent_audit_log")
BRIDGE_ROSTER_FILE=""
BRIDGE_ROSTER_LOCAL_FILE=""
BRIDGE_ADMIN_AGENT_ID=$(printf '%q' "$admin_agent")
BRIDGE_AGENT_IDS=()
declare -g -A BRIDGE_AGENT_DESC=()
declare -g -A BRIDGE_AGENT_ENGINE=()
declare -g -A BRIDGE_AGENT_SESSION=()
declare -g -A BRIDGE_AGENT_WORKDIR=()
declare -g -A BRIDGE_AGENT_PROFILE_HOME=()
declare -g -A BRIDGE_AGENT_LAUNCH_CMD=()
declare -g -A BRIDGE_AGENT_SOURCE=()
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
declare -g -A BRIDGE_AGENT_DISCORD_CHANNEL_ID=()
declare -g -A BRIDGE_AGENT_CHANNELS=()
declare -g -A BRIDGE_AGENT_ISOLATION_MODE=()
declare -g -A BRIDGE_AGENT_OS_USER=()
declare -g -A BRIDGE_AGENT_MODEL=()
declare -g -A BRIDGE_AGENT_EFFORT=()
declare -g -A BRIDGE_AGENT_PERMISSION_MODE=()
bridge_add_agent_id_if_missing $(printf '%q' "$agent")
BRIDGE_AGENT_DESC["$agent"]=$(printf '%q' "$description")
BRIDGE_AGENT_ENGINE["$agent"]=$(printf '%q' "$engine")
BRIDGE_AGENT_SESSION["$agent"]=$(printf '%q' "$session")
BRIDGE_AGENT_WORKDIR["$agent"]=$(printf '%q' "$workdir")
BRIDGE_AGENT_PROFILE_HOME["$agent"]=$(printf '%q' "$profile_home")
BRIDGE_AGENT_LAUNCH_CMD["$agent"]=$(printf '%q' "$launch_cmd")
BRIDGE_AGENT_SOURCE["$agent"]="static"
BRIDGE_AGENT_LOOP["$agent"]=$(printf '%q' "$loop_mode")
BRIDGE_AGENT_CONTINUE["$agent"]=$(printf '%q' "$continue_mode")
BRIDGE_AGENT_SESSION_ID["$agent"]=$(printf '%q' "$session_id")
BRIDGE_AGENT_HISTORY_KEY["$agent"]=$(printf '%q' "$history_key")
BRIDGE_AGENT_CREATED_AT["$agent"]=$(printf '%q' "$created_at")
BRIDGE_AGENT_UPDATED_AT["$agent"]=$(printf '%q' "$updated_at")
BRIDGE_AGENT_IDLE_TIMEOUT["$agent"]=$(printf '%q' "$idle_timeout")
BRIDGE_AGENT_NOTIFY_KIND["$agent"]=$(printf '%q' "$notify_kind")
BRIDGE_AGENT_NOTIFY_TARGET["$agent"]=$(printf '%q' "$notify_target")
BRIDGE_AGENT_NOTIFY_ACCOUNT["$agent"]=$(printf '%q' "$notify_account")
BRIDGE_AGENT_DISCORD_CHANNEL_ID["$agent"]=$(printf '%q' "$discord_channel")
BRIDGE_AGENT_CHANNELS["$agent"]=$(printf '%q' "$channels")
BRIDGE_AGENT_ISOLATION_MODE["$agent"]=$(printf '%q' "$isolation_mode")
BRIDGE_AGENT_OS_USER["$agent"]=$(printf '%q' "$os_user")
EOF
  # Inject engine CLI directory into PATH for sudo-wrapped launchers when
  # isolation is active. Under sudo, PATH falls back to secure_path which
  # almost never contains the operator's per-user bin (e.g.
  # ~/.local/bin/claude), so the launcher's bare `claude` / `codex` call
  # would die with "command not found". Resolving on every start picks up
  # CLI upgrades automatically; the matching ACL grant lives in
  # bridge_linux_grant_engine_cli_access (one-shot at isolate time).
  if [[ "$isolation_mode" == "linux-user" && -n "$engine" ]]; then
    local _engine_cli _engine_dir
    _engine_cli="$(bridge_resolve_engine_cli "$engine" 2>/dev/null || printf '')"
    if [[ -n "$_engine_cli" ]]; then
      _engine_dir="$(dirname "$_engine_cli")"
      printf '\nexport PATH=%s:"${PATH:-/usr/local/bin:/usr/bin:/bin}"\n' \
        "$(printf '%q' "$_engine_dir")" >>"$file"
    fi
  fi
  chmod 600 "$file"
  # `chmod 600` maps to mask::--- on a file that already carries named-user
  # ACLs (POSIX ACL: chmod's group bits drive the mask when named entries
  # exist). isolate originally grants the isolated UID `u:<os_user>:r--` so
  # it can read agent-env.sh under sudo-wrap, but the mask wipe makes that
  # entry effective `---`, so subsequent `agent start` cycles fail silently
  # — bridge-run.sh sources nothing, sees an empty roster, and exits before
  # tmux is created. Re-apply the named-user ACL so setfacl recomputes the
  # mask back to rw- (or whatever covers the named entries).
  if [[ "$isolation_mode" == "linux-user" \
        && -n "$os_user" \
        && "$(bridge_host_platform 2>/dev/null || printf '')" == "Linux" ]] \
      && command -v bridge_linux_acl_add >/dev/null 2>&1; then
    local _controller_user
    _controller_user="$(bridge_current_user 2>/dev/null || printf '')"
    bridge_linux_acl_add "u:${os_user}:r--" "$file" >/dev/null 2>&1 || true
    if [[ -n "$_controller_user" ]]; then
      bridge_linux_acl_add "u:${_controller_user}:rw-" "$file" >/dev/null 2>&1 || true
    fi
  fi
}

bridge_linux_prepare_agent_isolation() {
  local agent="$1"
  local os_user="$2"
  local workdir="$3"
  local controller_user="${4:-$(bridge_current_user)}"
  local user_home=""
  local env_file=""
  local runtime_state_dir=""
  local log_dir=""
  local audit_file=""
  local history_file=""
  local request_dir=""
  local response_dir=""
  local other=""
  local other_workdir=""
  local other_queue_dir=""
  local -a recursive_read_paths=()
  local -a recursive_write_paths=()
  local -a hidden_paths=()

  [[ "$(bridge_host_platform)" == "Linux" ]] || return 0
  [[ -n "$os_user" ]] || bridge_die "linux-user isolation requires os_user"

  bridge_linux_require_setfacl
  user_home="$(bridge_agent_linux_user_home "$os_user")"
  env_file="$(bridge_agent_linux_env_file "$agent")"
  runtime_state_dir="$(bridge_agent_runtime_state_dir "$agent")"
  log_dir="$(bridge_agent_log_dir "$agent")"
  audit_file="$(bridge_agent_audit_log_file "$agent")"
  history_file="$(bridge_history_file_for_agent "$agent")"
  request_dir="$(bridge_queue_gateway_requests_dir "$agent")"
  response_dir="$(bridge_queue_gateway_responses_dir "$agent")"

  bridge_linux_ensure_os_user "$os_user" "$user_home"
  bridge_linux_ensure_user_home "$os_user" "$user_home"
  bridge_linux_install_agent_bridge_symlink "$os_user" "$user_home" "$BRIDGE_HOME"

  recursive_read_paths+=("$BRIDGE_HOOKS_DIR" "$BRIDGE_SHARED_DIR")
  [[ -d "$BRIDGE_RUNTIME_ROOT" ]] && recursive_read_paths+=("$BRIDGE_RUNTIME_ROOT")
  [[ -d "$BRIDGE_HOME/.claude" ]] && recursive_read_paths+=("$BRIDGE_HOME/.claude")
  [[ -d "$BRIDGE_HOME/lib" ]] && recursive_read_paths+=("$BRIDGE_HOME/lib")
  [[ -d "$BRIDGE_HOME/plugins" ]] && recursive_read_paths+=("$BRIDGE_HOME/plugins")
  [[ -d "$BRIDGE_HOME/scripts" ]] && recursive_read_paths+=("$BRIDGE_HOME/scripts")
  [[ -d "$BRIDGE_AGENT_HOME_ROOT/.claude" ]] && recursive_read_paths+=("$BRIDGE_AGENT_HOME_ROOT/.claude")
  bridge_linux_acl_remove_recursive "u:${os_user}" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"
  bridge_linux_sudo_root mkdir -p "$runtime_state_dir" "$log_dir" "$request_dir" "$response_dir" "$(dirname "$history_file")"
  bridge_linux_sudo_root touch "$audit_file" "$history_file"

  # memory-daily state trees for the harvester (issue #219):
  #   <state>/memory-daily/                         — traverse only (r-x)
  #   <state>/memory-daily/<agent>/                 — per-agent rwX
  #   <state>/memory-daily/shared/aggregate/        — shared rwX (all isolated
  #     agents write to the fcntl.flock-guarded aggregate files; no cross-agent
  #     directory-entry tampering because peer <agent>/ dirs remain un-ACL'd)
  local memory_daily_root="$BRIDGE_STATE_DIR/memory-daily"
  local memory_daily_agent_dir="$memory_daily_root/$agent"
  local memory_daily_shared_aggregate_dir="$memory_daily_root/shared/aggregate"
  bridge_linux_sudo_root mkdir -p "$memory_daily_agent_dir" "$memory_daily_shared_aggregate_dir"

  # One-shot legacy aggregate migration — runs as sudo-root here so it has
  # write access on the memory-daily root even though the new ACL contract
  # only grants isolated UIDs r-x on the root. Idempotent + safe to re-run.
  local _agg_name
  for _agg_name in admin-aggregate-skip.json admin-aggregate-escalated.json; do
    if [[ -f "$memory_daily_root/$_agg_name" && ! -f "$memory_daily_shared_aggregate_dir/$_agg_name" ]]; then
      bridge_linux_sudo_root mv "$memory_daily_root/$_agg_name" "$memory_daily_shared_aggregate_dir/$_agg_name"
    fi
    if [[ -f "$memory_daily_root/$_agg_name.lock" && ! -f "$memory_daily_shared_aggregate_dir/$_agg_name.lock" ]]; then
      bridge_linux_sudo_root mv "$memory_daily_root/$_agg_name.lock" "$memory_daily_shared_aggregate_dir/$_agg_name.lock"
    fi
  done

  recursive_write_paths+=("$workdir" "$runtime_state_dir" "$log_dir" "$request_dir" "$response_dir" "$memory_daily_agent_dir" "$memory_daily_shared_aggregate_dir")
  hidden_paths+=("$BRIDGE_ROSTER_FILE" "$BRIDGE_ROSTER_LOCAL_FILE" "$BRIDGE_RUNTIME_CREDENTIALS_DIR" "$BRIDGE_RUNTIME_SECRETS_DIR" "$BRIDGE_RUNTIME_CONFIG_FILE" "$BRIDGE_TASK_DB" "${BRIDGE_LOG_DIR}/audit.jsonl")

  # Issue #233: every traverse_chain call used to climb unconditionally
  # to `/` and stamp `u:${os_user}:--x` on each ancestor, including
  # `/home` and `/`. Pass an explicit stop_path so the walk terminates
  # inside the controller's home. Ancestors above that (`/home`, `/`)
  # already have base `r-x` for `other`, so no named entry is needed —
  # and inserting one would strip the operator's own read access via
  # POSIX ACL override, which is exactly the #233 regression.
  #
  # The $user_home chain is intentionally dropped here: the isolated
  # UID owns its own home outright, and the ancestors `/home` + `/`
  # are already reachable via base permissions.
  local controller_home_for_traverse=""
  controller_home_for_traverse="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -n "$controller_home_for_traverse" && -d "$controller_home_for_traverse" ]]; then
    bridge_linux_grant_traverse_chain "$os_user" "$BRIDGE_HOME" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$workdir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$runtime_state_dir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$log_dir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$history_file" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$request_dir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$response_dir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$memory_daily_agent_dir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$memory_daily_shared_aggregate_dir" "$controller_home_for_traverse"
  else
    bridge_warn "controller_user=$controller_user has no passwd entry / home; traverse grants skipped (isolated agent may hit EACCES)"
  fi
  bridge_linux_acl_add "u:${os_user}:r-x" "$memory_daily_root" "$memory_daily_root/shared" >/dev/null 2>&1 || true

  bridge_linux_acl_add "u:${os_user}:r-x" "$BRIDGE_HOME" "$BRIDGE_AGENT_HOME_ROOT"
  bridge_linux_acl_add "u:${os_user}:r-x" "$BRIDGE_HOME/agent-bridge" "$BRIDGE_HOME/agb" "$BRIDGE_HOME/VERSION" >/dev/null 2>&1 || true
  # Root-level Bash and Python helpers (bridge-*.sh, bridge-*.py) live next
  # to agent-bridge/agb. lib/scripts/ are already covered by recursive_read_paths,
  # but root helpers like bridge-dev-plugin-cache.py default to mode 600 and
  # have no ACL grant, so things like dev-plugin-cache sync fail with EACCES
  # under the sudo wrap during agent start.
  local _bridge_root_helper
  shopt -s nullglob
  for _bridge_root_helper in "$BRIDGE_HOME"/bridge-*.sh "$BRIDGE_HOME"/bridge-*.py; do
    bridge_linux_acl_add "u:${os_user}:r-x" "$_bridge_root_helper" >/dev/null 2>&1 || true
  done
  shopt -u nullglob
  bridge_linux_grant_engine_cli_access "$os_user" "$(bridge_agent_engine "$agent")"
  bridge_linux_grant_claude_credentials_access "$os_user" "$user_home" "$controller_user" "$(bridge_agent_engine "$agent")"
  bridge_linux_acl_add_recursive "u:${os_user}:r-X" "${recursive_read_paths[@]}"
  bridge_linux_acl_add_recursive "u:${os_user}:rwX" "${recursive_write_paths[@]}"
  bridge_linux_acl_add_default_dirs_recursive "u:${os_user}:rwX" "$runtime_state_dir" "$log_dir" "$request_dir" "$response_dir" "$memory_daily_agent_dir" "$memory_daily_shared_aggregate_dir"
  bridge_linux_acl_add "u:${os_user}:rw-" "$history_file"

  for other in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$other" == "$agent" ]] && continue
    other_workdir="$(bridge_agent_workdir "$other")"
    other_queue_dir="$(bridge_queue_gateway_agent_dir "$other")"
    [[ "$other_workdir" == "$workdir" ]] && continue
    [[ -d "$other_workdir" ]] || continue
    bridge_linux_acl_remove_recursive "u:${os_user}" "$other_workdir"
    [[ -d "$other_queue_dir" ]] && bridge_linux_acl_remove_recursive "u:${os_user}" "$other_queue_dir"
  done

  for other in "${hidden_paths[@]}"; do
    [[ -e "$other" ]] || continue
    bridge_linux_acl_remove_recursive "u:${os_user}" "$other"
  done

  bridge_linux_sudo_root chown -R "$os_user" "$workdir"
  bridge_linux_sudo_root chown -R "$os_user" "$runtime_state_dir" "$log_dir"
  bridge_linux_sudo_root chown "$os_user" "$audit_file" "$history_file"
  bridge_linux_acl_add_recursive "u:${controller_user}:rwX" "$workdir"
  bridge_linux_acl_add_default_dirs_recursive "u:${controller_user}:rwX" "$workdir"
  bridge_linux_acl_add_recursive "u:${controller_user}:rwX" "$runtime_state_dir" "$log_dir" "$request_dir" "$response_dir" "$memory_daily_agent_dir" "$memory_daily_shared_aggregate_dir"

  # memory-daily transcripts read-access (issue #219 v1.3): grant the
  # controller user r-X on the isolated user's ~/.claude/projects/ so the
  # (controller-UID) harvester can _scan_transcripts under the target.
  # We intentionally do NOT grant write — this is a strict read lens.
  #
  # We pre-create $user_home/.claude (owned by the isolated UID, 0700) so
  # the default ACL lands before the first Claude session runs. Otherwise a
  # fresh agent's first `.claude/projects/` directory would be created
  # without the controller r-X inheritance, and the next harvester run
  # would fall back to --skipped-permission until the next reapply.
  local isolated_claude_dir="$user_home/.claude"
  local isolated_projects_dir="$isolated_claude_dir/projects"
  bridge_linux_sudo_root mkdir -p "$isolated_claude_dir"
  bridge_linux_sudo_root chown "$os_user" "$isolated_claude_dir" >/dev/null 2>&1 || true
  bridge_linux_sudo_root chmod 0700 "$isolated_claude_dir" >/dev/null 2>&1 || true
  # Issue #233: the previous `bridge_linux_grant_traverse_chain
  # $controller_user $isolated_claude_dir` call walked from
  # /home/agent-bridge-<agent>/.claude all the way up to / and left
  # `user:<controller>:--x` entries on `/home` and `/`. Under POSIX ACL
  # that named entry *reduced* the operator's own read access, because
  # the named entry overrides `other::r-x`. That's the exact mechanism
  # that silenced bun-based plugins. Grant search access only on the
  # two directories the controller actually needs to traverse: the
  # isolated user's home and its .claude subdirectory. `/home` and `/`
  # stay untouched — the controller reaches them via base perms.
  bridge_linux_acl_add "u:${controller_user}:--x" "$user_home" >/dev/null 2>&1 || true
  bridge_linux_acl_add "u:${controller_user}:r-x" "$isolated_claude_dir" >/dev/null 2>&1 || true
  # Default ACL on .claude/ so any subdirectory (projects/, sessions/, ...)
  # created later by the isolated UID inherits controller read access.
  bridge_linux_sudo_root setfacl -d -m "u:${controller_user}:r-X" "$isolated_claude_dir" >/dev/null 2>&1 || true
  if [[ -d "$isolated_projects_dir" ]]; then
    bridge_linux_acl_add_recursive "u:${controller_user}:r-X" "$isolated_projects_dir" >/dev/null 2>&1 || true
    bridge_linux_acl_add_default_dirs_recursive "u:${controller_user}:r-X" "$isolated_projects_dir" >/dev/null 2>&1 || true
  fi
  bridge_linux_acl_add "u:${controller_user}:rw-" "$history_file" "$audit_file"
  bridge_write_linux_agent_env_file "$agent" "$env_file"
  # Leave env_file owned by the controller so subsequent starts can chmod it.
  # Previously we chowned it to $os_user, which made the operator-run start
  # path hit EPERM on the trailing `chmod 600` (file ownership is an
  # owner-only op; rwX ACL doesn't cover it). Grant the isolated user read
  # access via ACL instead — the agent only needs to read this file.
  bridge_linux_acl_add "u:${os_user}:r--" "$env_file"
  bridge_linux_acl_add "u:${controller_user}:rw-" "$env_file"
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

bridge_channel_item_marketplace() {
  local item="${1-}"

  item="$(bridge_qualify_channel_item "$item")"
  [[ "$item" == plugin:*@* ]] || {
    printf '%s' ""
    return 0
  }

  printf '%s' "${item#*@}"
}

bridge_channel_item_is_development() {
  local item="${1-}"
  local marketplace=""

  item="$(bridge_qualify_channel_item "$item")"
  [[ "$item" == plugin:*@* ]] || return 1
  marketplace="$(bridge_channel_item_marketplace "$item")"
  [[ -n "$marketplace" && "$marketplace" != "claude-plugins-official" ]]
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

bridge_extract_development_channels_from_command() {
  local command="${1:-}"

  bridge_require_python
  python3 - "$command" <<'PY'
import shlex
import sys

command = sys.argv[1]

def normalize(raw: str):
    values = []
    seen = set()
    for chunk in raw.split(","):
        item = chunk.strip()
        if not item or item in seen:
            continue
        seen.add(item)
        values.append(item)
    return values

try:
    tokens = shlex.split(command)
except ValueError:
    print("")
    raise SystemExit(0)

items = []
seen = set()
i = 0
while i < len(tokens):
    token = tokens[i]
    if token == "--dangerously-load-development-channels":
        i += 1
        while i < len(tokens) and not tokens[i].startswith("-"):
            for item in normalize(tokens[i]):
                if item not in seen:
                    seen.add(item)
                    items.append(item)
            i += 1
        continue
    if token.startswith("--dangerously-load-development-channels="):
        for item in normalize(token.split("=", 1)[1]):
            if item not in seen:
                seen.add(item)
                items.append(item)
    i += 1

print(",".join(items))
PY
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

bridge_filter_development_channels_csv() {
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
    if bridge_channel_item_is_development "$item"; then
      filtered="$(bridge_append_csv_unique "$filtered" "$item")"
    fi
  done

  printf '%s' "$filtered"
}

bridge_filter_approved_channels_csv() {
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
    if ! bridge_channel_item_is_development "$item"; then
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
  local inferred_dev=""

  explicit="${BRIDGE_AGENT_CHANNELS[$agent]-}"
  if [[ -n "$explicit" ]]; then
    bridge_normalize_channels_csv "$explicit"
    return 0
  fi

  inferred="$(bridge_extract_channels_from_command "$(bridge_agent_launch_cmd_raw "$agent")")"
  inferred_dev="$(bridge_extract_development_channels_from_command "$(bridge_agent_launch_cmd_raw "$agent")")"
  inferred="$(bridge_merge_channels_csv "$inferred" "$inferred_dev")"
  if [[ -n "$inferred" ]]; then
    printf '%s' "$inferred"
    return 0
  fi

  printf '%s' ""
}

bridge_agent_dev_channels_csv() {
  local agent="$1"
  bridge_filter_development_channels_csv "$(bridge_agent_channels_csv "$agent")"
}

bridge_agent_auto_accept_dev_channels_csv() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_AUTO_ACCEPT_DEV_CHANNELS[$agent]-}"

  if [[ -n "$explicit" ]]; then
    bridge_normalize_channels_csv "$explicit"
    return 0
  fi

  bridge_normalize_channels_csv "${BRIDGE_AUTO_ACCEPT_DEV_CHANNELS_DEFAULT:-plugin:teams@agent-bridge}"
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
  local effective_dev=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || {
    printf '%s' "n/a"
    return 0
  }

  item="$(bridge_qualify_channel_item "$item")"
  generated="$(bridge_claude_launch_with_channels "$agent" "$(bridge_agent_launch_cmd_raw "$agent")")"
  generated="$(bridge_claude_launch_with_development_channels "$generated" "$(bridge_agent_dev_channels_csv "$agent")")"
  effective="$(bridge_extract_channels_from_command "$generated")"
  effective_dev="$(bridge_extract_development_channels_from_command "$generated")"
  if bridge_channel_item_is_development "$item"; then
    if bridge_channel_csv_is_subset "$item" "$effective_dev"; then
      printf '%s' "yes"
      return 0
    fi
    printf '%s' "no"
    return 0
  fi

  if bridge_channel_csv_is_subset "$item" "$effective"; then
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

bridge_agent_broken_launch_file() {
  local agent="$1"
  printf '%s/agents/%s/broken-launch' "$BRIDGE_STATE_DIR" "$agent"
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
  local broken_launch_file=""

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  onboarding_state="$(bridge_agent_onboarding_state "$agent")"
  broken_launch_file="$(bridge_agent_broken_launch_file "$agent")"

  if [[ -f "$broken_launch_file" ]]; then
    restart_readiness="broken-launch"
  elif [[ "$loop_mode" == "1" ]]; then
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
  python3 - "$agent" "$session" "$active" "$loop_mode" "$continue_mode" "$onboarding_state" "$attached_exit_behavior" "$restart_readiness" "$broken_launch_file" <<'PY'
import json
import sys

agent, session, active, loop_mode, continue_mode, onboarding_state, attached_exit_behavior, restart_readiness, broken_launch_file = sys.argv[1:]
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
if broken_launch_file:
    payload["broken_launch_file"] = broken_launch_file
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
  local broken_launch_file=""

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  onboarding_state="$(bridge_agent_onboarding_state "$agent")"
  broken_launch_file="$(bridge_agent_broken_launch_file "$agent")"
  exit_behavior="exit"
  restart_readiness="not-looped"
  if [[ -f "$broken_launch_file" ]]; then
    restart_readiness="broken-launch"
  elif [[ "$loop_mode" == "1" ]]; then
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
  if [[ -f "$broken_launch_file" ]]; then
    printf -- '- broken_launch_file: %s\n' "$broken_launch_file"
    printf -- '- recovery: agent-bridge agent safe-mode %s\n' "$agent"
  fi
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

bridge_agent_channel_runtime_drift_reason() {
  local agent="$1"
  local required=""
  local missing=""
  local ready=""

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    printf '%s' ""
    return 0
  }

  missing="$(bridge_agent_missing_channels_csv "$agent")"
  [[ -n "$missing" ]] || {
    printf '%s' ""
    return 0
  }

  ready="$(bridge_agent_ready_channels_csv "$agent")"
  printf 'declared channels (%s) do not match configured runtime (ready=%s missing=%s)' \
    "$required" \
    "${ready:--}" \
    "$missing"
}

bridge_agent_launch_channels_csv() {
  local agent="$1"
  local channels=""

  if [[ "${BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS:-0}" == "1" ]]; then
    channels="$(bridge_filter_approved_channels_csv "$(bridge_agent_ready_channels_csv "$agent")")"
  else
    channels="$(bridge_filter_approved_channels_csv "$(bridge_agent_channels_csv "$agent")")"
  fi
  bridge_filter_claude_plugin_channels_csv "$channels"
}

bridge_agent_effective_dev_channels_csv() {
  local agent="$1"

  if [[ "${BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS:-0}" == "1" ]]; then
    bridge_filter_development_channels_csv "$(bridge_agent_ready_channels_csv "$agent")"
    return 0
  fi

  bridge_agent_dev_channels_csv "$agent"
}

bridge_agent_effective_launch_plugin_channels_csv() {
  local agent="$1"
  local merged=""

  merged="$(bridge_merge_channels_csv "$(bridge_agent_launch_channels_csv "$agent")" "$(bridge_agent_effective_dev_channels_csv "$agent")")"
  bridge_filter_claude_plugin_channels_csv "$merged"
}

bridge_plugin_mcp_identity_for_item() {
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
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_plugin_mcp_descendant_ready_for_item() {
  local root_pid="$1"
  local item="$2"
  local identity=""

  [[ "$root_pid" =~ ^[0-9]+$ ]] || return 1
  identity="$(bridge_plugin_mcp_identity_for_item "$item")"
  [[ -n "$identity" ]] || return 1

  bridge_require_python
  python3 - "$root_pid" "$identity" <<'PY'
import re
import subprocess
import sys
from collections import defaultdict

root_pid = int(sys.argv[1])
identity = sys.argv[2].strip().lower()

try:
    completed = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,command="],
        check=True,
        text=True,
        capture_output=True,
    )
except subprocess.CalledProcessError:
    raise SystemExit(1)

procs = {}
children = defaultdict(list)
for raw in completed.stdout.splitlines():
    parts = raw.strip().split(None, 2)
    if len(parts) < 3:
        continue
    try:
        pid = int(parts[0])
        ppid = int(parts[1])
    except ValueError:
        continue
    command = parts[2]
    procs[pid] = (ppid, command)
    children[ppid].append(pid)

descendants = set()
stack = list(children.get(root_pid, []))
while stack:
    pid = stack.pop()
    if pid in descendants:
        continue
    descendants.add(pid)
    stack.extend(children.get(pid, []))

def command_has_identity_path_segment(command: str, identity: str) -> bool:
    for match in re.finditer(r"/[^\s]+", command):
        token = match.group(0)
        segments = [segment for segment in token.split("/") if segment]
        if identity in segments:
            return True
    return False

for pid in descendants:
    _ppid, command = procs.get(pid, (None, ""))
    lowered = command.lower()
    if "bun" not in lowered:
        continue
    if command_has_identity_path_segment(lowered, identity):
        raise SystemExit(0)

raise SystemExit(1)
PY
}

bridge_agent_plugin_mcp_alive_for_item() {
  local agent="$1"
  local item="$2"
  local session=""
  local pane_pid=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 1
  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || return 1
  bridge_tmux_session_exists "$session" || return 1
  pane_pid="$(bridge_tmux_session_pane_pid "$session")"
  [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
  bridge_plugin_mcp_descendant_ready_for_item "$pane_pid" "$item"
}

bridge_agent_missing_plugin_mcp_channels_csv() {
  local agent="$1"
  local required=""
  local item=""
  local missing=""
  local -a items=()

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  required="$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"
  [[ -n "$required" ]] || return 0

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if ! bridge_agent_plugin_mcp_alive_for_item "$agent" "$item"; then
      missing="$(bridge_merge_channels_csv "$missing" "$item")"
    fi
  done

  printf '%s' "$missing"
}

bridge_agent_required_launch_channels_csv() {
  local agent="$1"

  bridge_filter_claude_plugin_channels_csv "$(bridge_filter_approved_channels_csv "$(bridge_agent_channels_csv "$agent")")"
}

bridge_agent_required_dev_channels_csv() {
  local agent="$1"

  bridge_filter_claude_plugin_channels_csv "$(bridge_agent_dev_channels_csv "$agent")"
}

bridge_agent_required_runtime_channels_csv() {
  local agent="$1"

  bridge_agent_channels_csv "$agent"
}

bridge_claude_channel_banner_present_from_text() {
  local channels="$1"
  local recent="$2"
  local item=""
  local found=0
  local -a items=()

  channels="$(bridge_filter_claude_plugin_channels_csv "$channels")"
  [[ -n "$channels" ]] || return 0
  [[ "$recent" == *"Listening for channel messages from:"* ]] || return 1

  IFS=',' read -r -a items <<<"$channels"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    [[ "$recent" == *"$item"* ]] || return 1
    found=1
  done

  [[ "$found" == "1" ]]
}

bridge_tmux_session_has_claude_channel_banner() {
  local session="$1"
  local channels="$2"
  local recent=""

  channels="$(bridge_filter_claude_plugin_channels_csv "$channels")"
  [[ -n "$channels" ]] || return 0
  recent="$(bridge_capture_recent "$session" 80 2>/dev/null || true)"
  [[ -n "$recent" ]] || return 1
  bridge_claude_channel_banner_present_from_text "$channels" "$recent"
}

bridge_tmux_wait_for_claude_channel_banner() {
  local session="$1"
  local channels="$2"
  local timeout="${3:-12}"
  local start_ts=0
  local elapsed=0

  channels="$(bridge_filter_claude_plugin_channels_csv "$channels")"
  [[ -n "$channels" ]] || return 0
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=12
  (( timeout > 0 )) || timeout=12

  if bridge_tmux_session_has_claude_channel_banner "$session" "$channels"; then
    return 0
  fi

  start_ts="$(date +%s)"
  while true; do
    if bridge_tmux_session_has_claude_channel_banner "$session" "$channels"; then
      return 0
    fi
    sleep 0.2
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

# bridge_tmux_wait_for_claude_plugin_mcp_alive — descendant-based readiness
# verifier for required Claude plugin MCP channels. Issue #143.
#
# The banner-based verifier (bridge_tmux_wait_for_claude_channel_banner)
# scans the last 80 tmux lines for a startup-only banner; busy sessions
# scroll the banner off-window in seconds, so restart verify keeps
# failing even when every plugin bun process is healthy. The daemon's
# steady-state liveness already uses a descendant process probe
# (bridge_agent_missing_plugin_mcp_channels_csv → *_alive_for_item →
# bridge_plugin_mcp_descendant_ready_for_item); route restart verify
# through the same signal for consistency.
#
# Polls until every required plugin MCP is alive under the pane PID or
# timeout elapses. Returns 0 when no channels are required, when
# liveness is already clean, or when the loop observes it cleanly.
# Returns 1 if timeout expires with at least one channel still missing.
bridge_tmux_wait_for_claude_plugin_mcp_alive() {
  local agent="$1"
  local timeout="${2:-12}"
  local required=""
  local missing=""
  local start_ts=0
  local elapsed=0

  [[ -n "$agent" ]] || return 0
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  required="$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"
  [[ -n "$required" ]] || return 0
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=12
  (( timeout > 0 )) || timeout=12

  missing="$(bridge_agent_missing_plugin_mcp_channels_csv "$agent")"
  [[ -z "$missing" ]] && return 0

  start_ts="$(date +%s)"
  while true; do
    sleep 0.5
    missing="$(bridge_agent_missing_plugin_mcp_channels_csv "$agent")"
    [[ -z "$missing" ]] && return 0
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

bridge_agent_launch_channel_status_reason() {
  local agent="$1"
  local required=""
  local required_dev=""
  local effective=""
  local effective_dev=""
  local generated=""

  required="$(bridge_agent_required_launch_channels_csv "$agent")"
  required_dev="$(bridge_agent_required_dev_channels_csv "$agent")"
  generated="$(bridge_claude_launch_with_channels "$agent" "$(bridge_agent_launch_cmd_raw "$agent")")"
  generated="$(bridge_claude_launch_with_development_channels "$generated" "$required_dev")"
  effective_dev="$(bridge_extract_development_channels_from_command "$generated")"
  [[ -n "$required" ]] || {
    if [[ -z "$required_dev" ]]; then
      printf '%s' ""
      return 0
    fi
  }

  effective="$(bridge_extract_channels_from_command "$generated")"
  if [[ -n "$required" ]] && ! bridge_channel_csv_is_subset "$required" "$effective"; then
    printf 'launch command missing required Claude --channels (%s)' "$required"
    return 0
  fi
  if [[ -n "$required_dev" ]] && ! bridge_channel_csv_is_subset "$required_dev" "$effective_dev"; then
    printf 'launch command missing required development channels (%s)' "$required_dev"
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
  local roster_local="$BRIDGE_HOME/agent-roster.local.sh"

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
  printf "\nIf this agent intentionally runs with fewer channels, update %s so BRIDGE_AGENT_CHANNELS[\"%s\"] matches the live runtime before restarting." "$roster_local" "$agent"
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

bridge_agent_restart_preflight_reason() {
  local agent="$1"
  local session=""
  local reason=""
  local drift=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || {
    printf '%s' ""
    return 0
  }

  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || {
    printf '%s' ""
    return 0
  }
  bridge_tmux_session_exists "$session" || {
    printf '%s' ""
    return 0
  }

  reason="$(bridge_agent_channel_status_reason "$agent")"
  [[ -n "$reason" ]] || {
    printf '%s' ""
    return 0
  }

  drift="$(bridge_agent_channel_runtime_drift_reason "$agent")"
  if [[ -n "$drift" ]]; then
    printf '%s' "$drift"
    return 0
  fi

  printf '%s' "$reason"
}

bridge_agent_restart_preflight_guidance() {
  local agent="$1"
  local reason="${2:-$(bridge_agent_restart_preflight_reason "$agent")}"

  [[ -n "$reason" ]] || {
    printf '%s' ""
    return 0
  }

  printf "Restart is blocked for '%s': %s" "$agent" "$reason"
  printf "\nThe running session was left intact to avoid downtime."
  printf "\n%s" "$(bridge_agent_channel_setup_guidance "$agent" "$reason")"
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
  local plugins=""

  [[ "$(bridge_agent_channel_status "$agent")" == "ok" || "$(bridge_agent_channel_status "$agent")" == "-" ]] || return 1
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  plugins="$(bridge_merge_channels_csv "$(bridge_agent_required_launch_channels_csv "$agent")" "$(bridge_agent_required_dev_channels_csv "$agent")")"
  bridge_claude_channel_plugins_ready_for_csv "$plugins"
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
  bridge_ensure_claude_channel_plugins_for_csv "$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"
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

bridge_agent_model() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_MODEL[$agent]-}"
}

bridge_agent_effort() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_EFFORT[$agent]-}"
}

bridge_agent_permission_mode() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_PERMISSION_MODE[$agent]-}"
}

# Returns 0 (true) when none of model/effort/permission_mode have been set
# for $agent and permission_mode is not explicitly "legacy". In that case the
# launch builders MUST emit the historical command shape (no --model /
# --effort / --permission-mode flags, --dangerously-skip-permissions kept) so
# rosters that predate these fields keep launching byte-for-byte the same.
bridge_agent_uses_legacy_launch_flags() {
  local agent="$1"
  local pm model effort
  pm="$(bridge_agent_permission_mode "$agent")"
  model="$(bridge_agent_model "$agent")"
  effort="$(bridge_agent_effort "$agent")"
  if [[ "$pm" == "legacy" ]]; then
    return 0
  fi
  [[ -z "$pm" && -z "$model" && -z "$effort" ]]
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

bridge_agent_plugin_port_from_env_file() {
  # Read a single <KEY>=<value> line from a plugin .env file and echo the
  # value if it parses as a port. Empty output on miss.
  local env_file="$1"
  local key="$2"
  local line=""
  local value=""

  [[ -n "$env_file" && -f "$env_file" ]] || return 0
  [[ -n "$key" ]] || return 0
  # Grab the last occurrence — plugin .env files are append-style in places.
  line="$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0
  value="${line#${key}=}"
  # Strip optional surrounding quotes and whitespace.
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  value="${value//[[:space:]]/}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
}

bridge_agent_plugin_ports() {
  # Enumerate known plugin ports for an agent. Currently only teams binds
  # a long-lived port inside the tmux pane tree, but the helper is built
  # to grow: each entry is "<port>\t<binary-name>\t<plugin-label>".
  local agent="$1"
  local teams_env=""
  local port=""

  teams_env="$(bridge_agent_teams_state_dir "$agent")/.env"
  port="$(bridge_agent_plugin_port_from_env_file "$teams_env" "TEAMS_WEBHOOK_PORT" 2>/dev/null || true)"
  if [[ -n "$port" ]]; then
    printf '%s\t%s\t%s\n' "$port" "bun" "teams"
  fi
}

bridge_kill_port_holder_if_orphan() {
  # Port-aware fallback to the generic orphan cleanup: if $port is still
  # bound after session stop, find the pid holding it, confirm it is
  # rooted at pid 1 (reparented to init) and that its command matches the
  # plugin binary name, then SIGTERM → wait → SIGKILL it specifically.
  # See issue #69 Defect A.
  local port="$1"
  local binary_name="$2"
  local plugin_label="$3"
  local -a holders=()
  local pid=""
  local ppid_value=""
  local cmd=""
  local attempt=0

  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  [[ -n "$binary_name" ]] || return 0

  # Enumerate PIDs holding the port. Prefer ss -tlnp, fall back to lsof.
  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && holders+=("$pid")
    done < <(
      ss -H -tlnp "sport = :${port}" 2>/dev/null \
        | grep -oE 'pid=[0-9]+' \
        | awk -F= '{print $2}' \
        | sort -u
    )
  fi
  if [[ ${#holders[@]} -eq 0 ]] && command -v lsof >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && holders+=("$pid")
    done < <(lsof -ti ":${port}" 2>/dev/null | sort -u)
  fi

  [[ ${#holders[@]} -gt 0 ]] || return 0

  for pid in "${holders[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    # Only touch processes that have been reparented to init/launchd (ppid=1
    # or 0). A live session's bun child still parented to a tmux pane
    # process must not be killed from under it.
    ppid_value="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$ppid_value" =~ ^[0-9]+$ ]] || continue
    (( ppid_value == 0 || ppid_value == 1 )) || continue
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    # Require the recognized binary name in the command line to avoid
    # killing an unrelated process that happened to bind the same port.
    [[ "$cmd" == *"${binary_name}"* ]] || continue

    bridge_info "[info] killing reparented ${plugin_label} port holder pid=${pid} port=${port} cmd='${cmd}' (issue #69)"
    kill -TERM "$pid" >/dev/null 2>&1 || true
    for attempt in {1..20}; do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  done
}

bridge_agent_port_aware_orphan_cleanup_after_session_stop() {
  # Complement to bridge_mcp_orphan_cleanup_after_session_stop: walk the
  # plugin ports this agent reserves and make sure nothing is still
  # holding them after the tmux tree comes down. Belt-and-suspenders for
  # issue #69 Defect A, where reparented bun processes have been observed
  # to survive the pattern-based cleanup.
  local agent="$1"
  local port=""
  local binary=""
  local label=""

  [[ "${BRIDGE_PLUGIN_PORT_ORPHAN_CLEANUP_ENABLED:-1}" == "1" ]] || return 0

  while IFS=$'\t' read -r port binary label; do
    [[ -n "$port" ]] || continue
    bridge_kill_port_holder_if_orphan "$port" "$binary" "$label" \
      >/dev/null 2>&1 || true
  done < <(bridge_agent_plugin_ports "$agent" 2>/dev/null || true)
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
  bridge_agent_port_aware_orphan_cleanup_after_session_stop "$agent" \
    >/dev/null 2>&1 || true
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

bridge_plugin_port_range_start() {
  printf '%s' "${BRIDGE_PLUGIN_PORT_RANGE_START:-39800}"
}

bridge_plugin_port_range_end() {
  printf '%s' "${BRIDGE_PLUGIN_PORT_RANGE_END:-39999}"
}

bridge_plugin_channel_state_dir() {
  local agent="$1"
  local label="$2"

  case "$label" in
    teams)
      bridge_agent_teams_state_dir "$agent"
      ;;
    discord)
      bridge_agent_discord_state_dir "$agent"
      ;;
    telegram)
      bridge_agent_telegram_state_dir "$agent"
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_plugin_port_env_key() {
  local label="$1"

  case "$label" in
    teams)
      printf 'TEAMS_WEBHOOK_PORT'
      ;;
    discord)
      printf 'DISCORD_WEBHOOK_PORT'
      ;;
    telegram)
      printf 'TELEGRAM_WEBHOOK_PORT'
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_read_port_from_env_file() {
  local env_file="$1"
  local key="$2"
  local line=""
  local value=""

  [[ -f "$env_file" ]] || return 0
  [[ -n "$key" ]] || return 0
  line="$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0
  value="${line#"${key}="}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  value="${value//[[:space:]]/}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
}

bridge_port_is_free() {
  local port="$1"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  python3 - "$port" <<'PY' 2>/dev/null
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("127.0.0.1", port))
except OSError:
    sys.exit(1)
finally:
    sock.close()
sys.exit(0)
PY
}

bridge_allocate_channel_port() {
  local agent="$1"
  local label="$2"
  local state_dir=""
  local env_file=""
  local env_key=""
  local range_start range_end span
  local current=""
  local candidate=""
  local hash_hex
  local -i offset=0
  local -i attempts=0
  local -i max_attempts=0
  local -i allocated=0

  if [[ -z "$agent" || -z "$label" ]]; then
    bridge_warn "bridge_allocate_channel_port: agent와 plugin label이 필요합니다"
    return 1
  fi

  if ! state_dir="$(bridge_plugin_channel_state_dir "$agent" "$label")"; then
    bridge_warn "bridge_allocate_channel_port: 지원하지 않는 plugin label: $label"
    return 1
  fi
  if ! env_key="$(bridge_plugin_port_env_key "$label")"; then
    bridge_warn "bridge_allocate_channel_port: plugin label에 대한 port env key를 결정하지 못했습니다: $label"
    return 1
  fi

  env_file="$state_dir/.env"
  range_start="$(bridge_plugin_port_range_start)"
  range_end="$(bridge_plugin_port_range_end)"

  if ! [[ "$range_start" =~ ^[0-9]+$ && "$range_end" =~ ^[0-9]+$ ]] || (( range_start <= 0 || range_end <= 0 || range_end < range_start )); then
    bridge_warn "BRIDGE_PLUGIN_PORT_RANGE_* 가 유효하지 않습니다: ${range_start}-${range_end}"
    return 1
  fi
  span=$(( range_end - range_start + 1 ))

  if [[ -f "$env_file" ]]; then
    current="$(bridge_read_port_from_env_file "$env_file" "$env_key" 2>/dev/null || true)"
  fi
  if [[ "$current" =~ ^[0-9]+$ ]] && (( current >= range_start && current <= range_end )); then
    if bridge_port_is_free "$current"; then
      printf '%s' "$current"
      return 0
    fi
  fi

  hash_hex="$(bridge_sha1 "${agent}|${label}")"
  hash_hex="${hash_hex:0:8}"
  if [[ -z "$hash_hex" ]]; then
    offset=0
  else
    offset=$(( 16#${hash_hex} % span ))
  fi

  max_attempts="$span"
  attempts=0
  while (( attempts < max_attempts )); do
    candidate=$(( range_start + ( offset + attempts ) % span ))
    if bridge_port_is_free "$candidate"; then
      allocated="$candidate"
      break
    fi
    attempts=$(( attempts + 1 ))
  done

  if (( allocated == 0 )); then
    bridge_warn "bridge_allocate_channel_port: ${range_start}-${range_end} 범위에서 사용 가능한 포트를 찾지 못했습니다 (agent=${agent}, label=${label})"
    return 1
  fi

  mkdir -p "$state_dir"
  bridge_upsert_env_value "$env_file" "$env_key" "$allocated"
  printf '%s' "$allocated"
}

bridge_upsert_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local tmp_file=""

  if [[ -z "$env_file" || -z "$key" ]]; then
    return 1
  fi

  mkdir -p "$(dirname "$env_file")"
  if [[ ! -f "$env_file" ]]; then
    printf '%s=%s\n' "$key" "$value" >"$env_file"
    return 0
  fi

  tmp_file="$(mktemp "${env_file}.XXXXXX")" || return 1
  if grep -Eq "^${key}=" "$env_file" 2>/dev/null; then
    awk -v key="$key" -v value="$value" '
      BEGIN { replaced = 0 }
      {
        if ($0 ~ "^" key "=") {
          if (!replaced) {
            print key "=" value
            replaced = 1
          }
        } else {
          print $0
        }
      }
      END {
        if (!replaced) {
          print key "=" value
        }
      }
    ' "$env_file" >"$tmp_file"
  else
    cat "$env_file" >"$tmp_file"
    printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
  fi
  mv "$tmp_file" "$env_file"
}
