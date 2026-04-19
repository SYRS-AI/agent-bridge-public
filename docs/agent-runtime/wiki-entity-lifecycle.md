# Agent Runtime — Wiki Entity Lifecycle

> Canonical SSOT for entity creation, merging, aliases, redirects, and deletion in `shared/wiki/`. Defines the full lifecycle of an entity file from first appearance in agent memory through team-canonical promotion and eventual dedup.
>
> Promoted from `shared/upstream-candidates/2026-04-19-wiki-entity-cleanup-dedup.md` + lifecycle elements of `research-capture-protocol.md` §§"Update vs new-file" and "Legacy file migration".
>
> Related: [`wiki-graph-rules.md`](wiki-graph-rules.md), [`memory-schema.md`](memory-schema.md), [`research-capture-protocol.md`](research-capture-protocol.md), [`wiki-mention-index.md`](wiki-mention-index.md).

## 1. What is an entity

An entity is a durable reference to a real-world thing:

- **person** (묘님, 션, 리드, …)
- **brand / organization** (COSMAX, SYRS, VT Cosmetics, …)
- **product / SKU** (시그니처세트, syrs-repair-cream, …)
- **ingredient / component** (adenosine, cica-callus-ev, …)
- **system / tool** (GA4, TracX, Shopify, …)
- **concept** (cascading summary, retention cohort, …) — arguable boundary with entity; when in doubt prefer `concepts/`.

Not entities (meta-index antipattern — forbidden):

- Folder-shaped names: `memory-md`, `compound-lessons-md`, `session-handoff-md`, `index`, `log`.
- Daily dump summaries: anything whose body is "a list of daily notes" or "a history of checks". Those are cascading summaries, not entities.

## 2. Obsidian aliases — the standard

Every team-canonical entity uses `aliases` frontmatter. This is the mechanism that lets `[[COSMAX]]`, `[[코스맥스]]`, `[[コスマックス]]` all resolve to the same single file.

```yaml
---
type: entity
slug: cosmax
title: COSMAX (코스맥스)
aliases: [COSMAX, cosmax, 코스맥스, コスマックス]
canonical_from: [COSMAX.md, 코스맥스.md, コスマックス.md]   # audit trail of merged files
date_captured: 2026-04-01
date_updated: 2026-04-19
---
```

Rules:

- `slug` is a single ASCII kebab-case string. It matches the filename.
- `title` is the human-readable display name.
- `aliases` is every surface form the team uses, including original-script and romanized variants.
- `canonical_from` lists the original filenames that got merged into this canonical. This is the audit trail — do not delete it.
- `date_updated` moves forward on every merge or material body change.

Per-person files follow the same schema:

```yaml
---
type: entity
slug: myo
title: 묘님 (Myo)
aliases: [묘님, Myo, 妙, 묘묘]
role: co-founder / brand owner
---
```

## 3. Lifecycle — new → canonical → dedup → delete

### 3.1 Create (new entity appears in an agent)

1. Agent writes under its own namespace: `shared/wiki/agents/<agent>/entities/<slug>.md`.
2. Frontmatter includes `type`, `slug`, `title`, `date_captured`. `aliases` optional but recommended from day 1.
3. Body is free-form. Include `## Summary` (1–3 sentences), `## Key facts`, `## Related`.
4. Cross-references go into `## Related` following [`wiki-graph-rules.md`](wiki-graph-rules.md).

### 3.2 Update (new information about an existing entity)

- **Same entity, new data**: update the existing file. Add a row or bullet under `## Key facts` with `(updated YYYY-MM-DD)` prefix. Bump `date_updated`.
- Never rewrite the whole body. Append additive information so the audit trail is readable.
- If the change is significant (e.g. rebrand, merger, relocation), add a `## History` section with the dated change.

### 3.3 Promote to team-canonical (admin curation pass)

Trigger: same entity appears under two or more agent namespaces (detected by `agb knowledge dedup-scan`), or admin decides an entity is team-wide durable.

Procedure:

1. Admin creates `shared/wiki/entities/<slug>.md` (or `shared/wiki/people/<slug>.md` for people).
2. Merge the bodies. Keep the union of verified facts; dedup duplicate lines.
3. Populate `aliases` with every slug + title seen across sources. Populate `canonical_from` with the source filenames.
4. Each contributing `agents/<agent>/entities/<slug>.md` becomes a redirect stub (§3.5) or a namespace-specific subpage if the agent has unique facts worth preserving (e.g. "syrs-derm's ingredient testing notes").
5. Log the merge under `shared/wiki/_audit/dedup-<YYYY-MM-DD>.md`.

### 3.4 Dedup (fragmented entity detection + merge)

Run periodically (admin). Fragmentation = same real-world target, multiple files.

**Detection pipeline:**

1. **Fuzzy match**: collect `slug + title + aliases` from all entity files. Normalize (lowercase, ASCII-transliterate, strip whitespace/hyphens). Pairs with identical normalized form or Levenshtein ≤ 2 → candidates.
2. **LLM cluster**: feed fuzzy candidates + `title + first-200-char-summary` to LLM with the prompt "group entities referring to the same real-world target". Output: `[{canonical: "cosmax", aliases: [...], confidence: 0.0–1.0}]`.
3. **Human review**: admin reviews clusters. Confidence < 0.8 requires explicit admin decision.
4. **Apply**: per approved cluster, follow §3.3 merge steps.
5. **Validate**: `agb knowledge validate --dedup` — zero duplicate aliases, zero broken links, graph node count decreased.

Tools (to land with Track 3 PR):

- `agb knowledge dedup-scan --out <path>` — detection + candidate JSON.
- `agb knowledge dedup-apply --plan <path> [--dry-run]` — apply reviewed plan.
- `agb knowledge validate --dedup` — post-apply integrity.

### 3.5 Redirect stubs (post-merge)

When a merged file has no unique facts worth preserving, replace it with a redirect stub:

```markdown
---
moved_to: cosmax
type: redirect
---
# COSMAX (moved)

Canonical: [[cosmax]]. This file kept as a redirect stub for backward-compat links. It will be removed in a future cleanup pass.
```

Obsidian `aliases` already routes `[[COSMAX]]` to the canonical file, so most existing links keep working without rewriting. The stub exists only for direct path references.

### 3.6 Delete (only these cases)

Deletion is rare. Only these cases justify removing an entity file outright:

1. **Meta-index antipattern node** (§1 Not-entities list): delete immediately, fix inbound links.
2. **Redirect stub older than one migration cycle** with no inbound path references: delete. `aliases` on canonical already covers the link-level redirect.
3. **Confirmed duplicate** with full body already merged into canonical and `canonical_from` audit-trail filed.
4. **Factual error entity** that never existed (e.g. typo-generated file). Delete + log in `_audit/`.

Never delete:

- An entity still referenced as `canonical_from` in another file.
- An entity with unique facts not yet merged.
- Any entity during an active rollout — queue for the post-rollout cleanup pass instead.

## 4. Single-file-with-anchors antipattern (CRITICAL)

Old pattern: `shared/wiki/people.md` with `## 묘님`, `## 션`, `## 리드` as heading anchors. Links like `[[people#묘님]]` all resolve to the same file in Obsidian's graph view — the graph cannot distinguish the people.

Fix: **one person = one file**.

```
shared/wiki/people/
├── myo.md     # aliases: [묘님, Myo, 妙, 묘묘]
├── sean.md    # aliases: [션, Sean, 순석, 오순석]
└── lead.md    # aliases: [리드, Lead]
```

Replace old `[[people#묘님]]` with `[[myo|묘님]]`. Because aliases includes `묘님`, `[[묘님]]` alone also resolves.

The legacy `people.md` becomes a 3-line link-list index or gets deleted (after all inbound references migrate).

Same audit applies to any other single-file-with-anchors hub: `agents.md`, `tools.md`. Inspect each; split if the anchor-as-link pattern exists. (For `agents.md`, tree edges are already forbidden by [`wiki-graph-rules.md`](wiki-graph-rules.md), so the impact is smaller but the split still helps entity-level clarity.)

## 5. Research file lifecycle

Research captures follow [`research-capture-protocol.md`](research-capture-protocol.md). Lifecycle specifics that interact with this doc:

- **Paper update vs new file**: new data → new file. Correction/retraction → new file + old file's `## Summary` gets `**CORRECTED by [[<new-slug>]]**` note.
- **Ingredient dedup across agents**: `syrs-derm/research/ingredients/adenosine.md` + `syrs-production/research/ingredients/adenosine.md` → admin merges into `shared/wiki/entities/adenosine.md` with both namespaces' notes preserved as subsections.
- **Legacy aggregation split**: `memory/projects/ev-exosome-research.md` (17 sections, one file) → `agb knowledge split-legacy --llm` splits into `memory/research/papers/*.md` per section. Original becomes an index with `[[<slug>]]` links only.

## 6. Validation checklist

Before merging a rollout or dedup pass:

- [ ] Every canonical entity has `aliases` covering original-script + romanized + casing variants.
- [ ] No meta-index antipattern nodes (`*-md`, `memory`, `log`, `index` slugs classified as entity).
- [ ] No single-file-with-anchors hubs (`people#X`, `agents#X`, `tools#X`). Where found, split.
- [ ] `canonical_from` is populated on every merge — audit trail never empty.
- [ ] `_audit/dedup-YYYY-MM-DD.md` exists for every dedup pass with source → canonical mapping.
- [ ] `agb knowledge validate --dedup` passes with zero duplicate aliases.
- [ ] Zero broken `[[<link>]]` targets (alias-resolved).

## 7. Prohibited

- Automatic merge without admin review.
- Deleting `canonical_from` metadata — that is the audit trail.
- Using heading anchors (`[[file#heading]]`) as a substitute for per-entity files when the anchors represent distinct real-world things.
- Overwriting body content during merge — always append with `## History` or merged-from attribution.
- Running dedup during a wiki rollout. Queue for after.

## 8. Changelog

- 2026-04-19: initial ratified version. Consolidates `shared/upstream-candidates/2026-04-19-wiki-entity-cleanup-dedup.md` + the "Update vs new-file" and "Legacy file migration" sections of `research-capture-protocol.md`. Obsidian aliases frontmatter formalized as standard. Single-file-with-anchors antipattern promoted to CRITICAL section with explicit split procedure.
- 2026-04-19 (evening): daily-note ingest path split into two lanes
  after the operating-rules.md misroute incident (see
  `_audit/incident-2026-04-19-daily-note-misroute.md`). Daily notes are
  now **never** routed through the librarian promote pipeline. They are
  byte-equivalent copies handled by `scripts/wiki-daily-copy.py`. The
  librarian only handles research/project/decision captures and has a
  hard reject gate against daily-shaped paths and ambiguous kinds.
