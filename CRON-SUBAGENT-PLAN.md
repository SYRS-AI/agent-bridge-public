# Cron Subagent Execution Plan

## Problem

Current `cron enqueue` materializes a legacy OpenClaw recurring job and turns it
into a normal queue task for a bridge agent. If the target is `main`, the full
cron payload lands directly in the long-lived main session.

That creates the wrong shape for family-facing or orchestrator-facing agents:

- heavy cron work pollutes the main conversation context
- follow-up logic and user-facing delivery live in the same context as the raw
  execution trace
- if a separate cron session delivers directly to the user, `main` loses the
  chance to verify, synthesize, and follow up

Desired model:

1. the cron request reaches `main`
2. `main` spawns a disposable child worker
3. the child does the heavy cron work in isolation
4. the child returns a compact structured result to `main`
5. `main` decides follow-up, human-facing delivery, and any downstream tasks

## Constraints

### Codex

Observed locally on 2026-04-05:

- `codex --help` exposes no native `agents` or `subagents` command
- `codex exec --help` does expose a strong non-interactive worker surface:
  - `--ephemeral`
  - `--json`
  - `--output-schema`
  - `-C/--cd`

Implication:

- Codex has a solid disposable runner interface today
- a native in-session subagent API is not visible in the local Codex CLI

### Claude Code

Observed locally on 2026-04-05:

- `claude --help` exposes `--agent`, `--agents`, and `claude agents`
- Anthropic docs describe Claude Code subagents / custom agents and worktree
  isolation hooks

Relevant sources:

- Claude CLI help on this machine
- Anthropic docs:
  - https://docs.anthropic.com/en/docs/claude-code/sub-agents
  - https://code.claude.com/docs/en/hooks

Implication:

- Claude has a native subagent concept
- but the bridge still needs a deterministic, automation-friendly contract that
  also works for Codex

## Recommendation

Use a **bridge-managed disposable child runner for v1 on both engines**.

This is the key decision.

Why:

- one execution contract across Claude and Codex
- one result schema across Claude and Codex
- one audit trail under bridge state
- no dependence on tmux free-form injection
- Codex is supported immediately
- Claude can still adopt native subagents later behind the same bridge
  interface if that proves better

Important nuance:

- `main` remains the orchestrator
- the bridge must not bypass `main` and deliver child output directly to the
  user
- the child worker is an implementation detail of how `main` executes cron work
  safely

## v1 Execution Model

### 1. Cron task shape changes

`cron enqueue` should stop posting the full legacy payload as the task body to
`main`.

Instead it should create a compact dispatch task:

- task title: `[cron-dispatch] <job-name> (<slot>)`
- task body:
  - run id
  - job metadata
  - path to the materialized legacy payload file
  - one explicit instruction:
    - do not execute inline
    - spawn a cron child worker
    - inspect the result
    - decide follow-up and user-facing delivery from `main`

The full original payload remains on disk as an artifact, not in the queue body.

### 2. Main-session protocol

When `main` receives a `[cron-dispatch]` task:

1. read the run metadata
2. invoke `agent-bridge cron run-subagent <run-id>`
3. wait for the child result artifact
4. read the compact result
5. decide:
   - no-op
   - user/channel update
   - follow-up queue tasks
   - memory/status update
6. mark the parent cron task done with a note that references the child run id

### 3. Child worker protocol

The child worker:

- reads the materialized cron payload
- performs the heavy work in an isolated disposable run
- writes a structured result artifact
- never sends user-facing messages directly
- never marks the parent queue task done directly

The child is an execution worker, not a delivery agent.

## New Bridge Surface

Add a new helper:

```bash
agent-bridge cron run-subagent <run-id> [--dry-run]
```

Suggested behavior:

1. resolve the parent task / target agent / job metadata
2. resolve the parent agent engine and workdir
3. create a per-run state directory
4. execute an engine-specific disposable child
5. write:
   - `state/cron/runs/<run-id>/request.json`
   - `state/cron/runs/<run-id>/result.json`
   - `state/cron/runs/<run-id>/stdout.log`
   - `state/cron/runs/<run-id>/stderr.log`
6. return a short machine-readable summary to the caller

## Engine Adapters

### Codex adapter

Use the local non-interactive runner:

```bash
codex exec \
  --ephemeral \
  --json \
  --output-schema <schema-file> \
  -C <workdir> \
  <prompt>
```

Notes:

- this is the cleanest currently visible Codex sub-worker surface
- no persistent child session is required for v1
- result parsing should rely on the schema, not free-form prose

### Claude adapter

Use the local non-interactive runner in v1 as well:

```bash
claude -p \
  --output-format json \
  --json-schema <schema> \
  --add-dir <workdir> \
  <prompt>
```

If a dedicated worker identity is needed, the adapter can later add:

- `--agent <worker-name>`
- or `--agents <json>`

But that should be optional in v1.

Reason not to lead with native Claude subagents:

- the bridge needs parity with Codex first
- a disposable CLI run is easier to make deterministic and testable
- it avoids coupling cron execution to tmux/session-specific interactive state

## Result Contract

The child result should be small and structured.

Suggested schema:

```json
{
  "status": "success",
  "summary": "short operator-facing summary",
  "findings": ["..."],
  "actions_taken": ["..."],
  "needs_human_followup": false,
  "recommended_next_steps": ["..."],
  "artifacts": ["/abs/path/to/file"],
  "confidence": "high"
}
```

Rules:

- `summary` should be compact enough for `main` to ingest without dragging the
  entire worker trace into context
- verbose logs stay in `stdout.log` / `stderr.log`
- child output is for `main`, not for end users

## State And Idempotency

Each cron dispatch needs a stable run directory:

```text
state/cron/runs/<job-slug>/<slot>/
```

Required files:

- `request.json`
- `result.json`
- `stdout.log`
- `stderr.log`
- `status.json`

Suggested status values:

- `queued`
- `running`
- `success`
- `error`
- `timed_out`

Idempotency rule:

- if a completed `result.json` already exists for the same job/slot, reruns
  should be explicit

## Why This Solves The Main-Context Problem

Without this change, the main session sees:

- the full cron prompt
- the execution details
- the reconciliation thoughts
- the delivery decision

With this change, the main session sees only:

- a short dispatch instruction
- a compact child result
- the final delivery or follow-up decision

That keeps `main` authoritative without making it a dumping ground for raw cron
execution context.

## Rollout Plan

### Phase 1: runner skeleton

- add `cron run-subagent --dry-run`
- add run directory creation
- add result schema
- add request/result artifacts

### Phase 2: Codex adapter

- implement disposable Codex child execution
- validate schema capture and error handling

### Phase 3: Claude adapter

- implement disposable Claude child execution
- validate schema capture and error handling

### Phase 4: main dispatch protocol

- change `cron enqueue` task body to dispatch mode
- update the `main` profile instructions so cron work is never done inline

### Phase 5: migrate one family first

Start with one recurring family only, likely:

- `memory-daily`

Do not migrate all cron families in one shot.

## Tests

Minimum tests:

1. `cron run-subagent --dry-run` for both engine types
2. parent task -> child run artifact creation
3. successful child result -> parent main can summarize and complete task
4. child error -> parent sees structured failure and can alert/follow up
5. duplicate slot -> idempotent behavior
6. no direct user-facing delivery from child

## Future v2

If the v1 contract is stable, Claude can optionally swap its adapter from
`claude -p` to a native Claude subagent implementation behind the same bridge
interface.

That would preserve:

- the same dispatch task shape
- the same result schema
- the same parent/child responsibility split

while allowing Claude-specific optimizations later.
