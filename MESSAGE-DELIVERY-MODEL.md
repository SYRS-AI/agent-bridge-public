# Message Delivery Model

## Status

This document reflects the current A2A v2 behavior.

- `Claude Code` uses `queue + idle-gated local tmux wake`.
- `Codex` still uses prompt-gated short `tmux` delivery as a temporary fallback.
- The queue is the durable source of truth for both engines.

## Core Rules

1. Every task payload lives in the SQLite queue.
2. Claude never receives free-form `tmux send-keys`.
3. Claude wake signals are short local sends such as `agb inbox <agent>`, and only happen when `idle-since` is present.
4. Requester completion notices are queued back into the requester's inbox.
5. Codex keeps prompt-gated short `tmux` messages until it has a native wake surface.

## Claude Delivery

### Urgent and daemon nudges

For Claude agents, the bridge does this:

1. create a durable queue task
2. if the session is locally reachable and explicitly idle, send a short wake line into the Claude prompt
3. if the agent is busy or stopped, leave the task queued and wait for the next safe wake point

The wake line is intentionally short:

```text
[Agent Bridge] task #104: Redis incident needs triage
agb inbox qa
```

The actual task body stays in the queue.

### Completion notifications

When agent `A` finishes a task created by agent `B`, the bridge does not inject a completion message into `B`'s pane.

Instead it creates a new queue task for `B`:

- title: `[task-complete] <original title>`
- body: who completed it, the original task id, and `agb show <id>`

Then the normal engine-aware wake path applies:

- Claude requester: idle-gated local wake if safe
- Codex requester: prompt-gated short message

## Claude Wake Metadata

Claude wake depends on:

- a live tmux session
- `Stop` hook marking `idle-since`
- `UserPromptSubmit` hook clearing `idle-since`

The dashboard surfaces this as:

- `wake=ok`: the agent has a local wake path
- `wake=miss`: session metadata is incomplete

## Codex Delivery

Codex still uses the guarded `tmux` path:

- short message only
- prompt-gated
- queue remains durable source of truth

This is still a temporary compromise.

## Why This Model

- durable inbox first
- no user-input corruption in Claude panes
- clear idle/busy separation for Claude
- completion flow remains followable by the parent agent
- no hidden work outside the queue

## Non-Goals

Out of scope here:

- replacing Codex `tmux` delivery before Codex has a native wake surface
- redesigning queue storage
- removing optional external notification helpers such as `bridge-notify.py`

## Optional External Notifications

`bridge-notify.py`, `bridge-channel-server.py`, and the `.mcp.json` webhook helpers remain in the repo for future use, but they are not part of the active Claude runtime path.

The bridge runtime should work without Discord webhooks or Telegram chat ids as long as:

- the queue is available
- Claude sessions run with the bridge hooks installed

## Implementation Notes

Primary files:

- `bridge-send.sh`
- `bridge-task.sh`
- `bridge-daemon.sh`
- `bridge-start.sh`
- `lib/bridge-notify.sh`
- `lib/bridge-channels.sh`
- `lib/bridge-state.sh`
