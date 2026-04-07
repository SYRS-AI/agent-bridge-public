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
  $(basename "$0") start <agent> [--attach] [--replace] [--continue|--no-continue] [--dry-run]
  $(basename "$0") stop <agent>
  $(basename "$0") restart <agent> [--attach] [--continue|--no-continue] [--dry-run]
  $(basename "$0") attach <agent>

Options:
  --engine claude|codex        Agent runtime engine (default: claude)
  --session <name>             tmux session name (default: <agent>)
  --workdir <path>             live home / workdir (default: \$BRIDGE_AGENT_HOME_ROOT/<agent>)
  --profile-home <path>        tracked profile target when different from workdir
  --description <text>         roster description
  --display-name <text>        scaffold display name (default: <agent>)
  --role <text>                scaffold role summary
  --launch-cmd <cmd>           explicit launch command
  --channels <csv>             required Claude channels metadata
  --discord-channel <id>       primary Discord channel metadata
  --notify-kind <kind>         out-of-band notify transport metadata
  --notify-target <target>     notify target metadata
  --notify-account <account>   notify account metadata
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
  $(basename "$0") stop reviewer
  $(basename "$0") attach reviewer
EOF
}

bridge_agent_manage_python() {
  bridge_require_python
  python3 - "$@"
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

  bridge_agent_manage_python "$source_file" "$agent_id" "$display_name" "$role_text" "$engine" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
agent_id, display_name, role_text, engine = sys.argv[2:]
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
  local template_root="$SCRIPT_DIR/agents/_template"
  local file=""
  local rel=""
  local target=""

  mkdir -p "$home"
  [[ -d "$template_root" ]] || bridge_die "agent template root가 없습니다: $template_root"

  while IFS= read -r file; do
    rel="${file#"$template_root"/}"
    target="$home/$rel"
    mkdir -p "$(dirname "$target")"
    if [[ -e "$target" ]]; then
      continue
    fi
    bridge_render_template_string "$file" "$agent" "$display_name" "$role_text" "$engine" >"$target"
  done < <(find "$template_root" -type f | LC_ALL=C sort)

  while IFS= read -r rel; do
    mkdir -p "$home/$rel"
  done < <(cd "$template_root" && find . -type d | sed 's#^\./##' | grep -v '^$' | LC_ALL=C sort)
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
    "$always_on" <<'PY'
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

  bridge_agent_manage_python "$agent" "$engine" "$session" "$workdir" "$profile_home" "$launch_cmd" "$channels" "$roster_file" "$dry_run" <<'PY'
import json
import sys

agent, engine, session, workdir, profile_home, launch_cmd, channels, roster_file, dry_run = sys.argv[1:]
payload = {
    "agent": agent,
    "engine": engine,
    "session": session,
    "workdir": workdir,
    "profile_home": profile_home,
    "launch_cmd": launch_cmd,
    "channels": channels,
    "roster_file": roster_file,
    "dry_run": dry_run == "1",
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
  echo -e "agent\tdescription\tengine\tsource\tsession\tsession_id\tworkdir\tprofile_home\tprofile_source\tactive\tactivity_state\tloop\tcontinue\talways_on\tidle_timeout\twake_status\tnotify_status\tchannel_status\tchannels\tnotify_kind\tnotify_target\tnotify_account\tdiscord_channel_id\tqueue_queued\tqueue_claimed\tqueue_blocked\tactions\tadmin"

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

    echo -e "${agent}\t$(bridge_agent_desc "$agent")\t$(bridge_agent_engine "$agent")\t$(bridge_agent_source "$agent")\t$(bridge_agent_session "$agent")\t$(bridge_agent_session_id "$agent")\t$(bridge_agent_workdir "$agent")\t${profile_home}\t${profile_source}\t${active}\t$(bridge_agent_activity_state "$agent")\t$(bridge_agent_loop "$agent")\t$(bridge_agent_continue "$agent")\t${always_on}\t$(bridge_agent_idle_timeout "$agent")\t$(bridge_agent_wake_status "$agent")\t$(bridge_agent_notify_status "$agent")\t$(bridge_agent_channel_status "$agent")\t$(bridge_agent_channels_csv "$agent")\t$(bridge_agent_notify_kind "$agent")\t$(bridge_agent_notify_target "$agent")\t$(bridge_agent_notify_account "$agent")\t$(bridge_agent_discord_channel_id "$agent")\t${queued_counts[$agent]-0}\t${claimed_counts[$agent]-0}\t${blocked_counts[$agent]-0}\t$(bridge_agent_actions_csv "$agent")\t${admin}"
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

  printf 'agent | eng | src | active | state | q/c/b | wake | notify | chan | session | workdir\n'
  while IFS=$'\t' read -r agent _description engine source session _session_id workdir _profile_home _profile_source active activity_state _loop _continue always_on _idle_timeout wake_status notify_status channel_status _channels _notify_kind _notify_target _notify_account _discord_channel_id queue_queued queue_claimed queue_blocked _actions admin; do
    [[ "$agent" == "agent" ]] && continue
    printf '%s%s | %s | %s | %s | %s | %s/%s/%s | %s | %s | %s | %s | %s\n' \
      "$agent" \
      "$([[ "$admin" == "yes" ]] && printf ' [admin]' || true)" \
      "$engine" \
      "$source" \
      "$active" \
      "$activity_state" \
      "$queue_queued" \
      "$queue_claimed" \
      "$queue_blocked" \
      "$wake_status" \
      "$notify_status" \
      "$channel_status" \
      "$session" \
      "$workdir"
  done <<<"$output"
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
    emit_agent_records_json show "$output"
    return 0
  fi

  while IFS=$'\t' read -r row_agent description engine source session session_id workdir profile_home profile_source active activity_state loop_mode continue_mode always_on idle_timeout wake_status notify_status channel_status channels notify_kind notify_target notify_account discord_channel_id queue_queued queue_claimed queue_blocked actions admin; do
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
    printf 'queue: queued=%s claimed=%s blocked=%s\n' "$queue_queued" "$queue_claimed" "$queue_blocked"
    printf 'actions: %s\n' "$actions"
  done <<<"$output"
}

run_create() {
  local agent="${1:-}"
  local engine="claude"
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
  local loop_mode=0
  local continue_mode=1
  local always_on=0
  local dry_run=0
  local json_mode=0
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

  session="${session:-$agent}"
  default_home="$(bridge_agent_default_home "$agent")"
  workdir="$(bridge_expand_user_path "${workdir:-$default_home}")"
  profile_home="$(bridge_expand_user_path "${profile_home:-}")"
  description="${description:-$agent static role}"
  display_name="${display_name:-$agent}"
  role_text="${role_text:-Long-lived agent role}"
  launch_cmd="${launch_cmd:-$(bridge_agent_default_launch_cmd "$engine")}"
  channels="$(bridge_normalize_channels_csv "$channels")"

  default_home="$(bridge_expand_user_path "$default_home")"
  if [[ -z "$profile_home" && "$workdir" != "$default_home" ]]; then
    profile_home="$workdir"
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
    bridge_scaffold_agent_home "$agent" "$workdir" "$display_name" "$role_text" "$engine"
    bridge_bootstrap_project_skill "$engine" "$workdir" >/dev/null 2>&1 || true
    if [[ "$engine" == "claude" ]]; then
      bridge_bootstrap_claude_shared_skills "$workdir" >/dev/null 2>&1 || true
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
      "$always_on" >/dev/null
    bridge_load_roster
    start_dry_run="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --dry-run 2>&1)"
  fi

  if [[ $json_mode -eq 1 ]]; then
    emit_create_json "$agent" "$engine" "$session" "$workdir" "$profile_home" "$launch_cmd" "$channels" "$BRIDGE_ROSTER_LOCAL_FILE" "$dry_run"
    exit 0
  fi

  printf 'agent: %s\n' "$agent"
  printf 'engine: %s\n' "$engine"
  printf 'session: %s\n' "$session"
  printf 'workdir: %s\n' "$workdir"
  if [[ -n "$profile_home" ]]; then
    printf 'profile_home: %s\n' "$profile_home"
  fi
  printf 'launch_cmd: %s\n' "$launch_cmd"
  if [[ -n "$channels" ]]; then
    printf 'channels: %s\n' "$channels"
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
    bridge_die "에이전트 '$agent' 세션이 존재하지 않습니다."
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

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") restart <agent> [...]"
  bridge_require_agent "$agent"
  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || bridge_die "세션 이름이 없습니다: $agent"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --attach)
        attach_mode=1
        start_args+=("$1")
        shift
        ;;
      --continue|--no-continue|--dry-run)
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

  if bridge_tmux_session_exists "$session"; then
    bridge_kill_agent_session "$agent"
    bridge_refresh_runtime_state
  fi
  exec "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --replace "${start_args[@]}"
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
  stop)
    run_stop "$@"
    ;;
  restart)
    run_restart "$@"
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
