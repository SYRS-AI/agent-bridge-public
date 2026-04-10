#!/usr/bin/env bash
# bridge-user.sh — canonical shared user profile helpers

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  $(basename "$0") set [--user <id>] --name <name> [--preferred-name <name>] [--timezone <tz>] [--pronouns <text>] [--json]
  $(basename "$0") show [--user <id>] [--json]

Examples:
  $(basename "$0") set --name "Sean" --timezone Asia/Seoul
  $(basename "$0") show --json
EOF
}

run_user_python() {
  bridge_require_python
  python3 - "$@"
}

cmd_set() {
  local user_id="default"
  local name=""
  local preferred_name=""
  local timezone=""
  local pronouns=""
  local json_mode=0
  local shared_users_root="${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}/users"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        user_id="$2"
        shift 2
        ;;
      --name)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        name="$2"
        shift 2
        ;;
      --preferred-name)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        preferred_name="$2"
        shift 2
        ;;
      --timezone)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        timezone="$2"
        shift 2
        ;;
      --pronouns)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        pronouns="$2"
        shift 2
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
        bridge_die "지원하지 않는 user set 옵션입니다: $1"
        ;;
    esac
  done

  [[ -n "$name" ]] || bridge_die "--name is required"
  [[ -n "$preferred_name" ]] || preferred_name="$name"

  run_user_python \
    "$shared_users_root" \
    "$SCRIPT_DIR/agents/_template/users/default" \
    "$user_id" \
    "$name" \
    "$preferred_name" \
    "$timezone" \
    "$pronouns" \
    "$json_mode" <<'PY'
import json
import re
import shutil
import sys
from pathlib import Path

shared_root, template_root, user_id, name, preferred_name, timezone, pronouns, json_mode = sys.argv[1:]
if not re.match(r"^[A-Za-z0-9._-]+$", user_id):
    raise SystemExit(f"invalid user id: {user_id}")

shared_root = Path(shared_root)
template_root = Path(template_root)
target = shared_root / user_id
if not target.exists():
    if not template_root.exists():
        raise SystemExit(f"missing user template: {template_root}")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(template_root, target, symlinks=True)

profile = target / "USER.md"
if not profile.exists():
    profile.write_text("# User Profile\n\n## Identity\n\n- Name:\n- Preferred name:\n- Timezone:\n- Pronouns:\n", encoding="utf-8")

text = profile.read_text(encoding="utf-8")

def set_field(body: str, field: str, value: str) -> str:
    if not value:
        return body
    pattern = rf"(?m)^- {re.escape(field)}:.*$"
    replacement = f"- {field}: {value}"
    if re.search(pattern, body):
        return re.sub(pattern, replacement, body)
    if "## Identity" in body:
        return body.replace("## Identity", f"## Identity\n\n{replacement}", 1)
    return body.rstrip() + f"\n\n## Identity\n\n{replacement}\n"

text = set_field(text, "Name", name)
text = set_field(text, "Preferred name", preferred_name)
text = set_field(text, "Timezone", timezone)
text = set_field(text, "Pronouns", pronouns)
profile.write_text(text.rstrip() + "\n", encoding="utf-8")

payload = {
    "user_id": user_id,
    "name": name,
    "preferred_name": preferred_name,
    "timezone": timezone,
    "pronouns": pronouns,
    "path": str(profile),
}
if json_mode == "1":
    print(json.dumps(payload, ensure_ascii=False, indent=2))
else:
    print(f"user: {user_id}")
    print(f"name: {name}")
    print(f"preferred_name: {preferred_name}")
    print(f"path: {profile}")
PY
}

cmd_show() {
  local user_id="default"
  local json_mode=0
  local shared_users_root="${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}/users"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        user_id="$2"
        shift 2
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
        bridge_die "지원하지 않는 user show 옵션입니다: $1"
        ;;
    esac
  done

  run_user_python "$shared_users_root" "$user_id" "$json_mode" <<'PY'
import json
import re
import sys
from pathlib import Path

shared_root, user_id, json_mode = sys.argv[1:]
profile = Path(shared_root) / user_id / "USER.md"
if not profile.exists():
    raise SystemExit(f"user profile not found: {profile}")

text = profile.read_text(encoding="utf-8")
fields = {}
for line in text.splitlines():
    match = re.match(r"^- ([^:]+):\s*(.*)$", line)
    if match:
        fields[match.group(1).lower().replace(" ", "_")] = match.group(2)

payload = {"user_id": user_id, "path": str(profile), **fields}
if json_mode == "1":
    print(json.dumps(payload, ensure_ascii=False, indent=2))
else:
    print(f"user: {user_id}")
    for key in ("name", "preferred_name", "timezone", "pronouns"):
        if key in payload:
            print(f"{key}: {payload[key]}")
    print(f"path: {profile}")
PY
}

case "${1:-}" in
  set)
    shift
    cmd_set "$@"
    ;;
  show)
    shift
    cmd_show "$@"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    bridge_die "지원하지 않는 user 명령입니다: $1"
    ;;
esac
