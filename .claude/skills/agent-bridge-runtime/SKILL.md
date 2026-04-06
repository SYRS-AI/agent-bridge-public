---
name: agent-bridge-runtime
description: "CRITICAL: When you see '[Agent Bridge]' in any message or context, you MUST immediately run agb inbox and process tasks. This is not optional."
---

## When This Skill Triggers

- You receive a message starting with `[Agent Bridge]`
- Stop hook additionalContext mentions `inbox`, `queued tasks`, or `agb inbox`
- Any context includes "queued tasks waiting", "inbox", or task references like `next: #<id>`

## Required Actions (Mandatory)

**When triggered, immediately execute the following. Do NOT just acknowledge with "got it" or "understood".**

1. Run `~/.agent-bridge/agb inbox <your-agent-name>`
2. If queued tasks exist, run `~/.agent-bridge/agb show <task-id>` for the first one
3. Claim it: `~/.agent-bridge/agb claim <task-id> --agent <your-agent-name>`
4. Do the work described in the task
5. Complete it: `~/.agent-bridge/agb done <task-id> --agent <your-agent-name> --note "summary"`

## Prohibited

- Responding to `[Agent Bridge]` with just "acknowledged" or "noted" without running inbox — FORBIDDEN
- Skipping inbox check — FORBIDDEN
- Assuming inbox is empty without running the command — FORBIDDEN
- Using `bridge-task.sh`, sqlite queries, or filesystem searches instead of `agb` CLI — FORBIDDEN

## Queue Source of Truth

- Live queue: `~/.agent-bridge/state/tasks.db`
- Never read `~/agent-bridge/state/tasks.db` (repo copy)
- Never infer queue state from memory or prior conversation

## Example

```bash
~/.agent-bridge/agb inbox newsbot
~/.agent-bridge/agb show 604
~/.agent-bridge/agb claim 604 --agent newsbot
# ... do the work ...
~/.agent-bridge/agb done 604 --agent newsbot --note "trend feed delivered"
```
