#!/usr/bin/env bash
# memory-enforce.sh — detect wiki memory hygiene violations and optionally notify the admin agent

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-lib.sh"
bridge_load_roster

MAX_BYTES="${BRIDGE_MEMORY_ENFORCE_MAX_BYTES:-8192}"
DRY_RUN=0
JSON_MODE=0
NOTIFY=0
PRINT_CRON_PAYLOAD=0

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--notify] [--dry-run] [--json]
  $(basename "$0") --print-cron-payload

Checks:
  - top-level MEMORY.md and users/*/MEMORY.md size cap (${MAX_BYTES} bytes default)
  - misplaced daily note files below memory/ subdirectories outside users/<id>/memory/YYYY-MM-DD.md

Examples:
  $(basename "$0") --json
  $(basename "$0") --notify
  $(basename "$0") --print-cron-payload
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notify)
      NOTIFY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --print-cron-payload)
      PRINT_CRON_PAYLOAD=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      bridge_die "지원하지 않는 memory-enforce 옵션입니다: $1"
      ;;
  esac
done

resolved_script_path="${BASH_SOURCE[0]}"
if [[ "$resolved_script_path" != /* ]]; then
  resolved_script_path="$SCRIPT_DIR/$(basename "$resolved_script_path")"
fi

if [[ $PRINT_CRON_PAYLOAD -eq 1 ]]; then
  cat <<EOF
memory-enforce.sh 실행.

다음 명령어를 실행해:
bash ${resolved_script_path} --notify --json

결과를 확인하고 위반이 있으면 관리자 채널에 짧게 요약하세요.
EOF
  exit 0
fi

[[ "$MAX_BYTES" =~ ^[0-9]+$ ]] || bridge_die "BRIDGE_MEMORY_ENFORCE_MAX_BYTES must be numeric"

declare -a VIOLATIONS=()
declare -a AGENT_IDS=()

append_violation() {
  local agent="$1"
  local kind="$2"
  local path="$3"
  local detail="$4"
  VIOLATIONS+=("${agent}"$'\t'"${kind}"$'\t'"${path}"$'\t'"${detail}")
}

scan_memory_file() {
  local agent="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0
  local size=0
  size="$(wc -c <"$file" | tr -d ' ')"
  if (( size > MAX_BYTES )); then
    append_violation "$agent" "oversize-memory" "$file" "${size}B exceeds ${MAX_BYTES}B"
  fi
}

scan_daily_paths() {
  local agent="$1"
  local home="$2"
  local path=""
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    append_violation "$agent" "misplaced-daily-note" "$path" "daily note must live under users/<id>/memory/YYYY-MM-DD.md"
  done < <(find "$home/memory" -mindepth 2 -type f -name '202[0-9]-[0-1][0-9]-[0-3][0-9].md' 2>/dev/null)
}

collect_agent_homes() {
  local agent=""
  local home=""
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -n "$agent" ]] || continue
    home="$(bridge_agent_workdir "$agent" || true)"
    [[ -d "$home" ]] || continue
    [[ -f "$home/MEMORY.md" || -d "$home/memory" || -d "$home/users" ]] || continue
    AGENT_IDS+=("$agent")
  done
}

scan_agent_home() {
  local agent="$1"
  local home=""
  local user_dir=""

  home="$(bridge_agent_workdir "$agent")"
  [[ -d "$home" ]] || return 0

  scan_memory_file "$agent" "$home/MEMORY.md"
  if [[ -d "$home/users" ]]; then
    for user_dir in "$home"/users/*; do
      [[ -d "$user_dir" ]] || continue
      scan_memory_file "$agent" "$user_dir/MEMORY.md"
    done
  fi
  scan_daily_paths "$agent" "$home"
}

render_body_file() {
  local body_file="$1"
  local created_at="$2"
  {
    echo "# Memory Enforce Report"
    echo
    echo "- created_at: ${created_at}"
    echo "- max_bytes: ${MAX_BYTES}"
    echo "- violation_count: ${#VIOLATIONS[@]}"
    echo
    echo "## Violations"
    echo
    if ((${#VIOLATIONS[@]} == 0)); then
      echo "- none"
    else
      local item=""
      local agent=""
      local kind=""
      local path=""
      local detail=""
      for item in "${VIOLATIONS[@]}"; do
        IFS=$'\t' read -r agent kind path detail <<<"$item"
        echo "- agent: ${agent}"
        echo "  - kind: ${kind}"
        echo "  - path: \`${path}\`"
        echo "  - detail: ${detail}"
      done
    fi
  } >"$body_file"
}

notify_admin() {
  local created_at="$1"
  local admin_agent=""
  local title=""
  local body_dir=""
  local body_file=""
  local open_task=""

  ((${#VIOLATIONS[@]} > 0)) || return 0
  admin_agent="$(bridge_require_admin_agent)"
  title="[memory-enforce] ${#VIOLATIONS[@]} memory hygiene issues detected"
  open_task="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$admin_agent" --title-prefix "[memory-enforce]" 2>/dev/null || true)"
  if [[ -n "$open_task" ]]; then
    return 0
  fi

  body_dir="$BRIDGE_SHARED_DIR/memory-enforce"
  body_file="$body_dir/${created_at//:/-}.md"
  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi

  mkdir -p "$body_dir"
  render_body_file "$body_file" "$created_at"
  bash "$REPO_ROOT/bridge-task.sh" create \
    --to "$admin_agent" \
    --title "$title" \
    --body-file "$body_file" \
    --from memory-enforce \
    --priority high >/dev/null
}

collect_agent_homes
for agent in "${AGENT_IDS[@]}"; do
  scan_agent_home "$agent"
done

created_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"
if [[ $NOTIFY -eq 1 ]]; then
  notify_admin "$created_at"
fi

if [[ $JSON_MODE -eq 1 ]]; then
  bridge_require_python
  python3 - "$created_at" "$MAX_BYTES" "${VIOLATIONS[@]}" <<'PY'
import json
import sys

created_at = sys.argv[1]
max_bytes = int(sys.argv[2])
violations = []
for raw in sys.argv[3:]:
    agent, kind, path, detail = raw.split("\t", 3)
    violations.append(
        {
            "agent": agent,
            "kind": kind,
            "path": path,
            "detail": detail,
        }
    )

payload = {
    "created_at": created_at,
    "max_bytes": max_bytes,
    "ok": len(violations) == 0,
    "violation_count": len(violations),
    "violations": violations,
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
else
  printf 'created_at: %s\n' "$created_at"
  printf 'violation_count: %s\n' "${#VIOLATIONS[@]}"
  if ((${#VIOLATIONS[@]} == 0)); then
    echo "status: clean"
  else
    echo "status: violations"
    printf '%s\n' "${VIOLATIONS[@]}"
  fi
fi
