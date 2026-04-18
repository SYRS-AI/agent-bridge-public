# Operations

This is the operator runbook for a normal Agent Bridge install.

The recommended layout is:

- Source checkout: `~/.agent-bridge-source`
- Live runtime: `~/.agent-bridge`

The source checkout is safe to pull from GitHub. The live runtime contains local
state, logs, queues, agent homes, and machine-specific configuration. Do not
replace it with a raw `cp -R` or `git clone`.

## Daily Startup

Verify prerequisites:

```bash
git --version
python3 --version
tmux -V
claude --version
```

On macOS, use Homebrew Bash when available because the system Bash is too old
for associative arrays:

```bash
/opt/homebrew/bin/bash --version
```

Start or verify the daemon:

```bash
~/.agent-bridge/agent-bridge daemon ensure
~/.agent-bridge/agent-bridge daemon status
```

If the shell integration is installed, the shorthand is:

```bash
agb daemon ensure
agb daemon status
```

On macOS, keep the daemon under `launchd` so crashes auto-restart:

```bash
cd ~/.agent-bridge
./scripts/install-daemon-launchagent.sh --apply --load
launchctl print gui/$UID/ai.agent-bridge.daemon
```

Check overall status:

```bash
agb status
agb list
```

If the daemon misbehaves, inspect live runtime logs:

```bash
tail -n 80 ~/.agent-bridge/state/daemon.log
tail -n 80 ~/.agent-bridge/state/daemon-crash.log
tail -n 80 ~/.agent-bridge/state/launchagent.log
```

## Upgrade

Use the built-in upgrade path instead of copying files by hand:

```bash
agb upgrade --dry-run
agb upgrade
```

The upgrader preserves local runtime data by default:

- `agent-roster.local.sh`
- `state/`
- `logs/`
- `shared/`
- `agents/*` runtime homes
- local backups and generated files

For a source checkout to live runtime deploy during development:

```bash
cd ~/.agent-bridge-source
./scripts/deploy-live-install.sh --dry-run --target ~/.agent-bridge
./scripts/deploy-live-install.sh --target ~/.agent-bridge --restart-daemon
```

## Recommended Collaboration Pattern

1. Start agents
2. Create tasks through the queue
3. Let each agent claim work
4. Use urgent sends only for real interrupts

Typical operator flow:

```bash
agb --codex --name dev
agb --claude --name tester
agb task create --to tester --title "retest" --body-file ~/.agent-bridge/shared/report.md
agb inbox tester
agb claim 1 --agent tester
agb done 1 --agent tester --note "verified"
```

## Static Roles

Fresh installs have no static roles. This is intentional.

If you want machine-local static roles:

```bash
cp ~/.agent-bridge/agent-roster.local.example.sh ~/.agent-bridge/agent-roster.local.sh
```

Put machine-specific workdirs, channel IDs, tokens, and launch commands in
`agent-roster.local.sh`, not in tracked source.

Tracked prompt/profile templates live under `agents/`. Private production
prompt stacks should stay out of the public repository unless they are generic
enough for all users.

If the live CLI home differs from the bridge workdir, declare
`BRIDGE_AGENT_PROFILE_HOME["agent"]="..."` in `agent-roster.local.sh` and use:

```bash
agb profile status
agb profile diff <agent>
agb profile deploy <agent>
```

### Claude launch-flag overrides

For dynamic Claude agents (and static Claude agents that rely on the
bridge-built launch command), three optional roster fields control the
generated `claude` invocation:

| field | default when opted in | flag |
|---|---|---|
| `BRIDGE_AGENT_MODEL` | `claude-opus-4-7` | `--model` |
| `BRIDGE_AGENT_EFFORT` | `xhigh` | `--effort` |
| `BRIDGE_AGENT_PERMISSION_MODE` | `auto` | `--permission-mode` |

Leaving all three unset preserves the historical
`claude --dangerously-skip-permissions --name <agent>` shape byte-for-byte,
so rosters that predate these fields keep launching unchanged. Setting any
one field opts the agent into the new shape; remaining fields fall back to
the defaults above. Set `BRIDGE_AGENT_PERMISSION_MODE["agent"]="legacy"`
to explicitly pin the historical blanket-bypass shape (e.g. for sandboxed
offline roles).

## Worktree Workers

When multiple agents may edit the same git repository, prefer isolated managed
worktrees:

```bash
agb --codex --name reviewer-a --prefer new
agb worktree list
```

Managed worktrees live under:

```text
~/.agent-bridge/worktrees/<repo-slug>/<agent>
```

## Status And Debugging

Use these first:

```bash
agb status
agb status --watch
agb summary
agb list
agb cron inventory --limit 20
agb cron inventory --mode one-shot --limit 20
agb cron list --agent <agent>
agb cron errors report --limit 20
agb cron cleanup report
```

`agb status` includes columns for source kind, loop mode, queue load, wake
status, activity age, and stale-session health. Stale health is based on local
tmux activity and recorded bridge state, not on model calls.

When changing cron behavior, inspect jobs before modifying them:

```bash
agb cron show <job-id>
agb cron sync --dry-run
```

One-shot jobs should be tested with dry-run first:

```bash
agb cron enqueue <job-id> --slot 2026-04-05 --dry-run
```

Automatic recurring scheduling is opt-in. Enable it only on machines that
should actively enqueue scheduled work:

```bash
BRIDGE_CRON_SYNC_ENABLED=1
```

Inspect runtime state directly when needed:

```bash
cat ~/.agent-bridge/state/active-roster.md
sqlite3 ~/.agent-bridge/state/tasks.db '.tables'
tail -n 80 ~/.agent-bridge/state/daemon.log
tail -n 80 ~/.agent-bridge/logs/bridge-$(date +%Y%m%d).log
```

## Safe Cleanup

Kill active bridge sessions:

```bash
agb kill all
```

Stop the daemon:

```bash
agb daemon stop
```

Remove only runtime artifacts if you need a clean local reset:

```bash
rm -rf ~/.agent-bridge/state ~/.agent-bridge/logs
mkdir -p ~/.agent-bridge/state ~/.agent-bridge/logs ~/.agent-bridge/shared
```

Do not delete `agent-roster.local.sh` unless you intentionally want to remove
local static roles.

## Platform Scope

Agent Bridge runs on both macOS and Linux, but the two hosts have
different support targets for multi-tenant isolation:

- **macOS** is a developer and single-operator target. Static agents
  run in `shared` mode (the default); per-UID isolation is not
  implemented. Hardening is limited to the hook layer (tool policy,
  prompt guard) and operator vigilance.
- **Linux** is the production target for multi-principal deployments.
  `BRIDGE_AGENT_ISOLATION_MODE=linux-user` enforces per-agent UID
  separation and is required when agents hold delegated credentials or
  handle untrusted external input. See issues
  [#68](https://github.com/SYRS-AI/agent-bridge-public/issues/68) and
  [#85](https://github.com/SYRS-AI/agent-bridge-public/issues/85).

On macOS the `linux-user` mode falls back to shared silently (see
`bridge_agent_linux_user_isolation_effective` in
[`lib/bridge-agents.sh`](./lib/bridge-agents.sh)), and the migration
helper `agent-bridge isolate <agent>` (#85) exits with an explanatory
error. Full matrix and rationale in
[docs/platform-support.md](./docs/platform-support.md).

For the step-by-step operator walkthrough for transitioning an existing
Linux fleet from shared mode to per-UID isolation one agent at a time,
see [docs/isolation-migration-guide.md](./docs/isolation-migration-guide.md).

## Release Checklist

Before pushing bridge changes:

```bash
bash -n *.sh agent-bridge agb lib/*.sh scripts/*.sh
shellcheck *.sh agent-bridge agb lib/*.sh scripts/*.sh agent-roster.local.example.sh
bash ./scripts/oss-preflight.sh
./scripts/smoke-test.sh
```

If a change affects queue semantics, roster loading, session resume, worktree
handling, cron behavior, or upgrade behavior, include manual verification notes.

## Resume Checklist For Another Agent

If you just opened this repository and need to continue work:

1. Read `README.md`
2. Read `ARCHITECTURE.md`
3. Read `KNOWN_ISSUES.md`
4. Run `./scripts/smoke-test.sh`
5. Check `git status`
6. Check `agb status` if working in a live environment
