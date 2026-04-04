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
~/agent-bridge/ab status
~/agent-bridge/ab list
```

## Recommended Collaboration Pattern

1. Start agents
2. Create tasks through the queue
3. Let each agent claim work
4. Use urgent sends only for real interrupts

Typical operator flow:

```bash
~/agent-bridge/ab --codex --name dev
~/agent-bridge/ab --claude --name tester
~/agent-bridge/ab task create --to tester --title "retest" --body-file ~/agent-bridge/shared/report.md
~/agent-bridge/ab inbox tester
~/agent-bridge/ab claim 1 --agent tester
~/agent-bridge/ab done 1 --agent tester --note "verified"
```

## Static Roles

Fresh installs have no static roles. If you want them:

```bash
cp ~/agent-bridge/agent-roster.local.example.sh ~/agent-bridge/agent-roster.local.sh
```

Put machine-specific workdirs and launch commands in `agent-roster.local.sh`, not in tracked source.

## Worktree Workers

When the shared checkout already has a role or active worker, prefer isolation:

```bash
~/agent-bridge/ab --codex --name reviewer-a --prefer new
~/agent-bridge/ab worktree list
```

Use worktrees when two agents may edit the same repository concurrently.

## Status And Debugging

Use these first:

```bash
~/agent-bridge/ab status
~/agent-bridge/ab status --watch
~/agent-bridge/ab summary
~/agent-bridge/ab list
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
~/agent-bridge/ab kill all
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
bash -n *.sh ab
shellcheck *.sh ab
./scripts/smoke-test.sh
```

If a change touches queue semantics, include at least one real create/claim/done flow in your manual notes.

## Resume Checklist For Another Agent

If you just opened this repository and need to continue work:

1. Read `README.md`
2. Read `ARCHITECTURE.md`
3. Read `KNOWN_ISSUES.md`
4. Run `./scripts/smoke-test.sh`
5. Check `git status`
6. Check `~/agent-bridge/ab status` if working in a live environment
