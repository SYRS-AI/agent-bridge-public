# Agent Bridge

Agent Bridge is a `tmux`-based coordination layer for running Claude Code and Codex side by side. It provides a shared roster, queue-first task handoff, live status views, urgent interrupts, and optional git worktree isolation for parallel workers.

This repository is designed for trusted local projects. It assumes you are intentionally granting Claude Code or Codex access to the directory where you launch them.

If you hand this repository URL to another Claude or Codex agent, the expected bootstrap is simple: read `README.md`, complete the steps in **Install**, then use **Quick Start** from the target working directory.

## Highlights

- Start ad hoc Claude or Codex agents from the current directory with `ab`
- Keep long-lived named roles in a static roster
- Route normal collaboration through a durable SQLite task queue
- Reserve direct messages for urgent interrupts only
- Watch queue load, active sessions, and open work in a single dashboard
- Spawn isolated git worktree workers when one checkout is not enough

## Requirements

- Bash 4+
- `tmux`
- `python3`
- `git`
- At least one agent CLI:
  - `claude`
  - `codex`

Optional but recommended:

- `shellcheck`
- GitHub CLI `gh` for cloning private repos

## Install

### macOS

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

If you have GitHub CLI access:

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

### Start the daemon

```bash
bash bridge-daemon.sh ensure
```

The daemon keeps the live roster, queue heartbeats, and idle nudges in sync.

## Quick Start

### Run an agent against the bridge repo itself

If you want an agent to work on `agent-bridge`:

```bash
cd ~/agent-bridge
./ab --codex --name dev
```

Or:

```bash
cd ~/agent-bridge
./ab --claude --name tester
```

### Run an agent against another project

From the target repo:

```bash
cd ~/some-project
~/agent-bridge/ab --codex --name dev
```

The current directory becomes the agent's workdir. `ab` will also install a small project-local bridge skill:

- Codex: `.agents/skills/agent-bridge-project/SKILL.md`
- Claude: `.claude/skills/agent-bridge-project/SKILL.md`

### Queue-first workflow

Start an agent:

```bash
./ab --claude --name tester
```

Create work:

```bash
./ab task create --to tester --title "check this" --body-file ~/agent-bridge/shared/note.md
```

Inspect or complete work:

```bash
./ab inbox tester
./ab claim 1 --agent tester
./ab done 1 --agent tester --note "done"
```

Send a direct interrupt only when waiting for the queue is not acceptable:

```bash
./ab urgent tester "Check your inbox now."
```

## Core Concepts

### Static roles

Static roles live in [`agent-roster.sh`](./agent-roster.sh). Use them for long-lived names such as `developer`, `tester`, `codex-developer`, or `codex-tester`.

### Dynamic agents

Dynamic agents are created with `ab --codex|--claude --name ...` from the current directory. They are good for one-off workers and local experiments.

### Queue first, urgent second

Normal collaboration should go through the queue:

- `ab task create`
- `ab inbox`
- `ab claim`
- `ab done`
- `ab handoff`

Use `ab urgent` only when another agent must be interrupted immediately.

### Worktree workers

If one repository needs multiple active writers, prefer:

```bash
./ab --codex --name reviewer-a --prefer new
```

That creates an isolated git worktree under `~/.agent-bridge/worktrees/` instead of reusing the shared checkout.

## Common Commands

```bash
./ab status
./ab status --watch
./ab list
./ab kill 1
./ab kill all
./ab worktree list
bash bridge-start.sh --list
bash bridge-daemon.sh status
```

## Repository Layout

- `ab`: primary operator entry point
- `bridge-start.sh`, `bridge-run.sh`: session startup paths
- `bridge-task.sh`, `bridge-queue.py`: queue API and SQLite backend
- `bridge-send.sh`, `bridge-action.sh`: urgent interrupts and predefined actions
- `bridge-status.sh`, `bridge-daemon.sh`, `bridge-sync.sh`: status, background sync, and heartbeats
- `bridge-lib.sh`: shared shell helpers
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

### The daemon is not running

```bash
bash ~/agent-bridge/bridge-daemon.sh ensure
bash ~/agent-bridge/bridge-daemon.sh status
```

### You want to inspect everything at once

```bash
~/agent-bridge/ab status
~/agent-bridge/ab list
~/agent-bridge/ab summary
```

## Verification

For bridge changes, the minimum local check is:

```bash
bash -n *.sh ab
shellcheck *.sh ab
```

## Access and License

This repository is currently operated as a private codebase. If you plan to distribute it publicly, add an explicit `LICENSE` file first.
