# Agent Profile Sync Model

## Goal

Define how tracked agent profiles under `agents/` are promoted into each machine's live agent home without turning repository edits into immediate production mutations.

## Current Constraints

- `agents/` is now the tracked source of truth for migrated agent profile material.
- Live agent homes are machine-local and do not always match the bridge workdir.
- `shopify` already proves this split:
  - bridge workdir: `~/.openclaw/workspace-syrs-shopify`
  - live CLI home with `CLAUDE.md`: `~/syrs-shopify`
- Active tmux sessions should not be mutated implicitly while an operator is editing tracked files.
- Live memory state should not be overwritten by an early profile sync implementation.

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

Add a new local-roster mapping for agents that have tracked profiles:

```bash
BRIDGE_AGENT_PROFILE_HOME["patch"]="$HOME/.openclaw/patch"
BRIDGE_AGENT_PROFILE_HOME["shopify"]="$HOME/syrs-shopify"
```

This must stay separate from `BRIDGE_AGENT_WORKDIR`.

Reason:

- `patch`: workdir and live home happen to match
- `shopify`: they do not match

Workers such as `patch-codex` and `shopify-codex` do not need profile targets by default.

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

Reason:

- the tracked `memory/` directory is intended for future structured memory migration
- current live memory files are still runtime state and should not be clobbered by profile deploy

### 4. Explicit CLI surface

Add a new top-level command group:

```bash
agent-bridge profile status [agent|--all]
agent-bridge profile diff <agent>
agent-bridge profile deploy <agent> [--dry-run] [--force]
```

Behavior:

- `status`: show tracked source path, live target path, and whether drift exists
- `diff`: compare managed files between tracked source and live target
- `deploy`: copy managed files from tracked source to live target

Future expansion:

- `agent-bridge profile deploy --all`
- `agent-bridge profile deploy <agent> --include-memory`
- `agent-bridge profile pull <agent>` only after reverse-sync rules are defined

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

This enables:

- safer `status`
- target drift detection
- clearer operator audit trail

## Implementation Shape

Recommended split:

- CLI parsing in `agent-bridge`
- profile metadata helpers in `lib/bridge-state.sh`
- deploy/diff helpers in a new shell module or a focused Python helper

If file diff or manifest generation gets awkward in Bash, prefer a small Python helper over adding new external dependencies.

## Rollout Plan

1. Add `BRIDGE_AGENT_PROFILE_HOME` support in roster loading.
2. Implement `agent-bridge profile status`.
3. Implement `agent-bridge profile diff`.
4. Implement `agent-bridge profile deploy --dry-run`.
5. Test with `patch` and `shopify`.
6. After deploy behavior is stable, decide whether `memory/` should stay reserved or gain an explicit opt-in sync path.
7. Only then build a scaffold/generator around the finalized model.

## Recommendation For Current Phase

Proceed with:

1. `BRIDGE_AGENT_PROFILE_HOME` local mapping
2. `profile status|diff|deploy`
3. `CLAUDE.md` and `skills/` only

Do **not** sync `memory/` automatically yet.
