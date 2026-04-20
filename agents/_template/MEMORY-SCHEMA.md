# Memory Schema

## Purpose

This agent keeps memory as a markdown-first wiki.

- raw events are inputs, not memory
- durable memory lives in markdown pages
- search indexes or databases are derived helpers
- team-wide facts live in `~/.agent-bridge/shared/wiki/`, not in one agent's local memory

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

Team-wide knowledge lives outside this agent home:

- `~/.agent-bridge/shared/wiki/people.md`
  - primary operator profile plus team members, aliases, handles, decision scope, communication preferences
- `~/.agent-bridge/shared/wiki/agents.md`
  - agent roles, owners, lifecycle, channels, escalation paths
- `~/.agent-bridge/shared/wiki/operating-rules.md`
  - global rules that apply across agents
- `~/.agent-bridge/shared/wiki/data-sources.md`
  - database/API ownership and query paths
- `~/.agent-bridge/shared/wiki/tools.md`
  - shared tools, credentials policy, approval gates

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

### Promote to team knowledge when:

- multiple agents need the same fact
- the fact is about people, agent roles, operating rules, tools, data sources,
  durable decisions, projects, or playbooks
- the fact should survive individual agent replacement

### Create or update a decision page when:

- a workflow changes in a lasting way
- a repeated policy is agreed
- a project-level choice needs future traceability

## Daily Note Hygiene

Agent daily notes live at `memory/YYYY-MM-DD.md`. These are the raw source
that Agent Bridge copies byte-equivalent into
`~/.agent-bridge/shared/wiki/agents/<self>/daily/<self>-YYYY-MM-DD.md` as
read-only replicas (see `wiki-graph-rules.md §2`).

When you finish a daily note, close it with two things — in this order —
so the shared wiki graph picks up cross-references without post-hoc edits:

1. A `## Related (auto-wiki)` section, **only if the day surfaced
   durable cross-references**. Group the wikilinks by kind and keep each
   group on one line:

   ```markdown
   ## Related (auto-wiki)

   - **Entities:** [[cosmax]] · [[signature-set]]
   - **Concepts:** [[lp-atc-bottleneck]]
   - **Decisions:** [[2026-04-18-price-revert]]
   - **Systems:** [[meta-ads-api]]
   - **People:** [[myo|묘님]] · [[sean|션]]
   ```

   Rules:
   - Use `[[slug]]` for canonical entities you already know. If you
     introduce a new concept or entity, pick a stable kebab-case slug
     now; the wiki graph resolves aliases later.
   - Reference humans by per-person file with display alias:
     `[[myo|묘님]]`, not `[[people#묘님]]` (single-file-with-anchors is
     retired, see `wiki-entity-lifecycle.md`).
   - **Do not** include tree edges: no `[[<agent>-weekly-summary]]`,
     `[[<agent>-monthly-summary]]`, `[[agents#<self>]]`, or any
     self-reference. Daily ↔ rollup edges are forbidden by
     `wiki-graph-rules.md §1`.
   - Omit the whole section if nothing durable came up. An empty
     footer is worse than no footer — the auto-wiki scanner treats a
     present but empty `## Related` as a graph regression.

2. A tag line at the very end:

   ```markdown
   #<self> #daily #YYYY-MM
   ```

   Replace `<self>` with this agent's bridge id (e.g. `#syrs-meta`) and
   `YYYY-MM` with the current month (e.g. `#2026-04`). Tags let Obsidian
   group daily notes by agent and by month without tree edges.

The body of the daily note itself stays free-form prose. Only the
closing block is structural. Do not duplicate the Related footer at the
top of the note or mid-body — it belongs at the bottom, once.

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

### `memory/log.md` Append-Only Convention

`memory/log.md` is a maintenance ledger, not a curated summary page.

- append new entries at the end
- do not rewrite or reorder older entries unless you are adding an explicit correction note
- keep entries short, factual, and traceable
- include the action kind, target page, and raw capture or source when available

Preferred entry shape:

```text
- 2026-04-15T03:12:00+09:00 kind=ingest target=`users/owner/memory/2026-04-15.md` source=`20260415T031100+0900-chat.json`
- 2026-04-15T03:13:10+09:00 kind=promote target=`users/owner/MEMORY.md` source=`20260415T031100+0900-chat.json` summary="User prefers concise morning updates."
```

If you discover that an older log entry was wrong, append a correction entry instead of silently editing history.

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
- `agent-bridge knowledge capture|promote|search|lint`
  - maintain the bridge-level team knowledge SSOT under `~/.agent-bridge/shared/wiki/`
