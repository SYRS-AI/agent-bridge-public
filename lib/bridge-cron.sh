#!/usr/bin/env bash
# shellcheck shell=bash

bridge_require_openclaw_cron_jobs() {
  if [[ -f "$BRIDGE_OPENCLAW_CRON_JOBS_FILE" ]]; then
    return 0
  fi

  bridge_die "OpenClaw cron jobs 파일이 없습니다: $BRIDGE_OPENCLAW_CRON_JOBS_FILE"
}

bridge_cron_python() {
  bridge_require_python
  python3 "$BRIDGE_SCRIPT_DIR/bridge-cron.py" "$@"
}

bridge_cron_default_slot() {
  local family="${1:-memory-daily}"

  case "$family" in
    monthly-highlights)
      TZ=Asia/Seoul date +%Y-%m
      ;;
    *)
      TZ=Asia/Seoul date +%F
      ;;
  esac
}

bridge_cron_family_allowed() {
  local family="$1"
  local allowed

  for allowed in "${BRIDGE_CRON_ENQUEUE_FAMILIES[@]}"; do
    if [[ "$allowed" == "$family" ]]; then
      return 0
    fi
  done

  return 1
}

bridge_cron_safe_component() {
  local value="$1"

  bridge_require_python
  python3 - "$value" <<'PY'
import re
import sys

text = sys.argv[1]
slug = re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-")
print(slug or "item")
PY
}

bridge_cron_job_slug() {
  local job_name="$1"
  local job_id="$2"
  printf '%s-%s' "$(bridge_cron_safe_component "$job_name")" "${job_id%%-*}"
}

bridge_cron_slot_token() {
  local slot="$1"
  bridge_cron_safe_component "$slot"
}

bridge_cron_job_dir() {
  local job_name="$1"
  local job_id="$2"
  printf '%s/dispatch/%s' "$BRIDGE_CRON_STATE_DIR" "$(bridge_cron_job_slug "$job_name" "$job_id")"
}

bridge_cron_manifest_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  printf '%s/%s.json' "$(bridge_cron_job_dir "$job_name" "$job_id")" "$(bridge_cron_slot_token "$slot")"
}

bridge_cron_body_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  printf '%s/cron/%s/%s.md' "$BRIDGE_SHARED_DIR" "$(bridge_cron_job_slug "$job_name" "$job_id")" "$(bridge_cron_slot_token "$slot")"
}

bridge_resolve_openclaw_target() {
  local openclaw_agent="$1"
  local explicit="${BRIDGE_OPENCLAW_AGENT_TARGET[$openclaw_agent]-}"
  local suffix="${openclaw_agent##*-}"
  local candidate
  local matches=()

  if [[ -n "$explicit" ]]; then
    bridge_require_agent "$explicit"
    printf '%s' "$explicit"
    return 0
  fi

  if bridge_agent_exists "$openclaw_agent"; then
    printf '%s' "$openclaw_agent"
    return 0
  fi

  for candidate in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$candidate" == "$suffix" ]]; then
      matches+=("$candidate")
    fi
  done

  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s' "${matches[0]}"
    return 0
  fi

  return 1
}

bridge_cron_write_manifest() {
  local manifest_file="$1"
  local job_id="$2"
  local job_name="$3"
  local family="$4"
  local openclaw_agent="$5"
  local target="$6"
  local slot="$7"
  local task_id="$8"
  local created_at="$9"
  local body_file="${10}"
  local source_file="${11}"

  mkdir -p "$(dirname "$manifest_file")"

  bridge_require_python
  python3 - "$manifest_file" "$job_id" "$job_name" "$family" "$openclaw_agent" "$target" "$slot" "$task_id" "$created_at" "$body_file" "$source_file" <<'PY'
import json
import sys
from pathlib import Path

(manifest_file, job_id, job_name, family, openclaw_agent, target, slot, task_id, created_at, body_file, source_file) = sys.argv[1:]

payload = {
    "job_id": job_id,
    "job_name": job_name,
    "family": family,
    "openclaw_agent": openclaw_agent,
    "target_agent": target,
    "slot": slot,
    "task_id": int(task_id),
    "created_at": created_at,
    "body_file": body_file,
    "source_file": source_file,
}

Path(manifest_file).write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
}
