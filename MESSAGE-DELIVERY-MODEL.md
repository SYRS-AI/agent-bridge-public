# Message Delivery Model

## Status

This document reflects the current A2A v2 behavior.

- `Claude Code` uses `queue + local webhook wake`.
- `Codex` still uses prompt-gated short `tmux` delivery as a temporary fallback.
- The queue is the durable source of truth for both engines.

## Core Rules

1. Every task payload lives in the SQLite queue.
2. Claude never receives free-form `tmux send-keys`.
3. Claude wake signals are short webhook posts such as `agb inbox <agent>`.
4. Requester completion notices are queued back into the requester's inbox.
5. Codex keeps prompt-gated short `tmux` messages until it has a native wake surface.

## Claude Delivery

### Urgent and daemon nudges

For Claude agents, the bridge does this:

1. create a durable queue task
2. if the session is locally reachable and idle, POST a short wake signal to the agent's webhook channel
3. if the agent is busy, stopped, or missing a wake channel, leave the task queued and wait for the next safe wake point

The webhook message is intentionally short:

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

- Claude requester: webhook wake if idle
- Codex requester: prompt-gated short message

## Claude Wake Metadata

Claude wake is keyed off a local webhook port, not external Discord/Telegram metadata.

Static roles should configure:

```bash
BRIDGE_AGENT_WEBHOOK_PORT["tester"]="9001"
```

Dynamic Claude roles get a state-managed port automatically.

The dashboard surfaces this as:

- `wake=ok`: webhook wake channel is configured
- `wake=miss`: queue is durable, but automatic idle wake is unavailable

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

`bridge-notify.py` still exists for explicit channel notifications, but it is not the core A2A delivery path for Claude sessions.

The bridge runtime should work without Discord webhooks or Telegram chat ids as long as:

- the queue is available
- Claude wake ports are configured where needed

## Implementation Notes

Primary files:

- `bridge-send.sh`
- `bridge-task.sh`
- `bridge-daemon.sh`
- `bridge-start.sh`
- `lib/bridge-notify.sh`
- `lib/bridge-channels.sh`
- `lib/bridge-state.sh`
