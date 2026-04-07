#!/usr/bin/env bash
# bridge-init.sh — bootstrap a manager/admin role for a fresh Agent Bridge install

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--admin <agent>] [--engine claude|codex] [--session <name>] [--workdir <path>] [--channels <csv>] [--discord-channel <id>]... [--allow-from <id>]... [--default-chat <id>] [--channel-account <account>] [--runtime-config <path>] [--api-base-url <url>] [--skip-validate] [--skip-send-test] [--skip-channel-setup] [--test-start] [--dry-run] [--json]

Examples:
  $(basename "$0") --admin patch --engine claude --channels plugin:telegram --allow-from 123456789 --default-chat 123456789 --channel-account default
  $(basename "$0") --admin manager --engine codex --dry-run --json
EOF
}

bridge_init_emit_json() {
  local admin="$1"
  local engine="$2"
  local session="$3"
  local workdir="$4"
  local channels="$5"
  local created="$6"
  local channel_setup="$7"
  local preflight="$8"
  local admin_saved="$9"
  local dry_run="${10}"
  local warnings_json="${11}"

  bridge_require_python
  python3 - "$admin" "$engine" "$session" "$workdir" "$channels" "$created" "$channel_setup" "$preflight" "$admin_saved" "$dry_run" "$warnings_json" <<'PY'
import json
import sys

admin, engine, session, workdir, channels, created, channel_setup, preflight, admin_saved, dry_run, warnings_json = sys.argv[1:]
payload = {
    "admin": admin,
    "engine": engine,
    "session": session,
    "workdir": workdir,
    "channels": channels,
    "created": created == "1",
    "channel_setup": channel_setup,
    "preflight": preflight,
    "admin_saved": admin_saved == "1",
    "dry_run": dry_run == "1",
    "warnings": json.loads(warnings_json),
    "next_command": "agent-bridge admin" if admin_saved == "1" else "",
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

bridge_init_require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || bridge_die "필수 명령을 찾지 못했습니다: $cmd"
}

bridge_init_runtime_present() {
  local kind="$1"
  local agent="$2"

  case "$kind" in
    discord)
      [[ -f "$(bridge_agent_discord_state_dir "$agent")/.env" && -f "$(bridge_agent_discord_state_dir "$agent")/access.json" ]]
      ;;
    telegram)
      [[ -f "$(bridge_agent_telegram_state_dir "$agent")/.env" && -f "$(bridge_agent_telegram_state_dir "$agent")/access.json" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_init_append_warning() {
  local message="$1"
  WARNINGS+=("$message")
}

bridge_init_warnings_json() {
  bridge_require_python
  python3 - "${WARNINGS[@]}" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1:], ensure_ascii=False))
PY
}

admin_agent="${BRIDGE_ADMIN_AGENT_ID:-admin}"
engine="claude"
session=""
workdir=""
profile_home=""
display_name=""
role_text="Manager/admin role"
description=""
channels=""
channel_account=""
runtime_config="$HOME/.agent-bridge/runtime/bridge-config.json"
skip_channel_setup=0
test_start=0
dry_run=0
json_mode=0
always_on=1
skip_validate=0
skip_send_test=0
channel_setup_status="skipped"
preflight_status="skipped"
admin_saved=0
created=0
WARNINGS=()
discord_channels=()
telegram_allow_from=()
default_chat=""
notify_kind=""
notify_target=""
notify_account=""
api_base_url=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      admin_agent="$2"
      shift 2
      ;;
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
    --description)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      description="$2"
      shift 2
      ;;
    --channels)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      channels="$2"
      shift 2
      ;;
    --discord-channel)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      discord_channels+=("$2")
      shift 2
      ;;
    --allow-from)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      telegram_allow_from+=("$2")
      shift 2
      ;;
    --default-chat)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      default_chat="$2"
      shift 2
      ;;
    --channel-account|--openclaw-account)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      channel_account="$2"
      shift 2
      ;;
    --runtime-config|--openclaw-config)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      runtime_config="$2"
      shift 2
      ;;
    --api-base-url)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      api_base_url="$2"
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
    --skip-channel-setup)
      skip_channel_setup=1
      shift
      ;;
    --skip-validate)
      skip_validate=1
      shift
      ;;
    --skip-send-test)
      skip_send_test=1
      shift
      ;;
    --test-start)
      test_start=1
      shift
      ;;
    --always-on)
      always_on=1
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
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      bridge_die "지원하지 않는 init 옵션입니다: $1"
      ;;
  esac
done

case "$engine" in
  claude|codex) ;;
  *) bridge_die "지원하지 않는 engine 입니다: $engine" ;;
esac

session="${session:-$admin_agent}"
description="${description:-$admin_agent admin role}"
display_name="${display_name:-$admin_agent}"
channels="$(bridge_normalize_channels_csv "$channels")"

bridge_init_require_command tmux
bridge_init_require_command python3
bridge_init_require_command "$engine"

if bridge_agent_exists "$admin_agent"; then
  bridge_require_static_agent "$admin_agent"
else
  create_args=(agent create "$admin_agent" --engine "$engine" --session "$session" --display-name "$display_name" --role "$role_text" --description "$description")
  [[ -n "$workdir" ]] && create_args+=(--workdir "$workdir")
  [[ -n "$profile_home" ]] && create_args+=(--profile-home "$profile_home")
  [[ -n "$channels" ]] && create_args+=(--channels "$channels")
  [[ -n "$notify_kind" ]] && create_args+=(--notify-kind "$notify_kind")
  [[ -n "$notify_target" ]] && create_args+=(--notify-target "$notify_target")
  [[ -n "$notify_account" ]] && create_args+=(--notify-account "$notify_account")
  if [[ $always_on -eq 1 ]]; then
    create_args+=(--always-on)
  fi
  if [[ $dry_run -eq 1 ]]; then
    create_args+=(--dry-run)
  fi
  "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/agent-bridge" "${create_args[@]}" >/dev/null
  created=1
  if [[ $dry_run -eq 0 ]]; then
    bridge_load_roster
  fi
fi

if [[ $skip_channel_setup -eq 0 ]] && [[ $dry_run -eq 0 ]]; then
  channel_setup_status="ok"
  if bridge_channel_csv_contains "$channels" "plugin:discord"; then
    if ((${#discord_channels[@]} > 0)) || [[ -n "$channel_account" ]] || bridge_init_runtime_present discord "$admin_agent"; then
      setup_args=(discord "$admin_agent")
      for item in "${discord_channels[@]}"; do
        setup_args+=(--channel "$item")
      done
      [[ -n "$channel_account" ]] && setup_args+=(--channel-account "$channel_account")
      [[ -n "$runtime_config" ]] && setup_args+=(--runtime-config "$runtime_config")
      [[ -n "$api_base_url" ]] && setup_args+=(--api-base-url "$api_base_url")
      [[ $skip_validate -eq 1 ]] && setup_args+=(--skip-validate)
      [[ $skip_send_test -eq 1 ]] && setup_args+=(--skip-send-test)
      setup_args+=(--yes)
      "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-setup.sh" "${setup_args[@]}" >/dev/null
    else
      channel_setup_status="partial"
      bridge_init_append_warning "Discord channel setup skipped: no existing runtime, channel ids, or --channel-account provided."
    fi
  fi
  if bridge_channel_csv_contains "$channels" "plugin:telegram"; then
    if ((${#telegram_allow_from[@]} > 0)) || [[ -n "$channel_account" ]] || bridge_init_runtime_present telegram "$admin_agent"; then
      setup_args=(telegram "$admin_agent")
      for item in "${telegram_allow_from[@]}"; do
        setup_args+=(--allow-from "$item")
      done
      [[ -n "$default_chat" ]] && setup_args+=(--default-chat "$default_chat")
      [[ -n "$channel_account" ]] && setup_args+=(--channel-account "$channel_account")
      [[ -n "$runtime_config" ]] && setup_args+=(--runtime-config "$runtime_config")
      [[ -n "$api_base_url" ]] && setup_args+=(--api-base-url "$api_base_url")
      [[ $skip_validate -eq 1 ]] && setup_args+=(--skip-validate)
      [[ $skip_send_test -eq 1 ]] && setup_args+=(--skip-send-test)
      setup_args+=(--yes)
      "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-setup.sh" "${setup_args[@]}" >/dev/null
    else
      channel_setup_status="partial"
      bridge_init_append_warning "Telegram channel setup skipped: no existing runtime, allow_from ids, or --channel-account provided."
    fi
  fi
fi

if [[ $dry_run -eq 0 ]]; then
  preflight_args=(agent "$admin_agent" --skip-discord --skip-telegram)
  if [[ $test_start -eq 1 ]]; then
    preflight_args+=(--test-start)
  fi
  "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-setup.sh" "${preflight_args[@]}" >/dev/null
  preflight_status="ok"
  "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-setup.sh" admin "$admin_agent" >/dev/null
  admin_saved=1
else
  preflight_status="dry-run"
fi

final_engine="${BRIDGE_AGENT_ENGINE[$admin_agent]-$engine}"
final_session="${BRIDGE_AGENT_SESSION[$admin_agent]-$session}"
final_workdir="${BRIDGE_AGENT_WORKDIR[$admin_agent]-${workdir:-$(bridge_agent_default_home "$admin_agent")}}"
warnings_json="$(bridge_init_warnings_json)"

if [[ $json_mode -eq 1 ]]; then
  bridge_init_emit_json \
    "$admin_agent" \
    "$final_engine" \
    "$final_session" \
    "$final_workdir" \
    "$channels" \
    "$created" \
    "$channel_setup_status" \
    "$preflight_status" \
    "$admin_saved" \
    "$dry_run" \
    "$warnings_json"
  exit 0
fi

echo "== Bridge init =="
printf 'admin_agent: %s\n' "$admin_agent"
printf 'engine: %s\n' "$final_engine"
printf 'session: %s\n' "$final_session"
printf 'workdir: %s\n' "$final_workdir"
printf 'channels: %s\n' "${channels:-"(none)"}"
printf 'created: %s\n' "$([[ $created -eq 1 ]] && echo yes || echo no)"
printf 'channel_setup: %s\n' "$channel_setup_status"
printf 'preflight: %s\n' "$preflight_status"
printf 'admin_saved: %s\n' "$([[ $admin_saved -eq 1 ]] && echo yes || echo no)"
for warning in "${WARNINGS[@]}"; do
  printf 'warning: %s\n' "$warning"
done
if [[ $admin_saved -eq 1 ]]; then
  echo "next_command: agent-bridge admin"
fi
