# Agent Runtime — Wiki Mention Index (L1 Observation)

> Canonical SSOT for how Agent Bridge observes the wiki graph. Defines the
> schema, scan algorithm, and report format for the mention index that the
> entity-graph automation pipeline reads from.
>
> Related: [`wiki-graph-rules.md`](wiki-graph-rules.md), [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md).

## 1. Purpose

The wiki is the team's compounding knowledge base. For it to stay useful as
agents add entries, the system needs continuous observability of:

- which entities exist, who references them, how often
- which shared entities still have no canonical hub (Phase 2 candidates)
- which `[[wikilinks]]` do not resolve (candidates for stub creation)
- which entity slugs are declared but never referenced (orphan candidates)

This doc specifies the **Observation layer (L1)** of that pipeline:

```
[L1 Observation]    wiki-mention-scan.py     ← this doc
        ↓
[L2 Candidacy]      threshold-based hub-build/enrich task enqueue
        ↓
[L3 Enrichment]     librarian synthesizes hub content
        ↓
[L4 Validation]     graph-health nightly report
        ↓
[L5 Human Gate]     merge/delete admin approval
```

L1 is read-only with respect to the wiki. It never edits wiki files, never
creates tasks, never mutates entity frontmatter. It records what it sees.

## 2. Scope

L1 is generic. It runs on any Agent Bridge deployment that follows
`wiki-graph-rules.md` and `wiki-entity-lifecycle.md`. No deployment-specific
paths, agent names, or entity slugs are embedded in the scanner or cron
wiring.

The scanner:

- reads every `*.md` under the wiki root except `_workspace/`, `_audit/`,
  `_index/`, and `.obsidian/` (see `_SKIP_TOP_DIRS`)
- parses frontmatter `slug` + `aliases` to build the canonical alias table
- extracts `[[wikilinks]]`, skipping those inside backtick codespans
- resolves each link via alias → path → filename-stem fallback
- writes rows to `<wiki>/_index/mentions.db`

## 3. Artifact location

```
<wiki>/_index/
├── mentions.db                                sqlite, schema version 1
├── mentions.db-shm / mentions.db-wal          sqlite WAL files
└── distribution-report-YYYY-MM-DD.md          human-readable snapshot
```

Placing the index under `_index/` keeps it inside the wiki tree (so it
moves with wiki clones) while being excluded from content scans by
`_SKIP_TOP_DIRS`.

## 4. Schema (`mentions.db`, schema_version=1)

```
schema_meta          key/value header (schema_version)

entities             one row per declared slug in any frontmatter
  slug                 PK, canonical slug
  title                human-readable
  type                 frontmatter `type` (entity/person/concept/…)
  hub_path             wiki-relative path if canonical lives under shared
  hub_scope            'shared' | 'agent'
  first_seen_at        first time this slug was registered
  last_seen_at         last time a mention resolved to this slug
  updated_at           last metadata refresh

aliases              many-to-one: alias → entity
  alias_normalized     lookup key (NFC + lowercase)
  alias_surface        original text
  entity_slug          FK → entities.slug
  source_path          file that declared the alias

mentions             one row per (source file × entity × surface form)
  id, source_path, source_agent, source_kind, source_mtime
  entity_slug
  surface_form
  mention_count        # of times this surface appears in this file
  scanned_at

unresolved           wikilinks that could not be resolved
  source_path, surface_form, surface_normalized, scanned_at

scans                operational log
  id, started_at, finished_at, mode (full|incremental)
  files_scanned, entities_seen, mentions_new, unresolved_new, error
```

### 4.1 Resolution order

Every `[[surface]]` is resolved through a cascade:

1. **Alias lookup**: `aliases.alias_normalized = normalize(surface)`.
2. **Path lookup**: surface matches a wiki-relative path like
   `agents/<agent>/entities/<name>` with or without `.md` — stored as a
   pseudo-slug `path:<relpath>`.
3. **Stem fallback**: surface has no `/` and matches exactly one
   filename stem in the wiki — stored as `path:<relpath>`.
4. **Unresolved**: recorded in `unresolved`, candidate for stub creation.

### 4.2 Shared-hub precedence

When the same normalized alias maps to more than one slug (e.g. both a
shared hub and an agent-scoped duplicate declare `aliases: [코스맥스]`), the
shared hub wins. This matches `wiki-entity-lifecycle.md` §3.3: shared
hubs are the team's canonical view.

### 4.3 Source classification

`source_agent` is derived from the wiki-relative path:

- `agents/<name>/<file>.md` or deeper → `source_agent = <name>`
- `agents/<name>.md` (redirect stub at the agents/ root) → `source_agent = shared`
- any other top-level dir → `source_agent = shared`

`source_kind` is the first path segment that matches one of
`daily / weekly / monthly / entities / concepts / decisions / systems /
projects / people / research / frameworks / papers / ingredients /
playbooks / data-sources / tools`, else `other`.

## 5. CLI

```
wiki-mention-scan.py --full-rebuild                   # reset + rescan all
wiki-mention-scan.py --incremental                    # mtime-scoped rescan
wiki-mention-scan.py --report [--out <path>]          # distribution report
wiki-mention-scan.py --wiki-root <path>               # override wiki root
```

Wiki root resolution order:
1. `--wiki-root` CLI flag
2. `AGENT_BRIDGE_WIKI` env var
3. `<script-dir>/../shared/wiki` (bridge default layout)

Exit codes: `0` on success, `1` on config/IO error, `2` on scan exception.

## 6. Cron wiring

```
wiki-mention-scan    cron 17 * * * *  Asia/Seoul  patch-owned
```

- Offset :17 chosen to miss the top-of-hour cluster (memory-daily cron,
  wiki-daily-hygiene, hourly monitors).
- Runs `scripts/wiki-mention-scan.sh` (incremental mode) on each tick.
- Emits a fresh distribution report to `_index/distribution-report-<date>.md`.
- Failures file a `[cron-failure]` task to patch via
  `file_failure_task` in `_common.sh`.

For new Agent Bridge installs, register the cron via
`bootstrap-memory-system.sh` alongside the other Plan-D crons — the
scanner is generic and ships the same on every deployment.

## 7. Distribution report format

`distribution-report-YYYY-MM-DD.md` has five sections:

1. Summary counts (entities, aliases, mentions, unresolved, scan metadata)
2. Top 40 entities by cross-agent reach
3. Top 40 entities with no shared hub but ≥2 agents mentioning (Phase 2 candidates)
4. Top 40 unresolved wikilinks (candidates for stub creation)
5. Orphan entity slugs (declared but no inbound mentions)
6. Agent-scope activity breakdown

L2 Candidacy logic reads section 3 to decide which hubs to enqueue. L4
Validation reads sections 4 + 5 + orphan list to surface graph debt.

## 8. Thresholds (provisional — see Phase 2)

L1 collects raw data. Threshold decisions for Phase 2 automation live in a
separate policy doc once real distribution data is in hand. Initial
observations for threshold tuning:

- Cross-agent reach ≥ 2 is a floor; many cross-agent entities have 4–10
  agents mentioning.
- Mention count tracks writing frequency; a thin cross-agent entity may
  warrant a hub even at low mention count if the reach is wide (person,
  vendor, shared tool).

Do not hard-code thresholds in the scanner. They belong in the Phase 2
candidacy layer.

## 9. Validation

L1 itself validates on each scan:

- Every `[[wikilink]]` either resolves or appears in `unresolved`. There
  is no silent drop.
- `entities.last_seen_at` advances on every referenced slug.
- `scans.error` is populated when a run fails — downstream layers can
  detect stale data by checking the latest scan row.

## 10. Changelog

- 2026-04-19: initial ratified version. Scanner + cron shipped; schema
  version 1 documented; resolution cascade (alias → path → stem)
  specified; shared-hub precedence rule ratified.
