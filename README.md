# Agent Bridge

[![CI](https://github.com/SYRS-AI/agent-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/SYRS-AI/agent-bridge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](./LICENSE)

Agent Bridge is a `tmux`-based coordination layer for running Claude Code and Codex side by side. It provides a shared roster, queue-first task handoff, live status views, urgent interrupts, and optional git worktree isolation for parallel workers.

The primary CLI is `agent-bridge`. A bundled shorthand wrapper, `agb`, calls the same entry point.

This repository is designed for trusted local projects. It assumes you are intentionally granting Claude Code or Codex access to the directory where you launch them.

If you hand this repository URL to another Claude or Codex agent, the expected bootstrap is simple: read `README.md`, complete the steps in **Install**, then use **Quick Start** from the target working directory.

Companion docs for maintainers:

- [`ARCHITECTURE.md`](./ARCHITECTURE.md)
- [`OPERATIONS.md`](./OPERATIONS.md)
- [`KNOWN_ISSUES.md`](./KNOWN_ISSUES.md)
- [`agents/README.md`](./agents/README.md)
- [`agents/SYNC-MODEL.md`](./agents/SYNC-MODEL.md)
- [`agents/WORKSPACE-MIGRATION-PLAN.md`](./agents/WORKSPACE-MIGRATION-PLAN.md)

## Highlights

- Start ad hoc Claude or Codex agents from the current directory with `agent-bridge`
- Keep long-lived named roles in a static roster
- Route normal collaboration through a durable SQLite task queue
- Reserve direct messages for urgent interrupts only
- Watch queue load, active sessions, stale health, and open work in a single dashboard
- Spawn isolated git worktree workers when one checkout is not enough

## Requirements

- Bash 4+ available in `PATH` for running the bridge scripts
- `tmux`
- `python3`
- `git`
- At least one agent CLI:
  - `claude`
  - `codex`

Optional but recommended:

- `shellcheck`
- GitHub CLI `gh`

## Install

### macOS

Your interactive shell can stay `zsh`. The bridge scripts themselves run with `bash`, so the only requirement is that a modern Bash is available in `PATH`.

Install the base tools:

```bash
brew install bash tmux python shellcheck
```

Make sure Homebrew Bash is first in `PATH`:

```bash
echo 'export PATH="$(brew --prefix)/bin:$PATH"' >> ~/.zshrc
exec zsh
bash --version
```

If `bash --version` shows the macOS system Bash `3.2`, the bridge will not work correctly.

### Linux

Install the same toolchain with your package manager. Example for Ubuntu:

```bash
sudo apt update
sudo apt install -y bash tmux python3 python3-venv shellcheck git
```

### Clone

If you have GitHub CLI:

```bash
gh repo clone SYRS-AI/agent-bridge ~/agent-bridge
cd ~/agent-bridge
```

Or use Git directly:

```bash
git clone https://github.com/SYRS-AI/agent-bridge.git ~/agent-bridge
cd ~/agent-bridge
```

### Agent CLIs

Install and authenticate the CLIs you want to use:

- `claude`
- `codex`

The bridge does not install those tools for you.

### Optional legacy OpenClaw migration

Some bridge features are kept for teams migrating from an existing OpenClaw
install:

- cron inventory / enqueue / cleanup helpers
- `tools/memory-manager.py`
- legacy workspace migration docs under [`agents/`](./agents/README.md)

Clean installs can ignore those features entirely.

### Optional static roster

Fresh installs ship with no static roles. You can use dynamic agents with `agent-bridge` immediately and ignore the roster entirely.

If you want long-lived named roles like `developer` or `tester`, create a local roster file:

```bash
cp ~/agent-bridge/agent-roster.local.example.sh ~/agent-bridge/agent-roster.local.sh
```

`agent-roster.local.sh` is git-ignored and is sourced after the default roster, so you can add your own workdirs, descriptions, launch commands, and actions without changing the tracked repo.

By default, static roles can live under the standard bridge-owned home root:

```bash
BRIDGE_AGENT_HOME_ROOT="$HOME/.agent-bridge/agents"
```

If `BRIDGE_AGENT_WORKDIR["agent"]` is omitted, the bridge now defaults that role to `$BRIDGE_AGENT_HOME_ROOT/<agent>`. For tracked profiles, `profile deploy` also defaults to that same target.

Only declare `BRIDGE_AGENT_PROFILE_HOME` when the live CLI home differs from the workdir:

```bash
BRIDGE_AGENT_WORKDIR["analyst"]="$HOME/project-analyst"
BRIDGE_AGENT_PROFILE_HOME["analyst"]="$HOME/.agent-bridge/agents/analyst"
```

If one static role should act as the bridge admin, set it explicitly:

```bash
BRIDGE_ADMIN_AGENT_ID="developer"
```

After that, `agent-bridge admin` and `agb admin` always open that role using
its configured engine and home, regardless of the current working directory.

For Claude static roles, keep `BRIDGE_AGENT_LAUNCH_CMD` free of `-c`,
`--continue`, or `--resume`. The bridge manages continue/resume itself so
subcommands like `agent-bridge admin --no-continue` can work predictably.

### Optional zsh shell integration

If you use `zsh` and do not want to type `./agent-bridge`, install the shell integration:

```bash
cd ~/agent-bridge
./scripts/install-shell-integration.sh --shell zsh --apply
exec zsh
```

After that you can run:

```bash
agent-bridge status
agb status
bridge-start --list
bridge-daemon status
```

The integration adds the repo to `PATH`, registers completion for `agent-bridge` and `agb`, and installs convenience aliases for the `bridge-*.sh` commands.

### Deploy into a live local install

If you develop in `~/agent-bridge` but run the bridge from `~/.agent-bridge`, use the deploy helper instead of copying files by hand:

```bash
cd ~/agent-bridge
./scripts/deploy-live-install.sh --dry-run
./scripts/deploy-live-install.sh --restart-daemon
```

The deploy helper copies every tracked file from the working tree, verifies the copied bytes, and preserves target-only runtime files such as `agent-roster.local.sh`, `state/`, `logs/`, and `shared/`.

### Claude idle wake

Claude roles now wake through the local tmux session only when the bridge has
explicitly marked them idle via the installed hooks:

- `Stop` hook writes `idle-since`
- `UserPromptSubmit` clears `idle-since`
- the daemon sends only a short line such as `agb inbox <agent>` when `idle-since` exists

This keeps the durable payload in the queue and avoids mid-turn delivery.

### Optional external channel notifications

`bridge-notify.py` still supports explicit Discord webhooks or Telegram posts,
but that is not the core A2A delivery path for Claude roles.

Use these only when you intentionally want an out-of-band notification:

```bash
BRIDGE_AGENT_NOTIFY_KIND["tester"]="discord-webhook"
BRIDGE_AGENT_NOTIFY_TARGET["tester"]="<discord-webhook-url>"
BRIDGE_AGENT_NOTIFY_ACCOUNT["tester"]="default"
```

### Backlog: custom Claude channels

The repo still includes the dormant channel-webhook helpers:

- `bridge-channel-server.py`
- `bridge-channels.py`
- `lib/bridge-channels.sh`

They are currently disabled in the runtime path because
`--dangerously-load-development-channels` is not suitable for unattended setup
or OSS onboarding. If Claude later supports safe custom channels without that
prompt, the bridge can switch back to channel-based wake.

### Onboard a Discord-backed agent

If an agent should read and reply in Discord, set its primary channel metadata
in `agent-roster.local.sh` first:

```bash
BRIDGE_AGENT_DISCORD_CHANNEL_ID["tester"]="123456789012345678"
```

Then run the guided setup:

```bash
./agent-bridge setup discord tester
./agent-bridge setup agent tester
./agent-bridge setup admin tester
```

`setup discord` writes the runtime Discord files into the agent workdir:

- `<workdir>/.discord/.env`
- `<workdir>/.discord/access.json`

The wizard can:

- reuse the existing `.discord` token
- import a bot token from `~/.openclaw/openclaw.json` during migration
- scaffold the allowlist for one or more channel IDs
- validate the bot token
- send a small write-access test message unless you pass `--skip-send-test`

For broader preflight, `setup agent` also checks:

- roster presence and workdir/session wiring
- Claude `Stop` + `UserPromptSubmit` hook installation into `<workdir>/.claude/settings.json`
- Claude webhook channel entry in `<workdir>/.mcp.json` when a webhook port is enabled
- `CLAUDE.md` presence for Claude roles
- tracked profile status
- `bridge-start.sh --dry-run`

Use `--test-start` only when you want a real tmux launch smoke test:

```bash
./agent-bridge setup agent tester --test-start
```

### Optional: inspect OpenClaw cron inventory

If you are migrating existing OpenClaw cron jobs into Agent Bridge, start with the read-only inventory:

```bash
./agent-bridge cron inventory
./agent-bridge cron inventory --family memory-daily --limit 10
./agent-bridge cron inventory --mode one-shot --limit 20
./agent-bridge cron show <job-id>
./agent-bridge cron enqueue <memory-daily-job-id> --slot 2026-04-05 --dry-run
./agent-bridge cron enqueue <monthly-highlights-job-id> --dry-run
./agent-bridge cron sync --dry-run
./agent-bridge cron errors report --limit 20
./agent-bridge cron cleanup report
./agent-bridge cron cleanup prune --dry-run
```

By default the inventory reads `~/.openclaw/cron/jobs.json`. Override it with `BRIDGE_OPENCLAW_CRON_JOBS_FILE=/path/to/jobs.json` when testing snapshots.

`cron enqueue` now works for recurring OpenClaw jobs in general. It writes a materialized note under `shared/cron/`, records per-slot manifests under `state/cron/dispatch/`, and creates compact `[cron-dispatch]` queue tasks for the bridge daemon. The daemon claims those tasks, runs `agent-bridge cron run-subagent <run-id>` in a disposable child, then closes the dispatch task when the result artifact is ready.

For `memory-daily` the default slot is `YYYY-MM-DD`. For `monthly-highlights` it is `YYYY-MM`. Other recurring jobs default to the current minute as an ISO timestamp, so repeated enqueue calls on the same day do not collapse into one slot.

`cron sync` is the bridge-owned recurring scheduler. It scans legacy recurring jobs, derives due occurrence slots, and enqueues each occurrence through the same disposable-child path. When `BRIDGE_OPENCLAW_CRON_SYNC_ENABLED=1`, the daemon also drains queued `[cron-dispatch]` tasks itself, so recurring jobs do not wake long-lived agent sessions unless a run explicitly needs a separate `[cron-followup]` task.

If your daemon environment does not inherit the same `PATH` as your interactive shell, set `BRIDGE_CLAUDE_BIN` or `BRIDGE_CODEX_BIN` explicitly in `agent-roster.local.sh`. The cron runner also searches common install locations such as `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`.

`cron errors report` is the report-only view for recurring cron failures. It shows `lastErrorAt`, consecutive error counts, family and prefix summaries, and the highest-error outliers first so model-switch fallout is easy to separate from older failures.

`cron cleanup report` and `cron cleanup prune --dry-run` are the safe way to inspect stale one-shot jobs before deleting them. The current prune target is intentionally narrow: expired `schedule.kind=at` jobs with `deleteAfterRun=true` and `enabled=false`.

### Bridge-native cron jobs

For recurring work discovered inside Agent Bridge itself, use the bridge-native cron store instead of relying on OpenClaw:

```bash
./agent-bridge cron list --agent main
./agent-bridge cron create --agent main --schedule "0 9 * * *" --title "Daily check" --payload "Review the daily queue and summarize anything that needs follow-up."
./agent-bridge cron update <job-id> --schedule "0 10 * * *"
./agent-bridge cron delete <job-id>
```

Bridge-native jobs live at `~/.agent-bridge/cron/jobs.json`. `cron sync` now aggregates both legacy OpenClaw recurring jobs and bridge-native recurring jobs into the same disposable-child dispatch path.

The status dashboard also includes a lightweight health check for active sessions. It classifies them as `ok`, `warn`, or `crit` from recorded session activity age. Inactive on-demand roles are not treated as stale. Defaults are `BRIDGE_HEALTH_WARN_SECONDS=3600` and `BRIDGE_HEALTH_CRITICAL_SECONDS=14400`, and you can override them in `agent-roster.local.sh`.

### Optional: search legacy OpenClaw memory

If you are migrating a legacy OpenClaw install and want read-only retrieval over
existing memory SQLite files, use the bundled helper:

```bash
python3 tools/memory-manager.py search --agent <agent-id> "recent incident summary"
```

This helper is optional. It is intended for migration and compatibility work,
not for fresh installs that do not have OpenClaw memory state.

### Start the daemon

```bash
bash bridge-daemon.sh ensure
```

The daemon keeps the live roster, queue heartbeats, and idle nudges in sync.

On macOS you can also register it as a `LaunchAgent` so crashes auto-restart:

```bash
./scripts/install-daemon-launchagent.sh --apply --load
launchctl print gui/$UID/ai.agent-bridge.daemon
```

## Quick Start

### Run an agent against the bridge repo itself

If you want an agent to work on `agent-bridge`:

```bash
cd ~/agent-bridge
./agent-bridge --codex --name dev
```

Or:

```bash
cd ~/agent-bridge
./agent-bridge --claude --name tester
```

### Run an agent against another project

From the target repo:

```bash
cd ~/some-project
~/agent-bridge/agent-bridge --codex --name dev
```

The current directory becomes the agent's workdir. `agent-bridge` will also install a small project-local bridge skill:

- Codex: `.agents/skills/agent-bridge-project/SKILL.md`
- Claude: `.claude/skills/agent-bridge-project/SKILL.md`
- Claude shared cron skill: `.claude/skills/cron-manager/SKILL.md`

### Queue-first workflow

Start an agent:

```bash
./agent-bridge --claude --name tester
```

Create work:

```bash
./agent-bridge task create --to tester --title "check this" --body-file ~/agent-bridge/shared/note.md
```

Inspect or complete work:

```bash
./agent-bridge inbox tester
./agent-bridge claim 1 --agent tester
./agent-bridge done 1 --agent tester --note "done"
```

Send a direct interrupt only when waiting for the queue is not acceptable:

```bash
./agent-bridge urgent tester "Check your inbox now."
```

## Core Concepts

### Static roles

Static roles are optional. If you want long-lived names such as `developer`, `tester`, `codex-developer`, or `codex-tester`, define them in `agent-roster.local.sh`. Otherwise, just use dynamic agents with `agent-bridge`.

### Tracked agent profiles

If you are migrating existing long-lived agents, use [`agents/_template/`](./agents/_template/CLAUDE.md)
as the public scaffold and keep real production profiles in a private companion
repo or a local untracked tree.

- the public repo intentionally ships only the `_template/` profile scaffold
- `agent-bridge profile status|diff|deploy` still manages explicit copy-based promotion into the live home
- optional migration planning docs live under [`agents/`](./agents/README.md)

### Dynamic agents

Dynamic agents are created with `agent-bridge --codex|--claude --name ...` from the current directory. They are good for one-off workers and local experiments.

### Queue first, urgent second

Normal collaboration should go through the queue:

- `agent-bridge task create`
- `agent-bridge inbox`
- `agent-bridge claim`
- `agent-bridge done`
- `agent-bridge handoff`

Use `agent-bridge urgent` only when another agent must be interrupted immediately.

### Worktree workers

If one repository needs multiple active writers, prefer:

```bash
./agent-bridge --codex --name reviewer-a --prefer new
```

That creates an isolated git worktree under `~/.agent-bridge/worktrees/` instead of reusing the shared checkout.

## Common Commands

```bash
./agent-bridge status
./agb status
./agent-bridge status --watch
./agent-bridge list
./agent-bridge profile status --all
./agent-bridge profile diff <agent>
./agent-bridge profile deploy <agent> --dry-run
./agent-bridge setup discord tester
./agent-bridge setup agent tester
./agent-bridge cron inventory --mode one-shot --limit 20
./agent-bridge cron list --agent main
./agent-bridge cron create --agent main --schedule "0 9 * * *" --title "Daily check"
./agent-bridge cron enqueue <memory-daily-job-id> --slot 2026-04-05 --dry-run
./agent-bridge cron enqueue <monthly-highlights-job-id> --dry-run
./agent-bridge cron errors report --limit 20
./agent-bridge cron cleanup report
./agent-bridge kill 1
./agent-bridge kill all
./agent-bridge worktree list
bash bridge-start.sh --list
bash bridge-daemon.sh status
bash ./scripts/oss-preflight.sh
```

## Repository Layout

- `agent-bridge`: primary operator entry point
- `agb`: shorthand wrapper for `agent-bridge`
- `bridge-start.sh`, `bridge-run.sh`: session startup paths
- `bridge-task.sh`, `bridge-queue.py`: queue API and SQLite backend
- `bridge-setup.sh`, `bridge-setup.py`: Discord onboarding and agent preflight checks
- `bridge-cron.sh`, `bridge-cron.py`, `bridge-cron-scheduler.py`: bridge-native cron CRUD plus legacy OpenClaw cron inventory, scheduling, queue adapters, and cleanup helpers
- `bridge-send.sh`, `bridge-action.sh`: urgent interrupts and predefined actions
- `bridge-status.sh`, `bridge-daemon.sh`, `bridge-sync.sh`: status, background sync, and heartbeats
- `bridge-lib.sh`: thin loader for shared shell modules
- `lib/`: modular shell implementation split by concern (`core`, `agents`, `tmux`, `skills`, `state`)
- `agent-roster.sh`: static role definitions
- `shared/`, `logs/`, `state/`: runtime artifacts and handoff files

## Troubleshooting

### macOS uses Bash 3.2

Fix `PATH` so Homebrew Bash comes first:

```bash
echo 'export PATH="$(brew --prefix)/bin:$PATH"' >> ~/.zshrc
exec zsh
```

### Claude shows a trust prompt on first run

That is expected in a new folder. Confirm the prompt once, then future resumes will work normally.

### Discord replies fail with "channel is not allowlisted"

Run:

```bash
./agent-bridge setup discord <agent>
```

Make sure the intended channel ID is present in `<workdir>/.discord/access.json`
under `groups`, then restart the agent session if it was already running.

### The daemon is not running

```bash
bash ~/agent-bridge/bridge-daemon.sh ensure
bash ~/agent-bridge/bridge-daemon.sh status
```

If it keeps dying, inspect:

```bash
tail -n 80 ~/.agent-bridge/state/daemon.log
tail -n 80 ~/.agent-bridge/state/daemon-crash.log
tail -n 80 ~/.agent-bridge/state/launchagent.log
```

### You want to inspect everything at once

```bash
~/agent-bridge/agent-bridge status
~/agent-bridge/agent-bridge list
~/agent-bridge/agent-bridge summary
```

## Verification

For bridge changes, the minimum local check is:

```bash
bash -n *.sh agent-bridge agb
shellcheck *.sh agent-bridge agb
./scripts/smoke-test.sh
```

## Project Metadata

- License: [`MIT`](./LICENSE)
- Contributing guide: [`CONTRIBUTING.md`](./CONTRIBUTING.md)
- Code of conduct: [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md)
- Security policy: [`SECURITY.md`](./SECURITY.md)
