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
export BRIDGE_ROSTER_FILE="$REPO_ROOT/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"

SESSION_NAME="bridge-smoke-$$"
WORKDIR="$TMP_ROOT/workdir"

cleanup() {
  bash "$REPO_ROOT/bridge-daemon.sh" stop >/dev/null 2>&1 || true
  tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$BRIDGE_HOME" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR" "$WORKDIR"

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

log "smoke test passed"
