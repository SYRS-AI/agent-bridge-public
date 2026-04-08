# Memory Wiki Plan

## Goal

Bring OpenClaw's strong agent identity and memory continuity into Agent Bridge without copying the old template set verbatim.

The target is a bridge-native memory system with:

- clear agent character formation
- durable memory across sessions
- a markdown-first memory wiki maintained by the agent
- per-user memory partitioning for multi-user agents
- optional search/index layers built on top of files, not instead of files

## Source Principles

This plan keeps the useful parts of vanilla OpenClaw:

- `SOUL -> user context -> recent memory -> curated memory` session startup
- raw daily notes plus curated long-term memory
- agent identity as an explicit artifact, not an implicit prompt

It also adopts the "LLM-maintained wiki" model:

- raw events are not the memory system
- compiled markdown pages are the memory system
- search/index/vector layers are derived helpers

## Non-Goals

- Do not restore the entire OpenClaw document set as-is.
- Do not make SQLite or embeddings the source of truth.
- Do not mix multiple humans into one flat `MEMORY.md`.
- Do not put team-specific SYRS behavior into the public template.

## Target Model

### 1. Identity Layer

Keep identity small and explicit.

- `SOUL.md`
  - voice
  - philosophy
  - behavioral boundaries
  - what kind of collaborator this agent is
- `CLAUDE.md`
  - operational contract
  - queue/task/channel/escalation rules
  - startup checklist
- `MEMORY-SCHEMA.md`
  - what belongs in memory
  - where to write it
  - what can be promoted to long-term memory
  - how to avoid mixing users, projects, and temporary notes

`IDENTITY.md`, `AGENTS.md`, and `BOOTSTRAP.md` do not need to return as separate public template files.
Their semantics should be absorbed into:

- `SOUL.md`
- `CLAUDE.md`
- `agent create` / `init` bootstrap flow

### 2. Memory Layer

Memory should be markdown-first and wiki-shaped.

- `MEMORY.md`
  - top-level agent memory
  - concise, curated, durable facts
- `memory/index.md`
  - map of the memory wiki
  - important pages and how they relate
- `memory/log.md`
  - append-only synthesis log
  - memory changes, promotions, and important updates
- `memory/shared/*.md`
  - shared facts for the agent as a whole
- `memory/projects/*.md`
  - project or domain pages
- `memory/decisions/*.md`
  - important decisions and rationale

### 3. Per-User Partition

Multi-user agents need memory separation by default.

- `users/<user-id>/USER.md`
  - stable human profile
- `users/<user-id>/MEMORY.md`
  - curated long-term memory for that human
- `users/<user-id>/memory/YYYY-MM-DD.md`
  - raw or lightly synthesized daily interaction notes

This is required for agents like `jjujju`.

Example:

- `users/sean/...`
- `users/myo/...`

The agent can still keep shared pages under `memory/shared/`, but user-specific facts must stay in the correct partition unless intentionally promoted to shared memory.

### 4. Raw Event Layer

Raw events still exist, but they are not the memory system.

Examples:

- channel transcripts
- queue tasks
- cron payloads/results
- webhook bodies
- imported notes

These are source material for memory synthesis. They should not be the main thing the agent reads every session.

## Session Startup Contract

Static conversational agents should start with this order:

1. `SOUL.md`
2. `CLAUDE.md`
3. `MEMORY-SCHEMA.md`
4. current user's `users/<user-id>/USER.md`
5. current user's recent daily memory files
6. agent-wide `MEMORY.md`
7. current user's `users/<user-id>/MEMORY.md`
8. optionally relevant project/shared pages
9. `HEARTBEAT.md` only when the task is heartbeat or recurring work

This preserves continuity without loading everything every time.

## Memory Write Rules

### Write to daily user memory when:

- a new preference appears
- a new short-lived context appears
- a conversation produces actionably useful context

### Promote to curated user memory when:

- the fact has repeated value
- it affects future interaction quality
- it is stable enough not to churn daily

### Promote to shared memory when:

- it is about the agent's shared operating context
- it applies across users
- it is not private to a single human

### Record a decision page when:

- a recurring workflow changes
- the agent/user agree on a lasting policy
- a project-level choice will matter later

## Bridge-Native Command Surface

The current `tools/memory-manager.py` should not become the main write path.
It can remain a compatibility search tool for now.

The long-term command surface should become:

- `agent-bridge memory init`
- `agent-bridge memory append`
- `agent-bridge memory promote`
- `agent-bridge memory search`
- `agent-bridge memory rebuild-index`
- `agent-bridge memory lint`

### Expected behavior

- `init`
  - create wiki skeleton
- `append`
  - add a new daily memory entry
- `promote`
  - move durable facts into curated pages
- `search`
  - search files first, optional derived index second
- `rebuild-index`
  - recreate derived search/index state
- `lint`
  - detect stale pages, contradictions, orphan pages, missing cross-links

## Bootstrap Flow

Agent identity should be formed by bootstrap commands, not by a temporary tracked markdown file.

`agent-bridge init` and `agent create` should gather:

- display name
- role
- tone and boundaries
- channel model
- single-user vs multi-user mode
- initial humans to support
- whether heartbeat memory maintenance is enabled

Outputs:

- `SOUL.md`
- `CLAUDE.md`
- `MEMORY-SCHEMA.md`
- `MEMORY.md`
- `memory/index.md`
- `memory/log.md`
- `users/default/USER.md` or initial user pages

## Implementation Phases

## Phase 1: Template + Schema Foundation

Add the new memory structure to the template.

- add `MEMORY-SCHEMA.md`
- add `memory/index.md`
- add `memory/log.md`
- add `users/default/USER.md`
- add `users/default/MEMORY.md`
- add `users/default/memory/.gitkeep`
- update template `CLAUDE.md` startup order
- update template `SOUL.md` to point at the schema

Deliverable:

- newly created agents get the correct memory skeleton

## Phase 2: Bootstrap + Create Flow

Teach `agent create` and `init` how to scaffold and configure the new model.

- support single-user vs multi-user mode
- create initial user partitions
- seed agent identity and memory wiki pages
- write role metadata into the right files

Deliverable:

- a fresh agent can be born with a coherent identity and memory layout

## Phase 3: Memory Write Path

Add bridge-native write operations.

- `memory init`
- `memory append`
- `memory promote`
- `memory lint`

Deliverable:

- the agent can maintain its own wiki rather than just search legacy memory

## Phase 4: Search and Derived Index

Adapt or replace `tools/memory-manager.py`.

- prefer file-based search as default
- optionally maintain SQLite/vector indexes as derived state
- keep compatibility mode only where useful

Deliverable:

- fast retrieval without making the index the source of truth

## Immediate Next Step

Start with Phase 1.

That is the lowest-risk change and it fixes the biggest structural gap:
Agent Bridge already has `SOUL.md` and `MEMORY.md`, but it still lacks a proper schema and wiki skeleton.

Phase 1 should ship before any memory indexing rewrite.
