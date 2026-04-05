# Message Delivery Model

## Status

This document supersedes the earlier queue-only sketch.

The final direction after Sean review is:

- `Claude Code` agents should prefer webhook delivery when a webhook surface exists.
- `Claude Code` agents may use short prompt-gated local `tmux` attention messages as a fallback when running locally.
- `Codex` agents keep the current prompt-gated short-message path until a native push/webhook path exists.

## Problem

Free-form `send-keys` delivery is unsafe.

Failure modes already observed:

- bridge text merges with user-typed input
- `C-m` lands mid-turn or is ignored
- idle detection reduces the rate of failure but does not remove the underlying input-corruption risk

The bridge must stop using `tmux` pane input as the message transport for `Claude Code` agents.

## Final Model

### Claude Code agents

Delivery path:

1. create a queue task
2. if a webhook surface exists, send a short webhook notification
3. otherwise, if the session is active locally, send a short prompt-gated `tmux` attention message

The external push surface is the transport.

Examples:

- Discord-backed agents: prefer Discord webhooks, not bot-authored channel posts
- Telegram-backed agents: notify their Telegram channel or direct thread

This means:

- no free-form task-body injection into Claude panes
- when local `tmux` fallback is used, only send a short attention line such as `agb inbox <agent>`
- Discord bot-authored channel posts are not a reliable Claude delivery surface

### Codex agents

Codex does not yet have the same external push path.

So for now:

- keep short direct messages through `tmux`
- keep the prompt-gate protection
- treat Codex roles as backend workers rather than human-operated chat surfaces

This is explicitly a temporary compromise, not the long-term transport.

## Goals

1. Eliminate free-form `tmux` injection for Claude Code agents.
2. Preserve durable task payloads in the queue.
3. Use existing Discord/Telegram push surfaces as Claude delivery and wake channels.
4. Keep Codex working with the current guarded path until a better transport exists.
5. Avoid user-input corruption in all human-facing sessions.

## Non-Goals

Out of scope for the first change set:

- replacing predefined `bridge-action.sh` slash-command delivery
- redesigning queue storage
- replacing OpenClaw cron or memory integrations
- inventing a Codex webhook transport before it exists

## Delivery Surfaces

### 1. `agent-bridge urgent`

New meaning:

- always create a queue task first
- then dispatch a notifier based on the target engine

Dispatch rules:

- `claude` target:
  - queue task
  - prefer webhook delivery
  - otherwise fall back to short prompt-gated local attention if the session is active
- `codex` target:
  - keep current prompt-gated short direct message
  - queue remains the durable source of truth

### 2. Daemon nudges

Dispatch rules:

- `claude` target:
  - prefer webhook nudge
  - otherwise fall back to short prompt-gated local nudge text
- `codex` target:
  - keep current prompt-gated short nudge

Queue-side cooldown and new-task detection still stay in place.

### 3. Requester completion notifications

Dispatch rules should follow the same split:

- `claude` requester:
  - notify through the existing channel push surface
- `codex` requester:
  - keep short prompt-gated direct notification for now, or defer to queue-only if no safe prompt is available

The important rule is:

- completion payload must not be injected into Claude panes through `tmux`

## Required Metadata

To make Claude delivery generic, the bridge needs an explicit notifier target per agent.

Recommended roster-level shape:

- existing engine: `BRIDGE_AGENT_ENGINE["agent"]`
- new notification transport kind:
  - `discord`
  - `telegram`
  - empty for none
- new transport target id:
  - Discord channel id
  - Telegram chat/thread id

Possible names:

```bash
BRIDGE_AGENT_NOTIFY_KIND["main"]="telegram"
BRIDGE_AGENT_NOTIFY_TARGET["main"]="agent:main:telegram:direct:@seanssoh"

BRIDGE_AGENT_NOTIFY_KIND["syrs-satomi"]="discord"
BRIDGE_AGENT_NOTIFY_TARGET["syrs-satomi"]="1476851891290771487"
```

The exact variable names can still change, but the bridge needs this mapping.

## New Helper

Add one notifier helper instead of embedding provider logic across shell scripts.

Suggested file:

```text
bridge-notify.py
```

Suggested interface:

```bash
bridge-notify.py send \
  --agent <agent> \
  --kind <discord|telegram> \
  --target <id> \
  --title <short-title> \
  --task-id <id> \
  --message <short-message>
```

Responsibilities:

- resolve credentials from existing machine config
- send a short push message to the correct external channel
- keep the payload concise and channel-safe
- log delivery success/failure for operator review

## Message Shape

Channel notifications should be short.

They are not the full payload transport. The task queue is.

Recommended content:

- source tag: `Agent Bridge`
- priority
- task id
- short title
- one-line instruction to check inbox

Example:

```text
[Agent Bridge] urgent task #104 from patch: Redis 장애 확인 필요
agb inbox syrs-satomi
```

The full body stays in the queue or body file.

## Why Queue + Channel Push

This split gives the right behavior:

- queue stores the durable work item
- channel push gets the agent's attention inside Claude Code
- no pane mutation
- no dependency on prompt idleness
- no duplicated transport logic in every script

## Human Session Safety Rule

For `Claude Code`:

- never inject free-form message content into the tmux input line

For `Codex`:

- keep prompt-gated direct send
- keep the message short
- assume Codex roles are worker sessions, not primary human typing surfaces

## Implementation Order

1. keep `#11` prompt detection hotfix in place for Codex
2. define notifier metadata in roster
3. build `bridge-notify.py`
4. rewrite `bridge-send.sh` to queue first, then engine-aware dispatch
5. rewrite daemon nudges with the same engine split
6. rewrite requester-completion notifications with the same engine split

## File Impact

Expected implementation surfaces:

- `bridge-send.sh`
- `bridge-daemon.sh`
- `bridge-task.sh`
- `bridge-queue.py`
- `lib/bridge-discord.sh`
- new `bridge-notify.py`
- roster docs and examples

## Recommendation

Implement the next slice as:

1. notifier metadata + helper
2. urgent path rewrite
3. daemon nudge rewrite
4. requester completion rewrite

That matches the final direction from `#61` and avoids spending more time on a message transport we now explicitly do not want for Claude Code sessions.
