# Cron Parent Channel Relay Contract

## Problem

Agent Bridge cron jobs currently run in disposable child sessions, but some cron
payloads still tell the child to post directly to a human-facing channel
(Discord, Telegram, Teams, email).

That breaks the parent agent's conversation context:

- the parent owns the human relationship and receives the reply
- the child sends the outbound message
- the parent never saw its own outbound message in-session
- the human replies to context the parent does not have

The user experiences this as "the agent forgot what it just said."

## Existing Gaps

Current upstream behavior still leaves room for this fragmentation:

- `bridge-cron-runner.py` explicitly allows direct user-facing delivery when
  `allow_channel_delivery=true`
- disposable children can still describe delivery in free-form text only
- `[cron-followup]` tasks carry prose, not a typed channel relay payload
- parent agents are told to report results, but the contract is not enforced

Recent work such as `#56`, `#57`, `#59`, and `#61` already moved the system
toward "children should not own parent channels." This document closes the loop
and defines the missing contract.

## Design Goals

1. Parent agents remain the single context owner for human-facing channels.
2. Disposable cron children never send directly to a human surface.
3. Cron outputs intended for humans are returned as structured data, not prose.
4. The parent agent receives enough typed context to send the message from its
   own session and keep the conversation coherent.
5. The contract is generic across Discord, Telegram, Teams, Gmail, and future
   transports.

## Contract

### Rule 1: Disposable children do not touch human channels

Disposable child runs must not call human-facing `message`/`reply`/`send`
tools directly.

This includes:

- Discord channel sends
- Telegram sends
- Teams / M365 sends
- Gmail / email sends
- webhook-style direct human notifications

If a cron needs a human-facing message, the child returns a structured
`channel_relay` block instead.

### Rule 2: `channel_relay` is the typed output surface

Extend the cron child result schema with an optional `channel_relay` object:

```json
{
  "status": "success",
  "summary": "morning briefing prepared",
  "findings": [],
  "actions_taken": [
    "compiled briefing content"
  ],
  "needs_human_followup": true,
  "recommended_next_steps": [],
  "artifacts": [],
  "confidence": "high",
  "channel_relay": {
    "body": "Today's morning briefing ...",
    "urgency": "normal",
    "transport": "telegram",
    "target": "default"
  }
}
```

### Rule 3: Routing authority belongs to the parent/request, not the child

For safety, the child should not choose arbitrary recipients by default.

Priority order for routing:

1. request metadata such as `job_delivery_channel` / `job_delivery_target`
2. `channel_relay.transport` / `channel_relay.target` when request metadata is
   absent
3. parent-agent policy rejects raw webhook URLs or unknown targets

In practice:

- `body` is required when `channel_relay` exists
- `urgency` is optional, default `normal`
- `transport` and `target` are optional hints, not unconditional authority
- email-like transports may later add optional `subject`

### Rule 4: `channel_relay` implies parent follow-up

When `channel_relay` is present:

- `needs_human_followup` must be `true`
- daemon creates or refreshes a `[cron-followup]` task for the parent
- the parent sends the message from the parent's own session
- the parent then marks the follow-up task done with delivery evidence

### Rule 5: Daemon does not send on the parent's behalf

The daemon must not send the human-facing message directly.

Reason:

- daemon-send would still bypass the parent agent's working context
- the whole point of this contract is to make the parent see and own the send
- queueing a structured follow-up keeps the parent in the loop

## Data Shape

Phase-1 schema:

```json
{
  "channel_relay": {
    "type": "object",
    "properties": {
      "body": { "type": "string" },
      "urgency": { "type": "string" },
      "transport": { "type": "string" },
      "target": { "type": "string" },
      "subject": { "type": "string" }
    },
    "required": ["body"],
    "additionalProperties": false
  }
}
```

Notes:

- keep `body` mandatory and non-empty
- keep `transport` / `target` optional for backward compatibility with existing
  cron request metadata
- reserve `subject` for email-like transports
- avoid platform-specific keys such as `chat_id` in the generic contract

## Runtime Behavior

### Child side

`bridge-cron-runner.py` should:

- add `channel_relay` to `RESULT_SCHEMA`
- reject malformed relay payloads
- invert current prompt guidance:
  - do not send directly
  - return relay payload when human delivery is needed
- stop describing direct-send success as a reason to set
  `needs_human_followup=false`

### Daemon side

`bridge-daemon.sh` and `lib/bridge-cron.sh` should:

- preserve `channel_relay` into the follow-up body
- include a dedicated `## Channel Relay` section in `[cron-followup]`
- keep `needs_human_followup=true` when relay exists
- dedupe follow-up refreshes by run/job as today

### Parent side

Parent agents should treat `[cron-followup]` with `channel_relay` as:

1. review the generated message
2. send it from the parent session using the parent-owned channel tool
3. keep the outbound send in the parent's own context
4. mark the task done with delivery evidence

## Enforcement

### Prompt enforcement

Disposable child prompt should explicitly say:

- do not use channel send tools directly
- do not call delivery helper scripts directly
- return `channel_relay` instead

### Lint / migration enforcement

Add warnings for legacy direct-send patterns in cron payloads and runtime files:

- `message(`
- `reply(`
- `send_telegram`
- `discord.com/api/webhooks`
- phrases like `직접 발송`, `바로 보내`, `send directly`

This should start as warning-only, not hard-fail.

## Phased Implementation

### Phase 1

- define `channel_relay` schema
- update cron child prompt
- preserve relay payload into follow-up tasks
- update parent instructions for follow-up handling

### Phase 2

- add supervisor heuristics for relay-specific delivery evidence
- add lint warnings for direct-send cron payloads
- add smoke coverage for relay body generation

### Phase 3

- optional helpers for parent-session relay execution
- optional stricter policy preventing disposable channel tools entirely when
  relay contract is enabled everywhere

## Non-Goals

- daemon auto-sending human messages
- preserving arbitrary platform-specific send APIs in the generic contract
- forcing an immediate downstream rewrite of every legacy cron script in one go

## Migration Notes

Downstream deployments can migrate incrementally:

1. keep existing cron scheduling and queue flow
2. update payload prompts to return `channel_relay`
3. remove direct-send instructions from cron payloads and helper scripts
4. rely on parent follow-up tasks for the final send

This keeps the rollout low-risk while restoring parent-context integrity.
