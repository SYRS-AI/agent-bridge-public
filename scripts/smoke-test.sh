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

wait_for_tmux_session() {
  local session="$1"
  local expected="${2:-up}"
  local attempts="${3:-20}"
  local delay="${4:-0.2}"
  local i=0

  for ((i = 0; i < attempts; i++)); do
    if tmux has-session -t "$session" >/dev/null 2>&1; then
      [[ "$expected" == "up" ]] && return 0
    else
      [[ "$expected" == "down" ]] && return 0
    fi
    sleep "$delay"
  done
  return 1
}

kill_stale_smoke_tmux_sessions() {
  local session=""

  while IFS= read -r session; do
    [[ -n "$session" ]] || continue
    case "$session" in
      bridge-smoke-*|bridge-requester-*|auto-start-session-*|always-on-session-*|static-session-*|claude-static-bridge-smoke-*|worker-reuse-*|late-dynamic-agent-*|created-session-*|bootstrap-session-*|bootstrap-wrapper-session-*|broken-channel-*|codex-cli-session-*|project-claude-session-bridge-smoke-*)
        tmux kill-session -t "$session" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
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
export BRIDGE_DISCORD_RELAY_ENABLED=0
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
export BRIDGE_RUNTIME_CONFIG_FILE="$BRIDGE_RUNTIME_ROOT/bridge-config.json"
export BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE="$TMP_ROOT/installed_plugins.json"
export BRIDGE_CLAUDE_CHANNELS_HOME="$TMP_ROOT/claude-channels"
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
CODEX_CLI_AGENT="codex-cli-agent-$$"
CODEX_CLI_SESSION="codex-cli-session-$$"
LATE_DYNAMIC_AGENT="late-dynamic-agent-$$"
LATE_DYNAMIC_SESSION="late-dynamic-session-$$"
STALE_RESUME_AGENT="stale-resume-agent-$$"
WORKTREE_AGENT="worker-reuse-$$"
CREATED_AGENT="created-agent-$$"
CREATED_SESSION="created-session-$$"
INIT_AGENT="bootstrap-admin-$$"
INIT_SESSION="bootstrap-session-$$"
BOOTSTRAP_AGENT="bootstrap-wrapper-$$"
BOOTSTRAP_SESSION="bootstrap-wrapper-session-$$"
BOOTSTRAP_RCFILE="$TMP_ROOT/bootstrap-shell.rc"
BROKEN_CHANNEL_AGENT="broken-channel-$$"
WORKDIR="$TMP_ROOT/workdir"
REQUESTER_WORKDIR="$TMP_ROOT/requester-workdir"
AUTO_START_WORKDIR="$TMP_ROOT/auto-start-workdir"
BROKEN_CHANNEL_WORKDIR="$TMP_ROOT/broken-channel-workdir"
LATE_DYNAMIC_WORKDIR="$TMP_ROOT/late-dynamic-workdir"
PROJECT_ROOT="$TMP_ROOT/git-project"
HOOK_WORKDIR="$TMP_ROOT/claude-hook-workdir"
MCP_WORKDIR="$TMP_ROOT/claude-mcp-workdir"
CLAUDE_STATIC_WORKDIR="$BRIDGE_HOME/agents/claude-static"
FAKE_BIN="$TMP_ROOT/bin"
FAKE_DISCORD_PORT_FILE="$TMP_ROOT/fake-discord.port"
FAKE_DISCORD_REQUESTS="$TMP_ROOT/fake-discord-requests.jsonl"
FAKE_DISCORD_PID=""
FAKE_TELEGRAM_PORT_FILE="$TMP_ROOT/fake-telegram.port"
FAKE_TELEGRAM_REQUESTS="$TMP_ROOT/fake-telegram-requests.jsonl"
FAKE_TELEGRAM_PID=""
TOKENFILE_ENV="$TMP_ROOT/tokenfile-telegram.env"
CODEX_HOOKS_FILE="$TMP_ROOT/codex-home/.codex/hooks.json"
LIVE_ROSTER_FILE="$HOME/.agent-bridge/agent-roster.local.sh"
LIVE_ROSTER_BACKUP="$TMP_ROOT/live-agent-roster.local.sh.bak"
LIVE_ROSTER_PRESENT=0

if [[ -f "$LIVE_ROSTER_FILE" ]]; then
  cp "$LIVE_ROSTER_FILE" "$LIVE_ROSTER_BACKUP"
  LIVE_ROSTER_PRESENT=1
fi

[[ "$BRIDGE_ROSTER_LOCAL_FILE" != "$LIVE_ROSTER_FILE" ]] || die "smoke roster must not target the live roster"

cleanup() {
  local status=$?
  bash "$REPO_ROOT/bridge-daemon.sh" stop >/dev/null 2>&1 || true
  kill_stale_smoke_tmux_sessions
  tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
  tmux kill-session -t "$REQUESTER_SESSION" >/dev/null 2>&1 || true
  tmux kill-session -t "$AUTO_START_SESSION" >/dev/null 2>&1 || true
  tmux kill-session -t "$ALWAYS_ON_SESSION" >/dev/null 2>&1 || true
  tmux kill-session -t "$STATIC_SESSION" >/dev/null 2>&1 || true
  tmux kill-session -t "$CLAUDE_STATIC_SESSION" >/dev/null 2>&1 || true
  tmux kill-session -t "$WORKTREE_AGENT" >/dev/null 2>&1 || true
  tmux kill-session -t "$LATE_DYNAMIC_SESSION" >/dev/null 2>&1 || true
  if [[ -n "$FAKE_DISCORD_PID" ]]; then
    kill "$FAKE_DISCORD_PID" >/dev/null 2>&1 || true
    wait "$FAKE_DISCORD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$FAKE_TELEGRAM_PID" ]]; then
    kill "$FAKE_TELEGRAM_PID" >/dev/null 2>&1 || true
    wait "$FAKE_TELEGRAM_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$LIVE_ROSTER_PRESENT" == "1" ]] && ! cmp -s "$LIVE_ROSTER_BACKUP" "$LIVE_ROSTER_FILE"; then
    cp "$LIVE_ROSTER_BACKUP" "$LIVE_ROSTER_FILE"
    printf '[smoke][error] live roster changed during smoke; restored backup: %s\n' "$LIVE_ROSTER_FILE" >&2
    status=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

kill_stale_smoke_tmux_sessions

mkdir -p "$BRIDGE_HOME" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR" "$WORKDIR" "$REQUESTER_WORKDIR" "$AUTO_START_WORKDIR" "$BROKEN_CHANNEL_WORKDIR" "$LATE_DYNAMIC_WORKDIR"
mkdir -p "$HOOK_WORKDIR/.claude"
mkdir -p "$MCP_WORKDIR"
mkdir -p "$CLAUDE_STATIC_WORKDIR"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

mkdir -p "$PROJECT_ROOT"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
git -C "$PROJECT_ROOT" init -q
git -C "$PROJECT_ROOT" config user.email smoke-test
git -C "$PROJECT_ROOT" config user.name "Smoke Test"
echo "smoke" >"$PROJECT_ROOT/README.md"
git -C "$PROJECT_ROOT" add README.md
git -C "$PROJECT_ROOT" commit -qm "init"

log "cleaning stale smoke tmux sessions by prefix"
tmux new-session -d -s "bootstrap-session-stale-smoke" "sleep 30"
tmux new-session -d -s "codex-cli-session-stale-smoke" "sleep 30"
kill_stale_smoke_tmux_sessions
tmux has-session -t "bootstrap-session-stale-smoke" >/dev/null 2>&1 && die "stale bootstrap session survived smoke cleanup helper"
tmux has-session -t "codex-cli-session-stale-smoke" >/dev/null 2>&1 && die "stale codex session survived smoke cleanup helper"

cat >"$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"item.completed","item":{"type":"agent_message","text":"{\"status\":\"completed\",\"summary\":\"cron smoke ok\",\"findings\":[],\"actions_taken\":[\"processed cron dispatch\"],\"needs_human_followup\":false,\"recommended_next_steps\":[],\"artifacts\":[],\"confidence\":\"high\"}"}}
JSON
EOF
chmod +x "$FAKE_BIN/codex"
cp "$FAKE_BIN/codex" "$TMP_ROOT/codex-cron-fake"

cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
bridge_add_agent_id_if_missing "$SMOKE_AGENT"
bridge_add_agent_id_if_missing "$REQUESTER_AGENT"
bridge_add_agent_id_if_missing "$AUTO_START_AGENT"
bridge_add_agent_id_if_missing "$ALWAYS_ON_AGENT"
bridge_add_agent_id_if_missing "$CODEX_CLI_AGENT"
bridge_add_agent_id_if_missing "claude-static"
BRIDGE_ADMIN_AGENT_ID="$SMOKE_AGENT"
BRIDGE_AGENT_DESC["$SMOKE_AGENT"]="Smoke test role"
BRIDGE_AGENT_DESC["$REQUESTER_AGENT"]="Requester role"
BRIDGE_AGENT_DESC["$AUTO_START_AGENT"]="Auto-start role"
BRIDGE_AGENT_DESC["$ALWAYS_ON_AGENT"]="Always-on role"
BRIDGE_AGENT_DESC["$CODEX_CLI_AGENT"]="Codex CLI hook role"
BRIDGE_AGENT_DESC["claude-static"]="Claude static role"
BRIDGE_AGENT_ENGINE["$SMOKE_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["$REQUESTER_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["$AUTO_START_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["$ALWAYS_ON_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["$CODEX_CLI_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["claude-static"]="claude"
BRIDGE_AGENT_SESSION["$SMOKE_AGENT"]="$SESSION_NAME"
BRIDGE_AGENT_SESSION["$REQUESTER_AGENT"]="$REQUESTER_SESSION"
BRIDGE_AGENT_SESSION["$AUTO_START_AGENT"]="$AUTO_START_SESSION"
BRIDGE_AGENT_SESSION["$ALWAYS_ON_AGENT"]="$ALWAYS_ON_SESSION"
BRIDGE_AGENT_SESSION["$CODEX_CLI_AGENT"]="$CODEX_CLI_SESSION"
BRIDGE_AGENT_SESSION["claude-static"]="claude-static-$SESSION_NAME"
BRIDGE_AGENT_WORKDIR["$SMOKE_AGENT"]="$WORKDIR"
BRIDGE_AGENT_WORKDIR["$REQUESTER_AGENT"]="$REQUESTER_WORKDIR"
BRIDGE_AGENT_WORKDIR["$AUTO_START_AGENT"]="$AUTO_START_WORKDIR"
BRIDGE_AGENT_WORKDIR["$ALWAYS_ON_AGENT"]="$AUTO_START_WORKDIR"
BRIDGE_AGENT_WORKDIR["$CODEX_CLI_AGENT"]="$WORKDIR"
BRIDGE_AGENT_WORKDIR["claude-static"]="$CLAUDE_STATIC_WORKDIR"
BRIDGE_AGENT_DISCORD_CHANNEL_ID["$SMOKE_AGENT"]="123456789012345678"
BRIDGE_AGENT_NOTIFY_ACCOUNT["$SMOKE_AGENT"]="smoke"
BRIDGE_AGENT_CHANNELS["claude-static"]="plugin:discord@claude-plugins-official"
BRIDGE_CRON_AGENT_TARGET["legacy-ops"]="$AUTO_START_AGENT"
BRIDGE_AGENT_LAUNCH_CMD["$SMOKE_AGENT"]='python3 -c "import time; print(\"smoke-agent ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["$REQUESTER_AGENT"]='python3 -c "import time; print(\"requester-agent ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["$AUTO_START_AGENT"]='python3 -c "import time; print(\"auto-start ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["$ALWAYS_ON_AGENT"]='python3 -c "import time; print(\"always-on ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["$CODEX_CLI_AGENT"]='codex'
BRIDGE_AGENT_LAUNCH_CMD["claude-static"]='DISCORD_STATE_DIR=REPLACE_CLAUDE_DISCORD claude -c --dangerously-skip-permissions'
BRIDGE_AGENT_IDLE_TIMEOUT["$ALWAYS_ON_AGENT"]="0"
EOF

python3 - "$BRIDGE_ROSTER_LOCAL_FILE" "$CLAUDE_STATIC_WORKDIR/.discord" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("REPLACE_CLAUDE_DISCORD", sys.argv[2]), encoding="utf-8")
PY

mkdir -p "$CLAUDE_STATIC_WORKDIR/.discord"
cat >"$CLAUDE_STATIC_WORKDIR/.discord/.env" <<'EOF'
DISCORD_BOT_TOKEN=smoke-token
EOF
cat >"$CLAUDE_STATIC_WORKDIR/.discord/access.json" <<'EOF'
{
  "groups": {
    "123456789012345678": {
      "requireMention": false
    }
  }
}
EOF

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
    },
    "telegram": {
      "accounts": {
        "smoke": {
          "token": "smoke-telegram-token"
        }
      }
    }
  }
}
EOF

cat >"$BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE" <<'EOF'
{
  "version": 1,
  "plugins": {
    "telegram@claude-plugins-official": [
      {
        "scope": "user",
        "installPath": "/tmp/telegram",
        "version": "1.0.0"
      }
    ],
    "discord@claude-plugins-official": [
      {
        "scope": "user",
        "installPath": "/tmp/discord",
        "version": "1.0.0"
      }
    ]
  }
}
EOF
mkdir -p "$BRIDGE_CLAUDE_CHANNELS_HOME/telegram" "$BRIDGE_CLAUDE_CHANNELS_HOME/discord"
cat >"$BRIDGE_CLAUDE_CHANNELS_HOME/telegram/.env" <<'EOF'
TELEGRAM_BOT_TOKEN=plugin-telegram-token
EOF
cat >"$BRIDGE_CLAUDE_CHANNELS_HOME/discord/.env" <<'EOF'
DISCORD_BOT_TOKEN=plugin-discord-token
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
python3 - "$TMP_ROOT/openclaw.json" "$FAKE_DISCORD_API_BASE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload.setdefault("channels", {}).setdefault("discord", {}).setdefault("accounts", {}).setdefault("smoke", {})["apiBaseUrl"] = sys.argv[2]
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

log "starting fake Telegram API"
python3 -u - "$FAKE_TELEGRAM_PORT_FILE" "$FAKE_TELEGRAM_REQUESTS" <<'PY' >/dev/null 2>&1 &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, requests_file = sys.argv[1], sys.argv[2]
TOKEN = "smoke-telegram-token"

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

    def do_GET(self):
        if self.path == f"/bot{TOKEN}/getMe":
            self._send(200, {"ok": True, "result": {"id": "4242", "username": "smoke_telegram_bot"}})
            return
        self._send(404, {"ok": False, "description": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else "{}"
        with open(requests_file, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"path": self.path, "body": json.loads(body)}) + "\n")
        if self.path == f"/bot{TOKEN}/sendMessage":
            self._send(200, {"ok": True, "result": {"message_id": 1}})
            return
        self._send(404, {"ok": False, "description": "not found"})

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
FAKE_TELEGRAM_PID=$!

for _ in $(seq 1 50); do
  [[ -f "$FAKE_TELEGRAM_PORT_FILE" ]] && break
  sleep 0.1
done
[[ -f "$FAKE_TELEGRAM_PORT_FILE" ]] || die "fake Telegram API failed to start"
FAKE_TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$FAKE_TELEGRAM_PORT_FILE")"
python3 - "$TMP_ROOT/openclaw.json" "$FAKE_TELEGRAM_API_BASE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload.setdefault("channels", {}).setdefault("telegram", {}).setdefault("accounts", {}).setdefault("smoke", {})["apiBaseUrl"] = sys.argv[2]
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
mkdir -p "$BRIDGE_RUNTIME_ROOT"
cp "$TMP_ROOT/openclaw.json" "$BRIDGE_RUNTIME_CONFIG_FILE"

log "verifying empty runtime starts clean"
BRIDGE_ROSTER_LOCAL_FILE=/nonexistent bash "$REPO_ROOT/bridge-start.sh" --list >/dev/null

log "starting isolated daemon"
bash "$REPO_ROOT/bridge-daemon.sh" ensure >/dev/null
DAEMON_STATUS=""
for _ in {1..20}; do
  DAEMON_STATUS="$(bash "$REPO_ROOT/bridge-daemon.sh" status || true)"
  if [[ "$DAEMON_STATUS" == *"running pid="* ]]; then
    break
  fi
  sleep 0.2
done
assert_contains "$DAEMON_STATUS" "running pid="

log "starting isolated tmux role"
bash "$REPO_ROOT/bridge-start.sh" "$SMOKE_AGENT" >/dev/null
bash "$REPO_ROOT/bridge-start.sh" "$REQUESTER_AGENT" >/dev/null
wait_for_tmux_session "$SESSION_NAME" up 20 0.2 || die "smoke tmux session was not created"
wait_for_tmux_session "$REQUESTER_SESSION" up 20 0.2 || die "requester tmux session was not created"

log "syncing live roster"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null

LIST_OUTPUT="$("$REPO_ROOT/agent-bridge" list)"
assert_contains "$LIST_OUTPUT" "$SMOKE_AGENT"

STATUS_OUTPUT="$("$REPO_ROOT/agent-bridge" status --all-agents)"
assert_contains "$STATUS_OUTPUT" "$SMOKE_AGENT"
assert_contains "$STATUS_OUTPUT" "state"
assert_contains "$STATUS_OUTPUT" "$WORKDIR"
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
QUEUE_TASK_ID="$(printf '%s\n' "$CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$QUEUE_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse queue task id"

log "preferring BRIDGE_AGENT_ID when inferring task sender"
INFERRED_CREATE_OUTPUT="$(BRIDGE_AGENT_ID="$REQUESTER_AGENT" bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "env inferred queue" --body "env inferred body" 2>&1)"
assert_contains "$INFERRED_CREATE_OUTPUT" "[hint] --from omitted; inferred sender: $REQUESTER_AGENT"
assert_contains "$INFERRED_CREATE_OUTPUT" "created task #"
INFERRED_TASK_ID="$(printf '%s\n' "$INFERRED_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$INFERRED_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse inferred task id"
INFERRED_TASK_SHELL="$(python3 "$REPO_ROOT/bridge-queue.py" show "$INFERRED_TASK_ID" --format shell)"
assert_contains "$INFERRED_TASK_SHELL" "TASK_CREATED_BY=$REQUESTER_AGENT"

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
bash "$REPO_ROOT/bridge-task.sh" claim "$QUEUE_TASK_ID" --agent "$SMOKE_AGENT" >/dev/null
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
python3 "$REPO_ROOT/bridge-queue.py" done "$QUEUE_TASK_ID" --agent "$SMOKE_AGENT" --note "smoke ok" >/dev/null
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

SHOW_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show "$QUEUE_TASK_ID")"
assert_contains "$SHOW_OUTPUT" "status: done"
assert_contains "$SHOW_OUTPUT" "note: smoke ok"

NOTICE_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "smoke queue notice" --body-file "$BRIDGE_SHARED_DIR/note.md" --from "$REQUESTER_AGENT")"
assert_contains "$NOTICE_CREATE_OUTPUT" "created task #"
NOTICE_TASK_ID="$(printf '%s\n' "$NOTICE_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$NOTICE_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse notice task id"
bash "$REPO_ROOT/bridge-task.sh" "done" "$NOTICE_TASK_ID" --agent "$SMOKE_AGENT" --note "notice ok" >/dev/null

REQUESTER_INBOX_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" inbox "$REQUESTER_AGENT")"
assert_contains "$REQUESTER_INBOX_OUTPUT" "[task-complete] smoke queue notice"
REQUESTER_NOTICE_TASK_ID="$(REQUESTER_AGENT="$REQUESTER_AGENT" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
agent = os.environ["REQUESTER_AGENT"]
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT id FROM tasks WHERE assigned_to = ? AND title = ? ORDER BY id DESC LIMIT 1",
        (agent, "[task-complete] smoke queue notice"),
    ).fetchone()
print(int(row[0]) if row else 0)
PY
)"
[[ "$REQUESTER_NOTICE_TASK_ID" =~ ^[0-9]+$ ]] || die "completion notice task id was not numeric: $REQUESTER_NOTICE_TASK_ID"
(( REQUESTER_NOTICE_TASK_ID > 0 )) || die "completion notice task was not created"
REQUESTER_SHOW_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show "$REQUESTER_NOTICE_TASK_ID")"
assert_contains "$REQUESTER_SHOW_OUTPUT" "assigned_to: $REQUESTER_AGENT"
assert_contains "$REQUESTER_SHOW_OUTPUT" "original_task: #$NOTICE_TASK_ID"
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
wait_for_tmux_session "$ALWAYS_ON_SESSION" up 25 0.2 || die "always-on role did not restart without queue"

log "keeping a manually killed always-on role down until explicit restart"
"$REPO_ROOT/agent-bridge" kill "$ALWAYS_ON_AGENT" >/dev/null
sleep 2
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
wait_for_tmux_session "$ALWAYS_ON_SESSION" down 10 0.2 || die "always-on role respawned after manual kill"
"$REPO_ROOT/agent-bridge" agent start "$ALWAYS_ON_AGENT" >/dev/null
wait_for_tmux_session "$ALWAYS_ON_SESSION" up 25 0.2 || die "always-on role did not restart after explicit start"

log "running guided Discord setup"
SETUP_DISCORD_OUTPUT="$("$REPO_ROOT/agent-bridge" setup discord "claude-static" --channel-account smoke --channel 123456789012345678 --runtime-config "$TMP_ROOT/openclaw.json" --api-base-url "$FAKE_DISCORD_API_BASE" --yes)"
assert_contains "$SETUP_DISCORD_OUTPUT" "validation: ok"
assert_contains "$SETUP_DISCORD_OUTPUT" "token_source: channel:smoke"
assert_contains "$SETUP_DISCORD_OUTPUT" "channel 123456789012345678: read=ok send=ok"
[[ -f "$CLAUDE_STATIC_WORKDIR/.discord/.env" ]] || die "setup discord did not create .env"
[[ -f "$CLAUDE_STATIC_WORKDIR/.discord/access.json" ]] || die "setup discord did not create access.json"
assert_contains "$(cat "$CLAUDE_STATIC_WORKDIR/.discord/.env")" "DISCORD_BOT_TOKEN=smoke-token"
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_AGENT_NOTIFY_ACCOUNT[\"claude-static\"]=\"smoke\""
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_AGENT_CHANNELS[\"claude-static\"]=\"plugin:discord@claude-plugins-official\""
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_AGENT_DISCORD_CHANNEL_ID[\"claude-static\"]=\"123456789012345678\""
assert_contains "$(cat "$FAKE_DISCORD_REQUESTS")" "[Agent Bridge setup]"

log "running broader agent preflight"
SETUP_AGENT_OUTPUT="$("$REPO_ROOT/agent-bridge" setup agent "$SMOKE_AGENT" --skip-discord)"
assert_contains "$SETUP_AGENT_OUTPUT" "claude_md: n/a (engine=codex)"
assert_contains "$SETUP_AGENT_OUTPUT" "wake_channel: -"
assert_contains "$SETUP_AGENT_OUTPUT" "start_dry_run: ok"

log "ensuring Codex hooks and launch override"
CODEX_HOOK_ENSURE_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-codex-hooks --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)" --codex-hooks-file "$CODEX_HOOKS_FILE")"
assert_contains "$CODEX_HOOK_ENSURE_OUTPUT" "session_start_hook: present"
assert_contains "$CODEX_HOOK_ENSURE_OUTPUT" "stop_hook: present"
assert_contains "$CODEX_HOOK_ENSURE_OUTPUT" "prompt_hook: present"
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "\"SessionStart\""
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "\"Stop\""
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "\"UserPromptSubmit\""
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "session-start.py"
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "check-inbox.py"
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "prompt_timestamp.py"
CODEX_HOOK_STATUS_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" status-codex-hooks --codex-hooks-file "$CODEX_HOOKS_FILE")"
assert_contains "$CODEX_HOOK_STATUS_OUTPUT" "status: present"
assert_contains "$CODEX_HOOK_STATUS_OUTPUT" "prompt_hook: present"
CODEX_LAUNCH_DRY_RUN="$("$REPO_ROOT/bridge-run.sh" "$CODEX_CLI_AGENT" --dry-run)"
assert_contains "$CODEX_LAUNCH_DRY_RUN" "launch=codex -c features.codex_hooks=true"
CODEX_SESSION_START_OUTPUT="$(BRIDGE_AGENT_ID="$SMOKE_AGENT" python3 "$REPO_ROOT/hooks/codex-session-start.py")"
assert_contains "$CODEX_SESSION_START_OUTPUT" "\"hookEventName\": \"SessionStart\""
assert_contains "$CODEX_SESSION_START_OUTPUT" "agb inbox $SMOKE_AGENT"
CODEX_PROMPT_OUTPUT="$(BRIDGE_AGENT_ID="$SMOKE_AGENT" BRIDGE_HOME="$BRIDGE_HOME" python3 "$REPO_ROOT/hooks/prompt_timestamp.py" --format codex)"
assert_contains "$CODEX_PROMPT_OUTPUT" "\"hookEventName\": \"UserPromptSubmit\""
assert_contains "$CODEX_PROMPT_OUTPUT" "now:"
assert_contains "$CODEX_PROMPT_OUTPUT" "session_age:"
CODEX_STOP_TASK_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "codex stop pickup" --body "pickup" --from "$REQUESTER_AGENT")"
assert_contains "$CODEX_STOP_TASK_OUTPUT" "created task #"
CODEX_STOP_TASK_ID="$(printf '%s\n' "$CODEX_STOP_TASK_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ -n "$CODEX_STOP_TASK_ID" ]] || die "expected codex stop task id"
CODEX_STOP_OUTPUT="$(printf '%s' '{"stop_hook_active": false}' | BRIDGE_AGENT_ID="$SMOKE_AGENT" BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 "$REPO_ROOT/hooks/codex-stop.py")"
assert_contains "$CODEX_STOP_OUTPUT" "\"decision\": \"block\""
assert_contains "$CODEX_STOP_OUTPUT" "agb inbox $SMOKE_AGENT"
CODEX_STOP_ACTIVE_OUTPUT="$(printf '%s' '{"stop_hook_active": true}' | BRIDGE_AGENT_ID="$SMOKE_AGENT" BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 "$REPO_ROOT/hooks/codex-stop.py")"
assert_contains "$CODEX_STOP_ACTIVE_OUTPUT" "{}"
python3 "$REPO_ROOT/bridge-queue.py" done "$CODEX_STOP_TASK_ID" --agent "$SMOKE_AGENT" --note "codex hook smoke cleanup" >/dev/null

log "nudging prompt-ready Codex sessions without waiting for idle threshold"
tmux kill-session -t "$CODEX_CLI_SESSION" >/dev/null 2>&1 || true
tmux new-session -d -s "$CODEX_CLI_SESSION" "$BASH4_BIN -lc 'printf \"› ready\\n\"; sleep 30'"
bash "$REPO_ROOT/bridge-sync.sh" >/dev/null
CODEX_READY_TASK_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to "$CODEX_CLI_AGENT" --title "codex ready pickup" --body "pickup" --from "$REQUESTER_AGENT")"
assert_contains "$CODEX_READY_TASK_OUTPUT" "created task #"
CODEX_READY_TASK_ID="$(printf '%s\n' "$CODEX_READY_TASK_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ -n "$CODEX_READY_TASK_ID" ]] || die "expected codex ready task id"
CODEX_READY_OUTPUT="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  snapshot_file="$(mktemp)"
  ready_file="$(mktemp)"
  trap "rm -f \"$snapshot_file\" \"$ready_file\"" EXIT
  bridge_write_agent_snapshot "$snapshot_file"
  bridge_write_idle_ready_agents "$ready_file"
  python3 "'"$REPO_ROOT"'/bridge-queue.py" daemon-step \
    --snapshot "$snapshot_file" \
    --lease-seconds "$BRIDGE_TASK_LEASE_SECONDS" \
    --heartbeat-window "$BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS" \
    --idle-threshold 9999 \
    --nudge-cooldown "$BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS" \
    --zombie-threshold "${BRIDGE_ZOMBIE_NUDGE_THRESHOLD:-10}" \
    --ready-agents-file "$ready_file"
')"
assert_contains "$CODEX_READY_OUTPUT" "$CODEX_CLI_AGENT"
python3 "$REPO_ROOT/bridge-queue.py" done "$CODEX_READY_TASK_ID" --agent "$CODEX_CLI_AGENT" --note "codex ready smoke cleanup" >/dev/null

log "sending an immediate normal task nudge when the target session is prompt-ready"
NORMAL_NUDGE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$CODEX_CLI_AGENT" --title "normal ready pickup" --body "pickup" --from "$REQUESTER_AGENT")"
assert_contains "$NORMAL_NUDGE_OUTPUT" "created task #"
NORMAL_NUDGE_TASK_ID="$(printf '%s\n' "$NORMAL_NUDGE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ -n "$NORMAL_NUDGE_TASK_ID" ]] || die "expected normal task id"
sleep 1
NORMAL_NUDGE_RECENT="$(tmux capture-pane -pt "$CODEX_CLI_SESSION" -S -20 2>/dev/null || true)"
assert_contains "$NORMAL_NUDGE_RECENT" "agb inbox $CODEX_CLI_AGENT"
python3 "$REPO_ROOT/bridge-queue.py" done "$NORMAL_NUDGE_TASK_ID" --agent "$CODEX_CLI_AGENT" --note "normal nudge smoke cleanup" >/dev/null
tmux kill-session -t "$CODEX_CLI_SESSION" >/dev/null 2>&1 || true

log "reloading dynamic agents inside a long-lived daemon cycle"
cat >"$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '› ready\n'
sleep 30
EOF
chmod +x "$FAKE_BIN/codex"
LATE_DYNAMIC_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  tmp_daemon="'"$TMP_ROOT"'/daemon-source.sh"
  {
    printf "%s\n" "set -euo pipefail"
    printf "SCRIPT_DIR=%q\n" "'"$REPO_ROOT"'"
    printf "%s\n" "source \"\$SCRIPT_DIR/bridge-lib.sh\""
    printf "%s\n" "bridge_load_roster"
    printf "%s\n" "daemon_info() { :; }"
    printf "%s\n" "bridge_daemon_autostart_allowed() { return 0; }"
    printf "%s\n" "bridge_daemon_note_autostart_failure() { :; }"
    printf "%s\n" "bridge_daemon_clear_autostart_failure() { :; }"
    printf "%s\n" "bridge_dashboard_post_if_changed() { :; }"
    sed -n '"'"'/^bridge_agent_heartbeat_file()/,/^CMD="${1:-}"/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
  } >"$tmp_daemon"
  source "$tmp_daemon"
  "'"$REPO_ROOT"'/agent-bridge" --codex --name "'"$LATE_DYNAMIC_AGENT"'" --workdir "'"$LATE_DYNAMIC_WORKDIR"'" --no-attach >/dev/null
  python3 "'"$REPO_ROOT"'/bridge-queue.py" create --to "'"$LATE_DYNAMIC_AGENT"'" --title "late dynamic pickup" --body "pickup" --from "'"$REQUESTER_AGENT"'" >/dev/null
  sleep 1
  cmd_sync_cycle >/dev/null
  python3 "'"$REPO_ROOT"'/bridge-queue.py" summary --agent "'"$LATE_DYNAMIC_AGENT"'" --format tsv
  python3 - <<'"'"'PY'"'"'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
agent = "'"$LATE_DYNAMIC_AGENT"'"
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT COALESCE(active, 0), COALESCE(last_nudge_ts, 0) FROM agent_state WHERE agent = ?",
        (agent,),
    ).fetchone()
if row is None:
    print("NUDGE_TS=0")
else:
    print(f"NUDGE_TS={int(row[1] or 0) if int(row[0] or 0) == 1 else 0}")
PY
')"
LATE_DYNAMIC_SUMMARY="$(printf '%s\n' "$LATE_DYNAMIC_OUTPUT" | sed -n '1p')"
LATE_DYNAMIC_NUDGE_TS="$(printf '%s\n' "$LATE_DYNAMIC_OUTPUT" | sed -n 's/^NUDGE_TS=//p' | tail -n1)"
[[ "$LATE_DYNAMIC_NUDGE_TS" =~ ^[1-9][0-9]*$ ]] || die "late dynamic agent never received a daemon nudge"
printf '%s\n' "$LATE_DYNAMIC_SUMMARY" | awk -F'\t' 'NR==1 { exit !($5 == 1 && $9 != "") }' || die "late dynamic agent was not marked active in queue summary"
cp "$TMP_ROOT/codex-cron-fake" "$FAKE_BIN/codex"
chmod +x "$FAKE_BIN/codex"

log "reaping idle dynamic agents and orphan smoke sessions"
IDLE_REAP_AGENT="idle-reap-agent-$SESSION_NAME"
IDLE_REAP_WORKDIR="$TMP_ROOT/idle-reap-workdir"
ORPHAN_REAP_SESSION="bridge-smoke-orphan-$SESSION_NAME"
mkdir -p "$IDLE_REAP_WORKDIR"
IDLE_REAP_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  tmp_daemon="'"$TMP_ROOT"'/daemon-reaper.sh"
  {
    printf "%s\n" "set -euo pipefail"
    printf "SCRIPT_DIR=%q\n" "'"$REPO_ROOT"'"
    printf "%s\n" "source \"\$SCRIPT_DIR/bridge-lib.sh\""
    printf "%s\n" "bridge_load_roster"
    printf "%s\n" "daemon_info() { :; }"
    printf "%s\n" "bridge_daemon_autostart_allowed() { return 0; }"
    printf "%s\n" "bridge_daemon_note_autostart_failure() { :; }"
    printf "%s\n" "bridge_daemon_clear_autostart_failure() { :; }"
    printf "%s\n" "bridge_dashboard_post_if_changed() { :; }"
    sed -n '"'"'/^bridge_agent_heartbeat_file()/,/^CMD="${1:-}"/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
  } >"$tmp_daemon"
  source "$tmp_daemon"
  "'"$REPO_ROOT"'/agent-bridge" --codex --name "'"$IDLE_REAP_AGENT"'" --workdir "'"$IDLE_REAP_WORKDIR"'" --no-attach >/dev/null
  tmux new-session -d -s "'"$ORPHAN_REAP_SESSION"'" "sleep 30"
  sleep 2
  export BRIDGE_DYNAMIC_IDLE_REAP_SECONDS=1
  export BRIDGE_ORPHAN_SESSION_REAP_SECONDS=1
  cmd_sync_cycle >/dev/null
  if tmux has-session -t "'"$IDLE_REAP_AGENT"'" 2>/dev/null; then
    echo "DYNAMIC_ALIVE=yes"
  else
    echo "DYNAMIC_ALIVE=no"
  fi
  if tmux has-session -t "'"$ORPHAN_REAP_SESSION"'" 2>/dev/null; then
    echo "ORPHAN_ALIVE=yes"
  else
    echo "ORPHAN_ALIVE=no"
  fi
  if test -f "'"$BRIDGE_ACTIVE_AGENT_DIR"'/'"$IDLE_REAP_AGENT"'.env"; then
    echo "DYNAMIC_META=yes"
  else
    echo "DYNAMIC_META=no"
  fi
')"
assert_contains "$IDLE_REAP_OUTPUT" "DYNAMIC_ALIVE=no"
assert_contains "$IDLE_REAP_OUTPUT" "ORPHAN_ALIVE=no"
assert_contains "$IDLE_REAP_OUTPUT" "DYNAMIC_META=no"

log "refreshing a static Claude session after memory-daily when prompt is free"
MEMORY_REFRESH_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  tmp_daemon="'"$TMP_ROOT"'/daemon-memory-refresh.sh"
  {
    printf "%s\n" "set -euo pipefail"
    printf "SCRIPT_DIR=%q\n" "'"$REPO_ROOT"'"
    printf "%s\n" "source \"\$SCRIPT_DIR/bridge-lib.sh\""
    printf "%s\n" "bridge_load_roster"
    printf "%s\n" "daemon_info() { :; }"
    sed -n '"'"'/^bridge_report_channel_health_miss()/,/^process_channel_health()/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
  } >"$tmp_daemon"
  source "$tmp_daemon"
  send_log="'"$TMP_ROOT"'/memory-refresh-send.log"
  bridge_tmux_send_and_submit() {
    printf "%s|%s|%s\n" "$1" "$2" "$3" >>"'"$TMP_ROOT"'/memory-refresh-send.log"
    return 0
  }
  tmux kill-session -t "'"$CLAUDE_STATIC_SESSION"'" >/dev/null 2>&1 || true
  tmux new-session -d -s "'"$CLAUDE_STATIC_SESSION"'" "sleep 30"
  "'"$REPO_ROOT"'/agent-bridge" task create --to claude-static --title "busy refresh" --body "wait" --from smoke >/dev/null
  busy_task="$(python3 "'"$REPO_ROOT"'/bridge-queue.py" find-open --agent claude-static | head -n 1)"
  [[ "$busy_task" =~ ^[0-9]+$ ]] || exit 1
  python3 "'"$REPO_ROOT"'/bridge-queue.py" claim "$busy_task" --agent claude-static >/dev/null
  bridge_agent_note_memory_daily_refresh "claude-static" "run-busy" "2026-04-08"
  process_memory_daily_refresh_requests || true
  if bridge_agent_memory_daily_refresh_pending "claude-static"; then
    echo "BUSY_PENDING=yes"
  else
    echo "BUSY_PENDING=no"
  fi
  if [[ -f "$send_log" ]]; then
    send_count=0
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      send_count=$((send_count + 1))
    done <"$send_log"
    echo "BUSY_SENDS=$send_count"
  else
    echo "BUSY_SENDS=0"
  fi
  python3 "'"$REPO_ROOT"'/bridge-queue.py" done "$busy_task" --agent claude-static --note "ok" >/dev/null
  process_memory_daily_refresh_requests || true
  if bridge_agent_memory_daily_refresh_pending "claude-static"; then
    echo "FINAL_PENDING=yes"
  else
    echo "FINAL_PENDING=no"
  fi
  if [[ -f "$send_log" ]]; then
    send_count=0
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      send_count=$((send_count + 1))
    done <"$send_log"
    echo "FINAL_SENDS=$send_count"
    cat "$send_log"
  else
    echo "FINAL_SENDS=0"
  fi
')"
assert_contains "$MEMORY_REFRESH_OUTPUT" "BUSY_PENDING=yes"
assert_contains "$MEMORY_REFRESH_OUTPUT" "BUSY_SENDS=0"
assert_contains "$MEMORY_REFRESH_OUTPUT" "FINAL_PENDING=no"
assert_contains "$MEMORY_REFRESH_OUTPUT" "FINAL_SENDS=1"
assert_contains "$MEMORY_REFRESH_OUTPUT" "$CLAUDE_STATIC_SESSION|claude|/new"

log "skipping memory-daily refresh while the target session is attached"
ATTACHED_REFRESH_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  tmp_daemon="'"$TMP_ROOT"'/daemon-memory-refresh-attached.sh"
  {
    printf "%s\n" "set -euo pipefail"
    printf "SCRIPT_DIR=%q\n" "'"$REPO_ROOT"'"
    printf "%s\n" "source \"\$SCRIPT_DIR/bridge-lib.sh\""
    printf "%s\n" "bridge_load_roster"
    printf "%s\n" "daemon_info() { :; }"
    sed -n '"'"'/^bridge_report_channel_health_miss()/,/^process_channel_health()/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
  } >"$tmp_daemon"
  source "$tmp_daemon"
  send_log="'"$TMP_ROOT"'/memory-refresh-attached.log"
  bridge_tmux_send_and_submit() {
    printf "%s|%s|%s\n" "$1" "$2" "$3" >>"'"$TMP_ROOT"'/memory-refresh-attached.log"
    return 0
  }
  bridge_tmux_session_attached_count() { printf "1\n"; }
  tmux kill-session -t "'"$CLAUDE_STATIC_SESSION"'" >/dev/null 2>&1 || true
  tmux new-session -d -s "'"$CLAUDE_STATIC_SESSION"'" "sleep 30"
  bridge_agent_note_memory_daily_refresh "claude-static" "run-attached" "2026-04-08"
  process_memory_daily_refresh_requests || true
  if bridge_agent_memory_daily_refresh_pending "claude-static"; then
    echo "ATTACHED_PENDING=yes"
  else
    echo "ATTACHED_PENDING=no"
  fi
  if [[ -f "$send_log" ]]; then
    send_count=0
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      send_count=$((send_count + 1))
    done <"$send_log"
    echo "ATTACHED_SENDS=$send_count"
  else
    echo "ATTACHED_SENDS=0"
  fi
')"
assert_contains "$ATTACHED_REFRESH_OUTPUT" "ATTACHED_PENDING=yes"
assert_contains "$ATTACHED_REFRESH_OUTPUT" "ATTACHED_SENDS=0"

log "writing and querying the audit log"
AUDIT_OUTPUT="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_audit_log daemon smoke_audit claude-static --detail agent=claude-static --detail sample=yes
  "'"$REPO_ROOT"'/agent-bridge" audit --agent claude-static --action smoke_audit --limit 5 --json
')"
assert_contains "$AUDIT_OUTPUT" "\"action\": \"smoke_audit\""
assert_contains "$AUDIT_OUTPUT" "\"target\": \"claude-static\""
assert_contains "$AUDIT_OUTPUT" "\"sample\": \"yes\""
AUDIT_ROTATE_FILE="$TMP_ROOT/audit-rotate.jsonl"
AUDIT_ROTATE_OUTPUT="$("$BASH4_BIN" -lc '
  export BRIDGE_AUDIT_LOG="'"$AUDIT_ROTATE_FILE"'"
  export BRIDGE_AUDIT_ROTATE_BYTES=1
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_audit_log daemon smoke_rotate first --detail marker=alpha
  bridge_audit_log queue smoke_rotate second --detail marker=beta
  bridge_notify_send "'"$SMOKE_AGENT"'" "Smoke notify" "dry-run" "" normal 1 >/dev/null
  "'"$REPO_ROOT"'/agent-bridge" audit --actor queue --contains beta --limit 5 --json
')"
assert_contains "$AUDIT_ROTATE_OUTPUT" "\"actor\": \"queue\""
assert_contains "$AUDIT_ROTATE_OUTPUT" "\"marker\": \"beta\""
ROTATED_AUDIT_COUNT="$(find "$TMP_ROOT" -maxdepth 1 -name 'audit-rotate.*.jsonl' | wc -l | tr -d ' ')"
[[ "${ROTATED_AUDIT_COUNT:-0}" -ge 1 ]] || die "expected rotated audit files"
NOTIFY_AUDIT_OUTPUT="$(BRIDGE_AUDIT_LOG="$AUDIT_ROTATE_FILE" "$REPO_ROOT/agent-bridge" audit --action external_channel_send --limit 5 --json)"
assert_contains "$NOTIFY_AUDIT_OUTPUT" "\"action\": \"external_channel_send\""

log "falling back when a dynamic Claude resume session id is stale"
STALE_RESUME_OUTPUT="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_add_agent_id_if_missing "'"$STALE_RESUME_AGENT"'"
  BRIDGE_AGENT_ENGINE["'"$STALE_RESUME_AGENT"'"]="claude"
  BRIDGE_AGENT_SESSION["'"$STALE_RESUME_AGENT"'"]="'"$STALE_RESUME_AGENT"'"
  BRIDGE_AGENT_WORKDIR["'"$STALE_RESUME_AGENT"'"]="'"$HOOK_WORKDIR"'"
  BRIDGE_AGENT_SOURCE["'"$STALE_RESUME_AGENT"'"]="dynamic"
  BRIDGE_AGENT_CONTINUE["'"$STALE_RESUME_AGENT"'"]="1"
  BRIDGE_AGENT_SESSION_ID["'"$STALE_RESUME_AGENT"'"]="stale-session-id"
  BRIDGE_AGENT_CREATED_AT["'"$STALE_RESUME_AGENT"'"]="'"$(date +%s)"'"
  bridge_write_dynamic_agent_file "'"$STALE_RESUME_AGENT"'"
  bridge_agent_launch_cmd "'"$STALE_RESUME_AGENT"'"
  printf "\nSESSION_ID=%s\n" "${BRIDGE_AGENT_SESSION_ID["'"$STALE_RESUME_AGENT"'"]-}"
')"
assert_not_contains "$STALE_RESUME_OUTPUT" "--resume stale-session-id"
assert_not_contains "$STALE_RESUME_OUTPUT" "SESSION_ID=stale-session-id"
assert_contains "$STALE_RESUME_OUTPUT" "claude --continue --dangerously-skip-permissions --name $STALE_RESUME_AGENT"
assert_contains "$STALE_RESUME_OUTPUT" "SESSION_ID="

log "injecting bridge guidance into an existing project CLAUDE.md and forcing a fresh first launch"
PROJECT_CLAUDE_AGENT="project-claude-$SESSION_NAME"
PROJECT_CLAUDE_SESSION="project-claude-session-$SESSION_NAME"
PROJECT_CLAUDE_WORKDIR="$TMP_ROOT/project-claude-workdir"
mkdir -p "$PROJECT_CLAUDE_WORKDIR"
cat >"$PROJECT_CLAUDE_WORKDIR/CLAUDE.md" <<'EOF'
# Existing Project Instructions

Be careful.
EOF
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "$PROJECT_CLAUDE_AGENT"
BRIDGE_AGENT_DESC["$PROJECT_CLAUDE_AGENT"]="Project Claude role"
BRIDGE_AGENT_ENGINE["$PROJECT_CLAUDE_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$PROJECT_CLAUDE_AGENT"]="$PROJECT_CLAUDE_SESSION"
BRIDGE_AGENT_WORKDIR["$PROJECT_CLAUDE_AGENT"]="$PROJECT_CLAUDE_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$PROJECT_CLAUDE_AGENT"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["$PROJECT_CLAUDE_AGENT"]="1"
EOF
PROJECT_CLAUDE_DRY_RUN="$("$REPO_ROOT/bridge-start.sh" "$PROJECT_CLAUDE_AGENT" --dry-run 2>&1)"
assert_contains "$PROJECT_CLAUDE_DRY_RUN" "continue=0"
assert_contains "$(cat "$PROJECT_CLAUDE_WORKDIR/CLAUDE.md")" "BEGIN AGENT BRIDGE PROJECT GUIDANCE"
assert_contains "$(cat "$PROJECT_CLAUDE_WORKDIR/CLAUDE.md")" "Do not guess bridge commands."

log "returning success for non-tty tmux attach"
ATTACH_SESSION="attach-smoke-$SESSION_NAME"
tmux new-session -d -s "$ATTACH_SESSION" "sleep 30"
NONTTY_ATTACH_OUTPUT="$("$BASH4_BIN" -lc 'source "'"$REPO_ROOT"'/bridge-lib.sh"; bridge_attach_tmux_session "'"$ATTACH_SESSION"'"' 2>&1)"
assert_contains "$NONTTY_ATTACH_OUTPUT" "attach manually with: tmux attach -t $ATTACH_SESSION"
tmux kill-session -t "$ATTACH_SESSION" >/dev/null 2>&1 || true

log "requeueing stale claimed tasks from inactive agents"
INACTIVE_CLAIM_TASK_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to inactive-agent --title "inactive claim smoke" --body "orphan" --from "$REQUESTER_AGENT")"
assert_contains "$INACTIVE_CLAIM_TASK_OUTPUT" "created task #"
INACTIVE_CLAIM_TASK_ID="$(printf '%s\n' "$INACTIVE_CLAIM_TASK_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ -n "$INACTIVE_CLAIM_TASK_ID" ]] || die "expected inactive claim task id"
python3 "$REPO_ROOT/bridge-queue.py" claim "$INACTIVE_CLAIM_TASK_ID" --agent inactive-agent --lease-seconds 60 >/dev/null
python3 - "$BRIDGE_TASK_DB" "$INACTIVE_CLAIM_TASK_ID" <<'PY'
import sqlite3
import sys

db_path, task_id = sys.argv[1:]
with sqlite3.connect(db_path) as conn:
    conn.execute(
        "UPDATE tasks SET claimed_ts = claimed_ts - 3600, updated_ts = updated_ts - 3600 WHERE id = ?",
        (int(task_id),),
    )
    conn.commit()
PY
INACTIVE_REQUEUE_OUTPUT="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  snapshot_file="$(mktemp)"
  ready_file="$(mktemp)"
  trap "rm -f \"$snapshot_file\" \"$ready_file\"" EXIT
  bridge_write_agent_snapshot "$snapshot_file"
  : >"$ready_file"
  python3 "'"$REPO_ROOT"'/bridge-queue.py" daemon-step \
    --snapshot "$snapshot_file" \
    --lease-seconds "$BRIDGE_TASK_LEASE_SECONDS" \
    --heartbeat-window "$BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS" \
    --idle-threshold "${BRIDGE_IDLE_THRESHOLD_SECONDS:-300}" \
    --max-claim-age 900 \
    --nudge-cooldown "$BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS" \
    --zombie-threshold "${BRIDGE_ZOMBIE_NUDGE_THRESHOLD:-10}" \
    --ready-agents-file "$ready_file"
')"
INACTIVE_REQUEUE_STATUS="$(python3 "$REPO_ROOT/bridge-queue.py" show "$INACTIVE_CLAIM_TASK_ID")"
assert_contains "$INACTIVE_REQUEUE_STATUS" "status: queued"

log "creating a new static agent from the public template"
CREATE_DRY_RUN_OUTPUT="$("$REPO_ROOT/agent-bridge" agent create "$CREATED_AGENT" --engine claude --session "$CREATED_SESSION" --always-on --dry-run)"
assert_contains "$CREATE_DRY_RUN_OUTPUT" "agent: $CREATED_AGENT"
assert_contains "$CREATE_DRY_RUN_OUTPUT" "dry_run: yes"
CREATE_JSON_OUTPUT="$("$REPO_ROOT/agent-bridge" agent create "$CREATED_AGENT" --engine claude --session "$CREATED_SESSION" --channels plugin:telegram --user owner:Owner --user reviewer:Reviewer --dry-run --json)"
assert_contains "$CREATE_JSON_OUTPUT" "\"agent\": \"$CREATED_AGENT\""
assert_contains "$CREATE_JSON_OUTPUT" "\"session_type\": \"static-claude\""
assert_contains "$CREATE_JSON_OUTPUT" "\"channels\": \"plugin:telegram@claude-plugins-official\""
assert_contains "$CREATE_JSON_OUTPUT" "\"id\": \"owner\""
CREATE_JSON_OUTPUT_NO_REGISTRY="$(BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE="$TMP_ROOT/missing-installed-plugins.json" "$REPO_ROOT/agent-bridge" agent create "${CREATED_AGENT}-fallback" --engine claude --session "${CREATED_SESSION}-fallback" --channels plugin:telegram --dry-run --json)"
assert_contains "$CREATE_JSON_OUTPUT_NO_REGISTRY" "\"channels\": \"plugin:telegram@claude-plugins-official\""
CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" agent create "$CREATED_AGENT" --engine claude --session "$CREATED_SESSION" --role "Smoke created role" --channels plugin:telegram --user owner:Owner --user reviewer:Reviewer)"
assert_contains "$CREATE_OUTPUT" "create: ok"
assert_contains "$CREATE_OUTPUT" "start_dry_run: ok"
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_AGENT_ENGINE[\"$CREATED_AGENT\"]=claude"
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_AGENT_CHANNELS[\"$CREATED_AGENT\"]="
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "plugin:telegram@claude-plugins-official"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md" ]] || die "agent create did not scaffold CLAUDE.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SOUL.md" ]] || die "agent create did not scaffold SOUL.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/TOOLS.md" ]] || die "agent create did not scaffold TOOLS.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SKILLS.md" ]] || die "agent create did not scaffold SKILLS.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/MEMORY.md" ]] || die "agent create did not scaffold MEMORY.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/MEMORY-SCHEMA.md" ]] || die "agent create did not scaffold MEMORY-SCHEMA.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SESSION-TYPE.md" ]] || die "agent create did not scaffold SESSION-TYPE.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/index.md" ]] || die "agent create did not scaffold memory/index.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/log.md" ]] || die "agent create did not scaffold memory/log.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/owner/USER.md" ]] || die "agent create did not scaffold users/owner/USER.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/reviewer/MEMORY.md" ]] || die "agent create did not scaffold users/reviewer/MEMORY.md"
[[ ! -e "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/default" ]] || die "agent create should remove default user when explicit users are provided"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/owner/USER.md")" "Name: Owner"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SESSION-TYPE.md")" "Session Type: static-claude"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SESSION-TYPE.md")" "Onboarding State: pending"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "SESSION-TYPE.md"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "Onboarding State: pending"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/index.md")" "../users/owner/"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/raw/captures/inbox/.gitkeep" ]] || die "agent create did not scaffold raw capture inbox"
[[ -L "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.claude/skills/agent-bridge-runtime" ]] || die "agent create did not link runtime skill"
[[ -L "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.claude/skills/memory-wiki" ]] || die "agent create did not link memory-wiki skill"
MEMORY_CAPTURE_JSON="$("$REPO_ROOT/agent-bridge" memory capture --agent "$CREATED_AGENT" --user owner --source telegram --author "Owner" --channel "chat-1" --text "I prefer concise morning updates." --json)"
MEMORY_CAPTURE_ID="$(python3 - "$MEMORY_CAPTURE_JSON" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["capture_id"])
PY
)"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/raw/captures/inbox/$MEMORY_CAPTURE_ID.json" ]] || die "memory capture did not create inbox file"
MEMORY_INGEST_OUTPUT="$("$REPO_ROOT/agent-bridge" memory ingest --agent "$CREATED_AGENT" --capture "$MEMORY_CAPTURE_ID")"
assert_contains "$MEMORY_INGEST_OUTPUT" "$MEMORY_CAPTURE_ID"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/raw/captures/ingested/$MEMORY_CAPTURE_ID.json" ]] || die "memory ingest did not move capture to ingested"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/owner/memory/$(date +%F).md")" "I prefer concise morning updates."
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/log.md")" "$MEMORY_CAPTURE_ID"
MEMORY_PROMOTE_OUTPUT="$("$REPO_ROOT/agent-bridge" memory promote --agent "$CREATED_AGENT" --kind user --user owner --capture "$MEMORY_CAPTURE_ID" --summary "User prefers concise morning updates.")"
assert_contains "$MEMORY_PROMOTE_OUTPUT" "kind: user"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/owner/MEMORY.md")" "User prefers concise morning updates."
MEMORY_SHARED_PROMOTE_OUTPUT="$("$REPO_ROOT/agent-bridge" memory promote --agent "$CREATED_AGENT" --kind shared --page communication-preferences --summary "This agent should bias toward concise updates when the user prefers them.")"
assert_contains "$MEMORY_SHARED_PROMOTE_OUTPUT" "kind: shared"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/shared/communication-preferences.md" ]] || die "memory promote did not create shared page"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/shared/communication-preferences.md")" "bias toward concise updates"
MEMORY_LINT_JSON="$("$REPO_ROOT/agent-bridge" memory lint --agent "$CREATED_AGENT" --json)"
assert_contains "$MEMORY_LINT_JSON" "\"ok\": true"
MEMORY_SEARCH_JSON="$("$REPO_ROOT/agent-bridge" memory search --agent "$CREATED_AGENT" --user owner --query "concise morning updates" --json)"
assert_contains "$MEMORY_SEARCH_JSON" "\"total_matches\":"
assert_contains "$MEMORY_SEARCH_JSON" "\"users/owner/MEMORY.md\""
assert_contains "$MEMORY_SEARCH_JSON" "\"memory/shared/communication-preferences.md\""
MEMORY_INDEX_JSON="$("$REPO_ROOT/agent-bridge" memory rebuild-index --agent "$CREATED_AGENT" --json)"
assert_contains "$MEMORY_INDEX_JSON" "\"chunk_count\":"
MEMORY_QUERY_JSON="$("$REPO_ROOT/agent-bridge" memory query --agent "$CREATED_AGENT" --user owner --query "concise morning updates" --json)"
assert_contains "$MEMORY_QUERY_JSON" "\"backend\": \"index\""
assert_contains "$MEMORY_QUERY_JSON" "\"users/owner/MEMORY.md\""
MEMORY_REMEMBER_JSON="$("$REPO_ROOT/agent-bridge" memory remember --agent "$CREATED_AGENT" --user owner --source chat --text "The owner prefers weekly summary digests." --kind user --json)"
assert_contains "$MEMORY_REMEMBER_JSON" "\"capture_id\":"
assert_contains "$MEMORY_REMEMBER_JSON" "\"kind\": \"user\""
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/owner/MEMORY.md")" "weekly summary digests"
MEMORY_PROJECT_REMEMBER_JSON="$("$REPO_ROOT/agent-bridge" memory remember --agent "$CREATED_AGENT" --user owner --source chat --title "Derm Roadmap" --text $'Weekly derm roadmap check-in every Tuesday.\nTrack dermatologist feedback separately in the project page.' --kind project --page derm-roadmap --summary "Weekly derm roadmap follow-up cadence." --json)"
assert_contains "$MEMORY_PROJECT_REMEMBER_JSON" "\"kind\": \"project\""
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/projects/derm-roadmap.md")" "Weekly derm roadmap follow-up cadence."
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/projects/derm-roadmap.md")" "Track dermatologist feedback separately in the project page."

LEGACY_MEMORY_DB="$TMP_ROOT/legacy-memory-index.sqlite"
python3 - "$LEGACY_MEMORY_DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
conn.executescript(
    """
    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS documents (
        path TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        user_id TEXT NOT NULL DEFAULT '',
        format TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        indexed_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL,
        source TEXT NOT NULL,
        model TEXT NOT NULL DEFAULT 'bridge-wiki-fts-v1',
        kind TEXT NOT NULL,
        user_id TEXT NOT NULL DEFAULT '',
        start_line INTEGER NOT NULL,
        end_line INTEGER NOT NULL,
        text TEXT NOT NULL,
        embedding TEXT NOT NULL DEFAULT '[]'
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        text,
        path UNINDEXED,
        source UNINDEXED,
        model UNINDEXED,
        content='chunks',
        content_rowid='id'
    );
    """
)
conn.close()
PY
LEGACY_MEMORY_INDEX_JSON="$("$REPO_ROOT/agent-bridge" memory rebuild-index --agent "$CREATED_AGENT" --db-path "$LEGACY_MEMORY_DB" --json)"
assert_contains "$LEGACY_MEMORY_INDEX_JSON" "\"chunk_count\":"
SETUP_TELEGRAM_OUTPUT="$("$REPO_ROOT/agent-bridge" setup telegram "$CREATED_AGENT" --channel-account smoke --runtime-config "$TMP_ROOT/openclaw.json" --allow-from 123456789 --default-chat 123456789 --api-base-url "$FAKE_TELEGRAM_API_BASE" --yes)"
assert_contains "$SETUP_TELEGRAM_OUTPUT" "telegram_dir: $BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram"
assert_contains "$SETUP_TELEGRAM_OUTPUT" "validation: ok"
assert_contains "$SETUP_TELEGRAM_OUTPUT" "send: ok"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/.env" ]] || die "setup telegram did not create .env"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/access.json" ]] || die "setup telegram did not create access.json"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/.env")" "TELEGRAM_BOT_TOKEN=smoke-telegram-token"
assert_contains "$(cat "$FAKE_TELEGRAM_REQUESTS")" "[Agent Bridge setup]"
SETUP_CREATED_AGENT_OUTPUT="$("$REPO_ROOT/agent-bridge" setup agent "$CREATED_AGENT" --skip-discord --skip-telegram)"
assert_contains "$SETUP_CREATED_AGENT_OUTPUT" "telegram_dir: $BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram"
assert_contains "$SETUP_CREATED_AGENT_OUTPUT" "telegram_allow_from: 123456789"
assert_contains "$SETUP_CREATED_AGENT_OUTPUT" "channel_status: ok"
CREATE_LIST_JSON="$("$REPO_ROOT/agent-bridge" agent list --json)"
CREATE_SHOW_JSON="$("$REPO_ROOT/agent-bridge" agent show "$CREATED_AGENT" --json)"
python3 - "$CREATE_LIST_JSON" "$CREATE_SHOW_JSON" "$CREATED_AGENT" "$SMOKE_AGENT" <<'PY'
import json
import sys

list_payload = json.loads(sys.argv[1])
show_payload = json.loads(sys.argv[2])
created_agent = sys.argv[3]
admin_agent = sys.argv[4]

assert isinstance(list_payload, list) and list_payload, "agent list json should be a non-empty array"
created = next((row for row in list_payload if row["agent"] == created_agent), None)
assert created is not None, "created agent missing from list json"
assert created["engine"] == "claude"
assert created["channels"]["required"] == "plugin:telegram@claude-plugins-official"
assert created["queue"]["queued"] == 0
assert any(row["agent"] == admin_agent and row["admin"] for row in list_payload), "admin agent missing admin=true"

assert show_payload["agent"] == created_agent
assert show_payload["profile"]["source_present"] is True
assert show_payload["activity_state"] in {"stopped", "idle"}
assert show_payload["notify"]["status"] == "miss"
PY
CREATED_START_DRY_RUN="$("$REPO_ROOT/bridge-start.sh" "$CREATED_AGENT" --dry-run)"
assert_contains "$CREATED_START_DRY_RUN" "session=$CREATED_SESSION"
assert_contains "$CREATED_START_DRY_RUN" "channels=plugin:telegram@claude-plugins-official"
assert_contains "$CREATED_START_DRY_RUN" "channel_status=ok"
assert_contains "$CREATED_START_DRY_RUN" "bridge-run.sh $CREATED_AGENT"
CREATED_AGENT_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_agent_launch_cmd "'"$CREATED_AGENT"'"
')"
assert_contains "$CREATED_AGENT_LAUNCH" "TELEGRAM_STATE_DIR=$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram"
assert_contains "$CREATED_AGENT_LAUNCH" "claude --continue --dangerously-skip-permissions --name $CREATED_AGENT --channels plugin:telegram@claude-plugins-official"
CREATED_AGENT_START_OUTPUT="$("$REPO_ROOT/agent-bridge" agent start "$CREATED_AGENT" --dry-run)"
assert_contains "$CREATED_AGENT_START_OUTPUT" "$CREATED_SESSION"
CREATED_AGENT_RESTART_OUTPUT="$("$REPO_ROOT/agent-bridge" agent restart "$CREATED_AGENT" --dry-run)"
assert_contains "$CREATED_AGENT_RESTART_OUTPUT" "$CREATED_SESSION"
log "writing HEARTBEAT.md for static roles"
BRIDGE_HEARTBEAT_INTERVAL_SECONDS=1 "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/HEARTBEAT.md" ]] || die "daemon did not write HEARTBEAT.md"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/HEARTBEAT.md")" "agent: $CREATED_AGENT"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/HEARTBEAT.md")" "activity_state:"
log "scanning agent homes with watchdog"
WATCHDOG_JSON="$("$REPO_ROOT/agent-bridge" watchdog scan "$CREATED_AGENT" --json)"
assert_contains "$WATCHDOG_JSON" "\"agent\": \"$CREATED_AGENT\""
assert_contains "$WATCHDOG_JSON" "\"onboarding_state\": \"pending\""
assert_contains "$WATCHDOG_JSON" "\"problem_count\": 1"

log "bootstrapping a manager role with init"
INIT_DRY_RUN_JSON="$("$REPO_ROOT/agent-bridge" init --admin "$INIT_AGENT" --engine claude --session "$INIT_SESSION" --channels plugin:telegram --dry-run --json 2>&1)" || die "init dry-run failed: $INIT_DRY_RUN_JSON"
python3 - "$INIT_DRY_RUN_JSON" "$INIT_AGENT" "$INIT_SESSION" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
agent = sys.argv[2]
session = sys.argv[3]

assert payload["admin"] == agent
assert payload["session"] == session
assert payload["dry_run"] is True
assert payload["created"] is True
assert payload["preflight"] == "dry-run"
assert payload["warnings"] == []
PY
INIT_OUTPUT="$("$REPO_ROOT/agent-bridge" init --admin "$INIT_AGENT" --engine claude --session "$INIT_SESSION" --channels plugin:telegram --allow-from 123456789 --default-chat 123456789 --channel-account smoke --runtime-config "$TMP_ROOT/openclaw.json" --api-base-url "$FAKE_TELEGRAM_API_BASE" 2>&1)" || die "init actual failed: $INIT_OUTPUT"
assert_contains "$INIT_OUTPUT" "admin_agent: $INIT_AGENT"
assert_contains "$INIT_OUTPUT" "channel_setup: ok"
assert_contains "$INIT_OUTPUT" "preflight: ok"
assert_contains "$INIT_OUTPUT" "admin_saved: yes"
assert_contains "$INIT_OUTPUT" "next_command: agb admin"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$INIT_AGENT/.telegram/.env" ]] || die "init did not create telegram env"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$INIT_AGENT/.telegram/access.json" ]] || die "init did not create telegram access"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$INIT_AGENT/SESSION-TYPE.md" ]] || die "init did not scaffold SESSION-TYPE.md"
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_ADMIN_AGENT_ID=\"$INIT_AGENT\""
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$INIT_AGENT/SESSION-TYPE.md")" "Session Type: admin"
INIT_SHOW_JSON="$("$REPO_ROOT/agent-bridge" agent show "$INIT_AGENT" --json)"
python3 - "$INIT_SHOW_JSON" "$INIT_AGENT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
agent = sys.argv[2]
assert payload["agent"] == agent
assert payload["engine"] == "claude"
assert payload["channels"]["required"] == "plugin:telegram@claude-plugins-official"
PY

log "bootstrapping a manager role with bootstrap"
BOOTSTRAP_DRY_RUN_JSON="$("$REPO_ROOT/agent-bridge" bootstrap --admin "$BOOTSTRAP_AGENT" --engine claude --session "$BOOTSTRAP_SESSION" --channels plugin:telegram --allow-from 123456789 --default-chat 123456789 --channel-account smoke --runtime-config "$TMP_ROOT/openclaw.json" --api-base-url "$FAKE_TELEGRAM_API_BASE" --rcfile "$BOOTSTRAP_RCFILE" --skip-daemon --skip-launchagent --dry-run --json 2>&1)" || die "bootstrap dry-run failed: $BOOTSTRAP_DRY_RUN_JSON"
python3 - "$BOOTSTRAP_DRY_RUN_JSON" "$BOOTSTRAP_AGENT" "$BOOTSTRAP_SESSION" "$BOOTSTRAP_RCFILE" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
agent = sys.argv[2]
session = sys.argv[3]
rcfile = sys.argv[4]

assert payload["mode"] == "bootstrap"
assert payload["shell_integration"]["status"] == "planned"
assert payload["shell_integration"]["shell"] == "zsh"
assert payload["shell_integration"]["rcfile"] == rcfile
assert payload["daemon"]["status"] == "skipped"
assert payload["launchagent"]["status"] == "skipped"
assert payload["systemd"]["status"] == "unsupported"
assert payload["next_command"] == "agb admin"
assert payload["init"]["admin"] == agent
assert payload["init"]["session"] == session
assert payload["init"]["dry_run"] is True
assert payload["handoff_steps"], "bootstrap handoff steps should not be empty"
assert any("agb admin" in step for step in payload["handoff_steps"])
PY
BOOTSTRAP_OUTPUT="$("$REPO_ROOT/agent-bridge" bootstrap --admin "$BOOTSTRAP_AGENT" --engine claude --session "$BOOTSTRAP_SESSION" --channels plugin:telegram --allow-from 123456789 --default-chat 123456789 --channel-account smoke --runtime-config "$TMP_ROOT/openclaw.json" --api-base-url "$FAKE_TELEGRAM_API_BASE" --rcfile "$BOOTSTRAP_RCFILE" --skip-daemon --skip-launchagent 2>&1)" || die "bootstrap actual failed: $BOOTSTRAP_OUTPUT"
assert_contains "$BOOTSTRAP_OUTPUT" "== Agent Bridge bootstrap =="
assert_contains "$BOOTSTRAP_OUTPUT" "admin_agent: $BOOTSTRAP_AGENT"
assert_contains "$BOOTSTRAP_OUTPUT" "shell_integration: applied"
assert_contains "$BOOTSTRAP_OUTPUT" "daemon: skipped"
assert_contains "$BOOTSTRAP_OUTPUT" "launchagent: skipped"
assert_contains "$BOOTSTRAP_OUTPUT" "systemd: unsupported"
assert_contains "$BOOTSTRAP_OUTPUT" "3. Run: agb admin"
[[ -f "$BOOTSTRAP_RCFILE" ]] || die "bootstrap did not create shell rc file"
assert_contains "$(cat "$BOOTSTRAP_RCFILE")" "source \"$REPO_ROOT/shell/agent-bridge.zsh\""
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_ADMIN_AGENT_ID=\"$BOOTSTRAP_AGENT\""
BOOTSTRAP_SHOW_JSON="$("$REPO_ROOT/agent-bridge" agent show "$BOOTSTRAP_AGENT" --json)"
python3 - "$BOOTSTRAP_SHOW_JSON" "$BOOTSTRAP_AGENT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
agent = sys.argv[2]
assert payload["agent"] == agent
assert payload["engine"] == "claude"
assert payload["channels"]["required"] == "plugin:telegram@claude-plugins-official"
PY

log "rendering a Linux systemd user unit and bootstrap dry-run"
SYSTEMD_UNIT_OUTPUT="$("$REPO_ROOT/scripts/install-daemon-systemd.sh" --bridge-home "$BRIDGE_HOME")"
assert_contains "$SYSTEMD_UNIT_OUTPUT" "[Service]"
assert_contains "$SYSTEMD_UNIT_OUTPUT" "ExecStart="
assert_contains "$SYSTEMD_UNIT_OUTPUT" "service_path:"
BOOTSTRAP_LINUX_JSON="$(BRIDGE_BOOTSTRAP_OS=Linux "$REPO_ROOT/agent-bridge" bootstrap --admin bootstrap-linux --engine claude --session bootstrap-linux --channels plugin:telegram --allow-from 123456789 --default-chat 123456789 --channel-account smoke --runtime-config "$TMP_ROOT/openclaw.json" --api-base-url "$FAKE_TELEGRAM_API_BASE" --rcfile "$TMP_ROOT/bootstrap-linux.rc" --skip-daemon --skip-launchagent --dry-run --json 2>&1)" || die "linux bootstrap dry-run failed: $BOOTSTRAP_LINUX_JSON"
python3 - "$BOOTSTRAP_LINUX_JSON" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["mode"] == "bootstrap"
assert payload["launchagent"]["status"] == "skipped"
assert payload["systemd"]["status"] == "planned"
PY

log "surfacing bootstrap failure output and parsing tokenFile dotenv values"
cat >"$TOKENFILE_ENV" <<'EOF'
TELEGRAM_BOT_TOKEN=dotenv-telegram-token
EOF
python3 - "$TMP_ROOT/openclaw.json" "$TOKENFILE_ENV" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["channels"]["telegram"]["accounts"]["dotenv"] = {"tokenFile": sys.argv[2]}
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
SETUP_TELEGRAM_DOTENV_OUTPUT="$("$BASH4_BIN" "$REPO_ROOT/bridge-setup.sh" telegram "$CREATED_AGENT" --channel-account dotenv --runtime-config "$TMP_ROOT/openclaw.json" --allow-from 123456789 --default-chat 123456789 --skip-validate --skip-send-test --yes 2>&1)"
assert_contains "$SETUP_TELEGRAM_DOTENV_OUTPUT" "token_source: channel:dotenv"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/.env")" "TELEGRAM_BOT_TOKEN=dotenv-telegram-token"

BOOTSTRAP_FAIL_HOME="$TMP_ROOT/bootstrap-fail-home"
mkdir -p "$BOOTSTRAP_FAIL_HOME"
BOOTSTRAP_FAIL_OUTPUT="$(HOME="$BOOTSTRAP_FAIL_HOME" BRIDGE_CLAUDE_CHANNELS_HOME="$TMP_ROOT/empty-claude-channels" "$REPO_ROOT/agent-bridge" bootstrap --admin bootstrap-fail --engine claude --session bootstrap-fail --channels plugin:telegram --allow-from 123456789 --default-chat 123456789 --rcfile "$TMP_ROOT/bootstrap-fail.rc" --skip-daemon --skip-launchagent 2>&1 || true)"
assert_contains "$BOOTSTRAP_FAIL_OUTPUT" "error: Telegram bot token is required."
assert_contains "$BOOTSTRAP_FAIL_OUTPUT" "telegram bootstrap failed"

SETUP_TELEGRAM_HELP_OUTPUT="$("$BASH4_BIN" "$REPO_ROOT/bridge-setup.sh" telegram --help 2>&1)"
assert_contains "$SETUP_TELEGRAM_HELP_OUTPUT" "Usage:"
assert_contains "$SETUP_TELEGRAM_HELP_OUTPUT" "telegram <agent>"

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
assert_contains "$CLAUDE_LAUNCH_CONTINUE" "DISCORD_STATE_DIR=$CLAUDE_STATIC_WORKDIR/.discord claude --continue --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
assert_contains "$CLAUDE_LAUNCH_CONTINUE" "claude --continue --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
[[ "$CLAUDE_LAUNCH_CONTINUE" != *"'DISCORD_STATE_DIR="* ]] || die "static Claude env prefix should not be shell-quoted on continue"
CLAUDE_CHANNEL_STATUS="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  printf "%s" "$(bridge_agent_channel_status "claude-static")"
')"
[[ "$CLAUDE_CHANNEL_STATUS" == "ok" ]] || die "expected claude-static channel status to be ok"

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
assert_contains "$CLAUDE_STALE_RESUME_FALLBACK" "claude --continue --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
[[ "$CLAUDE_STALE_RESUME_FALLBACK" != *" --resume "* ]] || die "stale Claude session_id should not be used for resume"

log "configuring admin role and launching it"
SETUP_ADMIN_OUTPUT="$("$REPO_ROOT/agent-bridge" setup admin "$SMOKE_AGENT")"
assert_contains "$SETUP_ADMIN_OUTPUT" "admin_agent: $SMOKE_AGENT"
assert_contains "$SETUP_ADMIN_OUTPUT" "next_command: agb admin"
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_ADMIN_AGENT_ID=\"$SMOKE_AGENT\""

ADMIN_OUTPUT="$("$REPO_ROOT/agent-bridge" admin --no-attach 2>&1)"
if [[ "$ADMIN_OUTPUT" != *"세션 '$SESSION_NAME'이 이미 실행 중입니다."* && "$ADMIN_OUTPUT" != *"세션 '$SESSION_NAME' 시작 완료"* ]]; then
  die "expected admin launch to either reuse or start session"
fi

ADMIN_REPLACE_OUTPUT="$("$REPO_ROOT/agent-bridge" admin --replace --no-continue --no-attach 2>&1)"
assert_contains "$ADMIN_REPLACE_OUTPUT" "세션 '$SESSION_NAME' 시작 완료"

log "escalating a repeated unanswered question through the admin channel"
ESCALATE_DRY_RUN_JSON="$("$REPO_ROOT/agent-bridge" escalate question --agent "$CREATED_AGENT" --question "Should I deploy now?" --context "Second ask without a user reply." --wait-seconds 120 --json --dry-run)"
python3 - "$ESCALATE_DRY_RUN_JSON" "$SMOKE_AGENT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
admin_agent = sys.argv[2]

assert payload["agent"]
assert payload["admin_agent"] == admin_agent
assert payload["dry_run"] is True
assert payload["notify"]["target"]
PY

ESCALATE_JSON="$("$REPO_ROOT/agent-bridge" escalate question --agent "$CREATED_AGENT" --question "Should I deploy now?" --context "Second ask without a user reply." --wait-seconds 120 --json)"
python3 - "$ESCALATE_JSON" "$SMOKE_AGENT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
admin_agent = sys.argv[2]

assert payload["admin_agent"] == admin_agent
assert payload["task_id"]
assert payload["notify"]["status"] == "sent"
PY
assert_contains "$(cat "$FAKE_DISCORD_REQUESTS")" "Should I deploy now?"

STATIC_START_DRY_RUN="$("$REPO_ROOT/bridge-start.sh" "$SMOKE_AGENT" --dry-run --no-continue 2>&1 || true)"

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

SESSION_START_HOOK_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-session-start-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)")"
assert_contains "$SESSION_START_HOOK_OUTPUT" "session_start_hook: present"
HOOK_ENSURE_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-stop-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
assert_contains "$HOOK_ENSURE_OUTPUT" "status: updated"
assert_contains "$HOOK_ENSURE_OUTPUT" "stop_hook: present"
assert_contains "$HOOK_ENSURE_OUTPUT" "additional_context: true"
SESSION_START_HOOK_STATUS_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" status-session-start-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)")"
assert_contains "$SESSION_START_HOOK_STATUS_OUTPUT" "status: present"
assert_contains "$SESSION_START_HOOK_STATUS_OUTPUT" "session_start_hook: present"
HOOK_STATUS_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" status-stop-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
assert_contains "$HOOK_STATUS_OUTPUT" "status: present"
assert_contains "$HOOK_STATUS_OUTPUT" "additional_context: true"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"SessionStart\""
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"Stop\""
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"additionalContext\": true"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "mark-idle.sh"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "session-start.py"

PROMPT_HOOK_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-prompt-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash --python-bin "$(command -v python3)")"
assert_contains "$PROMPT_HOOK_OUTPUT" "prompt_hook: present"
assert_contains "$PROMPT_HOOK_OUTPUT" "timestamp_hook: present"
PROMPT_STATUS_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" status-prompt-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
assert_contains "$PROMPT_STATUS_OUTPUT" "status: present"
assert_contains "$PROMPT_STATUS_OUTPUT" "timestamp_hook: present"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"UserPromptSubmit\""
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "clear-idle.sh"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "prompt_timestamp.py"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"additionalContext\": true"
PROMPT_TIMESTAMP_TEXT="$(BRIDGE_AGENT_ID="$SMOKE_AGENT" BRIDGE_HOME="$BRIDGE_HOME" python3 "$REPO_ROOT/hooks/prompt_timestamp.py")"
assert_contains "$PROMPT_TIMESTAMP_TEXT" "<timestamp>"
assert_contains "$PROMPT_TIMESTAMP_TEXT" "now:"
assert_contains "$PROMPT_TIMESTAMP_TEXT" "since_last:"
assert_contains "$PROMPT_TIMESTAMP_TEXT" "<question_escalation>"
assert_contains "$PROMPT_TIMESTAMP_TEXT" "agent-bridge escalate question"

log "ensuring shared Claude settings symlink for bridge-owned agent homes"
cat >"$BRIDGE_HOME/agents/.claude/settings.local.json" <<'EOF'
{
  "enabledPlugins": {
    "local-test@example": true
  }
}
EOF
SHARED_HOOK_OUTPUT="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_ensure_claude_stop_hook \"$CLAUDE_STATIC_WORKDIR\"")"
assert_contains "$SHARED_HOOK_OUTPUT" "settings_file: $CLAUDE_STATIC_WORKDIR/.claude/settings.json"
assert_contains "$SHARED_HOOK_OUTPUT" "settings.effective.json"
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/settings.json" ]] || die "expected shared Claude settings symlink"
SHARED_SYMLINK_TARGET="$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/settings.json")"
assert_contains "$SHARED_SYMLINK_TARGET" "../../.claude/settings.effective.json"
assert_contains "$(cat "$BRIDGE_HOME/agents/.claude/settings.effective.json")" "\"additionalContext\": true"
assert_contains "$(cat "$BRIDGE_HOME/agents/.claude/settings.effective.json")" "\"enabledPlugins\""
assert_contains "$(cat "$BRIDGE_HOME/agents/.claude/settings.effective.json")" "local-test@example"

log "ensuring shared Claude runtime skills for bridge-owned agent homes"
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_bootstrap_claude_shared_skills \"$CLAUDE_STATIC_WORKDIR\""
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/skills/agent-bridge-runtime" ]] || die "expected shared agent-bridge runtime skill symlink"
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/skills/cron-manager" ]] || die "expected shared cron-manager skill symlink"
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/skills/memory-wiki" ]] || die "expected shared memory-wiki skill symlink"
assert_contains "$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/skills/agent-bridge-runtime")" "agent-bridge-runtime"
assert_contains "$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/skills/cron-manager")" "cron-manager"
assert_contains "$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/skills/memory-wiki")" "memory-wiki"
assert_contains "$(cat "$REPO_ROOT/.claude/skills/agent-bridge-runtime/SKILL.md")" "Queue Source of Truth"
assert_contains "$(cat "$REPO_ROOT/.claude/skills/agent-bridge-runtime/SKILL.md")" "Use the Bash tool and run exactly"
assert_contains "$(cat "$REPO_ROOT/.claude/skills/memory-wiki/SKILL.md")" "memory remember"

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
CODEX_PROMPT_READY="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; if bridge_tmux_codex_prompt_line_ready '> '; then echo ok; else echo bad; fi")"
assert_contains "$CODEX_PROMPT_READY" "ok"

log "ensuring mark-idle hook emits inbox summary context"
HOOK_QUEUE_CREATE_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to claude-static --title "Follow-up task" --from smoke --priority high --body "check inbox")"
assert_contains "$HOOK_QUEUE_CREATE_OUTPUT" "created task #"
HOOK_CONTEXT_OUTPUT="$(BRIDGE_HOME="$REPO_ROOT" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_ACTIVE_AGENT_DIR" BRIDGE_HISTORY_DIR="$BRIDGE_HISTORY_DIR" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" BRIDGE_ROSTER_FILE="$REPO_ROOT/agent-roster.sh" BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" BRIDGE_AGENT_ID="claude-static" "$BASH4_BIN" "$REPO_ROOT/hooks/mark-idle.sh")"
assert_contains "$HOOK_CONTEXT_OUTPUT" "[Agent Bridge] 1 pending task(s) for claude-static."
assert_contains "$HOOK_CONTEXT_OUTPUT" "ACTION REQUIRED: Use your Bash tool now."
assert_contains "$HOOK_CONTEXT_OUTPUT" "Run exactly: ~/.agent-bridge/agb inbox claude-static"
assert_contains "$HOOK_CONTEXT_OUTPUT" "Highest priority: Task #"
assert_contains "$HOOK_CONTEXT_OUTPUT" "Should the result of this task be shared with a human teammate?"

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

log "rebalancing memory-daily jobs onto 03:00 KST"
MEMORY_REBALANCE_JOBS="$TMP_ROOT/memory-daily-jobs.json"
python3 - <<'PY' "$MEMORY_REBALANCE_JOBS" "$SMOKE_AGENT"
import json
import sys

jobs_path, agent = sys.argv[1], sys.argv[2]
payload = {
    "format": "agent-bridge-cron-v1",
    "updatedAt": "2026-04-09T00:00:00+09:00",
    "jobs": [
        {
            "id": "memory-daily-1",
            "name": "memory-daily smoke",
            "agentId": agent,
            "enabled": True,
            "schedule": {"kind": "cron", "expr": "45 23 * * *", "tz": "Asia/Seoul"},
            "payload": {"kind": "text", "text": "daily memory"},
            "state": {},
            "metadata": {"source": "bridge-native"},
        },
        {
            "id": "briefing-1",
            "name": "morning-briefing smoke",
            "agentId": agent,
            "enabled": True,
            "schedule": {"kind": "cron", "expr": "0 9 * * *", "tz": "Asia/Seoul"},
            "payload": {"kind": "text", "text": "briefing"},
            "state": {},
            "metadata": {"source": "bridge-native"},
        },
    ],
}
with open(jobs_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
MEMORY_REBALANCE_DRY_RUN="$("$REPO_ROOT/agent-bridge" cron rebalance-memory-daily --jobs-file "$MEMORY_REBALANCE_JOBS" --dry-run --json)"
python3 - "$MEMORY_REBALANCE_DRY_RUN" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["dry_run"] is True
assert payload["changed_count"] == 1
assert payload["changed_jobs"][0]["after"]["expr"] == "0 3 * * *"
assert payload["changed_jobs"][0]["after"]["tz"] == "Asia/Seoul"
PY
"$REPO_ROOT/agent-bridge" cron rebalance-memory-daily --jobs-file "$MEMORY_REBALANCE_JOBS" >/dev/null
python3 - <<'PY' "$MEMORY_REBALANCE_JOBS"
import json
import sys

jobs = json.load(open(sys.argv[1], encoding="utf-8"))["jobs"]
memory_job = next(job for job in jobs if job["id"] == "memory-daily-1")
briefing_job = next(job for job in jobs if job["id"] == "briefing-1")
assert memory_job["schedule"]["expr"] == "0 3 * * *"
assert memory_job["schedule"]["tz"] == "Asia/Seoul"
assert briefing_job["schedule"]["expr"] == "0 9 * * *"
PY

log "creating a one-shot bridge-native cron job"
NATIVE_ONESHOT_OUTPUT="$("$REPO_ROOT/agent-bridge" cron create --agent "$SMOKE_AGENT" --at '2026-04-08T10:15:00+09:00' --title 'native smoke one-shot' --payload 'Run once.' --delete-after-run)"
assert_contains "$NATIVE_ONESHOT_OUTPUT" "created native cron job"
NATIVE_ONESHOT_ID="$(python3 - <<'PY' "$BRIDGE_NATIVE_CRON_JOBS_FILE"
import json, sys
jobs = json.load(open(sys.argv[1], encoding='utf-8'))['jobs']
for job in jobs:
    if job.get('name') == 'native smoke one-shot':
        print(job['id'])
        break
PY
)"
[[ -n "$NATIVE_ONESHOT_ID" ]] || die "native one-shot cron id was empty"
python3 - <<'PY' "$BRIDGE_NATIVE_CRON_JOBS_FILE" "$NATIVE_ONESHOT_ID"
import json, sys
jobs = json.load(open(sys.argv[1], encoding='utf-8'))['jobs']
job = next(job for job in jobs if job.get('id') == sys.argv[2])
assert job['schedule']['kind'] == 'at'
assert job['deleteAfterRun'] is True
PY
NATIVE_ONESHOT_SYNC_JSON="$("$REPO_ROOT/agent-bridge" cron sync --json --since '2026-04-08T10:14:00+09:00' --now '2026-04-08T10:15:00+09:00')"
assert_contains "$NATIVE_ONESHOT_SYNC_JSON" "\"status\": \"ok\""
assert_contains "$NATIVE_ONESHOT_SYNC_JSON" "\"due_occurrences\": 1"
NATIVE_ONESHOT_TASK_ID="$(python3 - <<'PY' "$NATIVE_ONESHOT_SYNC_JSON" "$NATIVE_ONESHOT_ID"
import json, sys
payload = json.loads(sys.argv[1])
for item in payload["sources"]["native"]["results"]:
    if item["job_id"] == sys.argv[2]:
        print(item["task_id"])
        break
PY
)"
[[ "$NATIVE_ONESHOT_TASK_ID" =~ ^[0-9]+$ ]] || die "native one-shot task id was invalid: $NATIVE_ONESHOT_TASK_ID"
python3 "$REPO_ROOT/bridge-queue.py" claim "$NATIVE_ONESHOT_TASK_ID" --agent "$SMOKE_AGENT" >/dev/null
NATIVE_ONESHOT_REQUEST_FILE="$(python3 - <<'PY' "$NATIVE_ONESHOT_SYNC_JSON" "$NATIVE_ONESHOT_ID"
import json, sys
payload = json.loads(sys.argv[1])
for item in payload["sources"]["native"]["results"]:
    if item["job_id"] == sys.argv[2]:
        print(item["request_file"])
        break
PY
)"
if [[ "$NATIVE_ONESHOT_REQUEST_FILE" != /* ]]; then
  NATIVE_ONESHOT_REQUEST_FILE="$BRIDGE_HOME/$NATIVE_ONESHOT_REQUEST_FILE"
fi
[[ -f "$NATIVE_ONESHOT_REQUEST_FILE" ]] || die "native one-shot request file missing: $NATIVE_ONESHOT_REQUEST_FILE"
python3 - <<'PY' "$NATIVE_ONESHOT_REQUEST_FILE"
import json, sys
from pathlib import Path

request = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(request["result_file"]).write_text(json.dumps({
    "run_id": request["run_id"],
    "status": "completed",
    "summary": "one-shot smoke completed",
    "findings": [],
    "actions_taken": [],
    "needs_human_followup": False,
    "recommended_next_steps": [],
    "artifacts": [],
    "confidence": "high",
    "duration_ms": 5,
}, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
Path(request["status_file"]).write_text(json.dumps({
    "run_id": request["run_id"],
    "state": "success",
    "engine": "codex",
    "request_file": request["dispatch_body_file"],
    "result_file": request["result_file"],
}, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
NATIVE_ONESHOT_FINALIZE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron finalize-run "$(basename "$(dirname "$NATIVE_ONESHOT_REQUEST_FILE")")")"
assert_contains "$NATIVE_ONESHOT_FINALIZE_OUTPUT" "action: deleted"
python3 - <<'PY' "$BRIDGE_NATIVE_CRON_JOBS_FILE" "$NATIVE_ONESHOT_ID"
import json, sys
jobs = json.load(open(sys.argv[1], encoding='utf-8'))['jobs']
assert all(job.get('id') != sys.argv[2] for job in jobs)
PY
python3 "$REPO_ROOT/bridge-queue.py" done "$NATIVE_ONESHOT_TASK_ID" --agent "$SMOKE_AGENT" --note "one-shot smoke cleaned up" >/dev/null

log "dry-run upgrade preserves custom paths"
UPGRADE_JSON="$("$REPO_ROOT/agent-bridge" upgrade --dry-run --json)"
assert_contains "$UPGRADE_JSON" "\"mode\": \"upgrade\""
assert_contains "$UPGRADE_JSON" "\"preserved_paths\""
assert_contains "$UPGRADE_JSON" "\"backup_enabled\": true"
assert_contains "$UPGRADE_JSON" "\"agent_migration\""
assert_contains "$UPGRADE_JSON" "\"analysis\""

log "upgrade backs up live install and migrates missing agent files"
rm -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/MEMORY-SCHEMA.md"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/output"
printf 'generated-report\n' >"$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/output/generated.txt"
python3 - <<'PY' "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md"
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("## Queue & Delivery", "## Queue & Delivery\n- STALE-UPGRADE-MARKER", 1)
path.write_text(text, encoding="utf-8")
PY
UPGRADE_APPLY_JSON="$("$REPO_ROOT/agent-bridge" upgrade --target "$BRIDGE_HOME" --no-restart-daemon --allow-dirty --json)"
assert_contains "$UPGRADE_APPLY_JSON" "\"backup_enabled\": true"
assert_contains "$UPGRADE_APPLY_JSON" "\"migrate_agents\": true"
assert_contains "$UPGRADE_APPLY_JSON" "\"added_files\""
assert_contains "$UPGRADE_APPLY_JSON" "\"updated_files\""
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/MEMORY-SCHEMA.md" ]] || die "upgrade did not restore missing agent template file"
assert_not_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "STALE-UPGRADE-MARKER"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "## Autonomy & Anti-Stall"
UPGRADE_BACKUP_ROOT="$(python3 - <<'PY' "$UPGRADE_APPLY_JSON"
import json, sys
print(json.loads(sys.argv[1])["backup_root"])
PY
)"
[[ -d "$UPGRADE_BACKUP_ROOT/live" ]] || die "upgrade did not create live backup snapshot"
[[ ! -e "$UPGRADE_BACKUP_ROOT/live/agents/$CREATED_AGENT/output/generated.txt" ]] || die "upgrade backup should skip generated agent output"
[[ -f "$BRIDGE_HOME/state/upgrade/last-upgrade.json" ]] || die "upgrade did not write last-upgrade state"
UPGRADE_ANALYZE_JSON="$("$REPO_ROOT/agent-bridge" upgrade analyze --target "$BRIDGE_HOME" --json)"
assert_contains "$UPGRADE_ANALYZE_JSON" "\"mode\": \"upgrade-analyze\""
assert_contains "$UPGRADE_ANALYZE_JSON" "\"base_ref\""

log "rolling back from an upgrade backup snapshot"
ROLLBACK_ROOT="$TMP_ROOT/rollback-root"
mkdir -p "$ROLLBACK_ROOT"
cp "$REPO_ROOT/bridge-task.sh" "$ROLLBACK_ROOT/bridge-task.sh"
ROLLBACK_BACKUP_ROOT="$TMP_ROOT/rollback-backup"
python3 "$REPO_ROOT/bridge-upgrade.py" backup-live --target-root "$ROLLBACK_ROOT" --backup-root "$ROLLBACK_BACKUP_ROOT" --source-root "$REPO_ROOT" >/dev/null
printf '\n# rollback smoke drift\n' >>"$ROLLBACK_ROOT/bridge-task.sh"
ROLLBACK_JSON="$("$REPO_ROOT/agent-bridge" upgrade rollback --target "$ROLLBACK_ROOT" --backup-root "$ROLLBACK_BACKUP_ROOT" --no-restart-daemon --json)"
assert_contains "$ROLLBACK_JSON" "\"mode\": \"upgrade-rollback\""
assert_not_contains "$(cat "$ROLLBACK_ROOT/bridge-task.sh")" "rollback smoke drift"

log "smart upgrade clean-merges text drift"
UPGRADE_SIM_REPO="$TMP_ROOT/upgrade-sim-repo"
mkdir -p "$UPGRADE_SIM_REPO"
git -C "$UPGRADE_SIM_REPO" init -q
git -C "$UPGRADE_SIM_REPO" config user.email smoke-test
git -C "$UPGRADE_SIM_REPO" config user.name "Bridge Smoke"
cat >"$UPGRADE_SIM_REPO/sample.txt" <<'EOF'
alpha
beta
EOF
git -C "$UPGRADE_SIM_REPO" add sample.txt
git -C "$UPGRADE_SIM_REPO" commit -qm "base sample"
UPGRADE_SIM_BASE="$(git -C "$UPGRADE_SIM_REPO" rev-parse HEAD)"
cat >"$UPGRADE_SIM_REPO/sample.txt" <<'EOF'
alpha-upstream
beta
EOF
MERGE_ROOT="$TMP_ROOT/upgrade-merge-root"
mkdir -p "$MERGE_ROOT"
git -C "$UPGRADE_SIM_REPO" show "$UPGRADE_SIM_BASE:sample.txt" >"$MERGE_ROOT/sample.txt"
printf 'live-note\n' >>"$MERGE_ROOT/sample.txt"
MERGE_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$UPGRADE_SIM_REPO" --target-root "$MERGE_ROOT" --base-ref "$UPGRADE_SIM_BASE")"
assert_contains "$MERGE_JSON" "\"files_merged_clean\": 1"
assert_contains "$(cat "$MERGE_ROOT/sample.txt")" "alpha-upstream"
assert_contains "$(cat "$MERGE_ROOT/sample.txt")" "live-note"

log "smart upgrade backs up conflict and applies upstream by default"
CONFLICT_ROOT="$TMP_ROOT/upgrade-conflict-root"
mkdir -p "$CONFLICT_ROOT"
printf 'alpha-live\nbeta\n' >"$CONFLICT_ROOT/sample.txt"
CONFLICT_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$UPGRADE_SIM_REPO" --target-root "$CONFLICT_ROOT" --base-ref "$UPGRADE_SIM_BASE")"
assert_contains "$CONFLICT_JSON" "\"files_merged_conflict\": 1"
assert_contains "$(cat "$CONFLICT_ROOT/sample.txt")" "alpha-upstream"
[[ -f "$CONFLICT_ROOT/sample.txt.upgrade-conflict" ]] || die "upgrade did not write conflict backup file"
assert_contains "$(cat "$CONFLICT_ROOT/sample.txt.upgrade-conflict")" "<<<<<<<"

log "strict merge aborts on conflict without touching live file"
STRICT_ROOT="$TMP_ROOT/upgrade-strict-root"
mkdir -p "$STRICT_ROOT"
printf 'alpha-live\nbeta\n' >"$STRICT_ROOT/sample.txt"
set +e
STRICT_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$UPGRADE_SIM_REPO" --target-root "$STRICT_ROOT" --base-ref "$UPGRADE_SIM_BASE" --strict-merge)"
STRICT_EXIT=$?
set -e
[[ "$STRICT_EXIT" -eq 2 ]] || die "strict merge should abort with exit 2, got $STRICT_EXIT"
assert_contains "$STRICT_JSON" "\"aborted\": true"
assert_contains "$(cat "$STRICT_ROOT/sample.txt")" "alpha-live"
assert_not_contains "$(cat "$STRICT_ROOT/sample.txt")" "alpha-upstream"

log "exporting a clean public snapshot from the current ref"
PUBLIC_EXPORT_DIR="$TMP_ROOT/public-export"
PUBLIC_EXPORT_JSON="$("$REPO_ROOT/scripts/export-public-snapshot.sh" --dest "$PUBLIC_EXPORT_DIR" --init-git --dry-run --json)"
python3 - "$PUBLIC_EXPORT_JSON" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["mode"] == "export-public-snapshot"
assert payload["init_git"] is True
assert payload["push"] is False
assert payload["dry_run"] is True
PY
"$REPO_ROOT/scripts/export-public-snapshot.sh" --dest "$PUBLIC_EXPORT_DIR" --init-git >/dev/null
[[ -f "$PUBLIC_EXPORT_DIR/README.md" ]] || die "public export missing README.md"
[[ -d "$PUBLIC_EXPORT_DIR/.git" ]] || die "public export did not initialize git"
[[ ! -e "$PUBLIC_EXPORT_DIR/HEARTBEAT.md" ]] || die "public export should not include untracked HEARTBEAT.md"
git -C "$PUBLIC_EXPORT_DIR" rev-parse --verify HEAD >/dev/null 2>&1 || die "public export missing initial commit"

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
python3 - <<PY
import json, os
path = os.path.join(os.environ["BRIDGE_HOME"], "cron", "jobs.json")
payload = json.load(open(path, "r", encoding="utf-8"))
job = next(item for item in payload["jobs"] if item["name"] == "morning-briefing-smoke")
assert job["agentId"] == "${SMOKE_AGENT}"
assert job["agent"] == job["agentId"]
PY
CRON_IMPORTED_SYNC_OUTPUT="$("$REPO_ROOT/agent-bridge" cron sync --dry-run --since '2026-04-05T08:59:00+00:00' --now '2026-04-05T09:00:00+00:00')"
assert_contains "$CRON_IMPORTED_SYNC_OUTPUT" "native: status=dry_run"
assert_contains "$CRON_IMPORTED_SYNC_OUTPUT" "due=1"

log "including one-shot native jobs during recurring sync"
python3 - <<PY
import json, os
path = os.path.join(os.environ["BRIDGE_HOME"], "cron", "jobs.json")
payload = json.load(open(path, "r", encoding="utf-8"))
payload["jobs"].append({
    "id": "native-at-smoke",
    "agentId": "${SMOKE_AGENT}",
    "name": "native-at-smoke",
    "enabled": True,
    "createdAtMs": 1743840000000,
    "updatedAtMs": 1743840000000,
    "schedule": {
        "kind": "at",
        "at": "2026-04-05T08:30:00+00:00",
    },
    "payload": {
        "kind": "agentTurn",
        "message": "one-shot smoke",
    },
    "deleteAfterRun": True,
    "state": {},
})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
CRON_IMPORTED_AT_OUTPUT="$("$REPO_ROOT/agent-bridge" cron sync --dry-run --since '2026-04-05T08:29:00+00:00' --now '2026-04-05T09:00:00+00:00')"
assert_contains "$CRON_IMPORTED_AT_OUTPUT" "native: status=dry_run"
assert_contains "$CRON_IMPORTED_AT_OUTPUT" "due=2"

log "auto-pruning expired one-shot jobs during native sync"
python3 - <<PY
import json, os
path = os.path.join(os.environ["BRIDGE_HOME"], "cron", "jobs.json")
payload = json.load(open(path, "r", encoding="utf-8"))
payload["jobs"].append({
    "id": "expired-at-cleanup-smoke",
    "agentId": "${SMOKE_AGENT}",
    "name": "expired-at-cleanup-smoke",
    "enabled": False,
    "createdAtMs": 1743840000000,
    "updatedAtMs": 1743840000000,
    "schedule": {
        "kind": "at",
        "at": "2026-04-04T08:30:00+00:00",
    },
    "payload": {
        "kind": "agentTurn",
        "message": "expired cleanup smoke",
    },
    "deleteAfterRun": True,
    "state": {},
})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
CRON_CLEANUP_SYNC_JSON="$("$REPO_ROOT/agent-bridge" cron sync --json --since '2026-04-05T08:29:00+00:00' --now '2026-04-05T09:00:00+00:00')"
assert_contains "$CRON_CLEANUP_SYNC_JSON" "\"cleanup_deleted_jobs\": 1"
[[ -f "$BRIDGE_STATE_DIR/cron/scheduler-state.json" ]] || die "expected canonical scheduler-state.json after native sync"
assert_contains "$(cat "$BRIDGE_STATE_DIR/cron/scheduler-state.json")" "\"last_sync_at\""
python3 - <<PY
import json, os
path = os.path.join(os.environ["BRIDGE_HOME"], "cron", "jobs.json")
payload = json.load(open(path, "r", encoding="utf-8"))
assert all(job.get("id") != "expired-at-cleanup-smoke" for job in payload["jobs"])
PY

log "resolving cron targets for sleeping static roles and fallback delivery"
CRON_ROUTE_JOBS_FILE="$TMP_ROOT/cron-route-jobs.json"
cat >"$CRON_ROUTE_JOBS_FILE" <<EOF
{
  "jobs": [
    {
      "id": "mapped-route-job",
      "name": "mapped-route-job",
      "enabled": true,
      "agentId": "legacy-ops",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      },
      "payload": {
        "text": "mapped route payload"
      }
    },
    {
      "id": "fallback-route-job",
      "name": "fallback-route-job",
      "enabled": true,
      "agentId": "missing-role",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      },
      "payload": {
        "text": "fallback route payload"
      }
    }
  ]
}
EOF
CRON_MAPPED_ROUTE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron enqueue mapped-route-job --jobs-file "$CRON_ROUTE_JOBS_FILE" --slot 2026-04-05 --dry-run)"
assert_contains "$CRON_MAPPED_ROUTE_OUTPUT" "target: $AUTO_START_AGENT"
assert_contains "$CRON_MAPPED_ROUTE_OUTPUT" "delivery_mode: mapped"
CRON_FALLBACK_ROUTE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron enqueue fallback-route-job --jobs-file "$CRON_ROUTE_JOBS_FILE" --slot 2026-04-05 --dry-run)"
assert_contains "$CRON_FALLBACK_ROUTE_OUTPUT" "target: $SMOKE_AGENT"
assert_contains "$CRON_FALLBACK_ROUTE_OUTPUT" "delivery_mode: fallback"

log "parsing Claude plain-text cron results without structured_output"
python3 - <<'PY'
import importlib.util
from pathlib import Path

path = Path("bridge-cron-runner.py").resolve()
spec = importlib.util.spec_from_file_location("bridge_cron_runner", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

payload = (
    '{"type":"result","subtype":"success","is_error":false,'
    '"result":"The cron run finished successfully with no events to remind."}'
)
result = module.parse_claude_output(payload)
assert result["status"] == "completed"
assert result["summary"] == "The cron run finished successfully with no events to remind."
assert result["needs_human_followup"] is False
assert result["confidence"] == "low"
PY

log "preserving cron channel-delivery metadata and target channel runtime"
CRON_CHANNEL_JOBS_FILE="$TMP_ROOT/cron-channel-jobs.json"
cat >"$CRON_CHANNEL_JOBS_FILE" <<EOF
{
  "jobs": [
    {
      "id": "channel-job",
      "name": "channel-job",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      },
      "delivery": {
        "mode": "direct",
        "channel": "telegram",
        "to": "telegram:123"
      },
      "metadata": {
        "allowChannelDelivery": true
      },
      "payload": {
        "text": "send a telegram update"
      }
    }
  ]
}
EOF
CHANNEL_SHELL_OUTPUT="$(python3 "$REPO_ROOT/bridge-cron.py" show --jobs-file "$CRON_CHANNEL_JOBS_FILE" --format shell channel-job)"
assert_contains "$CHANNEL_SHELL_OUTPUT" "CRON_JOB_JOB_DELIVERY_MODE=direct"
assert_contains "$CHANNEL_SHELL_OUTPUT" "CRON_JOB_JOB_DELIVERY_CHANNEL=telegram"
assert_contains "$CHANNEL_SHELL_OUTPUT" "CRON_JOB_ALLOW_CHANNEL_DELIVERY=1"

python3 - <<'PY'
import importlib.util
from pathlib import Path

path = Path("bridge-cron-runner.py").resolve()
spec = importlib.util.spec_from_file_location("bridge_cron_runner", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

request = {
    "target_agent": "tester",
    "target_engine": "claude",
    "job_name": "channel-job",
    "family": "channel-job",
    "slot": "2026-04-05T09:00+00:00",
    "run_id": "channel-job--2026-04-05T09-00-00-00",
    "payload_file": "/tmp/payload.md",
    "target_channels": "plugin:telegram",
    "target_telegram_state_dir": "/tmp/telegram-state",
    "allow_channel_delivery": True,
    "job_delivery_channel": "telegram",
    "job_delivery_target": "telegram:123",
}
prompt = module.build_prompt(request, "send a telegram update")
assert "You may send a user-facing message" in prompt
env = module.apply_channel_runtime_env(request, {"PATH": "/usr/bin"})
assert env["TELEGRAM_STATE_DIR"] == "/tmp/telegram-state"
PY

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
[[ "$(paste -sd ' ' "$SCHEDULER_ENQUEUE_LOG")" == "job-a job-b job-c" ]] || die "expected scheduler to continue after one enqueue failure"
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
[[ "$(paste -sd ' ' "$SCHEDULER_ENQUEUE_LOG")" == "job-a job-b job-c job-b job-c" ]] || die "expected scheduler retry to resume from the failed same-timestamp sibling while replaying later work"
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
[[ "$(paste -sd ' ' "$SCHEDULER_ENQUEUE_LOG")" == "job-a job-b job-c job-b job-c" ]] || die "expected completed scheduler sync to avoid replaying the finished bucket"

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
[[ -f "$BRIDGE_HOME/runtime/bridge-config.json" ]] || die "expected runtime config copy"

log "linking configured runtime skills into managed Claude homes"
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; BRIDGE_AGENT_SKILLS[\"claude-static\"]='sample-skill'; bridge_bootstrap_claude_shared_skills 'claude-static' '$CLAUDE_STATIC_WORKDIR'"
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/skills/sample-skill" ]] || die "expected runtime sample-skill symlink"
assert_contains "$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/skills/sample-skill")" "sample-skill"
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; BRIDGE_AGENT_SKILLS[\"claude-static\"]=''; bridge_bootstrap_claude_shared_skills 'claude-static' '$CLAUDE_STATIC_WORKDIR'"
[[ ! -e "$CLAUDE_STATIC_WORKDIR/.claude/skills/sample-skill" ]] || die "expected runtime skill symlink pruning when roster mapping is removed"

RUNTIME_COMPAT_PATHS_OUTPUT="$("$BASH4_BIN" -c "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; printf '%s\n%s\n%s\n' \"\$(bridge_compat_config_file)\" \"\$(bridge_compat_credentials_dir)\" \"\$(bridge_compat_secrets_dir)\"")"
assert_contains "$RUNTIME_COMPAT_PATHS_OUTPUT" "$BRIDGE_HOME/runtime/bridge-config.json"
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
grep -q "$BRIDGE_HOME/runtime/extensions/sample-ext" "$BRIDGE_HOME/runtime/bridge-config.json" || die "expected rewritten runtime extension installPath"

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

log "prioritizing idle memory-daily dispatch over busy sessions"
MEMORY_DAILY_READY_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  export BRIDGE_HOME="'"$BRIDGE_HOME"'"
  export BRIDGE_STATE_DIR="'"$BRIDGE_STATE_DIR"'"
  export BRIDGE_TASK_DB="'"$TMP_ROOT"'/cron-ready-test.db"
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  python3 "'"$REPO_ROOT"'/bridge-queue.py" init >/dev/null
  status_file="'"$TMP_ROOT"'/cron-ready-status.tsv"
  cat >"$status_file" <<EOF
agent	engine	session	workdir	source	loop	active	wake	channels	activity_state
claude-static	claude	'"$CLAUDE_STATIC_SESSION"'	'"$CLAUDE_STATIC_WORKDIR"'	static	1	1	ok	ok	working
'"$CREATED_AGENT"'	claude	'"$CREATED_SESSION"'	'"$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT"'	static	1	1	ok	ok	idle
EOF
  busy_body="'"$TMP_ROOT"'/cron-ready-busy.md"
  other_body="'"$TMP_ROOT"'/cron-ready-other.md"
  idle_body="'"$TMP_ROOT"'/cron-ready-idle.md"
  cat >"$busy_body" <<EOF
# [cron-dispatch] memory-daily busy

- family: memory-daily
EOF
  cat >"$other_body" <<EOF
# [cron-dispatch] briefing

- family: morning-briefing
EOF
  cat >"$idle_body" <<EOF
# [cron-dispatch] memory-daily idle

- family: memory-daily
EOF
  bash "'"$REPO_ROOT"'/bridge-task.sh" create --to claude-static --title "[cron-dispatch] memory-daily busy" --body-file "$busy_body" --from smoke >/dev/null
  bash "'"$REPO_ROOT"'/bridge-task.sh" create --to claude-static --title "[cron-dispatch] briefing" --body-file "$other_body" --from smoke >/dev/null
  bash "'"$REPO_ROOT"'/bridge-task.sh" create --to "'"$CREATED_AGENT"'" --title "[cron-dispatch] memory-daily idle" --body-file "$idle_body" --from smoke >/dev/null
  python3 "'"$REPO_ROOT"'/bridge-queue.py" cron-ready --format tsv --status-snapshot "$status_file" --memory-daily-defer-seconds 3600
')"
python3 - <<'PY' "$MEMORY_DAILY_READY_OUTPUT" "$CREATED_AGENT"
import sys

output = [line for line in sys.argv[1].splitlines() if line.strip()]
created_agent = sys.argv[2]
assert len(output) == 2
assert output[0].split("\t", 3)[1] == created_agent
assert "briefing" in output[1]
assert all("memory-daily busy" not in line for line in output)
PY

log "stopping background daemon before deterministic cron-dispatch tail"
bash "$REPO_ROOT/bridge-daemon.sh" stop >/dev/null

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
  "source_agent": "$SMOKE_AGENT",
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

for _ in $(seq 1 80); do
  SHOW_CRON_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show "$CRON_TASK_ID")"
  if [[ "$SHOW_CRON_OUTPUT" == *"status: done"* ]]; then
    break
  fi
  bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null || true
  sleep 0.25
done

if [[ "$SHOW_CRON_OUTPUT" != *"status: done"* ]]; then
  echo "[smoke][debug] cron-dispatch task did not finish within the polling window" >&2
  echo "[smoke][debug] task show:" >&2
  printf '%s\n' "$SHOW_CRON_OUTPUT" >&2
  echo "[smoke][debug] worker dir:" >&2
  ls -la "$BRIDGE_CRON_DISPATCH_WORKER_DIR" >&2 || true
  echo "[smoke][debug] run status file:" >&2
  sed -n '1,160p' "$RUN_DIR/status.json" >&2 || true
  echo "[smoke][debug] run stderr:" >&2
  sed -n '1,160p' "$RUN_DIR/stderr.log" >&2 || true
fi

assert_contains "$SHOW_CRON_OUTPUT" "status: done"
[[ -f "$RUN_DIR/result.json" ]] || die "cron worker did not write result artifact"

log "syncing cron run state when a cron-dispatch task is cancelled through the queue"
CANCEL_RUN_ID="smoke-cancel-run"
CANCEL_RUN_DIR="$BRIDGE_STATE_DIR/cron/runs/$CANCEL_RUN_ID"
CANCEL_DISPATCH_BODY="$BRIDGE_SHARED_DIR/cron-dispatch/$CANCEL_RUN_ID.md"
mkdir -p "$CANCEL_RUN_DIR" "$(dirname "$CANCEL_DISPATCH_BODY")"
cat >"$CANCEL_RUN_DIR/request.json" <<EOF
{
  "run_id": "$CANCEL_RUN_ID",
  "job_id": "cancel-job",
  "job_name": "cancel-job",
  "target_agent": "$SMOKE_AGENT",
  "target_engine": "claude",
  "result_file": "$CANCEL_RUN_DIR/result.json",
  "status_file": "$CANCEL_RUN_DIR/status.json",
  "request_file": "$CANCEL_RUN_DIR/request.json"
}
EOF
cat >"$CANCEL_RUN_DIR/status.json" <<EOF
{
  "run_id": "$CANCEL_RUN_ID",
  "state": "queued",
  "engine": "claude",
  "request_file": "$CANCEL_RUN_DIR/request.json",
  "result_file": "$CANCEL_RUN_DIR/result.json"
}
EOF
cat >"$CANCEL_DISPATCH_BODY" <<EOF
# [cron-dispatch] cancel-job

- run_id: $CANCEL_RUN_ID
EOF
CANCEL_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "[cron-dispatch] cancel-job (2026-04-05T11:00:00Z)" --body-file "$CANCEL_DISPATCH_BODY" --from smoke-test)"
[[ "$CANCEL_CREATE_OUTPUT" =~ created\ task\ \#([0-9]+) ]] || die "could not parse cancel cron dispatch task id"
CANCEL_TASK_ID="${BASH_REMATCH[1]}"
bash "$REPO_ROOT/bridge-task.sh" cancel "$CANCEL_TASK_ID" --actor smoke-test --note "cancelled via smoke" >/dev/null
assert_contains "$(bash "$REPO_ROOT/bridge-task.sh" show "$CANCEL_TASK_ID")" "status: cancelled"
assert_contains "$(cat "$CANCEL_RUN_DIR/status.json")" "\"state\": \"cancelled\""
python3 - "$("$REPO_ROOT/agent-bridge" audit --action cron_dispatch_cancelled --limit 20 --json)" "$CANCEL_TASK_ID" <<'PY'
import json, sys
rows = json.loads(sys.argv[1])
task_id = sys.argv[2]
assert any(str(row.get("detail", {}).get("task_id")) == task_id for row in rows), rows
PY

log "reporting channel health misses to the admin role"
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

bridge_add_agent_id_if_missing "$BROKEN_CHANNEL_AGENT"
BRIDGE_AGENT_DESC["$BROKEN_CHANNEL_AGENT"]="Broken channel role"
BRIDGE_AGENT_ENGINE["$BROKEN_CHANNEL_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$BROKEN_CHANNEL_AGENT"]="broken-channel-$SESSION_NAME"
BRIDGE_AGENT_WORKDIR["$BROKEN_CHANNEL_AGENT"]="$BROKEN_CHANNEL_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$BROKEN_CHANNEL_AGENT"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CHANNELS["$BROKEN_CHANNEL_AGENT"]="plugin:discord"
EOF

bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
CHANNEL_HEALTH_INBOX="$(bash "$REPO_ROOT/bridge-task.sh" inbox "$SMOKE_AGENT" --all)"
assert_contains "$CHANNEL_HEALTH_INBOX" "[channel-health] $BROKEN_CHANNEL_AGENT (miss)"
CHANNEL_HEALTH_OPEN_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[channel-health] $BROKEN_CHANNEL_AGENT " 2>/dev/null || true)"
[[ "$CHANNEL_HEALTH_OPEN_ID" =~ ^[0-9]+$ ]] || die "expected channel-health task for $BROKEN_CHANNEL_AGENT"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
CHANNEL_HEALTH_OPEN_ID_AGAIN="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[channel-health] $BROKEN_CHANNEL_AGENT " 2>/dev/null || true)"
[[ "$CHANNEL_HEALTH_OPEN_ID_AGAIN" == "$CHANNEL_HEALTH_OPEN_ID" ]] || die "channel-health alert should be deduped"

log "deduping identical watchdog drift reports"
BRIDGE_WATCHDOG_INTERVAL_SECONDS=1 BRIDGE_WATCHDOG_COOLDOWN_SECONDS=3600 bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
WATCHDOG_OPEN_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[watchdog] " 2>/dev/null || true)"
[[ "$WATCHDOG_OPEN_ID" =~ ^[0-9]+$ ]] || die "expected watchdog task for drift report"
bash "$REPO_ROOT/bridge-task.sh" done "$WATCHDOG_OPEN_ID" --agent "$SMOKE_AGENT" --note "watchdog handled" >/dev/null
sleep 1
BRIDGE_WATCHDOG_INTERVAL_SECONDS=1 BRIDGE_WATCHDOG_COOLDOWN_SECONDS=3600 bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
WATCHDOG_OPEN_ID_AGAIN="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[watchdog] " 2>/dev/null || true)"
[[ -z "$WATCHDOG_OPEN_ID_AGAIN" ]] || die "watchdog alert should be deduped while drift hash is unchanged"

log "monitoring usage thresholds and deduping alerts"
FAKE_USAGE_ROOT="$(mktemp -d)"
FAKE_CLAUDE_USAGE="$FAKE_USAGE_ROOT/claude-usage.json"
FAKE_CODEX_SESSIONS="$FAKE_USAGE_ROOT/codex-sessions"
FAKE_USAGE_MONITOR_STATE="$FAKE_USAGE_ROOT/usage-monitor-state.json"
FAKE_USAGE_DAEMON_AUDIT="$FAKE_USAGE_ROOT/usage-daemon-audit.jsonl"
FAKE_USAGE_DAEMON_STATE="$FAKE_USAGE_ROOT/usage-daemon-state.json"
mkdir -p "$FAKE_CODEX_SESSIONS/2026/04/09"
cat >"$FAKE_CLAUDE_USAGE" <<'EOF'
{
  "data": {
    "planName": "Max",
    "fiveHour": 91,
    "sevenDay": 22,
    "fiveHourResetAt": "2026-04-09T13:00:00+00:00",
    "sevenDayResetAt": "2026-04-15T17:00:00+00:00"
  }
}
EOF
cat >"$FAKE_CODEX_SESSIONS/2026/04/09/usage.jsonl" <<'EOF'
{"timestamp":"2026-04-09T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":92.0,"window_minutes":300,"resets_at":1775734470},"secondary":{"used_percent":17.0,"window_minutes":10080,"resets_at":1776209770},"plan_type":"pro"}}}
EOF
USAGE_STATUS_JSON="$(BRIDGE_CLAUDE_USAGE_CACHE="$FAKE_CLAUDE_USAGE" BRIDGE_CODEX_SESSIONS_DIR="$FAKE_CODEX_SESSIONS" "$REPO_ROOT/agent-bridge" usage status --json)"
python3 - "$USAGE_STATUS_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
snapshots = payload["snapshots"]
assert any(row["provider"] == "claude" and row["window"] == "5h" for row in snapshots)
assert any(row["provider"] == "codex" and row["window"] == "5h" for row in snapshots)
PY
USAGE_MONITOR_FIRST="$(python3 "$REPO_ROOT/bridge-usage.py" monitor --claude-usage-cache "$FAKE_CLAUDE_USAGE" --codex-sessions-dir "$FAKE_CODEX_SESSIONS" --state-file "$FAKE_USAGE_MONITOR_STATE" --json)"
python3 - "$USAGE_MONITOR_FIRST" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
alerts = payload["alerts"]
assert len(alerts) == 2, alerts
assert any(row["provider"] == "claude" and row["window"] == "5h" for row in alerts)
assert any(row["provider"] == "codex" and row["window"] == "5h" for row in alerts)
PY
USAGE_MONITOR_SECOND="$(python3 "$REPO_ROOT/bridge-usage.py" monitor --claude-usage-cache "$FAKE_CLAUDE_USAGE" --codex-sessions-dir "$FAKE_CODEX_SESSIONS" --state-file "$FAKE_USAGE_MONITOR_STATE" --json)"
python3 - "$USAGE_MONITOR_SECOND" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["alerts"] == [], payload["alerts"]
PY
BRIDGE_USAGE_MONITOR_INTERVAL_SECONDS=0 \
BRIDGE_DAEMON_NOTIFY_DRY_RUN=1 \
BRIDGE_AUDIT_LOG="$FAKE_USAGE_DAEMON_AUDIT" \
BRIDGE_CLAUDE_USAGE_CACHE="$FAKE_CLAUDE_USAGE" \
BRIDGE_CODEX_SESSIONS_DIR="$FAKE_CODEX_SESSIONS" \
BRIDGE_USAGE_MONITOR_STATE_FILE="$FAKE_USAGE_DAEMON_STATE" \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
POST_USAGE_ALERTS="$(BRIDGE_AUDIT_LOG="$FAKE_USAGE_DAEMON_AUDIT" "$REPO_ROOT/agent-bridge" usage alerts --json)"
python3 - "$POST_USAGE_ALERTS" <<'PY'
import json, sys
alerts = json.loads(sys.argv[1])
assert any(row["detail"]["provider"] == "claude" and row["detail"]["window"] == "5h" for row in alerts), alerts
assert any(row["detail"]["provider"] == "codex" and row["detail"]["window"] == "5h" for row in alerts), alerts
PY

log "escalating crash-loop reports to the admin role"
CRASH_ERRFILE="$TMP_ROOT/crash-loop.err"
cat >"$CRASH_ERRFILE" <<'EOF'
fatal: token expired
unable to open runtime config
EOF
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_write_crash_report \"$BROKEN_CHANNEL_AGENT\" \"claude\" \"5\" \"1\" \"$CRASH_ERRFILE\" 'claude --dangerously-skip-permissions'"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
CRASH_OPEN_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[crash-loop] $BROKEN_CHANNEL_AGENT " 2>/dev/null || true)"
[[ "$CRASH_OPEN_ID" =~ ^[0-9]+$ ]] || die "expected crash-loop task for $BROKEN_CHANNEL_AGENT"
bash "$REPO_ROOT/bridge-task.sh" done "$CRASH_OPEN_ID" --agent "$SMOKE_AGENT" --note "crash report handled" >/dev/null
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
CRASH_OPEN_ID_AGAIN="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[crash-loop] $BROKEN_CHANNEL_AGENT " 2>/dev/null || true)"
[[ -z "$CRASH_OPEN_ID_AGAIN" ]] || die "crash-loop report should be deduped while error hash is unchanged"
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_clear_crash_report \"$BROKEN_CHANNEL_AGENT\""

log "directly alerting on admin crash loops"
ADMIN_CRASH_ERRFILE="$TMP_ROOT/admin-crash-loop.err"
cat >"$ADMIN_CRASH_ERRFILE" <<'EOF'
admin fatal: runtime auth missing
EOF
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_write_crash_report \"$SMOKE_AGENT\" \"codex\" \"5\" \"2\" \"$ADMIN_CRASH_ERRFILE\" 'codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'"
PRE_ADMIN_CRASH_ALERTS="$("$REPO_ROOT/agent-bridge" audit --action crash_loop_admin_alert --limit 20 --json)"
BRIDGE_DAEMON_NOTIFY_DRY_RUN=1 bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
POST_ADMIN_CRASH_ALERTS="$("$REPO_ROOT/agent-bridge" audit --action crash_loop_admin_alert --limit 20 --json)"
python3 - "$PRE_ADMIN_CRASH_ALERTS" "$POST_ADMIN_CRASH_ALERTS" <<'PY'
import json, sys
before = json.loads(sys.argv[1])
after = json.loads(sys.argv[2])
assert len(after) >= len(before) + 1
PY
BRIDGE_DAEMON_NOTIFY_DRY_RUN=1 bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
POST_ADMIN_CRASH_ALERTS_DEDUPED="$("$REPO_ROOT/agent-bridge" audit --action crash_loop_admin_alert --limit 20 --json)"
python3 - "$POST_ADMIN_CRASH_ALERTS" "$POST_ADMIN_CRASH_ALERTS_DEDUPED" <<'PY'
import json, sys
before = json.loads(sys.argv[1])
after = json.loads(sys.argv[2])
assert len(after) == len(before)
PY
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_clear_crash_report \"$SMOKE_AGENT\""

log "detecting and recovering stalled sessions"
STALL_RATE_AGENT="stall-rate-$SESSION_NAME"
STALL_AUTH_AGENT="stall-auth-$SESSION_NAME"
STALL_UNKNOWN_AGENT="stall-unknown-$SESSION_NAME"
STALL_RATE_WORKDIR="$TMP_ROOT/$STALL_RATE_AGENT"
STALL_AUTH_WORKDIR="$TMP_ROOT/$STALL_AUTH_AGENT"
STALL_UNKNOWN_WORKDIR="$TMP_ROOT/$STALL_UNKNOWN_AGENT"
mkdir -p "$STALL_RATE_WORKDIR" "$STALL_AUTH_WORKDIR" "$STALL_UNKNOWN_WORKDIR"
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

bridge_add_agent_id_if_missing "$STALL_RATE_AGENT"
BRIDGE_AGENT_DESC["$STALL_RATE_AGENT"]="Stall rate-limit role"
BRIDGE_AGENT_ENGINE["$STALL_RATE_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$STALL_RATE_AGENT"]="$STALL_RATE_AGENT"
BRIDGE_AGENT_WORKDIR["$STALL_RATE_AGENT"]="$STALL_RATE_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$STALL_RATE_AGENT"]='claude --dangerously-skip-permissions'

bridge_add_agent_id_if_missing "$STALL_AUTH_AGENT"
BRIDGE_AGENT_DESC["$STALL_AUTH_AGENT"]="Stall auth role"
BRIDGE_AGENT_ENGINE["$STALL_AUTH_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$STALL_AUTH_AGENT"]="$STALL_AUTH_AGENT"
BRIDGE_AGENT_WORKDIR["$STALL_AUTH_AGENT"]="$STALL_AUTH_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$STALL_AUTH_AGENT"]='claude --dangerously-skip-permissions'

bridge_add_agent_id_if_missing "$STALL_UNKNOWN_AGENT"
BRIDGE_AGENT_DESC["$STALL_UNKNOWN_AGENT"]="Stall unknown role"
BRIDGE_AGENT_ENGINE["$STALL_UNKNOWN_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$STALL_UNKNOWN_AGENT"]="$STALL_UNKNOWN_AGENT"
BRIDGE_AGENT_WORKDIR["$STALL_UNKNOWN_AGENT"]="$STALL_UNKNOWN_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$STALL_UNKNOWN_AGENT"]='claude --dangerously-skip-permissions'
EOF

STALL_RATE_INPUT_LOG="$TMP_ROOT/stall-rate-input.log"
STALL_AUTH_INPUT_LOG="$TMP_ROOT/stall-auth-input.log"
STALL_UNKNOWN_INPUT_LOG="$TMP_ROOT/stall-unknown-input.log"
STALL_RATE_SCRIPT="$TMP_ROOT/stall-rate.py"
STALL_AUTH_SCRIPT="$TMP_ROOT/stall-auth.py"
STALL_UNKNOWN_SCRIPT="$TMP_ROOT/stall-unknown.py"
cat >"$STALL_RATE_SCRIPT" <<'PY'
#!/usr/bin/env python3
import sys
print("You've hit your limit")
print("❯ ")
sys.stdout.flush()
for _ in sys.stdin:
    pass
PY
cat >"$STALL_AUTH_SCRIPT" <<'PY'
#!/usr/bin/env python3
import sys
print("session expired")
print("❯ ")
sys.stdout.flush()
for _ in sys.stdin:
    pass
PY
cat >"$STALL_UNKNOWN_SCRIPT" <<'PY'
#!/usr/bin/env python3
import sys
print("still thinking")
print("❯ ")
sys.stdout.flush()
for _ in sys.stdin:
    pass
PY
chmod +x "$STALL_RATE_SCRIPT" "$STALL_AUTH_SCRIPT" "$STALL_UNKNOWN_SCRIPT"
tmux new-session -d -s "$STALL_RATE_AGENT" "$STALL_RATE_SCRIPT"
tmux new-session -d -s "$STALL_AUTH_AGENT" "$STALL_AUTH_SCRIPT"
tmux new-session -d -s "$STALL_UNKNOWN_AGENT" "$STALL_UNKNOWN_SCRIPT"
sleep 1
bash "$REPO_ROOT/bridge-sync.sh" >/dev/null

STALL_RATE_CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" task create --to "$STALL_RATE_AGENT" --title "stall rate" --body "smoke" --from smoke)"
STALL_RATE_TASK_ID="$(printf '%s\n' "$STALL_RATE_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$STALL_RATE_TASK_ID" =~ ^[0-9]+$ ]] || die "expected rate stall task id"
python3 "$REPO_ROOT/bridge-queue.py" claim "$STALL_RATE_TASK_ID" --agent "$STALL_RATE_AGENT" >/dev/null
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
BRIDGE_STALL_RATE_LIMIT_RETRY_SECONDS=0 \
BRIDGE_STALL_ESCALATE_AFTER_SECONDS=0 \
BRIDGE_STALL_MAX_NUDGES=2 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
BRIDGE_STALL_RATE_LIMIT_RETRY_SECONDS=0 \
BRIDGE_STALL_ESCALATE_AFTER_SECONDS=0 \
BRIDGE_STALL_MAX_NUDGES=2 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
RATE_LIMIT_STALL_TASK_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[STALL/RATE_LIMIT] $STALL_RATE_AGENT " 2>/dev/null || true)"
[[ "$RATE_LIMIT_STALL_TASK_ID" =~ ^[0-9]+$ ]] || die "expected rate-limit stall escalation"
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
BRIDGE_STALL_RATE_LIMIT_RETRY_SECONDS=0 \
BRIDGE_STALL_ESCALATE_AFTER_SECONDS=0 \
BRIDGE_STALL_MAX_NUDGES=2 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
RATE_LIMIT_STALL_TASK_ID_AGAIN="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[STALL/RATE_LIMIT] $STALL_RATE_AGENT " 2>/dev/null || true)"
[[ "$RATE_LIMIT_STALL_TASK_ID_AGAIN" == "$RATE_LIMIT_STALL_TASK_ID" ]] || die "expected deduped rate-limit stall escalation"
RATE_NUDGE_COUNT="$(python3 - "$BRIDGE_HOME/logs/audit.jsonl" "$STALL_RATE_AGENT" <<'PY'
import json, sys
count = 0
for raw in open(sys.argv[1], encoding="utf-8"):
    item = json.loads(raw)
    if item.get("action") == "stall_nudge_sent" and item.get("target") == sys.argv[2]:
        count += 1
print(count)
PY
)"
[[ "$RATE_NUDGE_COUNT" == "2" ]] || die "expected exactly two stall nudges before rate-limit escalation"

STALL_AUTH_CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" task create --to "$STALL_AUTH_AGENT" --title "stall auth" --body "smoke" --from smoke)"
STALL_AUTH_TASK_ID="$(printf '%s\n' "$STALL_AUTH_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$STALL_AUTH_TASK_ID" =~ ^[0-9]+$ ]] || die "expected auth stall task id"
python3 "$REPO_ROOT/bridge-queue.py" claim "$STALL_AUTH_TASK_ID" --agent "$STALL_AUTH_AGENT" >/dev/null
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
AUTH_STALL_TASK_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[STALL/AUTH] $STALL_AUTH_AGENT " 2>/dev/null || true)"
[[ "$AUTH_STALL_TASK_ID" =~ ^[0-9]+$ ]] || die "expected auth stall escalation"

STALL_UNKNOWN_CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" task create --to "$STALL_UNKNOWN_AGENT" --title "stall unknown" --body "smoke" --from smoke)"
STALL_UNKNOWN_TASK_ID="$(printf '%s\n' "$STALL_UNKNOWN_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$STALL_UNKNOWN_TASK_ID" =~ ^[0-9]+$ ]] || die "expected unknown stall task id"
python3 "$REPO_ROOT/bridge-queue.py" claim "$STALL_UNKNOWN_TASK_ID" --agent "$STALL_UNKNOWN_AGENT" >/dev/null
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_IDLE_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_RETRY_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_ESCALATE_SECONDS=0 \
BRIDGE_STALL_MAX_NUDGES=2 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_IDLE_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_RETRY_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_ESCALATE_SECONDS=0 \
BRIDGE_STALL_MAX_NUDGES=2 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
UNKNOWN_STALL_TASK_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[STALL/UNKNOWN] $STALL_UNKNOWN_AGENT " 2>/dev/null || true)"
[[ "$UNKNOWN_STALL_TASK_ID" =~ ^[0-9]+$ ]] || die "expected unknown stall escalation"

tmux kill-session -t "$STALL_RATE_AGENT" >/dev/null 2>&1 || true
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
STALL_RECOVERED_JSON="$("$REPO_ROOT/agent-bridge" audit --action stall_recovered --limit 20 --json)"
python3 - "$STALL_RECOVERED_JSON" "$STALL_RATE_AGENT" <<'PY'
import json, sys
rows = json.loads(sys.argv[1])
assert any(row.get("target") == sys.argv[2] for row in rows), rows
PY

log "smoke test passed"
