# Workspace Migration Plan

## Goal

Move long-lived agent homes from scattered `~/.openclaw/*` paths into a single Agent Bridge-owned root:

```text
~/.agent-bridge/agents/<agent>/
```

This is not just a path rename. The bridge is being split into two roles:

- **Dev track**: make Agent Bridge portable so a fresh install on a new Mac mini or Linux machine works without any hard dependency on `~/.openclaw`.
- **Patch track**: keep SYRS-specific install state, credentials, bots, and validation on top of that generic product.

## Current State

### Live homes today

Observed on this machine:

- 22 legacy agent home/workspace directories under `~/.openclaw/`
- 22 live `CLAUDE.md` profile directories already present under `~/.agent-bridge/agents/`

Representative legacy paths:

- `~/.openclaw/patch`
- `~/.openclaw/workspace`
- `~/.openclaw/workspace-huchu`
- `~/.openclaw/workspace-syrs-shopify`
- `~/.openclaw/workspace-syrs-satomi`

### Runtime material inside the current workspaces

The legacy workspaces are not just prompt files. They contain durable runtime state and agent-local data such as:

- `CLAUDE.md`, `SOUL.md`, `AGENTS.md`, `TOOLS.md`, `USER.md`
- `MEMORY.md`
- `memory/`
- `compound/`
- `.discord/`
- `.openclaw/workspace-state.json`
- `scripts/`
- `tmp/`, `output/`, previews, HTML scratch files
- agent-specific files like `STATUS.md`, `WORKFLOW.md`, `HEARTBEAT.md`

`patch` also carries extra local tool state such as `.claude/`, `.context/`, `.plugins/`, and `.playwright-mcp/`.

### Existing coupling in the bridge repo

The repo is already portable in some places, but several surfaces still assume OpenClaw-era paths:

- `bridge-lib.sh`
  - defaults `BRIDGE_OPENCLAW_HOME="$HOME/.openclaw"`
- `tools/memory-manager.py`
  - defaults config and workspace resolution from `~/.openclaw`
- docs and cutover notes
  - several files still reference `~/.openclaw/workspace*` as the canonical live home
- live local roster
  - `BRIDGE_AGENT_WORKDIR[...]` and `BRIDGE_AGENT_PROFILE_HOME[...]` still point at legacy `~/.openclaw/*`

## Target Model

### 1. Agent Bridge owns the live agent-home root

Bridge runtime root:

```text
BRIDGE_HOME=~/.agent-bridge
BRIDGE_AGENT_HOME_ROOT=$BRIDGE_HOME/agents
```

Each migrated long-lived agent lives at:

```text
~/.agent-bridge/agents/<agent>/
```

Examples:

- `~/.agent-bridge/agents/main`
- `~/.agent-bridge/agents/huchu`
- `~/.agent-bridge/agents/syrs-satomi`

### 2. Tracked source and live home remain separate

Two trees continue to exist:

- tracked repo source: `~/agent-bridge/agents/<agent>/`
- live machine home: `~/.agent-bridge/agents/<agent>/`

`agent-bridge profile deploy` remains the promotion boundary. Repo edits do not instantly mutate live homes.

### 3. Live home is the runtime workspace

For migrated agents, the live home and workdir should converge:

- `BRIDGE_AGENT_WORKDIR["agent"]="$HOME/.agent-bridge/agents/agent"`
- `BRIDGE_AGENT_PROFILE_HOME["agent"]="$HOME/.agent-bridge/agents/agent"`

This keeps the product story simple for fresh installs:

- one root
- one per-agent directory
- no hidden dependency on another tool's home layout

### 4. OpenClaw remains an optional legacy integration

`BRIDGE_OPENCLAW_HOME` stays only for bridge features that intentionally integrate with legacy OpenClaw data:

- cron inventory / adapters
- OpenClaw memory SQLite indexes
- any remaining gateway compatibility tooling

It should no longer be the default source of agent workdirs.

## Non-Goals For This Migration

These items should **not** move in the first workspace migration wave:

- `~/.openclaw/memory/*.sqlite`
- `~/.openclaw/openclaw.json`
- `~/.openclaw/cron/jobs.json`
- `~/.openclaw/agents/<id>/` gateway session archives

Reason:

- they are legacy gateway-owned state
- several bridge adapters still read them explicitly
- moving them is a separate compatibility problem from moving agent workspaces

## Required Product Changes

### A. Path abstraction in the bridge core

Add a generic concept of the default agent home root instead of assuming OpenClaw workspaces.

Recommended defaults:

```bash
BRIDGE_AGENT_HOME_ROOT="${BRIDGE_AGENT_HOME_ROOT:-$BRIDGE_HOME/agents}"
```

Add helper behavior along these lines:

- `bridge_agent_default_home <agent>`
- `bridge_agent_default_discord_state_dir <agent>`
- `bridge_agent_default_profile_home <agent>` if roster omits an explicit profile target

Outcome:

- fresh installs can use `~/.agent-bridge/agents/<agent>` immediately
- local rosters no longer need to spell out every path if they follow the standard layout

### B. Memory manager workspace resolution

`tools/memory-manager.py` currently derives workspace paths from `~/.openclaw`.

Change the resolution order to:

1. explicit `--workspace-dir`
2. agent entry `workspace` from config if present
3. bridge-standard home: `~/.agent-bridge/agents/<agent>`
4. legacy fallback: `~/.openclaw/workspace-<agent>`, plus current `main` / `patch` special cases

This keeps search working during migration while removing the legacy path as the primary assumption.

### C. Documentation reset

Update the generic product docs to describe:

- static roles living under `~/.agent-bridge/agents/<agent>`
- `BRIDGE_OPENCLAW_HOME` as optional legacy integration
- `BRIDGE_AGENT_PROFILE_HOME` as an override, not the normal case

The existing `~/.openclaw/...` examples should move into explicit legacy-migration notes.

### D. Migration helper

Add a purpose-built helper rather than relying on manual `cp` commands.

Suggested interface:

```bash
agent-bridge migrate workspace plan <agent>
agent-bridge migrate workspace copy <agent> [--dry-run]
agent-bridge migrate workspace cutover <agent> [--dry-run]
```

Minimum helper responsibilities:

- resolve legacy source and new destination
- print copy plan before mutation
- create timestamped backup marker
- copy with metadata preservation
- never delete the source automatically
- show the roster changes still required

This can start as a script if the CLI surface is too much for v1.

## Migration Rules

### Preserve

- `MEMORY.md`
- `memory/`
- `compound/`
- `.discord/`
- `.openclaw/workspace-state.json`
- agent-local scripts, prompts, output, scratch files
- `STATUS.md`, `WORKFLOW.md`, `HEARTBEAT.md`, and similar operational files

### Do not auto-copy into tracked repo

- `tmp/`
- `output/`
- preview images / HTML artifacts
- session-local caches unless explicitly required

These belong in the live home only, not in `~/agent-bridge/agents/<agent>/`.

### Rollback principle

Every cutover must be reversible by:

1. stopping the bridge-managed session
2. restoring the previous roster path entries
3. switching `BRIDGE_AGENT_WORKDIR` and `BRIDGE_AGENT_PROFILE_HOME` back to the legacy path
4. restarting the session from the legacy home

The source legacy workspace is not deleted during v1, so rollback is path-based, not data-recovery-based.

## Rollout Phases

### Phase 0: Inventory and freeze points

Before code changes:

- inventory all legacy homes under `~/.openclaw/`
- identify special cases like `main`, `huchu`, `patch`, and `shopify`
- classify which agents require Discord plugin state
- classify which agents have extra local runtime state beyond standard memory files

Status:

- inventory is already sufficient to start implementation

### Phase 1: Productize path handling

Scope:

- add `BRIDGE_AGENT_HOME_ROOT`
- add helper resolution for default live homes
- update generic docs and example roster
- make memory-manager prefer bridge-standard homes before legacy fallback

Success criteria:

- a fresh machine can define static roles without any `.openclaw/workspace-*` paths
- existing SYRS machine still works unchanged

### Phase 2: Add migration helper

Scope:

- dry-run planner
- copy helper
- cutover checklist output per agent

Success criteria:

- operators can migrate one agent with a repeatable command instead of ad hoc shell history

### Phase 3: Per-agent cutover waves

Recommended order:

1. leaf agents without orchestration duties
2. Discord on-demand specialists
3. `shopify`
4. `main`
5. `huchu`
6. `patch` last

Reason:

- `main`, `huchu`, and `patch` have the highest orchestration and operational coupling
- `patch` is the operator/debugging spine and should move last after the process is boring

### Phase 4: Default the team install to the new root

Once enough agents are cut over cleanly:

- change team-local roster defaults to `~/.agent-bridge/agents/<agent>`
- stop treating `.openclaw/workspace-*` as normal
- keep only explicit legacy references where OpenClaw integration is still required

## Dev vs Patch Responsibilities

### Dev track

Owned in this repo:

- generic path abstraction
- generic docs
- migration helper
- backwards-compatible code paths
- release and rollback behavior

### Patch track

Owned in team-local install/config:

- bot tokens and channel permissions
- local roster overrides
- validation on the real machine
- deciding per-agent cutover timing
- legacy OpenClaw cleanup after stability is proven

## Immediate Next Slices

1. Add `BRIDGE_AGENT_HOME_ROOT` and bridge helper functions for standard live homes.
2. Update `tools/memory-manager.py` to prefer bridge-standard homes before legacy fallback.
3. Reset generic docs and examples so fresh installs stop advertising `~/.openclaw` as the normal case.
4. Build a dry-run migration helper for one agent.
5. Trial the helper on a low-risk leaf agent before touching `main`, `huchu`, or `patch`.

## Open Questions

These do not block Phase 1, but they should be settled before bulk cutover:

- Should `patch` stay in a custom home longer because of its heavier local tool state?
- Do we want a standard place under `~/.agent-bridge/agents/<agent>/` for large scratch/output files, or is flat workspace sprawl acceptable in v1?
- When should OpenClaw memory SQLite indexes move, if ever?
- After enough cutovers, do we want a bridge-native replacement for the remaining OpenClaw session archives?
