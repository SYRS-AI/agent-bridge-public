#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

log() {
  printf '[smoke] %s\n' "$*"
}

die() {
  printf '[smoke][error] %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || die "expected output to contain: $needle"
}

require_cmd bash
require_cmd tmux
require_cmd python3
require_cmd git

log "linting shell entry points"
bash -n "$REPO_ROOT"/*.sh "$REPO_ROOT"/agent-bridge "$REPO_ROOT"/agb "$REPO_ROOT"/scripts/smoke-test.sh
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$REPO_ROOT"/*.sh "$REPO_ROOT"/agent-bridge "$REPO_ROOT"/agb "$REPO_ROOT"/scripts/smoke-test.sh "$REPO_ROOT"/agent-roster.local.example.sh
else
  log "shellcheck not installed; skipping"
fi

TMP_ROOT="$(mktemp -d)"
export BRIDGE_HOME="$TMP_ROOT/bridge-home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
export BRIDGE_DAEMON_INTERVAL=1
export BRIDGE_CRON_DISPATCH_MAX_PARALLEL=1
export BRIDGE_ROSTER_FILE="$REPO_ROOT/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"

SESSION_NAME="bridge-smoke-$$"
WORKDIR="$TMP_ROOT/workdir"
FAKE_BIN="$TMP_ROOT/bin"

cleanup() {
  bash "$REPO_ROOT/bridge-daemon.sh" stop >/dev/null 2>&1 || true
  tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$BRIDGE_HOME" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR" "$WORKDIR"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

cat >"$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"item.completed","item":{"type":"agent_message","text":"{\"status\":\"completed\",\"summary\":\"cron smoke ok\",\"findings\":[],\"actions_taken\":[\"processed cron dispatch\"],\"needs_human_followup\":false,\"recommended_next_steps\":[],\"artifacts\":[],\"confidence\":\"high\"}"}}
JSON
EOF
chmod +x "$FAKE_BIN/codex"

cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
bridge_add_agent_id_if_missing "smoke-agent"
BRIDGE_AGENT_DESC["smoke-agent"]="Smoke test role"
BRIDGE_AGENT_ENGINE["smoke-agent"]="codex"
BRIDGE_AGENT_SESSION["smoke-agent"]="$SESSION_NAME"
BRIDGE_AGENT_WORKDIR["smoke-agent"]="$WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["smoke-agent"]='python3 -c "import time; print(\"smoke-agent ready\", flush=True); time.sleep(30)"'
EOF

echo "temporary smoke note" >"$BRIDGE_SHARED_DIR/note.md"

log "verifying empty runtime starts clean"
EMPTY_LIST="$(BRIDGE_ROSTER_LOCAL_FILE=/nonexistent bash "$REPO_ROOT/bridge-start.sh" --list)"
assert_contains "$EMPTY_LIST" "(등록된 정적 에이전트 없음)"

log "starting isolated daemon"
bash "$REPO_ROOT/bridge-daemon.sh" ensure >/dev/null
DAEMON_STATUS="$(bash "$REPO_ROOT/bridge-daemon.sh" status)"
assert_contains "$DAEMON_STATUS" "running pid="

log "starting isolated tmux role"
bash "$REPO_ROOT/bridge-start.sh" smoke-agent >/dev/null
sleep 1
tmux has-session -t "$SESSION_NAME" >/dev/null 2>&1 || die "smoke tmux session was not created"

log "syncing live roster"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null

LIST_OUTPUT="$("$REPO_ROOT/agent-bridge" list)"
assert_contains "$LIST_OUTPUT" "smoke-agent"

STATUS_OUTPUT="$("$REPO_ROOT/agent-bridge" status --all-agents)"
assert_contains "$STATUS_OUTPUT" "smoke-agent"

log "creating queue task"
CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to smoke-agent --title "smoke queue" --body-file "$BRIDGE_SHARED_DIR/note.md" --from smoke-test)"
assert_contains "$CREATE_OUTPUT" "created task #"

INBOX_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" inbox smoke-agent)"
assert_contains "$INBOX_OUTPUT" "smoke queue"

log "claiming and completing queue task"
bash "$REPO_ROOT/bridge-task.sh" claim 1 --agent smoke-agent >/dev/null
bash "$REPO_ROOT/bridge-task.sh" "done" 1 --agent smoke-agent --note "smoke ok" >/dev/null

SHOW_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show 1)"
assert_contains "$SHOW_OUTPUT" "status: done"
assert_contains "$SHOW_OUTPUT" "note: smoke ok"

SUMMARY_OUTPUT="$("$REPO_ROOT/agb" summary smoke-agent)"
assert_contains "$SUMMARY_OUTPUT" "smoke-agent"

log "processing one queued cron-dispatch task through the daemon"
RUN_ID="smoke-job-1234--2026-04-05T10-00-00Z"
RUN_DIR="$BRIDGE_STATE_DIR/cron/runs/$RUN_ID"
DISPATCH_BODY="$BRIDGE_SHARED_DIR/cron-dispatch/$RUN_ID.md"
mkdir -p "$RUN_DIR" "$(dirname "$DISPATCH_BODY")"

cat >"$RUN_DIR/payload.md" <<'EOF'
# [cron] smoke-job

Do a disposable cron smoke run.
EOF

cat >"$RUN_DIR/request.json" <<EOF
{
  "run_id": "$RUN_ID",
  "job_id": "12345678-abcd",
  "job_name": "smoke-job",
  "family": "smoke-family",
  "openclaw_agent": "smoke-agent",
  "target_agent": "smoke-agent",
  "target_engine": "codex",
  "target_workdir": "$WORKDIR",
  "slot": "2026-04-05T10:00:00Z",
  "dispatch_task_id": 0,
  "created_at": "2026-04-05T10:00:00Z",
  "dispatch_body_file": "$DISPATCH_BODY",
  "payload_file": "$RUN_DIR/payload.md",
  "payload_kind": "agentTurn",
  "result_file": "$RUN_DIR/result.json",
  "status_file": "$RUN_DIR/status.json",
  "stdout_log": "$RUN_DIR/stdout.log",
  "stderr_log": "$RUN_DIR/stderr.log",
  "source_file": "$TMP_ROOT/jobs.json"
}
EOF

cat >"$DISPATCH_BODY" <<EOF
# [cron-dispatch] smoke-job

- run_id: $RUN_ID
EOF

CRON_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to smoke-agent --title "[cron-dispatch] smoke-job (2026-04-05T10:00:00Z)" --body-file "$DISPATCH_BODY" --from smoke-test)"
assert_contains "$CRON_CREATE_OUTPUT" "created task #2"

bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null

for _ in $(seq 1 20); do
  SHOW_CRON_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show 2)"
  if [[ "$SHOW_CRON_OUTPUT" == *"status: done"* ]]; then
    break
  fi
  sleep 0.25
done

assert_contains "$SHOW_CRON_OUTPUT" "status: done"
[[ -f "$RUN_DIR/result.json" ]] || die "cron worker did not write result artifact"

log "smoke test passed"
