# Workspace Migration Plan

## Goal

Move long-lived agent homes from scattered legacy OpenClaw paths into a single
Agent Bridge-owned root:

```text
~/.agent-bridge/agents/<agent>/
```

The public product should work on a fresh Mac or Linux install without any hard
dependency on `~/.openclaw`, while still supporting optional migration from
existing OpenClaw state.

## Current State

### Typical legacy homes

Common legacy layouts include:

- `~/.openclaw/workspace`
- `~/.openclaw/workspace-<agent>`
- `~/.openclaw/<agent>`

### Runtime material inside legacy workspaces

Legacy workspaces are not just prompt files. They often contain runtime state
and agent-local data such as:

- `CLAUDE.md`, `SOUL.md`, `AGENTS.md`, `TOOLS.md`, `USER.md`
- `MEMORY.md`
- `memory/`
- `compound/`
- `.discord/`
- `.openclaw/workspace-state.json`
- `scripts/`
- `tmp/`, `output/`, previews, HTML scratch files
- role-specific files like `STATUS.md`, `WORKFLOW.md`, `HEARTBEAT.md`

Some legacy homes also carry extra local tool state such as `.claude/`,
`.context/`, `.plugins/`, or browser/MCP caches.

### Existing coupling in the bridge repo

The repo is already portable in some places, but several surfaces still assume
OpenClaw-era paths:

- `bridge-lib.sh`
- `tools/memory-manager.py`
- migration docs
- machine-local roster files

## Target Model

### 1. Agent Bridge owns the live agent-home root

```text
BRIDGE_HOME=~/.agent-bridge
BRIDGE_AGENT_HOME_ROOT=$BRIDGE_HOME/agents
```

Each migrated long-lived agent lives at:

```text
~/.agent-bridge/agents/<agent>/
```

Example:

- `~/.agent-bridge/agents/researcher`

### 2. Tracked source and live home remain separate

Two trees continue to exist:

- tracked repo source
- live machine home

`agent-bridge profile deploy` remains the promotion boundary. Repo edits do not
instantly mutate live homes.

### 3. Live home is the runtime workspace

For migrated agents, the live home and workdir should converge when practical:

- `BRIDGE_AGENT_WORKDIR["agent"]="$HOME/.agent-bridge/agents/agent"`
- `BRIDGE_AGENT_PROFILE_HOME["agent"]="$HOME/.agent-bridge/agents/agent"`

This keeps the product story simple for fresh installs:

- one root
- one per-agent directory
- no hidden dependency on another tool's home layout

### 4. OpenClaw remains an optional legacy integration

`BRIDGE_OPENCLAW_HOME` stays only for bridge features that intentionally
integrate with legacy OpenClaw data:

- cron inventory / adapters
- OpenClaw memory SQLite indexes
- remaining gateway compatibility tooling

It should no longer be the default source of agent workdirs.

## Non-Goals For The First Migration Wave

These items should not move automatically in the first wave:

- live credentials
- runtime memory state
- session archives
- cached browser/MCP state
- target-only local override files

## Migration Sequence

1. Path abstraction first.
2. Read-only inventory and dry-run helpers.
3. Low-risk leaf roles.
4. Communication-heavy roles.
5. Orchestration-heavy roles.
6. Operator or debugger roles last.

Why this order:

- orchestration-heavy roles have the highest coupling
- debugger/operator roles should move only after the migration process is boring

## Recommendations

1. Keep OpenClaw migration tooling in the public repo, but mark it clearly as
   optional legacy integration.
2. Keep fresh-install docs centered on `~/.agent-bridge/agents`.
3. Trial migration helpers on a low-risk leaf role before touching
   orchestration-heavy or operator-critical roles.
