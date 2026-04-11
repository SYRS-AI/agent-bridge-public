# Shared Team Knowledge Contract

This document defines the public core contract for team-level knowledge in
Agent Bridge.

It is the design anchor for public issue `#22` and the parent contract for:

- `#25` Shared Operator Profiles
- `#23` Structured Handoff Bundles
- `#24` External Intake Triage

The goal is not to mirror the maintainer's private runtime files verbatim.
The goal is to define a clean public contract that can later replace private
POCs through upgrade and migration.

## Why This Exists

The public repo already has working primitives:

- bridge-level team wiki under `shared/wiki/`
- per-agent markdown memory wiki
- raw capture folders
- queue-first task transport
- restart handoff via `NEXT-SESSION.md`

What it did not yet have was a single contract that answers:

- what is canonical vs derived
- what belongs in team SSOT vs one agent's local memory
- how durable facts are promoted
- how multiple long-lived agents share the same human/operator context
- how external noisy inputs become structured routed work

This document fixes that gap.

## Design Goals

1. Keep one canonical home for each class of knowledge.
2. Prevent the same fact from drifting across many agent homes.
3. Preserve source material without confusing it for curated knowledge.
4. Make promotion and routing auditable.
5. Let a clean install behave correctly before the admin agent has years of
   local memory.

## Canonical Layers

| Layer | Canonical? | Purpose | Examples | Write Path | Read Path |
| --- | --- | --- | --- | --- | --- |
| Shared team wiki | Yes | Facts needed by multiple agents | people, agents, operating rules, data sources, tools, decisions, projects, playbooks | `agent-bridge knowledge capture|promote` | `shared/wiki/*.md`, `agent-bridge knowledge search` |
| Agent-local memory wiki | Yes, but local to one agent | Durable context for one agent or one human partition | user preferences, project notes, local decisions, daily notes | `agent-bridge memory capture|ingest|promote|remember` | `MEMORY.md`, `users/<id>/...`, `memory/...` |
| Shared raw captures | Yes for provenance, not for durable truth | Source material awaiting review, extraction, promotion, or routing | inbound channel events, mail triage inputs, cron result payloads | capture/triage flows | direct file read, extractor, search helpers |
| External structured systems | Yes for structured operational facts | Databases/APIs/SaaS systems that own business records | orders, tickets, inventory, calendars, ads, accounting | system-specific tools | system-specific tools; registry in `shared/wiki/data-sources.md` |
| Search indexes / SQLite / FTS | No, derived only | Retrieval acceleration | wiki FTS, memory FTS, search caches | rebuild from canonical sources | `memory query`, future shared query helpers |
| Queue tasks | No for long-term memory | Delivery and lifecycle transport | handoff tasks, cron follow-up, review requests | `agent-bridge task ...` | `agb inbox/show/summary` |

## Canonical Placement Rules

### Put a fact in the shared team wiki when:

- multiple agents need it
- it describes a person, agent role, operating rule, tool, data source,
  durable decision, shared project context, or repeatable playbook
- it should survive agent replacement

### Put a fact in agent-local memory when:

- it only matters to one agent
- it is a user-specific preference or local working pattern
- it improves future quality for that agent but is not team-wide policy

### Keep a fact in an external system when:

- it is structured operational data owned by a database/API/SaaS
- the wiki would only duplicate rows or snapshots
- the correct public behavior is to document the owner and query path, not copy
  the dataset

### Keep content as a raw capture when:

- it is source material that still needs extraction, routing, or review
- it may contain more detail than should be promoted
- provenance matters, but the whole payload is not durable knowledge

## Core Query Order

Long-lived agents should bias toward this order:

1. `NEXT-SESSION.md` if present
2. queue items requiring action or human follow-up
3. relevant team wiki pages under `shared/wiki/`
4. relevant agent-local memory
5. external structured systems named in `data-sources.md`
6. raw captures only when source detail is needed

That order prevents a common failure mode where an agent searches its own
history first, invents stale truth, and only later checks the team SSOT.

## Promotion Contract

Promotion is a movement across layers, not just a file write.

### Shared Team Promotion

Use this path when a fact becomes team knowledge:

1. Preserve source material as a raw capture when useful.
2. Promote the durable summary into the correct wiki page.
3. Record the promotion in `shared/wiki/log.md`.
4. Move the referenced raw capture from inbox to promoted storage when
   applicable.

Current public baseline already supports this with:

- `agent-bridge knowledge capture`
- `agent-bridge knowledge promote`
- `shared/wiki/log.md`

### Agent-Local Promotion

Use this path when a fact remains local to one agent:

1. capture raw note
2. ingest into daily note
3. promote into curated page only if it is stable
4. record the promotion in `memory/log.md`

Current public baseline already supports this with:

- `agent-bridge memory capture`
- `agent-bridge memory ingest`
- `agent-bridge memory promote`
- `agent-bridge memory remember`

## Conflict Rules

When the same topic appears in multiple places:

- team wiki beats one agent's local memory for team-wide facts
- the structured external system beats the wiki for operational records
- curated markdown beats raw capture summaries
- if two curated pages disagree, fix the canonical page instead of letting
  both versions persist

Agents should not silently overwrite conflicting team facts. They should either:

- update the canonical page with a reasoned replacement, or
- escalate the conflict to the admin/operator when the change is risky

## Audit Rules

Every durable change should leave a trace in the layer that owns it.

- team wiki promotions: `shared/wiki/log.md`
- agent-local promotions: `memory/log.md`
- cross-agent work transfer: queue task history
- extracted but not yet promoted source material: raw capture file remains

This means the public system does not need a hidden proprietary memory store to
explain why a durable fact exists.

## Shared Operator Profile

This is the first narrow slice under the umbrella contract and is tracked by
`#25`.

The operator profile belongs in the team wiki, not separately in every agent
home.

Canonical home:

- `shared/wiki/people.md`
- maintained through `agent-bridge knowledge operator set|show` for the primary operator profile

Required fields for the primary operator profile:

- preferred display name
- preferred address / form of address
- aliases or nicknames
- channel handles
- communication preferences
- approval or decision scope
- escalation relevance

Local agent memory may reference the operator, but it should not become the
canonical owner of those facts.

## Structured Handoff Bundles

This slice is tracked by `#23`.

The queue remains the durable transport, but file-backed cross-agent work needs
an explicit bundle contract instead of free-text conventions.

Canonical home:

- `shared/a2a-files/<bundle-id>/bundle.json`
- `shared/a2a-files/<bundle-id>/handoff.md`
- `shared/a2a-files/<bundle-id>/artifacts/`
- created and inspected through `agent-bridge bundle create|show`

A structured handoff bundle should contain:

- sender
- receiver
- short summary
- required action
- artifact manifest with purpose
- expected output or completion contract
- optional human-follow-up draft

`NEXT-SESSION.md` stays separate because it is same-agent restart continuity,
not cross-agent collaboration.

## External Intake Triage

This slice is tracked by `#24`.

The generic public flow should be:

1. preserve raw input
2. classify and extract the durable fields
3. route to the owning role through the queue
4. attach a human-follow-up draft only when required
5. promote only the durable team knowledge, not the whole payload

Canonical home:

- raw source: `shared/raw/captures/inbox/<capture-id>.json`
- triage record: `shared/raw/intake/<capture-id>.json`
- queue body / operator-readable summary: `shared/raw/intake/<capture-id>.md`
- built with `agent-bridge knowledge capture` plus `agent-bridge intake triage|show`

This generalizes the live mail triage pattern without copying a SYRS-specific
mail workflow into core.

## Migration Map From Private/Live Runtime

These mappings are the intended refactor direction, not a direct file copy.

| Live/Private Pattern | Public Destination |
| --- | --- |
| `shared/SYRS-USER.md` | `shared/wiki/people.md` plus operator profile rules |
| `shared/SYRS-CONTEXT.md` | `shared/wiki/projects/`, `decisions/`, `data-sources.md`, `tools.md`, and team rules |
| `shared/ROSTER.md` | `shared/wiki/agents.md` |
| `shared/a2a-files/...` | structured handoff bundle artifact storage (`#23`) |
| `shared/mailbot-triage/*.md` | external intake triage contract (`#24`) |
| ad hoc human/addressing facts embedded in many agent homes | shared operator profile (`#25`) |

## Implementation Order

Recommended order:

1. Land this umbrella contract (`#22`).
2. Implement `#25` Shared Operator Profiles.
3. Implement `#23` Structured Handoff Bundles.
4. Implement `#24` External Intake Triage.
5. After those slices are stable, migrate private/live POC behavior onto the
   public contract through upgrade-safe changes.

## Non-Goals

- Do not port private business facts, people IDs, or channel IDs into public
  templates.
- Do not make queue tasks the canonical memory store.
- Do not treat FTS/SQLite indexes as source of truth.
- Do not preserve private file names or workflows unless the public design
  actually needs them.
