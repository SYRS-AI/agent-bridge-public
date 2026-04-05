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

bridge_cron_runner_python() {
  bridge_require_python
  python3 "$BRIDGE_SCRIPT_DIR/bridge-cron-runner.py" "$@"
}

bridge_cron_scheduler_python() {
  bridge_require_python
  python3 "$BRIDGE_SCRIPT_DIR/bridge-cron-scheduler.py" "$@"
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

  if [[ ${#BRIDGE_CRON_ENQUEUE_FAMILIES[@]} -eq 0 ]]; then
    return 0
  fi

  for allowed in "${BRIDGE_CRON_ENQUEUE_FAMILIES[@]}"; do
    if [[ "$allowed" == "$family" ]]; then
      return 0
    fi
  done

  return 1
}

bridge_cron_scheduler_state_file() {
  printf '%s/scheduler-state.json' "$BRIDGE_CRON_STATE_DIR"
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

bridge_cron_run_id() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  printf '%s--%s' "$(bridge_cron_job_slug "$job_name" "$job_id")" "$(bridge_cron_slot_token "$slot")"
}

bridge_cron_run_dir_by_id() {
  local run_id="$1"
  printf '%s/runs/%s' "$BRIDGE_CRON_STATE_DIR" "$run_id"
}

bridge_cron_run_dir() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_run_dir_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_request_file_by_id() {
  local run_id="$1"
  printf '%s/request.json' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_request_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_request_file_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_result_file_by_id() {
  local run_id="$1"
  printf '%s/result.json' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_result_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_result_file_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_status_file_by_id() {
  local run_id="$1"
  printf '%s/status.json' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_status_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_status_file_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_stdout_log_by_id() {
  local run_id="$1"
  printf '%s/stdout.log' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_stdout_log() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_stdout_log_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_stderr_log_by_id() {
  local run_id="$1"
  printf '%s/stderr.log' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_stderr_log() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_stderr_log_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
}

bridge_cron_payload_file_by_id() {
  local run_id="$1"
  printf '%s/payload.md' "$(bridge_cron_run_dir_by_id "$run_id")"
}

bridge_cron_payload_file() {
  local job_name="$1"
  local job_id="$2"
  local slot="$3"
  bridge_cron_payload_file_by_id "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
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
  printf '%s/cron-dispatch/%s.md' "$BRIDGE_SHARED_DIR" "$(bridge_cron_run_id "$job_name" "$job_id" "$slot")"
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
  local run_id="${12}"
  local request_file="${13}"
  local payload_file="${14}"
  local result_file="${15}"
  local status_file="${16}"
  local stdout_log="${17}"
  local stderr_log="${18}"

  mkdir -p "$(dirname "$manifest_file")"

  bridge_require_python
  python3 - "$manifest_file" "$job_id" "$job_name" "$family" "$openclaw_agent" "$target" "$slot" "$task_id" "$created_at" "$body_file" "$source_file" "$run_id" "$request_file" "$payload_file" "$result_file" "$status_file" "$stdout_log" "$stderr_log" <<'PY'
import json
import sys
from pathlib import Path

(manifest_file, job_id, job_name, family, openclaw_agent, target, slot, task_id, created_at, body_file, source_file, run_id, request_file, payload_file, result_file, status_file, stdout_log, stderr_log) = sys.argv[1:]

payload = {
    "job_id": job_id,
    "job_name": job_name,
    "family": family,
    "openclaw_agent": openclaw_agent,
    "target_agent": target,
    "slot": slot,
    "task_id": int(task_id),
    "created_at": created_at,
    "run_id": run_id,
    "body_file": body_file,
    "request_file": request_file,
    "payload_file": payload_file,
    "result_file": result_file,
    "status_file": status_file,
    "stdout_log": stdout_log,
    "stderr_log": stderr_log,
    "source_file": source_file,
}

Path(manifest_file).write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
}

bridge_cron_write_request() {
  local request_file="$1"
  local run_id="$2"
  local job_id="$3"
  local job_name="$4"
  local family="$5"
  local openclaw_agent="$6"
  local target="$7"
  local slot="$8"
  local task_id="$9"
  local created_at="${10}"
  local body_file="${11}"
  local payload_file="${12}"
  local result_file="${13}"
  local status_file="${14}"
  local stdout_log="${15}"
  local stderr_log="${16}"
  local source_file="${17}"
  local payload_kind="${18}"
  local target_engine="${19}"
  local target_workdir="${20}"

  mkdir -p "$(dirname "$request_file")"

  bridge_require_python
  python3 - "$request_file" "$run_id" "$job_id" "$job_name" "$family" "$openclaw_agent" "$target" "$slot" "$task_id" "$created_at" "$body_file" "$payload_file" "$result_file" "$status_file" "$stdout_log" "$stderr_log" "$source_file" "$payload_kind" "$target_engine" "$target_workdir" <<'PY'
import json
import sys
from pathlib import Path

(request_file, run_id, job_id, job_name, family, openclaw_agent, target, slot, task_id, created_at, body_file, payload_file, result_file, status_file, stdout_log, stderr_log, source_file, payload_kind, target_engine, target_workdir) = sys.argv[1:]

payload = {
    "run_id": run_id,
    "job_id": job_id,
    "job_name": job_name,
    "family": family,
    "openclaw_agent": openclaw_agent,
    "target_agent": target,
    "target_engine": target_engine,
    "target_workdir": target_workdir,
    "slot": slot,
    "dispatch_task_id": int(task_id),
    "created_at": created_at,
    "dispatch_body_file": body_file,
    "payload_file": payload_file,
    "payload_kind": payload_kind,
    "result_file": result_file,
    "status_file": status_file,
    "stdout_log": stdout_log,
    "stderr_log": stderr_log,
    "source_file": source_file,
}

Path(request_file).write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
}

bridge_cron_write_status() {
  local status_file="$1"
  local run_id="$2"
  local state="$3"
  local engine="$4"
  local request_file="$5"
  local result_file="$6"
  local updated_at="$7"
  local error_message="${8:-}"

  mkdir -p "$(dirname "$status_file")"

  bridge_require_python
  python3 - "$status_file" "$run_id" "$state" "$engine" "$request_file" "$result_file" "$updated_at" "$error_message" <<'PY'
import json
import sys
from pathlib import Path

(status_file, run_id, state, engine, request_file, result_file, updated_at, error_message) = sys.argv[1:]

payload = {
    "run_id": run_id,
    "state": state,
    "engine": engine,
    "updated_at": updated_at,
    "request_file": request_file,
    "result_file": result_file,
}
if error_message:
    payload["error"] = error_message

Path(status_file).write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
}
