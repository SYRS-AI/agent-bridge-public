# Queue-Only Delivery Plan

## Problem

Current urgent and nudge delivery still writes message content into live `tmux` panes.

That is fundamentally unsafe:

- if the target session is mid-turn, `C-m` can be ignored or land at the wrong time
- if the target session is a human-operated prompt, `send-keys` can merge bridge text into the user's partially typed input
- prompt detection can reduce the failure rate, but it cannot make message injection safe enough

The bridge should stop treating pane input as a message transport.

## Direction

Message content moves to the task queue only.

The queue becomes the single durable transport for:

- urgent requests
- daemon nudges
- requester completion notices
- future relay-created wake intents

Agent sessions read queued work through prompt hooks, not direct pane injection.

## Goals

1. Stop using `send-keys` for message content.
2. Surface queued work through `UserPromptSubmit` hooks in Claude Code and Codex.
3. Keep message delivery durable across tmux restarts.
4. Avoid mutating human input buffers.
5. Preserve a small optional visual hint for human-operated sessions, but only when the input line is empty.

## Non-Goals

These are out of scope for the first cut:

- removing direct `/resume` or other predefined action sends from `bridge-action.sh`
- replacing OpenClaw cron or memory systems
- redesigning the queue schema from scratch

`bridge-action.sh` still sends deliberate operator commands. This plan is about free-form message content.

## Current Direct-Message Surfaces To Replace

### 1. `bridge-send.sh`

Today:

- `agent-bridge urgent <agent> "..."` writes `[AGENT BRIDGE URGENT] ...` into the pane

Target:

- `agent-bridge urgent` becomes queue sugar
- internally it creates a task with `priority=urgent`
- no pane write happens

### 2. `bridge-daemon.sh` nudges

Today:

- idle active agents get a short inbox reminder injected into the pane

Target:

- nudges do not inject task text into agent sessions
- daemon only updates queue-side state and optional human-session toast state
- task pickup happens on the next prompt submit through hooks

### 3. `bridge-task.sh notify_task_requester()`

Today:

- when a task completes, the creator can receive a direct pane message

Target:

- completion notices become queue-backed event surfacing
- the creator sees completion info via hook-injected context on the next prompt submit

## Hook Model

### Core idea

Before the CLI sends a user prompt, a local hook helper checks the queue and returns `additionalContext`.

The prompt itself is untouched. The LLM receives extra context that says:

- queued tasks exist
- priority and freshness
- short summaries or body-file pointers
- any completion notices relevant to the current agent

### Claude Code

Use `UserPromptSubmit` hook.

The hook helper should:

1. identify the current bridge agent
2. fetch queue summary for that agent
3. select unseen or changed urgent/high tasks first
4. render concise `additionalContext`
5. persist delivery state so the same task is not re-injected every submit unless it changed

### Codex

Use the same `UserPromptSubmit`-style hook flow and the same helper output contract.

The output format should stay CLI-neutral so one helper can drive both engines.

## Proposed Helper

Add a focused helper such as:

```text
bridge-hook-inbox.py
```

Suggested interface:

```bash
bridge-hook-inbox.py context --agent <agent> --engine <claude|codex>
bridge-hook-inbox.py notify --agent <agent>
```

`context` returns structured output for hooks.

`notify` is optional and only for human-operated sessions with an empty input line.

## Proposed Hook Context Contract

The helper should inject only high-signal content.

Suggested sections:

1. `Inbox summary`
   - queued counts by priority
   - claimed count
2. `New urgent/high tasks`
   - top 1-3 items
   - title
   - creator
   - created_at
   - body snippet or body file path
3. `Requester updates`
   - tasks you created that were completed or handed off since the last delivery

Example shape:

```text
[Agent Bridge Inbox]
- queued: urgent 1, high 2, normal 0
- claimed: 0
- new urgent task #91 from patch: Redis 장애 확인 필요
  body_file: /Users/.../shared/incidents/redis.md
- task #77 you created was completed by shopify
```

## Delivery-State Tracking

Hooks must avoid repeating the same payload forever.

Add per-agent state under:

```text
state/hooks/<agent>.json
```

Suggested fields:

- `last_context_task_ids`
- `last_completion_event_ids`
- `last_rendered_at`

Rules:

- re-inject a task when it is newly queued
- re-inject when its status or assigned owner changed
- do not re-inject unchanged items every submit

## Human-Session Exception

Some tmux sessions are user-operated, not agent-operated.

For those, queue content still must not be pasted into the input line.

Allowed behavior:

- show a very short toast such as `inbox 2건`
- only if the pane is at an idle prompt
- only if the current input line is empty

Disallowed behavior:

- appending message text to a partially typed line
- auto-submit
- multi-line task content

This implies a second helper in the tmux layer:

- detect prompt ownership
- detect whether there is pending user text after the prompt marker

This human-session toast should be optional in v1. Queue durability and hook injection are the primary path.

## Queue Semantics Changes

### `agent-bridge urgent`

Redefine it as:

- queue create shortcut
- `priority=urgent`
- title prefix like `[urgent]`
- optional actor preserved via `--from`

It no longer means "write directly into the pane now".

### Nudge

Nudge becomes a queue-state concern, not a text-delivery concern.

The daemon can still track:

- last nudge timestamp
- cooldown
- whether new queued task ids arrived

But the output is:

- hook-visible urgency metadata
- optional empty-input toast for human sessions

### Requester notifications

Requester notifications should stop using direct pane sends.

Instead:

- `bridge-task done` keeps emitting queue events
- hook helper reads those events for the creator
- completion is surfaced on next prompt submit

## Rollout Plan

### Phase 1: Safety pivot

1. keep recent prompt-gating fixes for direct sends as a temporary guardrail
2. redefine the architecture target as queue-only delivery
3. stop expanding direct message behavior any further

### Phase 2: Hook helper

1. build `bridge-hook-inbox.py`
2. add per-agent hook state under `state/hooks/`
3. test helper output for Claude and Codex

### Phase 3: Hook install model

1. define where hook config lives in live agent homes
2. make tracked profiles able to carry hook config templates
3. add profile deploy support for hook files if needed

### Phase 4: Cut over message paths

1. `agent-bridge urgent` -> queue create
2. requester completion notices -> hook surface only
3. daemon nudges -> no content injection

### Phase 5: Optional human-session toast

1. detect empty prompt safely
2. show only short local hint
3. keep it off by default until validated

## File-Level Impact

Expected implementation surfaces:

- `bridge-send.sh`
- `bridge-daemon.sh`
- `bridge-task.sh`
- `bridge-queue.py`
- `lib/bridge-tmux.sh`
- new hook helper
- profile/hook deployment logic
- docs for Claude/Codex hook install

## Recommendation

Do the next implementation slice in this order:

1. hook helper prototype
2. queue-backed `urgent` rewrite
3. requester completion rewrite
4. daemon nudge rewrite
5. optional human-session toast

This keeps the first real code change aligned with the new transport model instead of spending more time hardening a delivery path we already want to retire.
