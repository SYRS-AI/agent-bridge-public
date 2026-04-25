# Known Issues

This file tracks operational caveats that matter when extending the bridge.

## 1. Claude trust prompt on first run

Symptom:

- A fresh Claude session in a new folder may stop at a trust prompt before it accepts normal bridge input

Impact:

- The first interaction may require manual confirmation

Workaround:

- Confirm the trust prompt once in that folder
- Future resume flows can then proceed normally

## 2. Urgent sends still depend on prompt state

Current behavior:

- Claude urgent sends now use literal typing plus submit
- Codex urgent sends still use paste plus submit

Residual risk:

- If the target session is in an unusual TUI state or nonstandard input mode, submit behavior may still vary

Operator guidance:

- Keep urgent messages short
- Prefer queue-based work handoff
- If an urgent send looks stuck, inspect the pane before retrying

## 3. Fresh installs have no static roles

This is intentional.

Impact:

- `bridge-start.sh --list` will show no static roles until a user creates `agent-roster.local.sh`

Operator guidance:

- Use `agent-bridge --codex|--claude --name ...` immediately
- Add local static roles only when they add value

## 4. Runtime state is local and untracked

The following are not committed:

- `state/`
- `logs/`
- `shared/`
- `agent-roster.local.sh`

Impact:

- Another machine will not inherit your live sessions, queue history, or local static roles

Operator guidance:

- Treat these as local runtime state, not deployable source

## 5. Smoke test is synthetic

`scripts/smoke-test.sh` validates:

- shell syntax
- optional shellcheck
- isolated daemon startup
- isolated static role launch
- queue create/claim/done
- list, summary, status, and sync paths

It does not validate:

- real Claude CLI behavior
- real Codex CLI behavior
- model-side resume semantics

Use live smoke sessions for those.

## 6. macOS requires non-system Bash

macOS ships Bash `3.2`, but the bridge uses associative arrays.

Operator guidance:

- Install Homebrew Bash
- Put Homebrew `bin` ahead of `/bin` in your shell `PATH`

## 7. Claude custom channel wake is currently disabled

Current behavior:

- the repo still contains `bridge-channel-server.py`, `bridge-channels.py`, and `lib/bridge-channels.sh`
- the active runtime path does not use them
- Claude wake currently relies on `Stop` hook idle markers plus short idle-only `tmux` sends

Reason:

- `--dangerously-load-development-channels` is not suitable for unattended setup or OSS onboarding because it introduces an interactive trust step

Operator guidance:

- treat the channel helpers as backlog / future capability
- restart Claude sessions after bridge deploys that change idle wake behavior

## 8. `bridge-knowledge search` default auto-switches to hybrid when a v2 index exists

Current behavior:

- with no index present the default path stays legacy regex for backwards compatibility
- once an operator runs `bridge-memory rebuild-index --index-kind bridge-wiki-hybrid-v2`, `bridge-knowledge search` automatically prefers the hybrid engine for that agent
- `--legacy-text` is the explicit opt-out flag that forces the regex path regardless

Reason:

- the hybrid engine is higher quality when the index is available; the auto-switch saves operators from having to remember `--hybrid` on every call

Operator guidance:

- treat "did I build a v2 index?" as the effective toggle
- if result shape changes after an index rebuild, that is expected — rerun with `--legacy-text` to compare

## 9. Teams `/auth/callback` endpoint authenticates by state-token possession alone

Current behavior:

- the Teams plugin exposes `/auth/callback` for the ms365 authorization-code pairing flow
- incoming requests are validated only by the tight state regex (`^[A-Za-z0-9_-]{8,128}$`) and written atomically under `$BRIDGE_HOME/shared/ms365-callbacks/<state>.json`
- there is no separate check that a matching `pair_start` is currently pending

Reason:

- the ms365 plugin generates state as a random UUID with a 15-minute expiry, and `pair_poll` consumes and unlinks the callback file on success or error
- for the hosted/local-only deployment targets this is sufficient in practice, and the atomic file write keeps the endpoint safe against concurrent/partial writes

Operator guidance:

- do not expose the Teams plugin's `/auth/callback` to the public internet without additional ingress-level auth (mTLS, ingress token, IP allowlist)
- if you operate a multi-tenant hosted Teams plugin, layer your own `state` allowlist or HMAC before this handler

## 10. Singleton channel plugins (Telegram / Discord) poll-lock across concurrent agents

Current behavior:

- Telegram and Discord bots enforce one-poller-per-bot-token: only one process at a time may hold the `getUpdates` long-poll (Telegram) or the gateway websocket (Discord). A second connection on the same token gets a `409 Conflict` (Telegram) or a session-kick (Discord).
- Claude Code auto-spawns every `~/.claude/settings.json` `enabledPlugins` entry for every agent session, so absent an override every agent's claude process tries to run its own telegram/discord MCP child. The most recently restarted agent holds the lease; every earlier agent has been silently kicked off.

Fix (applied by default from #244):

- `scripts/apply-channel-policy.sh` writes the shared overlay at `agents/.claude/settings.local.json` so every agent whose `.claude/settings.json` resolves to the shared effective settings gets `telegram@claude-plugins-official` and `discord@claude-plugins-official` explicitly disabled.
- When an admin agent is configured (`BRIDGE_ADMIN_AGENT_ID` in env or roster), the same script writes a per-agent local overlay at `agents/<admin>/.claude/settings.local.json` re-enabling those singleton plugins for the router. Claude Code's settings merge order prefers the project `.claude/settings.local.json` over the project `.claude/settings.json` (the shared-effective symlink), so the admin keeps the channels while every other agent stops contending.
- `bridge-upgrade.sh` re-runs the policy on every upgrade (idempotent).

Operator guidance:

- Run `bash scripts/apply-channel-policy.sh` manually after adding or removing agents if the policy has drifted.
- If you change the admin agent (`BRIDGE_ADMIN_AGENT_ID`), re-run `apply-channel-policy.sh` and then remove `agents/<previous-admin>/.claude/settings.local.json` — the script only writes the new admin's overlay, it does not clean up prior admins.
- If a non-admin agent needs its own DM endpoint, provision a dedicated bot token per agent and add the plugin id to that agent's `.claude/settings.json` explicitly, rather than relying on the shared token.

## 11. Daemon exit observability (historical issue #194 closed by v0.6.x hardening)

Background:

- Issue #194 tracked a v0.4.2 → v0.6.0 upgrade where `launchd` respawned `bridge-daemon` six times in ~24 minutes; the only signal at the time was `mtime` gaps in OPERATIONS log because the daemon left no exit reason in `state/launchagent.log`, `state/daemon.log`, or `logs/audit.jsonl`. The issue body explicitly named "exit observability hook" as a precondition to root-causing the cascade.

Current behavior (from v0.6.x; see commit history of `bridge-daemon.sh`):

- `cmd_run` registers four traps before entering the main loop: `_bridge_daemon_on_signal` for `TERM`/`INT`/`HUP`, `_bridge_daemon_on_err` (under `set -E`) for any `set -e` abort, and `_bridge_daemon_on_exit` for `EXIT`.
- Every loop step writes its name into `BRIDGE_DAEMON_LAST_STEP` (27 distinct values across `load_roster`, `discord_relay`, `bridge_sync`, `queue_gateway`, `nudge_scan`, `plugin_liveness`, `idle_sleep`, etc.).
- On exit the EXIT trap appends a single structured line to `state/launchagent.log` and emits a `daemon daemon_exit` row to `logs/audit.jsonl` carrying `pid`, `exit_code`, `signal`, `last_step`, and `err_location` (file:line of the first ERR-trapped failure). `state/daemon-crash.log` also receives the message on non-zero exit.
- Issue #265's four-part hardening compounds the coverage: per-call `bridge_with_timeout` wrapper around the high-risk subprocess sites including every `tmux send-keys` (PRs #279, #281), periodic `daemon_tick` audit + heartbeat file (PR #274), sibling silence supervisor (PR #293), and OS-level liveness watcher (PR #292). Issues #261/#262 added broken-launch quarantine, #270 closed the stall self-loop, #273 sweeps PPID=1 orphan daemons.
- Result: the three plausible exit scenarios from #194 (`set -e` abort, SIGTERM, supervisor-driven restart cascade) all now leave a complete attribution trail across `launchagent.log` + `audit.jsonl` + `daemon-crash.log`.

Operator guidance:

- After a `launchd`/`systemd` respawn cascade, look first at `logs/audit.jsonl` filtered to `actor=daemon` — every exit pairs `daemon_exit` with the prior `daemon_tick` (showing which loop step was active before the silence), `daemon_subprocess_timeout` (showing which call_site hung), or `daemon_silence_*` (showing supervisor-initiated restarts).
- `state/launchagent.log` keeps the same line in plain text for hosts where the audit log is unreadable.
- The original v0.4.2 → v0.6.0 specific hypotheses in #194 (post-upgrade python helper missing, plugin MCP liveness restart against gone session, librarian cron cascade) refer to code paths that no longer exist in their #194-era form; the chain of fixes above either removed them or made them externally observable. Treat #194 as historical — if a similar respawn cascade reappears on a current install, file a fresh issue with the `daemon_exit` audit excerpt rather than reopening #194.
## 12. Disposable cron child cold-start latency

Current behavior:

- Each native cron fire spawns a fresh `claude -p --no-session-persistence ...` child via `bridge-cron-runner.py`. That child cold-loads the Claude CLI binary, every MCP server wired into the agent's plugin set, and a new session bootstrap.
- On warm hosts this adds several seconds per fire; on memory-pressured hosts (e.g. 8 GB Mac mini) it can push the child past `BRIDGE_CRON_SUBAGENT_TIMEOUT_SECONDS` before user code runs (issue #263).
- Most polling/reminder crons (`event-reminder-30min`, `cs-line-poll-5m`, etc.) never call MCP tools, so the MCP cold-load is pure waste.

Mitigation (applied from #263):

- Per-job opt-in: set `metadata.disableMcp` (or `disable_mcp` / `disposableDisableMcp` / `disposable_disable_mcp`) on a cron job to launch its disposable child with `--strict-mcp-config` and no `--mcp-config`, which loads zero MCP servers. Local benchmark on a warm host: claude `-p` cold start dropped from ~5–10 s real / ~2.9 s user to ~3.2–3.7 s real / ~0.6 s user (~78% CPU saved per fire).
- Ops A/B switch: `BRIDGE_CRON_DISPOSABLE_DISABLE_MCP=1` in the runtime env forces every cron child to skip MCP regardless of per-job config; `=0` forces it on. Unset defers to per-job metadata. Use this to roll the change install-wide before annotating individual jobs.
- Safety override: jobs with `metadata.disposableNeedsChannels=true` (channel-relay flow) keep MCP enabled even when the flag asks otherwise — the relay path still needs channel MCP servers to deliver.

Operator guidance:

- Tag every `*/N`-minute polling cron whose body is "fetch + summarise" with `metadata.disableMcp=true`. Reminder/scheduler families are the highest-leverage targets.
- Leave the flag unset for any cron whose payload calls MCP tools (e.g. plugin-driven research, workspace MCP queries).
- This addresses MCP cold-load only. The CLI binary load and session bootstrap remain per-fire; warm-pool / runtime-substitution work tracked in #263 follow-ups.
