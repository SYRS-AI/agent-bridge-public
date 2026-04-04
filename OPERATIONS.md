# Operations

This file is the operator runbook for Agent Bridge.

## Daily Startup

1. Ensure prerequisites exist: Bash 4+, `tmux`, `python3`, `git`, and at least one of `claude` or `codex`
2. Start or verify the daemon:

```bash
bash ~/agent-bridge/bridge-daemon.sh ensure
bash ~/agent-bridge/bridge-daemon.sh status
```

3. If you use static roles, verify them:

```bash
bash ~/agent-bridge/bridge-start.sh --list
```

4. Check overall status:

```bash
~/agent-bridge/agent-bridge status
~/agent-bridge/agent-bridge list
```

If your live runtime is `~/.agent-bridge` while development happens in `~/agent-bridge`, prefer the deploy helper over manual copying:

```bash
cd ~/agent-bridge
./scripts/deploy-live-install.sh --dry-run
./scripts/deploy-live-install.sh --restart-daemon
```

## Recommended Collaboration Pattern

1. Start agents
2. Create tasks through the queue
3. Let each agent claim work
4. Use urgent sends only for real interrupts

Typical operator flow:

```bash
~/agent-bridge/agent-bridge --codex --name dev
~/agent-bridge/agent-bridge --claude --name tester
~/agent-bridge/agent-bridge task create --to tester --title "retest" --body-file ~/agent-bridge/shared/report.md
~/agent-bridge/agent-bridge inbox tester
~/agent-bridge/agent-bridge claim 1 --agent tester
~/agent-bridge/agent-bridge done 1 --agent tester --note "verified"
```

## Static Roles

Fresh installs have no static roles. If you want them:

```bash
cp ~/agent-bridge/agent-roster.local.example.sh ~/agent-bridge/agent-roster.local.sh
```

Put machine-specific workdirs and launch commands in `agent-roster.local.sh`, not in tracked source.

If you are migrating named agents with existing prompts, keep the tracked prompt and per-agent profile skeleton under `agents/`, and keep only machine-local runtime paths in `agent-roster.local.sh`.

If the live CLI home differs from the bridge workdir, declare `BRIDGE_AGENT_PROFILE_HOME["agent"]="..."` in `agent-roster.local.sh` and use `agent-bridge profile status|diff|deploy` for explicit promotion into that live home.

## Worktree Workers

When the shared checkout already has a role or active worker, prefer isolation:

```bash
~/agent-bridge/agent-bridge --codex --name reviewer-a --prefer new
~/agent-bridge/agent-bridge worktree list
```

Use worktrees when two agents may edit the same repository concurrently.

## Status And Debugging

Use these first:

```bash
~/agent-bridge/agent-bridge status
~/agent-bridge/agent-bridge status --watch
~/agent-bridge/agent-bridge summary
~/agent-bridge/agent-bridge list
~/agent-bridge/agent-bridge cron inventory --limit 20
~/agent-bridge/agent-bridge cron inventory --mode one-shot --limit 20
~/agent-bridge/agent-bridge cron enqueue memory-daily-syrs-shopify --slot 2026-04-05 --dry-run
```

When planning cron migration work, inspect one job in detail before changing anything:

```bash
~/agent-bridge/agent-bridge cron show memory-daily-syrs-shopify
```

When you start bridging one recurring family into the queue, begin with a dry run:

```bash
~/agent-bridge/agent-bridge cron enqueue memory-daily-syrs-shopify --slot 2026-04-05 --dry-run
```

Inspect runtime state directly when needed:

```bash
cat ~/agent-bridge/state/active-roster.md
sqlite3 ~/agent-bridge/state/tasks.db '.tables'
tail -n 80 ~/agent-bridge/state/daemon.log
tail -n 80 ~/agent-bridge/logs/bridge-$(date +%Y%m%d).log
```

## Safe Cleanup

Kill active bridge sessions:

```bash
~/agent-bridge/agent-bridge kill all
```

Stop the daemon:

```bash
bash ~/agent-bridge/bridge-daemon.sh stop
```

Remove only runtime artifacts if you need a clean local reset:

```bash
rm -rf ~/agent-bridge/state ~/agent-bridge/logs
mkdir -p ~/agent-bridge/state ~/agent-bridge/logs ~/agent-bridge/shared
```

Do not delete `agent-roster.local.sh` unless you intentionally want to remove local static roles.

## Release Checklist

Before pushing bridge changes:

```bash
bash -n *.sh agent-bridge agb
shellcheck *.sh agent-bridge agb
./scripts/smoke-test.sh
```

If a change touches queue semantics, include at least one real create/claim/done flow in your manual notes.

If a change needs to be reflected in the live local install, use `./scripts/deploy-live-install.sh` so the full tracked tree is copied and verified together.

## Resume Checklist For Another Agent

If you just opened this repository and need to continue work:

1. Read `README.md`
2. Read `ARCHITECTURE.md`
3. Read `KNOWN_ISSUES.md`
4. Run `./scripts/smoke-test.sh`
5. Check `git status`
6. Check `~/agent-bridge/agent-bridge status` if working in a live environment
