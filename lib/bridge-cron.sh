#!/usr/bin/env bash
# shellcheck shell=bash

bridge_require_openclaw_cron_jobs() {
  if [[ -f "$BRIDGE_OPENCLAW_CRON_JOBS_FILE" ]]; then
    return 0
  fi

  bridge_die "OpenClaw cron jobs 파일이 없습니다: $BRIDGE_OPENCLAW_CRON_JOBS_FILE"
}

bridge_cron_source_jobs_file() {
  if [[ -f "$BRIDGE_NATIVE_CRON_JOBS_FILE" ]]; then
    printf '%s\n' "$BRIDGE_NATIVE_CRON_JOBS_FILE"
    return 0
  fi
  if [[ -f "$BRIDGE_OPENCLAW_CRON_JOBS_FILE" ]]; then
    printf '%s\n' "$BRIDGE_OPENCLAW_CRON_JOBS_FILE"
    return 0
  fi
  return 1
}

bridge_require_cron_source_jobs() {
  local jobs_file="${1:-}"
  if [[ -n "$jobs_file" && -f "$jobs_file" ]]; then
    return 0
  fi
  jobs_file="$(bridge_cron_source_jobs_file || true)"
  [[ -n "$jobs_file" ]] && return 0
  bridge_die "cron jobs 파일이 없습니다: $BRIDGE_NATIVE_CRON_JOBS_FILE"
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
    memory-daily)
      TZ=Asia/Seoul date +%F
      ;;
    *)
      bridge_require_python
      python3 - <<'PY'
from datetime import datetime, timezone

print(datetime.now(timezone.utc).astimezone().replace(second=0, microsecond=0).isoformat(timespec="minutes"))
PY
      ;;
  esac
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

bridge_cron_worker_dir() {
  printf '%s' "$BRIDGE_CRON_DISPATCH_WORKER_DIR"
}

bridge_cron_worker_pid_file() {
  local task_id="$1"
  printf '%s/task-%s.pid' "$(bridge_cron_worker_dir)" "$task_id"
}

bridge_cron_worker_log_file() {
  local task_id="$1"
  printf '%s/task-%s.log' "$(bridge_cron_worker_dir)" "$task_id"
}

bridge_cron_dispatch_completion_note_file_by_id() {
  local run_id="$1"
  printf '%s/cron-result/%s.md' "$BRIDGE_SHARED_DIR" "$run_id"
}

bridge_cron_dispatch_followup_file_by_id() {
  local run_id="$1"
  printf '%s/cron-followup/%s.md' "$BRIDGE_SHARED_DIR" "$run_id"
}

bridge_cron_run_id_from_body_path() {
  local body_path="$1"
  local base

  base="$(basename "$body_path")"
  printf '%s' "${base%.md}"
}

bridge_cron_load_run_shell() {
  local run_id="$1"
  local request_file result_file status_file

  request_file="$(bridge_cron_request_file_by_id "$run_id")"
  result_file="$(bridge_cron_result_file_by_id "$run_id")"
  status_file="$(bridge_cron_status_file_by_id "$run_id")"

  bridge_require_python
  python3 - "$request_file" "$result_file" "$status_file" <<'PY'
import json
import shlex
import sys
from pathlib import Path

request_file = Path(sys.argv[1])
result_file = Path(sys.argv[2])
status_file = Path(sys.argv[3])


def load(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


request = load(request_file)
result = load(result_file)
status = load(status_file)

fields = {
    "CRON_RUN_ID": request.get("run_id", request_file.parent.name),
    "CRON_JOB_ID": request.get("job_id", ""),
    "CRON_JOB_NAME": request.get("job_name", ""),
    "CRON_FAMILY": request.get("family", ""),
    "CRON_SLOT": request.get("slot", ""),
    "CRON_TARGET_AGENT": request.get("target_agent", ""),
    "CRON_TARGET_ENGINE": request.get("target_engine", ""),
    "CRON_RESULT_STATUS": result.get("status", ""),
    "CRON_RESULT_SUMMARY": result.get("summary", ""),
    "CRON_RUN_STATE": status.get("state", ""),
    "CRON_RESULT_FILE": str(result_file),
    "CRON_STATUS_FILE": str(status_file),
    "CRON_STDOUT_LOG": request.get("stdout_log", ""),
    "CRON_STDERR_LOG": request.get("stderr_log", ""),
    "CRON_PROMPT_FILE": str(request_file.parent / "prompt.txt"),
    "CRON_NEEDS_HUMAN_FOLLOWUP": "1" if result.get("needs_human_followup") else "0",
}

for key, value in fields.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
}

bridge_cron_write_completion_note() {
  local run_id="$1"
  local note_file="$2"
  local followup_task_id="${3:-}"

  bridge_require_python
  python3 - "$run_id" "$note_file" "$followup_task_id" "$(bridge_cron_request_file_by_id "$run_id")" "$(bridge_cron_result_file_by_id "$run_id")" "$(bridge_cron_status_file_by_id "$run_id")" <<'PY'
import json
import sys
from pathlib import Path

run_id, note_file, followup_task_id, request_file, result_file, status_file = sys.argv[1:]
request_path = Path(request_file)
result_path = Path(result_file)
status_path = Path(status_file)
note_path = Path(note_file)


def load(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


request = load(request_path)
result = load(result_path)
status = load(status_path)

job_name = request.get("job_name", "")
slot = request.get("slot", "")
state = status.get("state", result.get("status", "unknown"))

lines = [
    "# Cron Dispatch Result",
    "",
    f"- run_id: {run_id}",
    f"- job: {job_name}",
    f"- family: {request.get('family', '')}",
    f"- slot: {slot}",
    f"- target_agent: {request.get('target_agent', '')}",
    f"- engine: {request.get('target_engine', '')}",
    f"- state: {state}",
    f"- child_status: {result.get('status', '')}",
    f"- request_file: {request_file}",
    f"- result_file: {result_file}",
    f"- status_file: {status_file}",
]

stdout_log = request.get("stdout_log")
stderr_log = request.get("stderr_log")
if stdout_log:
    lines.append(f"- stdout_log: {stdout_log}")
if stderr_log:
    lines.append(f"- stderr_log: {stderr_log}")
if followup_task_id:
    lines.append(f"- followup_task_id: {followup_task_id}")

summary = str(result.get("summary", "")).strip()
if summary:
    lines.extend(["", "## Summary", "", summary])

recommended = result.get("recommended_next_steps") or []
if recommended:
    lines.extend(["", "## Recommended Next Steps", ""])
    for item in recommended:
        lines.append(f"- {item}")

runner_error = str(result.get("runner_error", "")).strip()
if runner_error:
    lines.extend(["", "## Runner Error", "", runner_error])

note_path.parent.mkdir(parents=True, exist_ok=True)
note_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
}

bridge_cron_write_followup_body() {
  local run_id="$1"
  local body_file="$2"

  bridge_require_python
  python3 - "$run_id" "$body_file" "$(bridge_cron_request_file_by_id "$run_id")" "$(bridge_cron_result_file_by_id "$run_id")" "$(bridge_cron_status_file_by_id "$run_id")" <<'PY'
import json
import sys
from pathlib import Path

run_id, body_file, request_file, result_file, status_file = sys.argv[1:]
request_path = Path(request_file)
result_path = Path(result_file)
status_path = Path(status_file)
body_path = Path(body_file)


def load(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


request = load(request_path)
result = load(result_path)
status = load(status_path)

job_name = request.get("job_name", run_id)
title = f"# [cron-followup] {job_name}"
lines = [
    title,
    "",
    f"- run_id: {run_id}",
    f"- slot: {request.get('slot', '')}",
    f"- family: {request.get('family', '')}",
    f"- target_agent: {request.get('target_agent', '')}",
    f"- engine: {request.get('target_engine', '')}",
    f"- run_state: {status.get('state', '')}",
    f"- child_status: {result.get('status', '')}",
    f"- request_file: {request_file}",
    f"- result_file: {result_file}",
    f"- status_file: {status_file}",
]

stdout_log = request.get("stdout_log")
stderr_log = request.get("stderr_log")
if stdout_log:
    lines.append(f"- stdout_log: {stdout_log}")
if stderr_log:
    lines.append(f"- stderr_log: {stderr_log}")

summary = str(result.get("summary", "")).strip()
if summary:
    lines.extend(["", "## Summary", "", summary])

for section, key in (
    ("Findings", "findings"),
    ("Actions Taken", "actions_taken"),
    ("Recommended Next Steps", "recommended_next_steps"),
    ("Artifacts", "artifacts"),
):
    values = result.get(key) or []
    if not values:
      continue
    lines.extend(["", f"## {section}", ""])
    for item in values:
        lines.append(f"- {item}")

runner_error = str(result.get("runner_error", "")).strip()
if runner_error:
    lines.extend(["", "## Runner Error", "", runner_error])

# Explicit delivery instruction so parent agent knows to report
lines.extend([
    "",
    "## Action Required",
    "",
    "You are the parent agent receiving this cron result. You MUST:",
    "1. Review the summary and findings above",
    "2. Post a concise report to your Discord or Telegram channel",
    "3. If recommended_next_steps includes DM or notification targets, execute them",
    "4. Mark this task done with a note summarizing what you reported",
    "",
    "Do NOT just acknowledge this task silently. Your channel subscribers expect reports.",
])

body_path.parent.mkdir(parents=True, exist_ok=True)
body_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
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

bridge_cron_job_always_followup() {
  local job_id="$1"

  bridge_require_python
  python3 - "$job_id" "$BRIDGE_NATIVE_CRON_JOBS_FILE" <<'PY'
import json
import sys
from pathlib import Path

job_id = sys.argv[1]
jobs_file = Path(sys.argv[2]).expanduser()

if not jobs_file.exists():
    print("0")
    raise SystemExit(0)

try:
    data = json.loads(jobs_file.read_text(encoding="utf-8"))
except Exception:
    print("0")
    raise SystemExit(0)

for job in data.get("jobs", []):
    if job.get("id") == job_id:
        metadata = job.get("metadata") or {}
        if metadata.get("alwaysFollowup") or metadata.get("always_followup"):
            print("1")
        else:
            print("0")
        raise SystemExit(0)

print("0")
PY
}
