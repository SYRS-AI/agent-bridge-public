# Architecture

This repository is a local orchestration layer for Claude Code and Codex sessions running inside `tmux`.

## Read This First

If you are resuming development, read in this order:

1. [`README.md`](./README.md)
2. [`ARCHITECTURE.md`](./ARCHITECTURE.md)
3. [`OPERATIONS.md`](./OPERATIONS.md)
4. [`KNOWN_ISSUES.md`](./KNOWN_ISSUES.md)
5. [`AGENTS.md`](./AGENTS.md)

## Core Model

There are two kinds of agents:

- Static roles: defined in `agent-roster.sh` or `agent-roster.local.sh`
- Dynamic agents: created with `agent-bridge --codex|--claude --name ...`

Static roles are optional. Fresh installs ship with an empty static roster.

Tracked long-lived agent profiles live under `agents/`. That tree is the portable source of truth for prompt text and future per-agent memory or skill directories; machine-local launch wiring still lives in the roster.

## Main Entry Points

- [`agent-bridge`](./agent-bridge): operator-facing CLI for status, task queue, urgent sends, worktree listing, and dynamic agent launch
- [`agb`](./agb): shorthand wrapper that delegates to `agent-bridge`
- [`bridge-start.sh`](./bridge-start.sh): start a static role inside `tmux`
- [`bridge-run.sh`](./bridge-run.sh): loop or one-shot launcher inside the tmux session
- [`bridge-task.sh`](./bridge-task.sh): shell wrapper around the SQLite queue
- [`bridge-profile.sh`](./bridge-profile.sh): tracked agent profile status, diff, and deploy
- [`bridge-cron.sh`](./bridge-cron.sh): OpenClaw cron inventory plus queue adapter wrapper
- [`bridge-send.sh`](./bridge-send.sh): urgent-only direct message path
- [`bridge-action.sh`](./bridge-action.sh): send predefined actions like `/resume`
- [`bridge-daemon.sh`](./bridge-daemon.sh): background sync and heartbeat loop
- [`bridge-sync.sh`](./bridge-sync.sh): reconcile active tmux sessions into live bridge state
- [`bridge-status.sh`](./bridge-status.sh): compact TUI-style dashboard
- [`bridge-lib.sh`](./bridge-lib.sh): thin loader that sources the shell modules under [`lib/`](./lib)
- [`bridge-queue.py`](./bridge-queue.py): persistent queue and daemon-side bookkeeping
- [`bridge-cron.py`](./bridge-cron.py): OpenClaw cron inventory parsing and job metadata export

## Shell Module Layout

Shared Bash implementation is split under [`lib/`](./lib):

- `bridge-core.sh`: generic helpers, hashing, queue wrapper, and path utilities
- `bridge-agents.sh`: roster accessors, active-agent queries, worktree preparation, and session kill helpers
- `bridge-tmux.sh`: tmux session I/O and submit helpers
- `bridge-skills.sh`: project-local skill generation and migration of older managed skill directories
- `bridge-state.sh`: roster loading, dynamic/static agent persistence, session-id detection, and daemon snapshots
- `bridge-cron.sh`: OpenClaw cron path helpers, family-aware default slots, target resolution, and enqueue manifests

## State Layout

Runtime state lives under `state/` and is intentionally untracked:

- `state/tasks.db`: SQLite queue plus agent heartbeat state
- `state/active-roster.tsv` and `state/active-roster.md`: current live roster snapshot
- `state/agents/`: dynamic agent metadata
- `state/history/`: persisted resume metadata for static and dynamic agents
- `state/worktrees/`: metadata for managed isolated workers
- `state/profiles/`: deploy manifests for tracked agent profiles
- `state/daemon.pid` and `state/daemon.log`: daemon process tracking

Human or agent handoff text belongs in `shared/`. Operator logs belong in `logs/`.

## Agent Lifecycle

### Dynamic

`agent-bridge --codex --name dev` or `agent-bridge --claude --name tester`:

1. Resolve workdir from the current directory unless `--workdir` is given
2. Optionally install a project-local bridge skill
3. Persist dynamic metadata under `state/agents/`
4. Start a tmux session
5. Detect and persist the native Claude or Codex session id when possible

### Static

`bridge-start.sh <agent>`:

1. Read the tracked roster and optional local override roster
2. Resolve tmux session name, workdir, launch command, loop mode, and actions
3. Persist state and start the tmux session

## Queue-First Collaboration

Normal inter-agent work should flow through the queue, not direct chat.

Queue operations:

- `create`
- `inbox`
- `show`
- `claim`
- `done`
- `handoff`
- `summary`

The queue backend stores:

- tasks
- task events
- agent_state snapshots used by the daemon

This makes the system durable across tmux restarts and daemon restarts.

## Heartbeats And Nudges

The daemon does not call an LLM on every loop. It polls local state only:

- tmux session presence
- tmux activity timestamps
- task assignments and leases
- last-seen timestamps for agents

When an idle active agent has queued work and its cooldown window has passed, the daemon sends a short nudge into the tmux session.

## Direct Messages

`bridge-send.sh` is restricted to urgent paths. This is intentional.

- Queue for normal work
- Urgent direct messages for interrupts only

Claude uses a literal typing path for submit reliability. Codex continues to use bracketed paste plus submit.

## Worktree Isolation

If multiple writers need to act on the same git repo, `agent-bridge --prefer new` creates a managed git worktree under:

`~/.agent-bridge/worktrees/<repo-slug>/<agent>`

Metadata for those worktrees is stored in `state/worktrees/`.

## Configuration Surface

Important environment variables:

- `BRIDGE_HOME`
- `BRIDGE_ROSTER_FILE`
- `BRIDGE_ROSTER_LOCAL_FILE`
- `BRIDGE_STATE_DIR`
- `BRIDGE_TASK_DB`
- `BRIDGE_DAEMON_INTERVAL`
- `BRIDGE_WORKTREE_ROOT`
- `BRIDGE_OPENCLAW_HOME`
- `BRIDGE_OPENCLAW_CRON_JOBS_FILE`
- `BRIDGE_CRON_STATE_DIR`

Use them for isolated testing and for machine-specific installs.

## Development Notes

- The tracked roster should stay generic
- Private machine paths belong in `agent-roster.local.sh`
- Runtime directories are not source files
- Cross-platform behavior assumes Bash 4+, tmux, Python 3, and git
