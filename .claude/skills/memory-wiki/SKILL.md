---
name: memory-wiki
description: Use when a conversation, task, or channel message contains durable facts, preferences, decisions, or project context that should be preserved in the agent's markdown-first memory wiki.
---

## Purpose

Use this skill when you need to preserve useful memory without asking a human to learn bridge memory commands.

The human should speak naturally. You decide whether the information deserves memory, then update the wiki yourself.

## Source Of Truth

- Markdown wiki files are source of truth.
- Raw capture files are inputs.
- SQLite indexes are derived helpers.

## Default Path

Prefer the one-step command unless you specifically need separate stages:

```bash
~/.agent-bridge/agent-bridge memory remember --agent "$BRIDGE_AGENT_ID" --user <user-id> --source chat --text "..." --kind user
```

This will:

1. create a raw capture
2. ingest it into the active user's daily memory
3. optionally promote it into long-term memory

## Raw-Source Ingest Workflow

Use the staged flow when the source is long, noisy, or arrives as a file rather than a short chat message.

Examples:

- a pasted meeting transcript
- a Discord export or support thread
- a markdown note captured from another system
- a long email or incident write-up

Recommended flow:

1. capture the raw source into `raw/captures/inbox/`
2. ingest it into the correct user's daily memory
3. only then promote durable facts into curated pages

Example with a file source:

```bash
~/.agent-bridge/agent-bridge memory capture \
  --agent "$BRIDGE_AGENT_ID" \
  --user <user-id> \
  --source notes-import \
  --title "Weekly ops retro" \
  --text-file /path/to/source.md

~/.agent-bridge/agent-bridge memory ingest \
  --agent "$BRIDGE_AGENT_ID" \
  --latest
```

If the source contains only a few durable facts, you may still prefer `memory remember`.
If the source is ambiguous or partly unverified, prefer `capture -> ingest` first and promote later.

## When To Remember

Use memory when a message contains:

- stable preferences
- recurring workflow expectations
- durable personal context
- long-lived project context
- decisions that should affect future behavior

Do not remember:

- transient chatter with no future value
- facts that clearly belong only to the current turn
- speculative or unverified claims you would not want to rely on later

## Which Kind To Use

- `--kind user`
  - default for one human's preferences, habits, constraints, or stable context
- `--kind shared`
  - facts that apply across humans for this agent
- `--kind project`
  - project/domain context worth keeping on a dedicated page
- `--kind decision`
  - policy changes, agreed rules, architectural choices
- `--kind none`
  - capture and ingest only, with no long-term promotion yet

## Multi-User Guardrail

If the agent supports multiple humans:

- always identify the active user first
- write user-specific facts under that user's partition
- never mix one person's preferences into another person's memory

When unsure, prefer:

1. daily user memory first
2. then promote later after more confidence

## Retrieval

Before asking the human to repeat known context, check memory:

```bash
~/.agent-bridge/agent-bridge memory query --agent "$BRIDGE_AGENT_ID" --user <user-id> --query "..."
```

If the derived index is missing or you want broader markdown-first matching:

```bash
~/.agent-bridge/agent-bridge memory search --agent "$BRIDGE_AGENT_ID" --user <user-id> --query "..."
```

## Maintenance

Use these when needed:

- `memory lint`
  - find missing structure, pending captures, and wiki hygiene problems
- `memory rebuild-index`
  - rebuild the derived SQLite index after significant edits

## Example

The human says:

> I prefer weekly summary digests on Fridays.

You may preserve it with:

```bash
~/.agent-bridge/agent-bridge memory remember \
  --agent "$BRIDGE_AGENT_ID" \
  --user owner \
  --source chat \
  --text "The user prefers weekly summary digests on Fridays." \
  --kind user
```
