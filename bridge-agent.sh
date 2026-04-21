#!/usr/bin/env bash
# bridge-agent.sh — static role lifecycle helpers

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  $(basename "$0") create <agent> [options]
  $(basename "$0") list [--json]
  $(basename "$0") show <agent> [--json]
  $(basename "$0") start <agent> [--attach|--no-attach] [--replace] [--continue|--no-continue] [--dry-run]
  $(basename "$0") safe-mode <agent> [--attach|--no-attach] [--replace] [--continue|--no-continue] [--dry-run]
  $(basename "$0") stop <agent>
  $(basename "$0") restart <agent> [--attach|--no-attach] [--continue|--no-continue] [--dry-run]
  $(basename "$0") attach <agent>

Options:
  --engine claude|codex        Agent runtime engine (default: claude)
  --session <name>             tmux session name (default: <agent>)
  --workdir <path>             live home / workdir (default: \$BRIDGE_AGENT_HOME_ROOT/<agent>)
  --profile-home <path>        tracked profile target when different from workdir
  --description <text>         roster description
  --display-name <text>        scaffold display name (default: <agent>)
  --role <text>                scaffold role summary
  --session-type <type>        admin|static-claude|static-codex|dynamic|cron
  --user <id[:display-name]>   scaffold one user memory partition (repeatable; defaults to shared users)
  --launch-cmd <cmd>           explicit launch command
  --channels <csv>             required Claude channels metadata
  --discord-channel <id>       primary Discord channel metadata
  --notify-kind <kind>         out-of-band notify transport metadata
  --notify-target <target>     notify target metadata
  --notify-account <account>   notify account metadata
  --isolation <mode>           shared|linux-user (default: shared)
  --isolate                    shorthand for --isolation linux-user
  --os-user <user>             explicit Linux service user for linux-user isolation
  --loop                       mark the role as loop-enabled
  --always-on                  configure IDLE_TIMEOUT=0 for this role
  --continue|--no-continue     explicit continue mode (default: continue)
  --dry-run                    print the planned role block without writing
  --json                       emit JSON instead of human text

Examples:
  $(basename "$0") create reviewer --engine claude
  $(basename "$0") create coder --engine codex --session codex-main --always-on
  $(basename "$0") create ops --engine claude --channels plugin:discord@claude-plugins-official --discord-channel 123456789012345678 --json
  $(basename "$0") list --json
  $(basename "$0") show reviewer --json
  $(basename "$0") start reviewer --dry-run
  $(basename "$0") restart reviewer --attach
  $(basename "$0") safe-mode reviewer --attach
  $(basename "$0") stop reviewer
  $(basename "$0") attach reviewer
EOF
}

bridge_agent_manage_python() {
  bridge_require_python
  python3 - "$@"
}

# bridge_ensure_memory_precompact_hook — wire the Plan-D PreCompact hook
# into an agent's .claude/settings.json. Safe to call repeatedly; the
# bridge-hooks.py helper already short-circuits when the hook is present.
#
# Called from:
#   - agent create (claude engine path)
#   - agent restart (as a safety net for pre-Plan-D installs)
bridge_ensure_memory_precompact_hook() {
  local agent="$1"
  local workdir="$2"
  local settings
  settings="$workdir/.claude/settings.json"
  if [[ -z "$workdir" || ! -f "$settings" ]]; then
    return 0
  fi
  local python_bin
  python_bin="${BRIDGE_PYTHON_BIN:-$(command -v python3 || echo /usr/bin/python3)}"
  if ! "$python_bin" "$SCRIPT_DIR/bridge-hooks.py" status-pre-compact-hook \
        --workdir "$workdir" \
        --bridge-home "$SCRIPT_DIR" \
        --python-bin "$python_bin" \
        --settings-file "$settings" >/dev/null 2>&1; then
    "$python_bin" "$SCRIPT_DIR/bridge-hooks.py" ensure-pre-compact-hook \
      --workdir "$workdir" \
      --bridge-home "$SCRIPT_DIR" \
      --python-bin "$python_bin" \
      --settings-file "$settings" >/dev/null 2>&1 || true
  fi
}

bridge_agent_default_launch_cmd() {
  local engine="$1"

  case "$engine" in
    claude)
      printf '%s' 'claude --dangerously-skip-permissions'
      ;;
    codex)
      printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'
      ;;
    *)
      bridge_die "지원하지 않는 engine 입니다: $engine"
      ;;
  esac
}

bridge_expand_user_path() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    printf '%s' ""
    return 0
  fi
  bridge_agent_manage_python "$raw" <<'PY'
from pathlib import Path
import sys

value = sys.argv[1]
print(str(Path(value).expanduser()))
PY
}

bridge_render_template_string() {
  local source_file="$1"
  local agent_id="$2"
  local display_name="$3"
  local role_text="$4"
  local engine="$5"
  local session_type="$6"

  bridge_agent_manage_python "$source_file" "$agent_id" "$display_name" "$role_text" "$engine" "$session_type" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
agent_id, display_name, role_text, engine, session_type = sys.argv[2:]
runtime = "Claude Code CLI" if engine == "claude" else "Codex CLI"
text = source.read_text(encoding="utf-8")
replacements = {
    "<Agent Name>": display_name,
    "<agent-id>": agent_id,
    "<Role>": role_text,
    "<Role Summary>": role_text,
    "<Runtime>": runtime,
    "<Boss>": "관리자 에이전트",
    "<한 줄 역할 설명>": role_text,
    "<표시 이름>": display_name,
    "<Session Type>": session_type,
    "<핵심 책임>": role_text,
    "<주 요청자>": "관리자 에이전트",
    "<Claude Code CLI | Codex CLI>": runtime,
    "<반드시 지킬 운영 규칙>": "큐를 source of truth로 삼고, claim/done note를 생략하지 않는다.",
    "<위험 작업 제한>": "크리티컬 변경 전에는 dry-run 또는 관련 상태 확인을 먼저 수행한다.",
    "<보고 방식>": "결과는 요청자 채널 또는 task queue로 반드시 남긴다.",
}
for old, new in replacements.items():
    text = text.replace(old, new)
print(text, end="")
PY
}

bridge_scaffold_agent_home() {
  local agent="$1"
  local home="$2"
  local display_name="$3"
  local role_text="$4"
  local engine="$5"
  local session_type="$6"
  local template_root="$SCRIPT_DIR/agents/_template"
  local session_template="$template_root/session-types/$session_type.md"
  local session_files_root="$template_root/session-type-files/$session_type"
  local file=""
  local rel=""
  local target=""

  mkdir -p "$home"
  [[ -d "$template_root" ]] || bridge_die "agent template root가 없습니다: $template_root"
  [[ -f "$session_template" ]] || bridge_die "session type template가 없습니다: $session_type"

  while IFS= read -r file; do
    rel="${file#"$template_root"/}"
    target="$home/$rel"
    mkdir -p "$(dirname "$target")"
    if [[ -e "$target" ]]; then
      continue
    fi
    bridge_render_template_string "$file" "$agent" "$display_name" "$role_text" "$engine" "$session_type" >"$target"
  done < <(find "$template_root" \
    -path "$template_root/session-types" -prune -o \
    -path "$template_root/session-type-files" -prune -o \
    -type f -print | LC_ALL=C sort)

  if [[ ! -e "$home/SESSION-TYPE.md" ]]; then
    bridge_render_template_string "$session_template" "$agent" "$display_name" "$role_text" "$engine" "$session_type" >"$home/SESSION-TYPE.md"
  fi

  if [[ "$session_type" == "static-claude" ]]; then
    python3 - "$home/SESSION-TYPE.md" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
updated = re.sub(
    r"(^- Onboarding State:\s*)([A-Za-z0-9._-]+)",
    r"\1complete",
    text,
    count=1,
    flags=re.MULTILINE,
)
path.write_text(updated, encoding="utf-8")
PY
  fi

  while IFS= read -r rel; do
    mkdir -p "$home/$rel"
  done < <(cd "$template_root" && find . \
    -path './session-types' -prune -o \
    -path './session-type-files' -prune -o \
    -type d -print | sed 's#^\./##' | grep -v '^$' | LC_ALL=C sort)

  if [[ -d "$session_files_root" ]]; then
    while IFS= read -r file; do
      rel="${file#"$session_files_root"/}"
      target="$home/$rel"
      mkdir -p "$(dirname "$target")"
      if [[ -e "$target" ]]; then
        continue
      fi
      bridge_render_template_string "$file" "$agent" "$display_name" "$role_text" "$engine" "$session_type" >"$target"
    done < <(find "$session_files_root" -type f -print | LC_ALL=C sort)

    while IFS= read -r rel; do
      mkdir -p "$home/$rel"
    done < <(cd "$session_files_root" && find . -type d -print | sed 's#^\./##' | grep -v '^$' | LC_ALL=C sort)
  fi
}

bridge_normalize_user_specs_json() {
  bridge_agent_manage_python "$@" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")

items = []
seen = set()

def display_name_from_user_file(path: Path, fallback: str) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return fallback
    preferred = ""
    name = ""
    for line in text.splitlines():
        if line.startswith("- Preferred name:"):
            preferred = line.split(":", 1)[1].strip()
        elif line.startswith("- Name:"):
            name = line.split(":", 1)[1].strip()
    return preferred or name or fallback

def add_user(user_id: str, display_name: str) -> None:
    user_id = user_id.strip()
    display_name = display_name.strip() or user_id
    if not user_id:
        raise SystemExit("empty user id is not allowed")
    if not NAME_RE.match(user_id):
        raise SystemExit(f"invalid user id: {user_id}")
    if user_id in seen:
        return
    seen.add(user_id)
    items.append({"id": user_id, "display_name": display_name})

for raw in sys.argv[1:]:
    if ":" in raw:
        user_id, display_name = raw.split(":", 1)
    else:
        user_id, display_name = raw, raw
    add_user(user_id, display_name)

def discover_shared_users() -> None:
    shared_dir = Path(os.environ.get("BRIDGE_SHARED_DIR") or Path(os.environ.get("BRIDGE_HOME", "~/.agent-bridge")).expanduser() / "shared")
    users_root = shared_dir / "users"
    if not users_root.exists():
        return
    for user_root in sorted(path for path in users_root.iterdir() if path.is_dir()):
        if not NAME_RE.match(user_root.name):
            continue
        display = display_name_from_user_file(user_root / "USER.md", user_root.name)
        add_user(user_root.name, display)

def discover_existing_agent_users() -> None:
    agents_root = Path(os.environ.get("BRIDGE_AGENT_HOME_ROOT") or Path(os.environ.get("BRIDGE_HOME", "~/.agent-bridge")).expanduser() / "agents")
    if not agents_root.exists():
        return
    for user_file in sorted(agents_root.glob("*/users/*/USER.md")):
        user_id = user_file.parent.name
        if not NAME_RE.match(user_id):
            continue
        display = display_name_from_user_file(user_file, user_id)
        if user_id == "default" and display == "default":
            continue
        add_user(user_id, display)

if not items:
    discover_shared_users()
if not items:
    discover_existing_agent_users()
if not items:
    add_user("default", "default")

print(json.dumps(items, ensure_ascii=False))
PY
}

bridge_scaffold_user_partitions() {
  local home="$1"
  local users_json="$2"
  local shared_users_root="${3:-${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}/users}"

  bridge_agent_manage_python "$home" "$users_json" "$shared_users_root" <<'PY'
from pathlib import Path
import json
import shutil
import sys

home = Path(sys.argv[1])
users = json.loads(sys.argv[2])
shared_users_root = Path(sys.argv[3])
users_root = home / "users"
default_root = users_root / "default"

if not default_root.exists():
    raise SystemExit(f"missing template user skeleton: {default_root}")

def patch_user_file(path: Path, user_id: str, display_name: str) -> None:
    text = path.read_text(encoding="utf-8")
    text = text.replace("- Name:\n", f"- Name: {display_name}\n")
    text = text.replace("- Preferred name:\n", f"- Preferred name: {display_name}\n")
    path.write_text(text, encoding="utf-8")

def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)

def link_or_copy(canonical: Path, target: Path) -> None:
    if target.exists() or target.is_symlink():
        remove_path(target)
    try:
        target.symlink_to(canonical, target_is_directory=True)
    except OSError:
        shutil.copytree(canonical, target, symlinks=True)

def ensure_canonical_user(user_id: str, display_name: str) -> Path:
    canonical = shared_users_root / user_id
    if not canonical.exists():
        canonical.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(default_root, canonical, symlinks=True)
    patch_user_file(canonical / "USER.md", user_id, display_name)
    return canonical

for user in users:
    user_id = user["id"]
    display_name = user.get("display_name") or user_id
    canonical = ensure_canonical_user(user_id, display_name)
    target = users_root / user_id
    if target.exists() and not target.is_symlink() and user_id != "default":
        continue
    link_or_copy(canonical, target)

if all(user["id"] != "default" for user in users) and (default_root.exists() or default_root.is_symlink()):
    remove_path(default_root)

index_path = home / "memory" / "index.md"
if index_path.exists():
    lines = index_path.read_text(encoding="utf-8").splitlines()
    out = []
    inserted = False
    for line in lines:
        out.append(line)
        if line.strip() == "## Users":
            inserted = True
            continue
        if inserted and line.strip() == "- `../users/`":
            for user in users:
                out.append(f"- `../users/{user['id']}/`")
            inserted = False
    index_path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

bridge_write_role_block() {
  local agent="$1"
  local description="$2"
  local engine="$3"
  local session="$4"
  local workdir="$5"
  local profile_home="$6"
  local launch_cmd="$7"
  local channels="$8"
  local discord_channel="$9"
  local notify_kind="${10}"
  local notify_target="${11}"
  local notify_account="${12}"
  local loop_mode="${13}"
  local continue_mode="${14}"
  local always_on="${15}"
  local isolation_mode="${16:-}"
  local os_user="${17:-}"

  bridge_agent_manage_python \
    "$BRIDGE_ROSTER_LOCAL_FILE" \
    "$agent" \
    "$description" \
    "$engine" \
    "$session" \
    "$workdir" \
    "$profile_home" \
    "$launch_cmd" \
    "$channels" \
    "$discord_channel" \
    "$notify_kind" \
    "$notify_target" \
    "$notify_account" \
    "$loop_mode" \
    "$continue_mode" \
    "$always_on" \
    "$isolation_mode" \
    "$os_user" <<'PY'
from pathlib import Path
import shlex
import sys

(
    path_str,
    agent,
    description,
    engine,
    session,
    workdir,
    profile_home,
    launch_cmd,
    channels,
    discord_channel,
    notify_kind,
    notify_target,
    notify_account,
    loop_mode,
    continue_mode,
    always_on,
    isolation_mode,
    os_user,
) = sys.argv[1:]

path = Path(path_str)
if path.exists():
    text = path.read_text(encoding="utf-8")
else:
    text = "#!/usr/bin/env bash\n# shellcheck shell=bash disable=SC2034\n"

begin = f"# BEGIN AGENT BRIDGE MANAGED ROLE: {agent}"
end = f"# END AGENT BRIDGE MANAGED ROLE: {agent}"
if begin in text or end in text:
    raise SystemExit(f"managed block already exists for {agent}: {path}")

def sq(value: str) -> str:
    return shlex.quote(value)

lines = [
    begin,
    f'bridge_add_agent_id_if_missing {sq(agent)}',
    f'BRIDGE_AGENT_DESC["{agent}"]={sq(description)}',
    f'BRIDGE_AGENT_ENGINE["{agent}"]={sq(engine)}',
    f'BRIDGE_AGENT_SESSION["{agent}"]={sq(session)}',
    f'BRIDGE_AGENT_WORKDIR["{agent}"]={sq(workdir)}',
    f'BRIDGE_AGENT_LAUNCH_CMD["{agent}"]={sq(launch_cmd)}',
]
if profile_home:
    lines.append(f'BRIDGE_AGENT_PROFILE_HOME["{agent}"]={sq(profile_home)}')
if channels:
    lines.append(f'BRIDGE_AGENT_CHANNELS["{agent}"]={sq(channels)}')
if discord_channel:
    lines.append(f'BRIDGE_AGENT_DISCORD_CHANNEL_ID["{agent}"]={sq(discord_channel)}')
if notify_kind:
    lines.append(f'BRIDGE_AGENT_NOTIFY_KIND["{agent}"]={sq(notify_kind)}')
if notify_target:
    lines.append(f'BRIDGE_AGENT_NOTIFY_TARGET["{agent}"]={sq(notify_target)}')
if notify_account:
    lines.append(f'BRIDGE_AGENT_NOTIFY_ACCOUNT["{agent}"]={sq(notify_account)}')
if loop_mode == "1":
    lines.append(f'BRIDGE_AGENT_LOOP["{agent}"]="1"')
if continue_mode == "1":
    lines.append(f'BRIDGE_AGENT_CONTINUE["{agent}"]="1"')
else:
    lines.append(f'BRIDGE_AGENT_CONTINUE["{agent}"]="0"')
if always_on == "1":
    lines.append(f'BRIDGE_AGENT_IDLE_TIMEOUT["{agent}"]="0"')
if isolation_mode:
    # Emit the isolation mode verbatim (including "shared") so roster
    # round-trips preserve explicit configuration. Downstream tooling that
    # distinguishes "unset" from "shared" relies on this being present.
    lines.append(f'BRIDGE_AGENT_ISOLATION_MODE["{agent}"]={sq(isolation_mode)}')
if os_user:
    lines.append(f'BRIDGE_AGENT_OS_USER["{agent}"]={sq(os_user)}')
lines.append(end)

block = "\n".join(lines) + "\n"
if text and not text.endswith("\n"):
    text += "\n"
if text and not text.endswith("\n\n"):
    text += "\n"
text += block

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(text, encoding="utf-8")
print(path)
PY
}

emit_create_json() {
  local agent="$1"
  local engine="$2"
  local session="$3"
  local workdir="$4"
  local profile_home="$5"
  local launch_cmd="$6"
  local channels="$7"
  local roster_file="$8"
  local dry_run="$9"
  local users_json="${10}"
  local session_type="${11}"
  local isolation_mode="${12}"
  local os_user="${13}"

  bridge_agent_manage_python "$agent" "$engine" "$session" "$workdir" "$profile_home" "$launch_cmd" "$channels" "$roster_file" "$dry_run" "$users_json" "$session_type" "$isolation_mode" "$os_user" <<'PY'
import json
import sys

agent, engine, session, workdir, profile_home, launch_cmd, channels, roster_file, dry_run, users_json, session_type, isolation_mode, os_user = sys.argv[1:]
payload = {
    "agent": agent,
    "engine": engine,
    "session_type": session_type,
    "session": session,
    "workdir": workdir,
    "profile_home": profile_home,
    "launch_cmd": launch_cmd,
    "channels": channels,
    "isolation": {
        "mode": isolation_mode,
        "os_user": os_user,
    },
    "roster_file": roster_file,
    "dry_run": dry_run == "1",
    "users": json.loads(users_json),
    "next_steps": [
        f"agent-bridge setup agent {agent}",
        f"agent-bridge status --all-agents",
        f"bash bridge-start.sh {agent} --dry-run",
    ],
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

bridge_agent_queue_maps() {
  local -n queued_ref="$1"
  local -n claimed_ref="$2"
  local -n blocked_ref="$3"
  local summary_output=""
  local agent_name=""
  local queued=""
  local claimed=""
  local blocked=""

  if ! summary_output="$(bridge_queue_cli summary --format tsv 2>/dev/null || true)"; then
    return 0
  fi

  while IFS=$'\t' read -r agent_name queued claimed blocked _active _idle _last_seen _last_nudge _session _engine _workdir; do
    [[ -n "$agent_name" ]] || continue
    queued_ref["$agent_name"]="${queued:-0}"
    claimed_ref["$agent_name"]="${claimed:-0}"
    blocked_ref["$agent_name"]="${blocked:-0}"
  done <<<"$summary_output"
}

bridge_agent_activity_state() {
  local agent="$1"
  local session=""

  if ! bridge_agent_is_active "$agent"; then
    printf '%s' "stopped"
    return 0
  fi

  session="$(bridge_agent_session "$agent")"
  if bridge_tmux_session_has_prompt "$session" "$(bridge_agent_engine "$agent")"; then
    printf '%s' "idle"
    return 0
  fi

  printf '%s' "working"
}

bridge_agent_actions_csv() {
  local agent="$1"
  local actions=""

  actions="$(bridge_list_actions "$agent" | paste -sd ',' -)"
  printf '%s' "${actions:--}"
}

bridge_agent_records_tsv() {
  local selected_agent="${1:-}"
  local agent=""
  local active=""
  local profile_home=""
  local profile_source=""
  local always_on=""
  local admin=""
  local -A queued_counts=()
  local -A claimed_counts=()
  local -A blocked_counts=()

  bridge_agent_queue_maps queued_counts claimed_counts blocked_counts
  echo -e "agent\tdescription\tengine\tsource\tsession\tsession_id\tworkdir\tprofile_home\tprofile_source\tactive\tactivity_state\tloop\tcontinue\talways_on\tidle_timeout\twake_status\tnotify_status\tchannel_status\tchannels\tnotify_kind\tnotify_target\tnotify_account\tdiscord_channel_id\tisolation_mode\tos_user\tqueue_queued\tqueue_claimed\tqueue_blocked\tactions\tadmin"

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ -n "$selected_agent" && "$agent" != "$selected_agent" ]]; then
      continue
    fi

    active="no"
    if bridge_agent_is_active "$agent"; then
      active="yes"
    fi

    profile_home="$(bridge_agent_profile_home "$agent")"
    if [[ -z "$profile_home" ]]; then
      profile_home="$(bridge_resolve_profile_target "$agent" 2>/dev/null || true)"
    fi

    profile_source="no"
    if bridge_profile_has_source "$agent"; then
      profile_source="yes"
    fi

    always_on="no"
    if bridge_agent_is_always_on "$agent"; then
      always_on="yes"
    fi

    admin="no"
    if [[ "$agent" == "$(bridge_admin_agent_id)" ]]; then
      admin="yes"
    fi

    echo -e "${agent}\t$(bridge_agent_desc "$agent")\t$(bridge_agent_engine "$agent")\t$(bridge_agent_source "$agent")\t$(bridge_agent_session "$agent")\t$(bridge_agent_session_id "$agent")\t$(bridge_agent_workdir "$agent")\t${profile_home}\t${profile_source}\t${active}\t$(bridge_agent_activity_state "$agent")\t$(bridge_agent_loop "$agent")\t$(bridge_agent_continue "$agent")\t${always_on}\t$(bridge_agent_idle_timeout "$agent")\t$(bridge_agent_wake_status "$agent")\t$(bridge_agent_notify_status "$agent")\t$(bridge_agent_channel_status "$agent")\t$(bridge_agent_channels_csv "$agent")\t$(bridge_agent_notify_kind "$agent")\t$(bridge_agent_notify_target "$agent")\t$(bridge_agent_notify_account "$agent")\t$(bridge_agent_discord_channel_id "$agent")\t$(bridge_agent_isolation_mode "$agent")\t$(bridge_agent_os_user "$agent")\t${queued_counts[$agent]-0}\t${claimed_counts[$agent]-0}\t${blocked_counts[$agent]-0}\t$(bridge_agent_actions_csv "$agent")\t${admin}"
  done
}

emit_agent_records_json() {
  local mode="$1"
  local tsv="$2"

  bridge_agent_manage_python "$mode" "$tsv" <<'PY'
import csv
import io
import json
import sys

mode = sys.argv[1]
rows = list(csv.DictReader(io.StringIO(sys.argv[2]), delimiter="\t"))
bool_fields = {"active", "profile_source", "always_on", "admin"}
int_fields = {"loop", "continue", "idle_timeout", "queue_queued", "queue_claimed", "queue_blocked"}

def convert_value(key: str, value: str):
    if key in bool_fields:
        return value == "yes"
    if key in int_fields:
        try:
            return int(value)
        except Exception:
            return 0
    return value

def convert_row(row: dict) -> dict:
    converted = {key: convert_value(key, value) for key, value in row.items()}
    return {
        "agent": converted["agent"],
        "description": converted["description"],
        "engine": converted["engine"],
        "source": converted["source"],
        "session": converted["session"],
        "session_id": converted["session_id"],
        "workdir": converted["workdir"],
        "profile": {
            "home": converted["profile_home"],
            "source_present": converted["profile_source"],
        },
        "active": converted["active"],
        "activity_state": converted["activity_state"],
        "loop": converted["loop"],
        "continue": converted["continue"],
        "always_on": converted["always_on"],
        "idle_timeout": converted["idle_timeout"],
        "wake_status": converted["wake_status"],
        "notify": {
            "status": converted["notify_status"],
            "kind": converted["notify_kind"],
            "target": converted["notify_target"],
            "account": converted["notify_account"],
        },
        "channels": {
            "status": converted["channel_status"],
            "required": converted["channels"],
            "discord_channel_id": converted["discord_channel_id"],
        },
        "isolation": {
            "mode": converted["isolation_mode"],
            "os_user": converted["os_user"],
        },
        "queue": {
            "queued": converted["queue_queued"],
            "claimed": converted["queue_claimed"],
            "blocked": converted["queue_blocked"],
        },
        "actions": [] if converted["actions"] in ("", "-") else converted["actions"].split(","),
        "admin": converted["admin"],
    }

payload = [convert_row(row) for row in rows]
if mode == "show":
    if len(payload) != 1:
        raise SystemExit("expected exactly one agent record")
    print(json.dumps(payload[0], ensure_ascii=False, indent=2))
else:
    print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

run_list() {
  local json_mode=0
  local output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json_mode=1
        shift
        ;;
      *)
        bridge_die "지원하지 않는 agent list 옵션입니다: $1"
        ;;
    esac
  done

  output="$(bridge_agent_records_tsv)"
  if [[ $json_mode -eq 1 ]]; then
    emit_agent_records_json list "$output"
    return 0
  fi
  bridge_agent_manage_python "$(emit_agent_records_json list "$output")" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
print("agent | eng | src | active | state | iso | q/c/b | wake | notify | chan | session | workdir")
for item in items:
    suffix = " [admin]" if item.get("admin") else ""
    isolation = item.get("isolation", {}) or {}
    mode = isolation.get("mode") or "shared"
    os_user = isolation.get("os_user") or ""
    iso_text = f"{mode}:{os_user}" if os_user else mode
    queue = item.get("queue", {}) or {}
    notify = item.get("notify", {}) or {}
    channels = item.get("channels", {}) or {}
    print(
        f"{item.get('agent','')}{suffix} | "
        f"{item.get('engine','')} | "
        f"{item.get('source','')} | "
        f"{'yes' if item.get('active') else 'no'} | "
        f"{item.get('activity_state','')} | "
        f"{iso_text} | "
        f"{queue.get('queued',0)}/{queue.get('claimed',0)}/{queue.get('blocked',0)} | "
        f"{item.get('wake_status','')} | "
        f"{notify.get('status','')} | "
        f"{channels.get('status','')} | "
        f"{item.get('session','')} | "
        f"{item.get('workdir','')}"
    )
PY
}

run_show() {
  local agent="${1:-}"
  local json_mode=0
  local output=""

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") show <agent> [--json]"
  bridge_require_agent "$agent"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json_mode=1
        shift
        ;;
      *)
        bridge_die "지원하지 않는 agent show 옵션입니다: $1"
        ;;
    esac
  done

  output="$(bridge_agent_records_tsv "$agent")"
  if [[ $json_mode -eq 1 ]]; then
    bridge_agent_manage_python \
      "$(emit_agent_records_json show "$output")" \
      "$(bridge_agent_channel_diagnostics_json "$agent")" \
      "$(bridge_agent_session_health_json "$agent")" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload.setdefault("channels", {})["diagnostics"] = json.loads(sys.argv[2])
payload["session_health"] = json.loads(sys.argv[3])
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
    return 0
  fi

  while IFS=$'\t' read -r row_agent description engine source session session_id workdir profile_home profile_source active activity_state loop_mode continue_mode always_on idle_timeout wake_status notify_status channel_status channels notify_kind notify_target notify_account discord_channel_id isolation_mode os_user queue_queued queue_claimed queue_blocked actions admin; do
    [[ "$row_agent" == "agent" ]] && continue
    printf 'agent: %s\n' "$row_agent"
    printf 'description: %s\n' "$description"
    printf 'engine: %s\n' "$engine"
    printf 'source: %s\n' "$source"
    printf 'admin: %s\n' "$admin"
    printf 'session: %s\n' "$session"
    printf 'session_id: %s\n' "${session_id:--}"
    printf 'workdir: %s\n' "$workdir"
    printf 'profile_home: %s\n' "${profile_home:--}"
    printf 'profile_source: %s\n' "$profile_source"
    printf 'active: %s\n' "$active"
    printf 'activity_state: %s\n' "$activity_state"
    printf 'loop: %s\n' "$loop_mode"
    printf 'continue: %s\n' "$continue_mode"
    printf 'always_on: %s\n' "$always_on"
    printf 'idle_timeout: %s\n' "$idle_timeout"
    printf 'wake_status: %s\n' "$wake_status"
    printf 'notify_status: %s\n' "$notify_status"
    printf 'notify_kind: %s\n' "${notify_kind:--}"
    printf 'notify_target: %s\n' "${notify_target:--}"
    printf 'notify_account: %s\n' "${notify_account:--}"
    printf 'channel_status: %s\n' "$channel_status"
    printf 'channels: %s\n' "${channels:--}"
    printf 'discord_channel_id: %s\n' "${discord_channel_id:--}"
    printf 'isolation_mode: %s\n' "${isolation_mode:--}"
    printf 'os_user: %s\n' "${os_user:--}"
    printf 'queue: queued=%s claimed=%s blocked=%s\n' "$queue_queued" "$queue_claimed" "$queue_blocked"
    printf 'actions: %s\n' "$actions"
    printf 'channel_diagnostics:\n'
    bridge_agent_channel_diagnostics_text "$agent" | sed 's/^/  /'
    printf 'session_health:\n'
    bridge_agent_session_guidance_text "$agent" | sed 's/^/  /'
  done <<<"$output"
}

run_create() {
  local agent="${1:-}"
  local engine="claude"
  local session_type=""
  local session=""
  local workdir=""
  local profile_home=""
  local description=""
  local display_name=""
  local role_text=""
  local launch_cmd=""
  local channels=""
  local discord_channel=""
  local notify_kind=""
  local notify_target=""
  local notify_account=""
  local isolation_mode="shared"
  local os_user=""
  local loop_mode=0
  local continue_mode=1
  local always_on=0
  local dry_run=0
  local json_mode=0
  local user_specs=()
  local users_json=""
  local default_home=""
  local start_dry_run=""

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") create <agent> [...]"
  bridge_validate_agent_name "$agent" || bridge_die "에이전트 이름은 영문/숫자/._- 만 사용할 수 있습니다: $agent"
  if bridge_agent_exists "$agent"; then
    bridge_die "이미 등록된 에이전트입니다: $agent"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --engine)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        engine="$2"
        shift 2
        ;;
      --session)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        session="$2"
        shift 2
        ;;
      --workdir)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        workdir="$2"
        shift 2
        ;;
      --profile-home)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        profile_home="$2"
        shift 2
        ;;
      --description)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        description="$2"
        shift 2
        ;;
      --display-name)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        display_name="$2"
        shift 2
        ;;
      --role)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        role_text="$2"
        shift 2
        ;;
      --session-type)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        session_type="$2"
        shift 2
        ;;
      --user)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        user_specs+=("$2")
        shift 2
        ;;
      --launch-cmd)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        launch_cmd="$2"
        shift 2
        ;;
      --channels)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        channels="$2"
        shift 2
        ;;
      --discord-channel)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        discord_channel="$2"
        shift 2
        ;;
      --notify-kind)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        notify_kind="$2"
        shift 2
        ;;
      --notify-target)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        notify_target="$2"
        shift 2
        ;;
      --notify-account)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        notify_account="$2"
        shift 2
        ;;
      --isolation)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        isolation_mode="$2"
        shift 2
        ;;
      --isolate)
        isolation_mode="linux-user"
        shift
        ;;
      --os-user)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        os_user="$2"
        shift 2
        ;;
      --loop)
        loop_mode=1
        shift
        ;;
      --always-on)
        always_on=1
        shift
        ;;
      --continue)
        continue_mode=1
        shift
        ;;
      --no-continue)
        continue_mode=0
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --json)
        json_mode=1
        shift
        ;;
      *)
        bridge_die "지원하지 않는 agent create 옵션입니다: $1"
        ;;
    esac
  done

  case "$engine" in
    claude|codex) ;;
    *) bridge_die "지원하지 않는 engine 입니다: $engine" ;;
  esac

  if [[ -z "$session_type" ]]; then
    case "$engine" in
      claude) session_type="static-claude" ;;
      codex) session_type="static-codex" ;;
    esac
  fi
  case "$session_type" in
    admin|static-claude|static-codex|dynamic|cron) ;;
    *) bridge_die "지원하지 않는 session type 입니다: $session_type" ;;
  esac
  case "$isolation_mode" in
    shared|linux-user) ;;
    *) bridge_die "지원하지 않는 isolation mode 입니다: $isolation_mode" ;;
  esac

  if [[ "$isolation_mode" == "shared" && -n "$os_user" ]]; then
    bridge_die "--os-user 는 --isolation linux-user 와 함께만 사용할 수 있습니다."
  fi

  session="${session:-$agent}"
  default_home="$(bridge_agent_default_home "$agent")"
  workdir="$(bridge_expand_user_path "${workdir:-$default_home}")"
  profile_home="$(bridge_expand_user_path "${profile_home:-}")"
  description="${description:-$agent static role}"
  display_name="${display_name:-$agent}"
  role_text="${role_text:-Long-lived agent role}"
  launch_cmd="${launch_cmd:-$(bridge_agent_default_launch_cmd "$engine")}"
  channels="$(bridge_normalize_channels_csv "$channels")"
  users_json="$(bridge_normalize_user_specs_json "${user_specs[@]}")"
  if [[ "$isolation_mode" == "linux-user" ]]; then
    if [[ "$(bridge_host_platform)" != "Linux" ]]; then
      bridge_warn "linux-user isolation은 Linux 전용입니다. 현재 호스트에서는 shared mode로 생성합니다."
      isolation_mode="shared"
      os_user=""
    else
      os_user="${os_user:-$(bridge_agent_default_os_user "$agent")}"
    fi
  fi

  default_home="$(bridge_expand_user_path "$default_home")"
  if [[ -z "$profile_home" && "$workdir" != "$default_home" ]]; then
    profile_home="$workdir"
  fi

  if [[ "$isolation_mode" == "linux-user" ]]; then
    local existing_agent=""
    local existing_workdir=""
    for existing_agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$existing_agent" == "$agent" ]] && continue
      existing_workdir="$(bridge_agent_workdir "$existing_agent")"
      [[ -n "$existing_workdir" ]] || continue
      if [[ "$(bridge_expand_user_path "$existing_workdir")" == "$workdir" ]]; then
        bridge_die "linux-user isolation에서는 workdir를 다른 에이전트와 공유할 수 없습니다: ${existing_agent} -> ${workdir}"
      fi
    done
  fi

  if [[ $dry_run -eq 0 ]]; then
    if [[ -e "$workdir" ]]; then
      if [[ -d "$workdir" ]] && [[ -z "$(find "$workdir" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]]; then
        :
      elif [[ -d "$workdir" && -f "$workdir/CLAUDE.md" ]]; then
        :
      else
        bridge_die "workdir가 이미 존재하고 비어 있지 않습니다: $workdir"
      fi
    fi
    bridge_scaffold_agent_home "$agent" "$workdir" "$display_name" "$role_text" "$engine" "$session_type"
    bridge_scaffold_user_partitions "$workdir" "$users_json"
    if [[ "$engine" == "claude" ]]; then
      bridge_ensure_project_claude_guidance "$workdir" >/dev/null 2>&1 || true
    fi
    bridge_bootstrap_project_skill "$engine" "$workdir" >/dev/null 2>&1 || true
    if [[ "$engine" == "claude" ]]; then
      bridge_bootstrap_claude_shared_skills "$agent" "$workdir" >/dev/null 2>&1 || true
      # Plan-D memory stack: ensure PreCompact hook at scaffold time so new
      # agents come up fully wired without a separate bootstrap pass.
      bridge_ensure_memory_precompact_hook "$agent" "$workdir" >/dev/null 2>&1 || true
    fi
    bridge_write_role_block \
      "$agent" \
      "$description" \
      "$engine" \
      "$session" \
      "$workdir" \
      "$profile_home" \
      "$launch_cmd" \
      "$channels" \
      "$discord_channel" \
      "$notify_kind" \
      "$notify_target" \
      "$notify_account" \
      "$loop_mode" \
      "$continue_mode" \
      "$always_on" \
      "$isolation_mode" \
      "$os_user" >/dev/null
    bridge_load_roster
    bridge_sync_skill_docs "$agent" >/dev/null 2>&1 || true
    if [[ "$isolation_mode" == "linux-user" ]]; then
      bridge_linux_prepare_agent_isolation "$agent" "$os_user" "$workdir"
    fi
    start_dry_run="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --dry-run 2>&1)"
  fi

  if [[ $json_mode -eq 1 ]]; then
    emit_create_json "$agent" "$engine" "$session" "$workdir" "$profile_home" "$launch_cmd" "$channels" "$BRIDGE_ROSTER_LOCAL_FILE" "$dry_run" "$users_json" "$session_type" "$isolation_mode" "$os_user"
    exit 0
  fi

  printf 'agent: %s\n' "$agent"
  printf 'engine: %s\n' "$engine"
  printf 'session_type: %s\n' "$session_type"
  printf 'session: %s\n' "$session"
  printf 'workdir: %s\n' "$workdir"
  if [[ -n "$profile_home" ]]; then
    printf 'profile_home: %s\n' "$profile_home"
  fi
  printf 'launch_cmd: %s\n' "$launch_cmd"
  printf 'users: %s\n' "$users_json"
  if [[ -n "$channels" ]]; then
    printf 'channels: %s\n' "$channels"
  fi
  printf 'isolation_mode: %s\n' "$isolation_mode"
  if [[ -n "$os_user" ]]; then
    printf 'os_user: %s\n' "$os_user"
  fi
  printf 'roster_file: %s\n' "$BRIDGE_ROSTER_LOCAL_FILE"
  if [[ $always_on -eq 1 ]]; then
    echo "always_on: yes"
  fi
  if [[ $dry_run -eq 1 ]]; then
    echo "dry_run: yes"
  else
    echo "create: ok"
    echo "start_dry_run: ok"
    echo "$start_dry_run"
    echo "next_steps:"
    echo "  - agent-bridge setup agent $agent"
    echo "  - agent-bridge status --all-agents"
  fi
}

run_start() {
  local agent="${1:-}"
  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") start <agent> [...]"
  bridge_require_agent "$agent"
  exec "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" "$@"
}

run_safe_mode() {
  local agent="${1:-}"
  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") safe-mode <agent> [...]"
  bridge_require_agent "$agent"
  exec "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --safe-mode "$@"
}

run_stop() {
  local agent="${1:-}"
  local session=""

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") stop <agent>"
  [[ $# -eq 0 ]] || bridge_die "지원하지 않는 agent stop 옵션입니다: $1"
  bridge_require_agent "$agent"
  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || bridge_die "세션 이름이 없습니다: $agent"
  if ! bridge_tmux_session_exists "$session"; then
    printf '[info] 에이전트 "%s" 세션이 이미 중지된 상태입니다.\n' "$agent"
    return 0
  fi
  bridge_manual_stop_agent_session "$agent"
  bridge_refresh_runtime_state
  printf 'stopped: %s\n' "$agent"
}

run_restart() {
  local agent="${1:-}"
  local session=""
  local start_args=()
  local attach_mode=0
  local dry_run_mode=0
  local engine=""
  local launch_channels=""
  local preflight_reason=""
  # Default raised from 12s to 30s: measured teams-plugin cold-start on a
  # healthy host is ~14s, 12s lost the race deterministically (issue #69
  # Defect B). Operators can still override via the env var.
  local verify_timeout="${BRIDGE_AGENT_RESTART_CHANNEL_VERIFY_SECONDS:-30}"
  # Kill-on-repeated-fail threshold: how many consecutive banner-verify
  # timeouts before we stop the session and let the daemon's cooldown retry
  # later. Previously hardcoded at 2, which combined with a too-short
  # timeout created a death loop (issue #69 Defect C). Default 5.
  local verify_max_attempts="${BRIDGE_AGENT_RESTART_CHANNEL_VERIFY_MAX_ATTEMPTS:-5}"
  local verify_attempts=0

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") restart <agent> [...]"
  bridge_require_agent "$agent"
  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || bridge_die "세션 이름이 없습니다: $agent"
  engine="$(bridge_agent_engine "$agent")"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --attach)
        attach_mode=1
        start_args+=("$1")
        shift
        ;;
      --no-attach)
        attach_mode=0
        shift
        ;;
      --continue|--no-continue|--dry-run)
        if [[ "$1" == "--dry-run" ]]; then
          dry_run_mode=1
        fi
        start_args+=("$1")
        shift
        ;;
      *)
        bridge_die "지원하지 않는 agent restart 옵션입니다: $1"
        ;;
    esac
  done

  if [[ ! " ${start_args[*]} " =~ [[:space:]]--attach[[:space:]] ]] && [[ $attach_mode -eq 0 ]]; then
    :
  fi

  if [[ $dry_run_mode -eq 1 ]]; then
    exec "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --replace "${start_args[@]}"
  fi

  preflight_reason="$(bridge_agent_restart_preflight_reason "$agent")"
  if [[ -n "$preflight_reason" ]]; then
    bridge_die "$(bridge_agent_restart_preflight_guidance "$agent" "$preflight_reason")"
  fi

  if bridge_tmux_session_exists "$session"; then
    bridge_kill_agent_session "$agent"
    bridge_refresh_runtime_state
  fi

  if [[ $attach_mode -eq 1 ]]; then
    exec "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --replace "${start_args[@]}"
  fi

  restart_once() {
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --replace "${start_args[@]}"
  }

  if ! restart_once; then
    return 1
  fi

  if [[ "$engine" != "claude" ]]; then
    return 0
  fi

  launch_channels="$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"

  [[ "$verify_max_attempts" =~ ^[0-9]+$ ]] || verify_max_attempts=5
  (( verify_max_attempts >= 1 )) || verify_max_attempts=1

  verify_attempts=1
  # Verify via descendant process probe (issue #143). The banner-based
  # verifier read only the last 80 tmux lines, so busy sessions (`--resume`
  # + `/compact` + first task dispatch) scrolled the startup banner off
  # within seconds and restart verify kept returning failure even when
  # every plugin bun was alive. Align with the daemon's steady-state
  # liveness check so the two signals no longer disagree.
  if bridge_tmux_wait_for_claude_plugin_mcp_alive "$agent" "$verify_timeout"; then
    return 0
  fi

  # Retry with fresh sessions up to verify_max_attempts total. Keep going
  # only while the session restarts cleanly. If we exhaust attempts without
  # the plugin MCP coming alive, leave the session running and return
  # non-zero so the daemon's next cooldown cycle can take another look.
  # Previously we killed the session after 2 attempts, which — combined
  # with the too-short 12s default timeout and reparented bun holding the
  # port — produced the observed permanent death loop (issue #69 Defect C).
  while (( verify_attempts < verify_max_attempts )); do
    verify_attempts=$(( verify_attempts + 1 ))
    bridge_warn "Claude plugin MCP liveness missing after restart for '$agent' (attempt ${verify_attempts}/${verify_max_attempts}). Retrying with a fresh session."
    if bridge_tmux_session_exists "$session"; then
      bridge_kill_agent_session "$agent" >/dev/null 2>&1 || true
      bridge_refresh_runtime_state
    fi
    if ! restart_once; then
      return 1
    fi
    if bridge_tmux_wait_for_claude_plugin_mcp_alive "$agent" "$verify_timeout"; then
      return 0
    fi
  done

  bridge_warn "Claude plugin MCP liveness still missing after ${verify_max_attempts} attempts for '$agent'. Leaving the session alive so the daemon's next cycle can re-check (avoids the plugin-port death loop from issue #69)."
  return 1
}

run_ack_crash() {
  local agent="${1:-}"

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") ack-crash <agent>"
  [[ $# -eq 0 ]] || bridge_die "지원하지 않는 agent ack-crash 옵션입니다: $1"
  bridge_require_agent "$agent"
  if bridge_agent_ack_crash_report "$agent"; then
    printf 'ack-crash: %s\n' "$agent"
  else
    bridge_die "ack-crash failed: no crash report or state available for '$agent'"
  fi
}

run_attach() {
  local agent="${1:-}"

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") attach <agent>"
  [[ $# -eq 0 ]] || bridge_die "지원하지 않는 agent attach 옵션입니다: $1"
  bridge_require_agent "$agent"
  exec "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/agent-bridge" attach "$agent"
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  create)
    run_create "$@"
    ;;
  list)
    run_list "$@"
    ;;
  show)
    run_show "$@"
    ;;
  start)
    run_start "$@"
    ;;
  safe-mode)
    run_safe_mode "$@"
    ;;
  stop)
    run_stop "$@"
    ;;
  restart)
    run_restart "$@"
    ;;
  ack-crash)
    run_ack_crash "$@"
    ;;
  attach)
    run_attach "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 agent 명령입니다: $subcommand"
    ;;
esac
