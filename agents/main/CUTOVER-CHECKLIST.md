# Main Cutover Checklist

Updated: 2026-04-05
Scope: `main` maintenance-window cutover from OpenClaw gateway prompt stack to Agent Bridge tracked profile

## 0. Current State

- Tracked profile commit: `1ff1058` (`main: mirror SOUL voice in CLAUDE`)
- Current model provider: OpenAI Codex (`~/.openclaw/patch/scripts/model-switch.sh status`)
- Live workspace: `~/.openclaw/workspace`
- Live session store: `~/.openclaw/agents/main/`
- Bridge live install: `~/.agent-bridge/`

## 1. Preconditions

These must be true before the maintenance window starts.

- `~/agent-bridge` is up to date and the tracked `agents/main/CLAUDE.md` contains the approved SOUL-based text.
- The live Agent Bridge install is refreshed:

```bash
cd ~/agent-bridge
./scripts/deploy-live-install.sh --restart-daemon
```

- `main` is added to `~/.agent-bridge/agent-roster.local.sh`.
  Minimum cutover stanza:

```bash
bridge_add_agent_id_if_missing "main"
BRIDGE_AGENT_DESC["main"]="Main family agent (Claude Code)"
BRIDGE_AGENT_ENGINE["main"]="claude"
BRIDGE_AGENT_SESSION["main"]="main"
BRIDGE_AGENT_WORKDIR["main"]="$HOME/.openclaw/workspace"
BRIDGE_AGENT_PROFILE_HOME["main"]="$HOME/.openclaw/workspace"
BRIDGE_AGENT_LAUNCH_CMD["main"]='claude --dangerously-skip-permissions -c --channels plugin:telegram@claude-plugins-official'
BRIDGE_AGENT_ACTION["main:resume"]="/resume"
BRIDGE_AGENT_ACTION["main:clear"]="/clear"
BRIDGE_OPENCLAW_AGENT_TARGET["main"]="main"
```

Notes:
- Start with Telegram only. Discord can be added after the first smoke if needed.
- `BRIDGE_AGENT_PROFILE_HOME` must point at `~/.openclaw/workspace`, or `profile deploy main` will not work.

- Dry-run the new static role before downtime:

```bash
~/.agent-bridge/agb profile status main
~/.agent-bridge/agb profile diff main
~/.agent-bridge/agb profile deploy main --dry-run
bash ~/.agent-bridge/bridge-start.sh main --dry-run
```

## 2. Provider Fallback Prep

`main` is currently on OpenAI Codex. Keep the Anthropic fallback ready before cutover:

```bash
~/.openclaw/patch/scripts/model-switch.sh status
~/.openclaw/patch/scripts/model-switch.sh anthropic --dry-run
```

If Claude/Codex rate limits or provider issues appear during smoke:

```bash
~/.openclaw/patch/scripts/model-switch.sh anthropic
```

Re-check after the switch:

```bash
~/.openclaw/patch/scripts/model-switch.sh status
```

## 3. Backup Before Stop

Back up the live gateway state before touching `main`. This captures both the prompt stack and the existing session archive.

```bash
export CUTOVER_TS="$(TZ=Asia/Seoul date +%Y%m%d-%H%M%S)"
export CUTOVER_BACKUP_DIR="$HOME/.openclaw/backups/main-cutover-$CUTOVER_TS"
mkdir -p "$CUTOVER_BACKUP_DIR"

cp -Rp ~/.openclaw/agents/main "$CUTOVER_BACKUP_DIR/agents-main"
cp -Rp ~/.openclaw/workspace "$CUTOVER_BACKUP_DIR/workspace"
cp -p ~/.openclaw/openclaw.json "$CUTOVER_BACKUP_DIR/openclaw.json"
cp -p ~/.agent-bridge/agent-roster.local.sh "$CUTOVER_BACKUP_DIR/agent-roster.local.sh"
```

Verification:

```bash
ls -la "$CUTOVER_BACKUP_DIR"
ls -la "$CUTOVER_BACKUP_DIR/agents-main"
ls -la "$CUTOVER_BACKUP_DIR/workspace"
```

Important:
- `~/.openclaw/agents/main/sessions/` contains the historical session archive, including `sessions.json`.
- Do not rely on Git alone for rollback. Copy the live directories.

## 4. Gateway Stop Order

Keep the stop sequence explicit to avoid split-brain between gateway `main` and bridge `main`.

1. Confirm gateway runtime before touching it:

```bash
pgrep -f "openclaw.*gateway"
openclaw gateway status
```

2. Stop the gateway:

```bash
openclaw gateway stop
```

3. Verify it is fully down:

```bash
pgrep -f "openclaw.*gateway"
openclaw gateway status
```

4. If the process survives `openclaw gateway stop`, use the LaunchAgent fallback:

```bash
launchctl bootout "gui/$UID/ai.openclaw.gateway" 2>/dev/null || true
sleep 3
pgrep -f "openclaw.*gateway"
```

Notes:
- Do not stop Agent Bridge here. Only the OpenClaw gateway should go down.
- Keep the gateway down through the first `main` bridge smoke so there is no double responder.

## 5. Profile Deploy And Start

Deploy the tracked `main` profile into the live workspace, then start the bridge-managed static role.

```bash
~/.agent-bridge/agb profile deploy main
bash ~/.agent-bridge/bridge-start.sh main
```

If the `main` tmux session already exists and needs replacement:

```bash
bash ~/.agent-bridge/bridge-start.sh main --replace
```

## 6. Smoke Tests

Run these immediately after the bridge `main` session starts.

```bash
~/.agent-bridge/agb profile status main
~/.agent-bridge/agb status --all-agents
~/.agent-bridge/agb cron inventory --agent main --mode recurring
~/.agent-bridge/agb cron errors report --family memory-daily --limit 10
tmux capture-pane -pt main | tail -n 60
```

Manual checks:
- `main` session boots in `~/.openclaw/workspace`
- `CLAUDE.md` is present in `~/.openclaw/workspace`
- no immediate startup error in the tmux pane
- bridge dashboard shows `main` as active
- cron inventory / error report commands still resolve `main`

Optional first-message check:
- Send a non-user-facing test instruction inside the tmux session and verify the prompt stack is coherent before exposing it to Telegram traffic.

## 7. Rollback

If `main` fails the smoke, revert immediately.

1. Stop the bridge `main` session:

```bash
tmux kill-session -t main 2>/dev/null || true
```

2. Restore the backed-up live directories:

```bash
cp -Rp "$CUTOVER_BACKUP_DIR/agents-main/." ~/.openclaw/agents/main/
cp -Rp "$CUTOVER_BACKUP_DIR/workspace/." ~/.openclaw/workspace/
cp -p "$CUTOVER_BACKUP_DIR/openclaw.json" ~/.openclaw/openclaw.json
cp -p "$CUTOVER_BACKUP_DIR/agent-roster.local.sh" ~/.agent-bridge/agent-roster.local.sh
```

3. Bring the gateway back:

```bash
openclaw gateway start
openclaw gateway status
```

4. If needed, switch the provider back to the known-good state:

```bash
~/.openclaw/patch/scripts/model-switch.sh status
~/.openclaw/patch/scripts/model-switch.sh openai
~/.openclaw/patch/scripts/model-switch.sh status
```

## 8. Post-Cutover Notes

Record these in shared notes right after the window:

- start time / end time
- exact backup directory used
- whether Anthropic fallback was needed
- smoke result
- whether the gateway stayed down or was restarted afterward
- follow-up items for Discord channel expansion or cron migration
