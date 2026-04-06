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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || die "expected output to not contain: $needle"
}

require_cmd bash
require_cmd tmux
require_cmd python3
require_cmd git

BASH4_BIN=""
for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  if "$candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
    BASH4_BIN="$candidate"
    break
  fi
done
[[ -n "$BASH4_BIN" ]] || die "missing bash 4+ interpreter"

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
export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
export BRIDGE_PROFILE_STATE_DIR="$BRIDGE_STATE_DIR/profiles"
export BRIDGE_CRON_STATE_DIR="$BRIDGE_STATE_DIR/cron"
export BRIDGE_CRON_HOME_DIR="$BRIDGE_HOME/cron"
export BRIDGE_NATIVE_CRON_JOBS_FILE="$BRIDGE_CRON_HOME_DIR/jobs.json"
export BRIDGE_CRON_DISPATCH_WORKER_DIR="$BRIDGE_CRON_STATE_DIR/workers"
export BRIDGE_OPENCLAW_CRON_JOBS_FILE="$TMP_ROOT/openclaw-jobs.json"
export BRIDGE_DAEMON_INTERVAL=1
export BRIDGE_CRON_DISPATCH_MAX_PARALLEL=1
export BRIDGE_ROSTER_FILE="$REPO_ROOT/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
export BRIDGE_RUNTIME_ROOT="$BRIDGE_HOME/runtime"
export BRIDGE_RUNTIME_SCRIPTS_DIR="$BRIDGE_RUNTIME_ROOT/scripts"
export BRIDGE_RUNTIME_SKILLS_DIR="$BRIDGE_RUNTIME_ROOT/skills"
export BRIDGE_RUNTIME_SHARED_DIR="$BRIDGE_RUNTIME_ROOT/shared"
export BRIDGE_RUNTIME_SHARED_TOOLS_DIR="$BRIDGE_RUNTIME_SHARED_DIR/tools"
export BRIDGE_RUNTIME_SHARED_REFERENCES_DIR="$BRIDGE_RUNTIME_SHARED_DIR/references"
export BRIDGE_RUNTIME_MEMORY_DIR="$BRIDGE_RUNTIME_ROOT/memory"
export BRIDGE_RUNTIME_CREDENTIALS_DIR="$BRIDGE_RUNTIME_ROOT/credentials"
export BRIDGE_RUNTIME_SECRETS_DIR="$BRIDGE_RUNTIME_ROOT/secrets"
export BRIDGE_RUNTIME_CONFIG_FILE="$BRIDGE_RUNTIME_ROOT/openclaw.json"
export BRIDGE_WEBHOOK_PORT_RANGE_START=9301
export BRIDGE_WEBHOOK_PORT_RANGE_END=9399

SESSION_NAME="bridge-smoke-$$"
REQUESTER_SESSION="bridge-requester-$$"
CLAUDE_STATIC_SESSION="claude-static-$SESSION_NAME"
SMOKE_AGENT="smoke-agent-$$"
REQUESTER_AGENT="requester-agent-$$"
AUTO_START_AGENT="auto-start-agent-$$"
AUTO_START_SESSION="auto-start-session-$$"
ALWAYS_ON_AGENT="always-on-agent-$$"
ALWAYS_ON_SESSION="always-on-session-$$"
STATIC_AGENT="static-role-$$"
STATIC_SESSION="static-session-$$"
WORKTREE_AGENT="worker-reuse-$$"
WORKDIR="$TMP_ROOT/workdir"
REQUESTER_WORKDIR="$TMP_ROOT/requester-workdir"
AUTO_START_WORKDIR="$TMP_ROOT/auto-start-workdir"
PROJECT_ROOT="$TMP_ROOT/git-project"
HOOK_WORKDIR="$TMP_ROOT/claude-hook-workdir"
MCP_WORKDIR="$TMP_ROOT/claude-mcp-workdir"
CLAUDE_STATIC_WORKDIR="$BRIDGE_HOME/agents/claude-static"
FAKE_BIN="$TMP_ROOT/bin"
FAKE_DISCORD_PORT_FILE="$TMP_ROOT/fake-discord.port"
FAKE_DISCORD_REQUESTS="$TMP_ROOT/fake-discord-requests.jsonl"
FAKE_DISCORD_PID=""

cleanup() {
  bash "$REPO_ROOT/bridge-daemon.sh" stop >/dev/null 2>&1 || true
  tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
  tmux kill-session -t "$REQUESTER_SESSION" >/dev/null 2>&1 || true
  tmux kill-session -t "$AUTO_START_SESSION" >/dev/null 2>&1 || true
  tmux kill-session -t "$ALWAYS_ON_SESSION" >/dev/null 2>&1 || true
  tmux kill-session -t "$STATIC_SESSION" >/dev/null 2>&1 || true
  tmux kill-session -t "$CLAUDE_STATIC_SESSION" >/dev/null 2>&1 || true
  tmux kill-session -t "$WORKTREE_AGENT" >/dev/null 2>&1 || true
  if [[ -n "$FAKE_DISCORD_PID" ]]; then
    kill "$FAKE_DISCORD_PID" >/dev/null 2>&1 || true
    wait "$FAKE_DISCORD_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$BRIDGE_HOME" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR" "$WORKDIR" "$REQUESTER_WORKDIR" "$AUTO_START_WORKDIR"
mkdir -p "$HOOK_WORKDIR/.claude"
mkdir -p "$MCP_WORKDIR"
mkdir -p "$CLAUDE_STATIC_WORKDIR"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

mkdir -p "$PROJECT_ROOT"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
git -C "$PROJECT_ROOT" init -q
git -C "$PROJECT_ROOT" config user.email smoke@example.com
git -C "$PROJECT_ROOT" config user.name "Smoke Test"
echo "smoke" >"$PROJECT_ROOT/README.md"
git -C "$PROJECT_ROOT" add README.md
git -C "$PROJECT_ROOT" commit -qm "init"

cat >"$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"item.completed","item":{"type":"agent_message","text":"{\"status\":\"completed\",\"summary\":\"cron smoke ok\",\"findings\":[],\"actions_taken\":[\"processed cron dispatch\"],\"needs_human_followup\":false,\"recommended_next_steps\":[],\"artifacts\":[],\"confidence\":\"high\"}"}}
JSON
EOF
chmod +x "$FAKE_BIN/codex"

cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
bridge_add_agent_id_if_missing "$SMOKE_AGENT"
bridge_add_agent_id_if_missing "$REQUESTER_AGENT"
bridge_add_agent_id_if_missing "$AUTO_START_AGENT"
bridge_add_agent_id_if_missing "$ALWAYS_ON_AGENT"
bridge_add_agent_id_if_missing "claude-static"
BRIDGE_ADMIN_AGENT_ID="$SMOKE_AGENT"
BRIDGE_AGENT_DESC["$SMOKE_AGENT"]="Smoke test role"
BRIDGE_AGENT_DESC["$REQUESTER_AGENT"]="Requester role"
BRIDGE_AGENT_DESC["$AUTO_START_AGENT"]="Auto-start role"
BRIDGE_AGENT_DESC["$ALWAYS_ON_AGENT"]="Always-on role"
BRIDGE_AGENT_DESC["claude-static"]="Claude static role"
BRIDGE_AGENT_ENGINE["$SMOKE_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["$REQUESTER_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["$AUTO_START_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["$ALWAYS_ON_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["claude-static"]="claude"
BRIDGE_AGENT_SESSION["$SMOKE_AGENT"]="$SESSION_NAME"
BRIDGE_AGENT_SESSION["$REQUESTER_AGENT"]="$REQUESTER_SESSION"
BRIDGE_AGENT_SESSION["$AUTO_START_AGENT"]="$AUTO_START_SESSION"
BRIDGE_AGENT_SESSION["$ALWAYS_ON_AGENT"]="$ALWAYS_ON_SESSION"
BRIDGE_AGENT_SESSION["claude-static"]="claude-static-$SESSION_NAME"
BRIDGE_AGENT_WORKDIR["$SMOKE_AGENT"]="$WORKDIR"
BRIDGE_AGENT_WORKDIR["$REQUESTER_AGENT"]="$REQUESTER_WORKDIR"
BRIDGE_AGENT_WORKDIR["$AUTO_START_AGENT"]="$AUTO_START_WORKDIR"
BRIDGE_AGENT_WORKDIR["$ALWAYS_ON_AGENT"]="$AUTO_START_WORKDIR"
BRIDGE_AGENT_WORKDIR["claude-static"]="$CLAUDE_STATIC_WORKDIR"
BRIDGE_AGENT_DISCORD_CHANNEL_ID["$SMOKE_AGENT"]="123456789012345678"
BRIDGE_AGENT_LAUNCH_CMD["$SMOKE_AGENT"]='python3 -c "import time; print(\"smoke-agent ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["$REQUESTER_AGENT"]='python3 -c "import time; print(\"requester-agent ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["$AUTO_START_AGENT"]='python3 -c "import time; print(\"auto-start ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["$ALWAYS_ON_AGENT"]='python3 -c "import time; print(\"always-on ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["claude-static"]='DISCORD_STATE_DIR=REPLACE_CLAUDE_DISCORD claude -c --dangerously-skip-permissions --channels plugin:discord@claude-plugins-official'
BRIDGE_AGENT_IDLE_TIMEOUT["$ALWAYS_ON_AGENT"]="0"
EOF

python3 - "$BRIDGE_ROSTER_LOCAL_FILE" "$CLAUDE_STATIC_WORKDIR/.discord" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("REPLACE_CLAUDE_DISCORD", sys.argv[2]), encoding="utf-8")
PY

echo "temporary smoke note" >"$BRIDGE_SHARED_DIR/note.md"
echo "# Smoke CLAUDE" >"$WORKDIR/CLAUDE.md"

cat >"$TMP_ROOT/openclaw.json" <<'EOF'
{
  "channels": {
    "discord": {
      "accounts": {
        "smoke": {
          "token": "smoke-token"
        }
      }
    }
  }
}
EOF

log "starting fake Discord API"
python3 -u - "$FAKE_DISCORD_PORT_FILE" "$FAKE_DISCORD_REQUESTS" <<'PY' >/dev/null 2>&1 &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, requests_file = sys.argv[1], sys.argv[2]
TOKEN = "smoke-token"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth_ok(self):
        return self.headers.get("Authorization") == f"Bot {TOKEN}"

    def do_GET(self):
        if not self._auth_ok():
            self._send(401, {"message": "401: Unauthorized"})
            return
        if self.path == "/users/@me":
            self._send(200, {"id": "999", "username": "smoke-bot", "bot": True})
            return
        if self.path.startswith("/channels/"):
            channel_id = self.path.split("/")[2].split("?", 1)[0]
            self._send(200, {"id": channel_id, "name": f"channel-{channel_id}"})
            return
        self._send(404, {"message": "404: Not Found"})

    def do_POST(self):
        if not self._auth_ok():
            self._send(401, {"message": "401: Unauthorized"})
            return
        if self.path.startswith("/channels/") and self.path.endswith("/messages"):
            channel_id = self.path.split("/")[2]
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8") if length else "{}"
            with open(requests_file, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"path": self.path, "body": json.loads(body)}) + "\n")
            self._send(200, {"id": "message-1", "channel_id": channel_id})
            return
        self._send(404, {"message": "404: Not Found"})

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
FAKE_DISCORD_PID=$!

for _ in $(seq 1 50); do
  [[ -f "$FAKE_DISCORD_PORT_FILE" ]] && break
  sleep 0.1
done
[[ -f "$FAKE_DISCORD_PORT_FILE" ]] || die "fake Discord API failed to start"
FAKE_DISCORD_API_BASE="http://127.0.0.1:$(cat "$FAKE_DISCORD_PORT_FILE")"

log "verifying empty runtime starts clean"
BRIDGE_ROSTER_LOCAL_FILE=/nonexistent bash "$REPO_ROOT/bridge-start.sh" --list >/dev/null

log "starting isolated daemon"
bash "$REPO_ROOT/bridge-daemon.sh" ensure >/dev/null
DAEMON_STATUS="$(bash "$REPO_ROOT/bridge-daemon.sh" status)"
assert_contains "$DAEMON_STATUS" "running pid="

log "starting isolated tmux role"
bash "$REPO_ROOT/bridge-start.sh" "$SMOKE_AGENT" >/dev/null
bash "$REPO_ROOT/bridge-start.sh" "$REQUESTER_AGENT" >/dev/null
sleep 1
tmux has-session -t "$SESSION_NAME" >/dev/null 2>&1 || die "smoke tmux session was not created"
tmux has-session -t "$REQUESTER_SESSION" >/dev/null 2>&1 || die "requester tmux session was not created"

log "syncing live roster"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null

LIST_OUTPUT="$("$REPO_ROOT/agent-bridge" list)"
assert_contains "$LIST_OUTPUT" "$SMOKE_AGENT"

STATUS_OUTPUT="$("$REPO_ROOT/agent-bridge" status --all-agents)"
assert_contains "$STATUS_OUTPUT" "$SMOKE_AGENT"
assert_contains "$STATUS_OUTPUT" "state"
printf '%s\n' "$STATUS_OUTPUT" | grep -E "$SMOKE_AGENT[[:space:]].*(idle|working)" >/dev/null || die "status should show activity state for $SMOKE_AGENT"

RELAY_ROWS="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_discord_relay_rows_tsv
')"
assert_contains "$RELAY_ROWS" "$SMOKE_AGENT"$'\t'"123456789012345678"

log "verifying session alias resolution and worktree replace"
tmux new-session -d -s "$WORKTREE_AGENT" -c "$PROJECT_ROOT" 'python3 -c "import time; print(\"worker active\", flush=True); time.sleep(30)"'
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "$STATIC_AGENT"
BRIDGE_AGENT_DESC["$STATIC_AGENT"]="Static project role"
BRIDGE_AGENT_ENGINE["$STATIC_AGENT"]="codex"
BRIDGE_AGENT_SESSION["$STATIC_AGENT"]="$STATIC_SESSION"
BRIDGE_AGENT_WORKDIR["$STATIC_AGENT"]="$PROJECT_ROOT"
BRIDGE_AGENT_LAUNCH_CMD["$STATIC_AGENT"]='python3 -c "import time; print(\"static role ready\", flush=True); time.sleep(30)"'
EOF

"$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_add_agent_id_if_missing "'"$WORKTREE_AGENT"'"
  BRIDGE_AGENT_DESC["'"$WORKTREE_AGENT"'"]="Existing worker"
  BRIDGE_AGENT_ENGINE["'"$WORKTREE_AGENT"'"]="codex"
  BRIDGE_AGENT_SESSION["'"$WORKTREE_AGENT"'"]="'"$WORKTREE_AGENT"'"
  BRIDGE_AGENT_WORKDIR["'"$WORKTREE_AGENT"'"]="'"$PROJECT_ROOT"'"
  BRIDGE_AGENT_SOURCE["'"$WORKTREE_AGENT"'"]="dynamic"
  BRIDGE_AGENT_LOOP["'"$WORKTREE_AGENT"'"]="0"
  BRIDGE_AGENT_CONTINUE["'"$WORKTREE_AGENT"'"]="1"
  BRIDGE_AGENT_HISTORY_KEY["'"$WORKTREE_AGENT"'"]="smoke-history"
  bridge_persist_agent_state "'"$WORKTREE_AGENT"'"
'

bash "$REPO_ROOT/bridge-start.sh" "$STATIC_AGENT" >/dev/null
STATIC_CANDIDATE_OUTPUT="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_static_agents_for_project_engine "'"$PROJECT_ROOT"'" codex
')"
assert_contains "$STATIC_CANDIDATE_OUTPUT" "$STATIC_AGENT"

ALIAS_OUTPUT="$("$REPO_ROOT/agent-bridge" --codex --name "$STATIC_SESSION" --workdir "$PROJECT_ROOT" --no-attach 2>&1)"
assert_contains "$ALIAS_OUTPUT" "세션 '$STATIC_SESSION'은(는) 역할 '$STATIC_AGENT'에 연결됩니다."

WORKTREE_OUTPUT="$("$REPO_ROOT/agent-bridge" --codex --name "$WORKTREE_AGENT" --workdir "$PROJECT_ROOT" --prefer new --no-attach 2>&1)"
assert_contains "$WORKTREE_OUTPUT" "isolated worktree를 사용합니다:"

EXPECTED_WORKTREE_DIR="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_worktree_launch_dir_for "'"$PROJECT_ROOT"'" "'"$WORKTREE_AGENT"'"
')"
ACTIVE_WORKTREE_DIR="$("$BASH4_BIN" -c '
  source "'"$BRIDGE_ACTIVE_AGENT_DIR"'/'"$WORKTREE_AGENT"'.env"
  printf "%s" "$AGENT_WORKDIR"
')"
[[ "$ACTIVE_WORKTREE_DIR" == "$EXPECTED_WORKTREE_DIR" ]] || die "worktree spawn reused stale session: expected $EXPECTED_WORKTREE_DIR got $ACTIVE_WORKTREE_DIR"

log "creating queue task"
CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "smoke queue" --body-file "$BRIDGE_SHARED_DIR/note.md" --from "$REQUESTER_AGENT")"
assert_contains "$CREATE_OUTPUT" "created task #"

INBOX_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" inbox "$SMOKE_AGENT")"
assert_contains "$INBOX_OUTPUT" "smoke queue"

log "claiming and completing queue task"
SMOKE_AGENT="$SMOKE_AGENT" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3
import time

db = os.environ["BRIDGE_TASK_DB"]
agent = os.environ["SMOKE_AGENT"]
stale_ts = int(time.time()) - 7200
with sqlite3.connect(db) as conn:
    conn.execute(
        """
        INSERT INTO agent_state (agent, active, last_seen_ts, session_activity_ts)
        VALUES (?, 1, ?, ?)
        ON CONFLICT(agent) DO UPDATE SET
          active = 1,
          last_seen_ts = excluded.last_seen_ts,
          session_activity_ts = excluded.session_activity_ts
        """,
        (agent, stale_ts, stale_ts),
    )
    conn.commit()
PY
bash "$REPO_ROOT/bridge-task.sh" claim 1 --agent "$SMOKE_AGENT" >/dev/null
CLAIM_SUMMARY_TSV="$(python3 "$REPO_ROOT/bridge-queue.py" summary --agent "$SMOKE_AGENT" --format tsv)"
CLAIM_IDLE_SECONDS="$(printf '%s\n' "$CLAIM_SUMMARY_TSV" | awk -F'\t' 'NR==1 {print $6}')"
[[ "$CLAIM_IDLE_SECONDS" =~ ^[0-9]+$ ]] || die "claim idle seconds was not numeric: $CLAIM_IDLE_SECONDS"
(( CLAIM_IDLE_SECONDS < 10 )) || die "claim should refresh agent activity; idle=$CLAIM_IDLE_SECONDS"

SMOKE_AGENT="$SMOKE_AGENT" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3
import time

db = os.environ["BRIDGE_TASK_DB"]
agent = os.environ["SMOKE_AGENT"]
stale_ts = int(time.time()) - 7200
with sqlite3.connect(db) as conn:
    conn.execute(
        """
        UPDATE agent_state
        SET last_seen_ts = ?, session_activity_ts = ?
        WHERE agent = ?
        """,
        (stale_ts, stale_ts, agent),
    )
    conn.commit()
PY
DONE_BEFORE_TS="$(date +%s)"
python3 "$REPO_ROOT/bridge-queue.py" done 1 --agent "$SMOKE_AGENT" --note "smoke ok" >/dev/null
DONE_ACTIVITY_TS="$(SMOKE_AGENT="$SMOKE_AGENT" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
agent = os.environ["SMOKE_AGENT"]
with sqlite3.connect(db) as conn:
    value = conn.execute(
        "SELECT session_activity_ts FROM agent_state WHERE agent = ?",
        (agent,),
    ).fetchone()
print(int(value[0] or 0))
PY
)"
[[ "$DONE_ACTIVITY_TS" =~ ^[0-9]+$ ]] || die "done activity ts was not numeric: $DONE_ACTIVITY_TS"
(( DONE_ACTIVITY_TS >= DONE_BEFORE_TS )) || die "done should refresh agent activity; activity_ts=$DONE_ACTIVITY_TS before=$DONE_BEFORE_TS"

SHOW_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show 1)"
assert_contains "$SHOW_OUTPUT" "status: done"
assert_contains "$SHOW_OUTPUT" "note: smoke ok"

NOTICE_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "smoke queue notice" --body-file "$BRIDGE_SHARED_DIR/note.md" --from "$REQUESTER_AGENT")"
assert_contains "$NOTICE_CREATE_OUTPUT" "created task #"
bash "$REPO_ROOT/bridge-task.sh" "done" 2 --agent "$SMOKE_AGENT" --note "notice ok" >/dev/null

REQUESTER_INBOX_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" inbox "$REQUESTER_AGENT")"
assert_contains "$REQUESTER_INBOX_OUTPUT" "[task-complete] smoke queue notice"
REQUESTER_SHOW_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show 3)"
assert_contains "$REQUESTER_SHOW_OUTPUT" "assigned_to: $REQUESTER_AGENT"
assert_contains "$REQUESTER_SHOW_OUTPUT" "original_task: #2"
assert_contains "$REQUESTER_SHOW_OUTPUT" "completed_by: $SMOKE_AGENT"

log "cancelling an orphan task without a roster entry"
ORPHAN_TASK_ID=""
ORPHAN_CREATE_OUTPUT="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 "$REPO_ROOT/bridge-queue.py" create --to tester --title "orphan cleanup" --from smoke --priority high --body "cleanup me" --format shell)"
assert_contains "$ORPHAN_CREATE_OUTPUT" "TASK_ID="
ORPHAN_TASK_ID="$(printf '%s\n' "$ORPHAN_CREATE_OUTPUT" | sed -n 's/^TASK_ID=//p' | head -n1)"
[[ -n "$ORPHAN_TASK_ID" ]] || die "expected orphan task id"
CANCEL_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" cancel "$ORPHAN_TASK_ID" --actor smoke --note "cleanup stale test task")"
assert_contains "$CANCEL_OUTPUT" "cancelled task #$ORPHAN_TASK_ID as smoke"
ORPHAN_SHOW_OUTPUT="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 "$REPO_ROOT/bridge-queue.py" show "$ORPHAN_TASK_ID")"
assert_contains "$ORPHAN_SHOW_OUTPUT" "status: cancelled"

SUMMARY_OUTPUT="$("$REPO_ROOT/agb" summary "$SMOKE_AGENT")"
assert_contains "$SUMMARY_OUTPUT" "$SMOKE_AGENT"

log "marking zombie after repeated unanswered nudges and clearing on activity"
for nudge_try in $(seq 1 10); do
  python3 "$REPO_ROOT/bridge-queue.py" note-nudge --agent "$SMOKE_AGENT" --key "smoke-zombie-$nudge_try" --zombie-threshold 10 >/dev/null
done
ZOMBIE_STATUS_OUTPUT="$("$REPO_ROOT/agent-bridge" status --all-agents)"
assert_contains "$ZOMBIE_STATUS_OUTPUT" "zombie=1"
assert_contains "$ZOMBIE_STATUS_OUTPUT" "zmb"

ZOMBIE_RESET_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "zombie reset smoke" --body "reset" --from "$REQUESTER_AGENT")"
assert_contains "$ZOMBIE_RESET_CREATE_OUTPUT" "created task #"
ZOMBIE_RESET_TASK_ID="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT id FROM tasks WHERE title = ? ORDER BY id DESC LIMIT 1",
        ("zombie reset smoke",),
    ).fetchone()
print(int(row[0]))
PY
)"
python3 "$REPO_ROOT/bridge-queue.py" claim "$ZOMBIE_RESET_TASK_ID" --agent "$SMOKE_AGENT" --lease-seconds 60 >/dev/null
python3 "$REPO_ROOT/bridge-queue.py" done "$ZOMBIE_RESET_TASK_ID" --agent "$SMOKE_AGENT" --note "cleared zombie" >/dev/null
ZOMBIE_CLEARED_STATUS_OUTPUT="$("$REPO_ROOT/agent-bridge" status --all-agents)"
assert_contains "$ZOMBIE_CLEARED_STATUS_OUTPUT" "zombie=0"
assert_not_contains "$ZOMBIE_CLEARED_STATUS_OUTPUT" "zmb"

log "ensuring events reader and supervisor prefilter"
EVENTS_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" events --type done --after-id 0 --limit 5 --format json)"
assert_contains "$EVENTS_OUTPUT" '"event_type": "done"'
assert_contains "$EVENTS_OUTPUT" '"task_title"'
EVENTS_TEXT="$(python3 "$REPO_ROOT/bridge-queue.py" events --type done --after-id 0 --limit 2 --format text)"
assert_contains "$EVENTS_TEXT" "done"
SUPERVISOR_STATUS="$(python3 "$REPO_ROOT/bridge-supervisor.py" status)"
assert_contains "$SUPERVISOR_STATUS" "checkpoint:"
assert_contains "$SUPERVISOR_STATUS" "model:"

log "ensuring Task Processing Protocol in managed CLAUDE.md block"
TEMPLATE_CLAUDE="$(cat "$REPO_ROOT/agents/_template/CLAUDE.md")"
assert_contains "$TEMPLATE_CLAUDE" "Task Processing Protocol"
assert_contains "$TEMPLATE_CLAUDE" "조용한 done 금지"

log "auto-starting static role even when timeout=0"
AUTO_START_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$AUTO_START_AGENT" --title "auto-start smoke" --body "wake" --from "$REQUESTER_AGENT")"
assert_contains "$AUTO_START_OUTPUT" "created task #"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
sleep 1
tmux has-session -t "$AUTO_START_SESSION" >/dev/null 2>&1 || die "auto-start role did not start with timeout=0"

log "ensuring explicit timeout=0 role is restarted even without queue"
tmux has-session -t "$ALWAYS_ON_SESSION" >/dev/null 2>&1 && tmux kill-session -t "$ALWAYS_ON_SESSION" >/dev/null 2>&1 || true
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
sleep 1
tmux has-session -t "$ALWAYS_ON_SESSION" >/dev/null 2>&1 || die "always-on role did not restart without queue"

log "running guided Discord setup"
SETUP_DISCORD_OUTPUT="$("$REPO_ROOT/agent-bridge" setup discord "$SMOKE_AGENT" --openclaw-account smoke --openclaw-config "$TMP_ROOT/openclaw.json" --api-base-url "$FAKE_DISCORD_API_BASE" --yes)"
assert_contains "$SETUP_DISCORD_OUTPUT" "validation: ok"
assert_contains "$SETUP_DISCORD_OUTPUT" "token_source: openclaw:smoke"
assert_contains "$SETUP_DISCORD_OUTPUT" "channel 123456789012345678: read=ok send=ok"
[[ -f "$WORKDIR/.discord/.env" ]] || die "setup discord did not create .env"
[[ -f "$WORKDIR/.discord/access.json" ]] || die "setup discord did not create access.json"
assert_contains "$(cat "$WORKDIR/.discord/.env")" "DISCORD_BOT_TOKEN=smoke-token"
assert_contains "$(cat "$FAKE_DISCORD_REQUESTS")" "[Agent Bridge setup]"

log "running broader agent preflight"
SETUP_AGENT_OUTPUT="$("$REPO_ROOT/agent-bridge" setup agent "$SMOKE_AGENT" --skip-discord)"
assert_contains "$SETUP_AGENT_OUTPUT" "claude_md: n/a (engine=codex)"
assert_contains "$SETUP_AGENT_OUTPUT" "wake_channel: -"
assert_contains "$SETUP_AGENT_OUTPUT" "start_dry_run: ok"

log "ensuring static Claude launch command is bridge-controlled"
CLAUDE_LAUNCH_NO_CONTINUE="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="0"
  bridge_agent_launch_cmd "claude-static"
')"
assert_contains "$CLAUDE_LAUNCH_NO_CONTINUE" "DISCORD_STATE_DIR=$CLAUDE_STATIC_WORKDIR/.discord claude --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
assert_contains "$CLAUDE_LAUNCH_NO_CONTINUE" "claude --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
[[ "$CLAUDE_LAUNCH_NO_CONTINUE" != *" -c "* ]] || die "static Claude launch still contains -c"
[[ "$CLAUDE_LAUNCH_NO_CONTINUE" != *"'DISCORD_STATE_DIR="* ]] || die "static Claude env prefix should not be shell-quoted"

CLAUDE_LAUNCH_CONTINUE="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="1"
  unset BRIDGE_AGENT_SESSION_ID["claude-static"]
  bridge_agent_launch_cmd "claude-static"
')"
assert_contains "$CLAUDE_LAUNCH_CONTINUE" "DISCORD_STATE_DIR=$CLAUDE_STATIC_WORKDIR/.discord claude --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
assert_contains "$CLAUDE_LAUNCH_CONTINUE" "claude --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
[[ "$CLAUDE_LAUNCH_CONTINUE" != *" --continue "* ]] || die "static Claude launch without session_id should start fresh, not use --continue"
[[ "$CLAUDE_LAUNCH_CONTINUE" != *"'DISCORD_STATE_DIR="* ]] || die "static Claude env prefix should not be shell-quoted on continue"

STATIC_HISTORY_CONTINUE="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  history_file="$(bridge_history_file_for_agent "claude-static")"
  cat >"$history_file" <<EOF
AGENT_ID=claude-static
AGENT_CONTINUE=0
AGENT_SESSION_ID=history-session-id
EOF
  bridge_load_roster
  printf "%s" "$(bridge_agent_continue "claude-static")"
')"
[[ "$STATIC_HISTORY_CONTINUE" == "1" ]] || die "static history should not override continue defaults"

CLAUDE_STALE_RESUME_FALLBACK="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  history_file="$(bridge_history_file_for_agent "claude-static")"
  cat >"$history_file" <<EOF
AGENT_ID=claude-static
AGENT_ENGINE=claude
AGENT_WORKDIR='"$CLAUDE_STATIC_WORKDIR"'
AGENT_CONTINUE=1
AGENT_SESSION_ID=stale-session-id
EOF
  bridge_load_roster
  bridge_agent_launch_cmd "claude-static"
')"
assert_contains "$CLAUDE_STALE_RESUME_FALLBACK" "claude --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
[[ "$CLAUDE_STALE_RESUME_FALLBACK" != *" --resume "* ]] || die "stale Claude session_id should not be used for resume"
[[ "$CLAUDE_STALE_RESUME_FALLBACK" != *" --continue "* ]] || die "stale Claude session_id should fall back to fresh start"

log "configuring admin role and launching it"
SETUP_ADMIN_OUTPUT="$("$REPO_ROOT/agent-bridge" setup admin "$SMOKE_AGENT")"
assert_contains "$SETUP_ADMIN_OUTPUT" "admin_agent: $SMOKE_AGENT"
assert_contains "$SETUP_ADMIN_OUTPUT" "next_command: agent-bridge admin"
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_ADMIN_AGENT_ID=\"$SMOKE_AGENT\""

ADMIN_OUTPUT="$("$REPO_ROOT/agent-bridge" admin --no-attach 2>&1)"
if [[ "$ADMIN_OUTPUT" != *"세션 '$SESSION_NAME'이 이미 실행 중입니다."* && "$ADMIN_OUTPUT" != *"세션 '$SESSION_NAME' 시작 완료"* ]]; then
  die "expected admin launch to either reuse or start session"
fi

ADMIN_REPLACE_OUTPUT="$("$REPO_ROOT/agent-bridge" admin --replace --no-continue --no-attach 2>&1)"
assert_contains "$ADMIN_REPLACE_OUTPUT" "세션 '$SESSION_NAME' 시작 완료"

STATIC_START_DRY_RUN="$("$REPO_ROOT/bridge-start.sh" "$SMOKE_AGENT" --dry-run --no-continue)"
assert_contains "$STATIC_START_DRY_RUN" "continue=0"

log "ensuring Claude Stop hook settings merge"
cat >"$HOOK_WORKDIR/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/session-start.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
EOF

HOOK_ENSURE_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-stop-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
assert_contains "$HOOK_ENSURE_OUTPUT" "status: updated"
assert_contains "$HOOK_ENSURE_OUTPUT" "stop_hook: present"
assert_contains "$HOOK_ENSURE_OUTPUT" "additional_context: true"
HOOK_STATUS_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" status-stop-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
assert_contains "$HOOK_STATUS_OUTPUT" "status: present"
assert_contains "$HOOK_STATUS_OUTPUT" "additional_context: true"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"SessionStart\""
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"Stop\""
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"additionalContext\": true"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "mark-idle.sh"

PROMPT_HOOK_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-prompt-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
assert_contains "$PROMPT_HOOK_OUTPUT" "prompt_hook: present"
PROMPT_STATUS_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" status-prompt-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
assert_contains "$PROMPT_STATUS_OUTPUT" "status: present"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"UserPromptSubmit\""
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "clear-idle.sh"

log "ensuring shared Claude settings symlink for bridge-owned agent homes"
SHARED_HOOK_OUTPUT="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_ensure_claude_stop_hook \"$CLAUDE_STATIC_WORKDIR\"")"
assert_contains "$SHARED_HOOK_OUTPUT" "settings_file: $CLAUDE_STATIC_WORKDIR/.claude/settings.json"
assert_contains "$SHARED_HOOK_OUTPUT" "command: $BRIDGE_HOME/agents/.claude/settings.json"
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/settings.json" ]] || die "expected shared Claude settings symlink"
SHARED_SYMLINK_TARGET="$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/settings.json")"
assert_contains "$SHARED_SYMLINK_TARGET" "../../.claude/settings.json"
assert_contains "$(cat "$BRIDGE_HOME/agents/.claude/settings.json")" "\"additionalContext\": true"

log "ensuring shared Claude runtime skills for bridge-owned agent homes"
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_bootstrap_claude_shared_skills \"$CLAUDE_STATIC_WORKDIR\""
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/skills/agent-bridge-runtime" ]] || die "expected shared agent-bridge runtime skill symlink"
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/skills/cron-manager" ]] || die "expected shared cron-manager skill symlink"
assert_contains "$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/skills/agent-bridge-runtime")" "agent-bridge-runtime"
assert_contains "$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/skills/cron-manager")" "cron-manager"
assert_contains "$(cat "$REPO_ROOT/.claude/skills/agent-bridge-runtime/SKILL.md")" "Queue Source of Truth"
assert_contains "$(cat "$REPO_ROOT/.claude/skills/agent-bridge-runtime/SKILL.md")" "Use the Bash tool and run exactly"

log "ensuring Claude project trust seed and startup blocker detection"
CLAUDE_USER_FILE="$TMP_ROOT/claude-user.json"
echo '{}' >"$CLAUDE_USER_FILE"
TRUST_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-project-trust --workdir "$CLAUDE_STATIC_WORKDIR" --claude-user-file "$CLAUDE_USER_FILE")"
assert_contains "$TRUST_OUTPUT" "status: updated"
assert_contains "$TRUST_OUTPUT" "trust_accepted: true"
assert_contains "$(cat "$CLAUDE_USER_FILE")" "\"$CLAUDE_STATIC_WORKDIR\""
assert_contains "$(cat "$CLAUDE_USER_FILE")" "\"hasTrustDialogAccepted\": true"
CLAUDE_TRUST_BLOCKER="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; text=\$'Quick safety check:\\n❯ 1. Yes, I trust this folder'; bridge_tmux_claude_blocker_state_from_text \"\$text\"")"
assert_contains "$CLAUDE_TRUST_BLOCKER" "trust"
CLAUDE_SUMMARY_BLOCKER="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; text=\$'This session is 2h old\\n❯ 1. Resume from summary (recommended)\\n2. Resume full session as-is'; bridge_tmux_claude_blocker_state_from_text \"\$text\"")"
assert_contains "$CLAUDE_SUMMARY_BLOCKER" "summary"
CLAUDE_PROMPT_READY="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; if bridge_tmux_claude_prompt_line_ready '❯ 1. Resume from summary'; then echo bad; else echo ok; fi")"
assert_contains "$CLAUDE_PROMPT_READY" "ok"

log "ensuring mark-idle hook emits inbox summary context"
HOOK_QUEUE_CREATE_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to claude-static --title "Follow-up task" --from smoke --priority high --body "check inbox")"
assert_contains "$HOOK_QUEUE_CREATE_OUTPUT" "created task #"
HOOK_CONTEXT_OUTPUT="$(BRIDGE_HOME="$REPO_ROOT" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_ACTIVE_AGENT_DIR" BRIDGE_HISTORY_DIR="$BRIDGE_HISTORY_DIR" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" BRIDGE_ROSTER_FILE="$REPO_ROOT/agent-roster.sh" BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" BRIDGE_AGENT_ID="claude-static" "$BASH4_BIN" "$REPO_ROOT/hooks/mark-idle.sh")"
assert_contains "$HOOK_CONTEXT_OUTPUT" "[Agent Bridge] 1 pending task(s) for claude-static."
assert_contains "$HOOK_CONTEXT_OUTPUT" "ACTION REQUIRED: Use your Bash tool now."
assert_contains "$HOOK_CONTEXT_OUTPUT" "Run exactly: ~/.agent-bridge/agb inbox claude-static"
assert_contains "$HOOK_CONTEXT_OUTPUT" "Highest priority: Task #"

log "ensuring Claude webhook MCP config merge"
cat >"$MCP_WORKDIR/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "existing": {
      "transport": "stdio",
      "command": "python3",
      "args": ["existing.py"]
    }
  }
}
EOF

MCP_ENSURE_OUTPUT="$(python3 "$REPO_ROOT/bridge-channels.py" ensure-webhook-server --workdir "$MCP_WORKDIR" --bridge-home "$BRIDGE_HOME" --bridge-state-dir "$BRIDGE_STATE_DIR" --python-bin "$(command -v python3)" --server-script "$REPO_ROOT/bridge-channel-server.py" --server-name bridge-webhook --port 9301 --agent claude-smoke)"
assert_contains "$MCP_ENSURE_OUTPUT" "status: updated"
assert_contains "$(cat "$MCP_WORKDIR/.mcp.json")" "\"existing\""
assert_contains "$(cat "$MCP_WORKDIR/.mcp.json")" "\"bridge-webhook\""
assert_contains "$(cat "$MCP_WORKDIR/.mcp.json")" "\"BRIDGE_WEBHOOK_PORT\": \"9301\""

log "exercising standalone bridge channel server"
python3 - "$REPO_ROOT" "$BRIDGE_STATE_DIR" <<'PY'
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

repo_root = Path(sys.argv[1])
state_dir = Path(sys.argv[2])
agent = "claude-smoke"
port = 9302
idle_file = state_dir / "agents" / agent / "idle-since"
idle_file.parent.mkdir(parents=True, exist_ok=True)
idle_file.write_text("123\n", encoding="utf-8")

env = os.environ.copy()
env.update(
    {
        "BRIDGE_WEBHOOK_PORT": str(port),
        "BRIDGE_WEBHOOK_AGENT": agent,
        "BRIDGE_STATE_DIR": str(state_dir),
        "PYTHONUNBUFFERED": "1",
    }
)

proc = subprocess.Popen(
    [sys.executable, str(repo_root / "bridge-channel-server.py")],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    env=env,
)

def send(payload: dict) -> None:
    body = json.dumps(payload).encode("utf-8")
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    proc.stdin.write(body)
    proc.stdin.flush()

def read_message(timeout: float = 5.0) -> dict:
    deadline = time.time() + timeout
    headers = {}
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            raise SystemExit("channel server stdout closed unexpectedly")
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode("utf-8").split(":", 1)
        headers[key.strip().lower()] = value.strip()
    length = int(headers["content-length"])
    body = proc.stdout.read(length)
    return json.loads(body.decode("utf-8"))

try:
    send(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}},
        }
    )
    response = read_message()
    assert response["id"] == 1
    assert response["result"]["capabilities"]["experimental"]["claude/channel"] == {}

    for _ in range(50):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=0.2) as resp:
                assert resp.status == 200
                break
        except Exception:
            time.sleep(0.1)
    else:
        raise SystemExit("channel server health endpoint never became ready")

    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/",
        data=b"agb inbox claude-smoke",
        headers={"Content-Type": "text/plain; charset=utf-8"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=2) as resp:
        assert resp.status == 200

    notification = read_message()
    assert notification["method"] == "notifications/claude/channel"
    assert notification["params"]["content"] == "agb inbox claude-smoke"
    assert notification["params"]["meta"]["chat_id"] == agent
    assert not idle_file.exists(), "idle marker should be cleared on webhook delivery"
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
PY

log "creating and managing a bridge-native cron job"
NATIVE_CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron create --agent "$SMOKE_AGENT" --schedule '0 10 * * *' --tz UTC --title 'native smoke daily' --payload 'Do the native cron smoke run.')"
assert_contains "$NATIVE_CREATE_OUTPUT" "created native cron job"

NATIVE_LIST_OUTPUT="$("$REPO_ROOT/agent-bridge" cron list --agent "$SMOKE_AGENT")"
assert_contains "$NATIVE_LIST_OUTPUT" "native smoke daily"

NATIVE_JOB_ID="$(python3 - <<'PY'
import json, os
path = os.path.join(os.environ["BRIDGE_HOME"], "cron", "jobs.json")
payload = json.load(open(path, "r", encoding="utf-8"))
print(payload["jobs"][0]["id"])
PY
)"
[[ -n "$NATIVE_JOB_ID" ]] || die "native cron id was empty"

NATIVE_UPDATE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron update "$NATIVE_JOB_ID" --schedule '15 10 * * *' --title 'native smoke daily updated')"
assert_contains "$NATIVE_UPDATE_OUTPUT" "updated native cron job"

SYNC_DRY_RUN_OUTPUT="$("$REPO_ROOT/agent-bridge" cron sync --dry-run --since '2026-04-05T10:14:00+00:00' --now '2026-04-05T10:15:00+00:00')"
assert_contains "$SYNC_DRY_RUN_OUTPUT" "native: status=dry_run"
assert_contains "$SYNC_DRY_RUN_OUTPUT" "due=1"

NATIVE_DELETE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron delete "$NATIVE_JOB_ID")"
assert_contains "$NATIVE_DELETE_OUTPUT" "deleted native cron job"

log "inventorying legacy runtime references"
LEGACY_ROOT="$TMP_ROOT/legacy-runtime"
mkdir -p "$LEGACY_ROOT/cron" "$LEGACY_ROOT/scripts" "$LEGACY_ROOT/skills/sample-skill" "$LEGACY_ROOT/credentials"
mkdir -p "$LEGACY_ROOT/shared/tools" "$LEGACY_ROOT/shared/references" "$LEGACY_ROOT/memory"
mkdir -p "$LEGACY_ROOT/secrets" "$LEGACY_ROOT/data" "$LEGACY_ROOT/assets/sample" "$LEGACY_ROOT/extensions/sample-ext"
cat >"$LEGACY_ROOT/scripts/morning-briefing.py" <<'EOF'
#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.expanduser("~/.openclaw/scripts"))
CRED_DIR = os.path.expanduser("~/.openclaw/credentials")
SECRET_DIR = os.path.expanduser("~/.openclaw/secrets")
DB_PATH = os.path.expanduser("~/.openclaw/data/example.db")
ASSET_PATH = os.path.expanduser("~/.openclaw/assets/sample/logo.txt")
EOF
printf '# sample skill\n' >"$LEGACY_ROOT/skills/sample-skill/SKILL.md"
printf 'tool note\n' >"$LEGACY_ROOT/shared/tools/tool.md"
printf 'reference note\n' >"$LEGACY_ROOT/shared/references/ref.md"
: >"$LEGACY_ROOT/memory/$SMOKE_AGENT.sqlite"
printf 'sqlite-placeholder\n' >"$LEGACY_ROOT/data/example.db"
printf 'asset\n' >"$LEGACY_ROOT/assets/sample/logo.txt"
printf 'extension\n' >"$LEGACY_ROOT/extensions/sample-ext/README.md"
printf '{"channels":{"discord":{"accounts":{"default":{"token":"smoke-token"}}}},"extensions":{"sample-ext":{"installPath":"~/.openclaw/extensions/sample-ext"}}}\n' >"$LEGACY_ROOT/openclaw.json"
printf 'cred\n' >"$LEGACY_ROOT/credentials/example.txt"
printf 'secret\n' >"$LEGACY_ROOT/secrets/example.token"
cat >"$LEGACY_ROOT/cron/jobs.json" <<EOF
{
  "jobs": [
    {
      "id": "legacy-job-1",
      "name": "morning-briefing-smoke",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      },
      "payload": {
        "text": "python3 ~/.openclaw/scripts/morning-briefing.py\nsessions_history(sessionKey=\"agent:smoke-agent:discord:channel:123\")\nsessions_send(sessionKey=\"agent:smoke-helper:discord:channel:123\", message=\"[ALERT] check queue\")\nexec: openclaw message send --channel discord --account smoke --target \"123\" --message \"done\""
      }
    }
  ]
}
EOF
mkdir -p "$BRIDGE_HOME/shared"
cat >"$BRIDGE_HOME/shared/runtime-note.md" <<'EOF'
Legacy ref: ~/.openclaw/skills/shopify-api and agent-db are still mentioned here.
EOF
RUNTIME_INVENTORY_OUTPUT="$("$REPO_ROOT/agent-bridge" migrate runtime inventory --bridge-home "$BRIDGE_HOME" --legacy-home "$LEGACY_ROOT" --jobs-file "$LEGACY_ROOT/cron/jobs.json")"
assert_contains "$RUNTIME_INVENTORY_OUTPUT" "cron_with_legacy_refs: 1"
assert_contains "$RUNTIME_INVENTORY_OUTPUT" "files_with_legacy_refs: 1"
assert_contains "$RUNTIME_INVENTORY_OUTPUT" "skills: 1"
assert_contains "$RUNTIME_INVENTORY_OUTPUT" "notify: 1"

log "importing recurring jobs into the bridge-native cron store"
CRON_IMPORT_DRY_RUN_OUTPUT="$("$REPO_ROOT/agent-bridge" cron import --source-jobs-file "$LEGACY_ROOT/cron/jobs.json" --dry-run)"
assert_contains "$CRON_IMPORT_DRY_RUN_OUTPUT" "\"status\": \"dry_run\""
assert_contains "$CRON_IMPORT_DRY_RUN_OUTPUT" "\"imported_jobs\": 1"
CRON_IMPORT_OUTPUT="$("$REPO_ROOT/agent-bridge" cron import --source-jobs-file "$LEGACY_ROOT/cron/jobs.json")"
assert_contains "$CRON_IMPORT_OUTPUT" "\"status\": \"imported\""
CRON_IMPORTED_SHOW_OUTPUT="$("$REPO_ROOT/agent-bridge" cron show morning-briefing-smoke)"
assert_contains "$CRON_IMPORTED_SHOW_OUTPUT" "morning-briefing-smoke"
CRON_IMPORTED_SYNC_OUTPUT="$("$REPO_ROOT/agent-bridge" cron sync --dry-run --since '2026-04-05T08:59:00+00:00' --now '2026-04-05T09:00:00+00:00')"
assert_contains "$CRON_IMPORTED_SYNC_OUTPUT" "native: status=dry_run"
assert_contains "$CRON_IMPORTED_SYNC_OUTPUT" "due=1"

log "checkpointing cron sync progress only through the successful prefix"
SCHEDULER_JOBS_FILE="$TMP_ROOT/scheduler-jobs.json"
SCHEDULER_STATE_FILE="$TMP_ROOT/scheduler-state.json"
SCHEDULER_ENQUEUE_LOG="$TMP_ROOT/scheduler-enqueue.log"
SCHEDULER_FAIL_MARK="$TMP_ROOT/scheduler-job-b.failed"
SCHEDULER_BRIDGE_CRON="$TMP_ROOT/fake-bridge-cron.sh"
cat >"$SCHEDULER_JOBS_FILE" <<EOF
{
  "jobs": [
    {
      "id": "job-a",
      "name": "job-a",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      }
    },
    {
      "id": "job-b",
      "name": "job-b",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      }
    },
    {
      "id": "job-c",
      "name": "job-c",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      }
    }
  ]
}
EOF
cat >"$SCHEDULER_BRIDGE_CRON" <<EOF
#!/usr/bin/env bash
set -euo pipefail

command="\${1:-}"
shift || true
[[ "\$command" == "enqueue" ]] || exit 64

job_id="\${1:-}"
printf '%s\n' "\$job_id" >>"$SCHEDULER_ENQUEUE_LOG"

if [[ "\$job_id" == "job-b" && ! -f "$SCHEDULER_FAIL_MARK" ]]; then
  : >"$SCHEDULER_FAIL_MARK"
  printf 'simulated failure for %s\n' "\$job_id" >&2
  exit 1
fi

printf 'created task #1\n'
EOF
chmod +x "$SCHEDULER_BRIDGE_CRON"

set +e
SCHEDULER_FIRST_OUTPUT="$(
  python3 "$REPO_ROOT/bridge-cron-scheduler.py" sync \
    --jobs-file "$SCHEDULER_JOBS_FILE" \
    --state-file "$SCHEDULER_STATE_FILE" \
    --bridge-cron "$SCHEDULER_BRIDGE_CRON" \
    --repo-root "$TMP_ROOT" \
    --since '2026-04-05T08:59:00+00:00' \
    --now '2026-04-05T09:00:00+00:00' 2>&1
)"
SCHEDULER_FIRST_CODE=$?
set -e
[[ $SCHEDULER_FIRST_CODE -eq 1 ]] || die "expected first scheduler run to fail once"
assert_contains "$SCHEDULER_FIRST_OUTPUT" "errors: 1"
[[ "$(paste -sd ' ' "$SCHEDULER_ENQUEUE_LOG")" == "job-a job-b" ]] || die "expected scheduler to stop after first enqueue failure"
python3 - <<'PY' "$SCHEDULER_STATE_FILE"
import json
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
assert payload["last_sync_key"]["job_id"] == "job-a", payload
PY

SCHEDULER_SECOND_OUTPUT="$(
  python3 "$REPO_ROOT/bridge-cron-scheduler.py" sync \
    --jobs-file "$SCHEDULER_JOBS_FILE" \
    --state-file "$SCHEDULER_STATE_FILE" \
    --bridge-cron "$SCHEDULER_BRIDGE_CRON" \
    --repo-root "$TMP_ROOT" \
    --now '2026-04-05T09:00:00+00:00' 2>&1
)"
assert_contains "$SCHEDULER_SECOND_OUTPUT" "errors: 0"
[[ "$(paste -sd ' ' "$SCHEDULER_ENQUEUE_LOG")" == "job-a job-b job-b job-c" ]] || die "expected scheduler retry to resume from the failed same-timestamp sibling"
python3 - <<'PY' "$SCHEDULER_STATE_FILE"
import json
import sys
from datetime import datetime, timezone

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
cursor = datetime.fromisoformat(payload["last_sync_at"]).astimezone(timezone.utc)
assert cursor.isoformat(timespec="seconds").startswith("2026-04-05T09:00:00"), payload
assert "last_sync_key" not in payload, payload
PY

SCHEDULER_THIRD_OUTPUT="$(
  python3 "$REPO_ROOT/bridge-cron-scheduler.py" sync \
    --jobs-file "$SCHEDULER_JOBS_FILE" \
    --state-file "$SCHEDULER_STATE_FILE" \
    --bridge-cron "$SCHEDULER_BRIDGE_CRON" \
    --repo-root "$TMP_ROOT" \
    --now '2026-04-05T09:00:00+00:00' 2>&1
)"
assert_contains "$SCHEDULER_THIRD_OUTPUT" "errors: 0"
[[ "$(paste -sd ' ' "$SCHEDULER_ENQUEUE_LOG")" == "job-a job-b job-b job-c" ]] || die "expected completed scheduler sync to avoid replaying the finished bucket"

log "syncing bridge-local runtime roots from legacy source"
RUNTIME_SYNC_OUTPUT="$(BRIDGE_OPENCLAW_HOME="$LEGACY_ROOT" BRIDGE_RUNTIME_ROOT="$BRIDGE_HOME/runtime" "$REPO_ROOT/agent-bridge" migrate runtime sync)"
assert_contains "$RUNTIME_SYNC_OUTPUT" "item[scripts]"
[[ -f "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" ]] || die "expected runtime scripts copy"
[[ -f "$BRIDGE_HOME/runtime/skills/sample-skill/SKILL.md" ]] || die "expected runtime skills copy"
[[ -f "$BRIDGE_HOME/runtime/shared/tools/tool.md" ]] || die "expected runtime shared tools copy"
[[ -f "$BRIDGE_HOME/runtime/shared/references/ref.md" ]] || die "expected runtime shared references copy"
[[ -f "$BRIDGE_HOME/runtime/memory/$SMOKE_AGENT.sqlite" ]] || die "expected runtime memory copy"
[[ -f "$BRIDGE_HOME/runtime/data/example.db" ]] || die "expected runtime data copy"
[[ -f "$BRIDGE_HOME/runtime/assets/sample/logo.txt" ]] || die "expected runtime assets copy"
[[ -f "$BRIDGE_HOME/runtime/extensions/sample-ext/README.md" ]] || die "expected runtime extensions copy"
[[ -f "$BRIDGE_HOME/runtime/credentials/example.txt" ]] || die "expected runtime credentials copy"
[[ -f "$BRIDGE_HOME/runtime/secrets/example.token" ]] || die "expected runtime secrets copy"
[[ -f "$BRIDGE_HOME/runtime/openclaw.json" ]] || die "expected runtime config copy"

RUNTIME_COMPAT_PATHS_OUTPUT="$("$BASH4_BIN" -c "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; printf '%s\n%s\n%s\n' \"\$(bridge_compat_config_file)\" \"\$(bridge_compat_credentials_dir)\" \"\$(bridge_compat_secrets_dir)\"")"
assert_contains "$RUNTIME_COMPAT_PATHS_OUTPUT" "$BRIDGE_HOME/runtime/openclaw.json"
assert_contains "$RUNTIME_COMPAT_PATHS_OUTPUT" "$BRIDGE_HOME/runtime/credentials"
assert_contains "$RUNTIME_COMPAT_PATHS_OUTPUT" "$BRIDGE_HOME/runtime/secrets"

log "rewriting cron payloads to bridge-local runtime paths"
RUNTIME_REWRITE_OUTPUT="$("$REPO_ROOT/agent-bridge" migrate runtime rewrite-cron --bridge-home "$BRIDGE_HOME" --legacy-home "$LEGACY_ROOT" --jobs-file "$LEGACY_ROOT/cron/jobs.json")"
assert_contains "$RUNTIME_REWRITE_OUTPUT" "status: rewritten"
assert_contains "$RUNTIME_REWRITE_OUTPUT" "changed_jobs: 1"
grep -q "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" "$LEGACY_ROOT/cron/jobs.json" || die "expected rewritten runtime script path"
grep -q 'agent-bridge task create --to smoke-helper' "$LEGACY_ROOT/cron/jobs.json" || die "expected rewritten runtime handoff guidance"
grep -q 'needs_human_followup=true' "$LEGACY_ROOT/cron/jobs.json" || die "expected rewritten runtime follow-up guidance"
! grep -q 'sessions_send' "$LEGACY_ROOT/cron/jobs.json" || die "expected sessions_send removed from cron payload"
! grep -q 'openclaw message send' "$LEGACY_ROOT/cron/jobs.json" || die "expected direct send removed from cron payload"
! grep -q 'sessions_history' "$LEGACY_ROOT/cron/jobs.json" || die "expected sessions_history removed from cron payload"

log "rewriting copied runtime files to bridge-local paths"
RUNTIME_FILE_REWRITE_OUTPUT="$("$REPO_ROOT/agent-bridge" migrate runtime rewrite-files --bridge-home "$BRIDGE_HOME" --legacy-home "$LEGACY_ROOT" --runtime-root "$BRIDGE_HOME/runtime")"
assert_contains "$RUNTIME_FILE_REWRITE_OUTPUT" "status: rewritten"
grep -q "$BRIDGE_HOME/runtime/scripts" "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" || die "expected rewritten runtime scripts import path"
grep -q "$BRIDGE_HOME/runtime/credentials" "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" || die "expected rewritten runtime credentials path"
grep -q "$BRIDGE_HOME/runtime/secrets" "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" || die "expected rewritten runtime secrets path"
grep -q "$BRIDGE_HOME/runtime/data/example.db" "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" || die "expected rewritten runtime data path"
grep -q "$BRIDGE_HOME/runtime/assets/sample/logo.txt" "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" || die "expected rewritten runtime asset path"
grep -q "$BRIDGE_HOME/runtime/extensions/sample-ext" "$BRIDGE_HOME/runtime/openclaw.json" || die "expected rewritten runtime extension installPath"

log "overlaying repo-managed runtime canonical templates"
RUNTIME_CANON_OUTPUT="$("$REPO_ROOT/agent-bridge" migrate runtime canonicalize --runtime-root "$BRIDGE_HOME/runtime")"
assert_contains "$RUNTIME_CANON_OUTPUT" "overlay[scripts/call-shopify.sh]"
assert_contains "$RUNTIME_CANON_OUTPUT" "overlay[scripts/email-webhook-handler.py]"
assert_contains "$RUNTIME_CANON_OUTPUT" "overlay[scripts/webhook_utils.py]"
assert_contains "$RUNTIME_CANON_OUTPUT" "overlay[skills/agent-db/scripts/email-sync.py]"
grep -q 'task create' "$BRIDGE_HOME/runtime/scripts/call-shopify.sh" || die "expected bridge-native task delivery in call-shopify"
grep -q 'bridge-notify.py' "$BRIDGE_HOME/runtime/scripts/call-shopify.sh" || die "expected bridge-native notify helper in call-shopify"
grep -q '\[cron-failure\] recurring failures detected' "$BRIDGE_HOME/runtime/scripts/cron-failure-monitor.sh" || die "expected bridge-native cron failure title"
grep -q 'queue-based A2A is the source of truth' "$BRIDGE_HOME/runtime/scripts/patch-a2a-bridge.sh" || die "expected deprecated A2A bridge stub"
grep -q 'agent-bridge setup agent' "$BRIDGE_HOME/runtime/skills/agent-factory/scripts/create-agent.sh" || die "expected bridge-native setup guidance in create-agent"
grep -q 'agent-bridge task create' "$BRIDGE_HOME/runtime/scripts/email-webhook-handler.py" || die "expected queue handoff in email webhook handler"
grep -q 'queue-dispatch' "$BRIDGE_HOME/runtime/scripts/webhook_utils.py" || die "expected bridge-native one-shot cron helper in webhook utils"
grep -q 'gws_api' "$BRIDGE_HOME/runtime/skills/agent-db/scripts/email-sync.py" || die "expected gws-backed email sync script"

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
  "openclaw_agent": "$SMOKE_AGENT",
  "target_agent": "$SMOKE_AGENT",
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

CRON_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "[cron-dispatch] smoke-job (2026-04-05T10:00:00Z)" --body-file "$DISPATCH_BODY" --from smoke-test)"
[[ "$CRON_CREATE_OUTPUT" =~ created\ task\ \#([0-9]+) ]] || die "could not parse cron dispatch task id"
CRON_TASK_ID="${BASH_REMATCH[1]}"

bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null

for _ in $(seq 1 20); do
  SHOW_CRON_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show "$CRON_TASK_ID")"
  if [[ "$SHOW_CRON_OUTPUT" == *"status: done"* ]]; then
    break
  fi
  sleep 0.25
done

assert_contains "$SHOW_CRON_OUTPUT" "status: done"
[[ -f "$RUN_DIR/result.json" ]] || die "cron worker did not write result artifact"

log "smoke test passed"
