# Agent Profile Sync Model

## Goal

Define how tracked agent profiles are promoted into each machine's live agent
home without turning repository edits into immediate production mutations.

## Current Constraints

- `agents/` is the tracked source of truth for public profile scaffolding.
- Live agent homes are machine-local and do not always match the bridge
  workdir.
- Some installations use a split model where the bridge workdir and the live
  CLI home differ.
- Active tmux sessions should not be mutated implicitly while an operator is
  editing tracked files.
- Live memory state should not be overwritten by profile deploy.

## Options Considered

### A. Symlink tracked files into live homes

Pros:

- zero-copy
- instant reflection of repo edits in live homes

Cons:

- unsafe for production because a bad edit immediately affects the live agent
- harder to reason about when a live session picked up a change
- brittle when a machine wants a local override or a different home layout

### B. Copy plus explicit deploy command

Pros:

- safer separation between development state and live state
- operators control when a live profile changes
- easier to add dry-run, diff, force, and audit history

Cons:

- requires a small deploy surface and per-agent target mapping
- live home can drift until deployed

## Recommendation

Use **Option B: copy plus explicit deploy**.

This matches the current bridge philosophy better:

- tracked source stays portable
- machine-specific paths stay local
- production mutation happens only through an operator action

## Proposed Model

### 1. One-way sync in v1

The initial model is one-way only:

- source: `~/agent-bridge/agents/<agent>/`
- target: machine-local live home declared in local roster config

There is no automatic reverse sync from live home back into `agents/`.

### 2. Separate profile target from bridge workdir

Add a local-roster mapping for agents that have tracked profiles:

```bash
BRIDGE_AGENT_PROFILE_HOME["ops"]="$HOME/.agent-bridge/agents/ops"
BRIDGE_AGENT_PROFILE_HOME["analyst"]="$HOME/project-analyst"
```

This must stay separate from `BRIDGE_AGENT_WORKDIR`.

Some roles have matching workdir and live home. Others intentionally do not.
Ephemeral workers usually do not need profile targets by default.

### 3. Managed vs unmanaged files

`profile deploy` should manage only a safe allowlist in v1:

- `CLAUDE.md`
- `skills/**`

Reserved but not auto-deployed in v1:

- `memory/**`

Explicitly unmanaged:

- `MEMORY.md`
- `compound/**`
- `sessions/**`
- `.status`
- repo-specific runtime artifacts

### 4. Explicit CLI surface

```bash
agent-bridge profile status [agent|--all]
agent-bridge profile diff <agent>
agent-bridge profile deploy <agent> [--dry-run] [--force]
```

### 5. Safety rules for deploy

Default deploy must be conservative:

- create missing target directories
- copy only managed files
- never delete target-only files in v1
- fail if local target drift is detected unless `--force` is given
- back up an overwritten `CLAUDE.md` to `.CLAUDE.md.bak`
- print a restart warning if the agent session is active

Deploy should not automatically restart or interrupt the live session in v1.

### 6. Drift tracking

Persist a small manifest per deployed profile under:

```text
state/profiles/<agent>.json
```

Suggested fields:

- `agent`
- `source_root`
- `target_root`
- `managed_paths`
- `source_hash`
- `deployed_at`
- `deployed_by`

## Rollout Plan

1. Add `BRIDGE_AGENT_PROFILE_HOME` support in roster loading.
2. Implement `agent-bridge profile status`.
3. Implement `agent-bridge profile diff`.
4. Implement `agent-bridge profile deploy --dry-run`.
5. Test with one same-home role and one split-home role.
6. Decide later whether `memory/` gains an explicit opt-in sync path.
