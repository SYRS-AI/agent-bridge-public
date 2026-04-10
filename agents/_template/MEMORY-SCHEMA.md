# Memory Schema

## Purpose

This agent keeps memory as a markdown-first wiki.

- raw events are inputs, not memory
- durable memory lives in markdown pages
- search indexes or databases are derived helpers

## Layout

- `MEMORY.md`
  - top-level long-term memory for the agent
- `memory/index.md`
  - memory wiki map and important pages
- `memory/log.md`
  - append-only memory maintenance log
- `memory/shared/*.md`
  - agent-wide facts that apply across humans or projects
- `memory/projects/*.md`
  - project or domain pages
- `memory/decisions/*.md`
  - important decisions and rationale
- `users/<user-id>/USER.md`
  - stable user profile; bridge-managed agents may link this to `~/.agent-bridge/shared/users/<user-id>/USER.md`
- `users/<user-id>/MEMORY.md`
  - long-term memory for one human
- `users/<user-id>/memory/YYYY-MM-DD.md`
  - daily notes for one human

## Write Rules

Humans should not have to memorize special slash commands for memory.
If a message naturally contains durable preferences, stable context, or important facts, the agent may capture it proactively.

### Write to daily user memory when:

- a new preference appears
- a new temporary context appears
- a conversation produces useful follow-up context

### Promote to user long-term memory when:

- the fact is likely to matter again
- it improves future interaction quality
- it is stable enough not to churn every day

### Promote to shared memory when:

- the fact applies across users
- it belongs to the agent's shared operating context
- it is not private to a single human

### Create or update a decision page when:

- a workflow changes in a lasting way
- a repeated policy is agreed
- a project-level choice needs future traceability

## Separation Rules

- Do not mix one human's preferences into another human's memory files.
- If an agent supports multiple humans, read and write the active user's partition first.
- Shared pages may reference multiple humans, but user-specific facts should stay attributed.

## Session Startup

Default read order:

1. `SOUL.md`
2. `CLAUDE.md`
3. this file
4. active user's `users/<user-id>/USER.md`
5. active user's recent `users/<user-id>/memory/*.md`
6. `MEMORY.md`
7. active user's `users/<user-id>/MEMORY.md`
8. relevant shared/project/decision pages

## Maintenance

- Keep `MEMORY.md` concise.
- Use `memory/log.md` to record meaningful promotions or restructures.
- Prefer updating an existing page over creating near-duplicates.
- If memory becomes contradictory, fix the wiki page instead of carrying both versions forward.

## Bridge Commands

- `agent-bridge memory capture`
  - store raw candidate memory in `raw/captures/inbox/`
- `agent-bridge memory ingest`
  - move raw captures into the wiki's daily user memory and log the ingest
- `agent-bridge memory promote`
  - move durable facts into curated user/shared/project/decision pages
- `agent-bridge memory remember`
  - preferred one-step path when the agent decides a message contains a durable fact
  - writes a raw capture, ingests it into daily memory, and optionally promotes it
- `memory-wiki` shared skill
  - behavioral guidance for deciding when to remember, how to separate users, and when to query existing memory first
- `agent-bridge memory search`
  - search the wiki first, then optional raw capture files if needed
- `agent-bridge memory rebuild-index`
  - rebuild a derived SQLite FTS index from the wiki and raw captures
- `agent-bridge memory query`
  - query the derived index for faster retrieval while keeping markdown as source of truth
