# Agent Runtime — Wiki Graph Rules

> Canonical SSOT for how agents write into `shared/wiki/`. These rules keep the Obsidian graph readable (cross-reference clusters instead of tree hairballs) and keep multi-agent writes race-free.
>
> Promoted from `shared/upstream-candidates/2026-04-19-wiki-graph-build-rules.md` §§1–3. Rollout plan (§5) and deferred logic changes (§§4, 7) live in that candidate; this file is the runtime-facing contract only.
>
> Related: [`memory-schema.md`](memory-schema.md), [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md), [`research-capture-protocol.md`](research-capture-protocol.md).
>
> **Antipattern — per-agent `index.md`/`overview.md` 금지**: 폴더 구조가 이미 navigation을 수행하므로 per-agent index 파일은 중복이며 Obsidian graph에서 stem collision(여러 `index` 노드) 야기. 오직 `shared/wiki/index.md` 1개(vault 최상위 카탈로그)만 허용.

## 1. Graph edge policy

Obsidian graph shows **meaningful cross-references only**. Tree edges (folder/section/rollup structure already implicit in paths) are forbidden — they create hairball hubs that destroy retrieval quality and visual clustering.

### Keep — cross-reference edges

- `daily ↔ entities` — a daily note references a thing (brand, product, ingredient, system).
- `daily ↔ concepts` — a daily note uses a concept (e.g. cascade summary, supply chain).
- `daily ↔ decisions` — a daily note led to or depends on a decision.
- `daily ↔ systems` — a daily note touched an infra/tool system.
- `entities ↔ concepts` — an entity is an instance of a concept.
- `decisions ↔ entities/concepts` — a decision changes a thing or applies a concept.
- `daily ↔ people/<person>` — named humans mentioned that day. `agents/<self>` is **excluded** (self-reference is a tree edge).

### Forbid — tree edges

- `daily ↔ weekly-summary` / `daily ↔ monthly-summary`.
- `weekly-summary ↔ monthly-summary`.
- `daily ↔ agents#<self>` (self-reference).
- `<agent-namespace>/daily ↔ <agent-namespace>/weekly|monthly` (in-namespace rollup).
- `index.md → <rollup page>` autolinks (navigation only; keep minimal, don't let the index become a hub).
- Any edge whose only purpose is to reflect folder structure. Folders already tell the graph that story.

> **Audit override (CRITICAL cases, from auditor feedback):** if a tree edge is found in the wild, add its exact pattern to the "Forbid" list and fix it in the rollout. Known examples caught so far: `[[people]]` linking to single-file `people.md` heading anchor → now forbidden by §3 of [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md). Meta-index entity nodes (`memory-md`, `session-handoff-md`, `compound-lessons-md`) → delete on sight.

## 2. Daily note hygiene in the wiki

Daily memory files copied from an agent home into `shared/wiki/agents/<agent>/daily/<agent>-YYYY-MM-DD.md` are **read-only replicas**.

- **Do not rewrite the body.** The wiki copy is a snapshot of the original memory — provenance requires byte-equivalence with the raw capture.
- Append exactly one section at the bottom:

  ```markdown
  ## Related (auto-wiki)

  - **Entities:** [[a]] · [[b]]
  - **Concepts:** [[c]] · [[d]]
  - **Decisions:** [[e]]
  - **People:** [[myo|묘님]] · [[sean|션]]
  ```

- Add a tag line at the very end: `#<agent> #daily #YYYY-MM`.
- **No tree links** in the Related section: `[[<agent>-weekly-summary]]`, `[[<agent>-monthly-summary]]`, `[[agents#<agent>]]` are forbidden.
- People links use per-person files (`[[myo|묘님]]`), not heading anchors (`[[people#묘님]]`). The single-file-with-anchors pattern was retired — see [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md).

## 3. Namespace — race-free multi-agent writes

Every agent has a private namespace in the wiki. Only admin writes into the team-canonical namespaces.

```
shared/wiki/
├── agents/
│   ├── <agent>/
│   │   ├── weekly-summary.md
│   │   ├── monthly-summary.md
│   │   ├── daily/<agent>-YYYY-MM-DD.md
│   │   ├── entities/<slug>.md
│   │   ├── concepts/<slug>.md
│   │   ├── decisions/YYYY-MM-DD-<slug>.md
│   │   └── systems/<slug>.md
│   └── ...
├── entities/        # team-canonical (admin-curated)
├── concepts/        # team-canonical
├── decisions/       # team-canonical
├── systems/         # team-canonical
├── people/          # one person per file (myo.md, sean.md, ...)
└── projects/syrs/   # legacy syrs-meta namespace (kept read-only)
```

- Each teammate writes **only** under `agents/<agent>/`. Concurrent runs do not collide.
- Cross-agent canonical entities (e.g. `묘님`, `션`, `시그니처세트`, `GA4`, `COSMAX`) get promoted into `shared/wiki/entities/` by admin (patch). After promotion, agent pages link to the canonical; Obsidian `aliases` handles the legacy link rewrite automatically.
- Team-canonical folders are **append-only from admin** until an explicit dedup run (see [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md)).

## 4. Validation

A promotion or daily-copy is compliant iff all hold:

- `[[<link>]]` targets resolve to an actual file or a frontmatter alias — zero broken links.
- No forbidden tree edges (§1).
- Copied daily body byte-equivalent to the raw capture (mtime + SHA check).
- Namespace rule (§3): writes from agent X are only under `agents/X/`.
- Obsidian `aliases` frontmatter on canonical entity pages covers every legacy slug (see entity lifecycle).

Ongoing validators:

- `agb knowledge validate` — link integrity + namespace rule.
- `agb knowledge validate --dedup` — zero duplicate aliases across entity files.
- `agb knowledge promote --llm-review` — before writing, LLM flags tree-edge antipatterns.

## 5. Quick reference — what to do day-to-day

| Situation | Action |
|---|---|
| Write a daily note | In agent's `memory/YYYY-MM-DD.md`. Add `## Related (auto-wiki)` only when the day has durable cross-refs. |
| Promote a daily to wiki | Let `bridge-knowledge promote --graph-mode` do it. Do not hand-edit the copied body. |
| Record a cross-agent entity | Write under `agents/<self>/entities/<slug>.md`. Admin promotes to `shared/wiki/entities/<slug>.md` on next curation pass. |
| Record a team decision | Under `agents/<self>/decisions/YYYY-MM-DD-<slug>.md` with `## Participants` + people links. |
| Reference a teammate | `[[myo|묘님]]` or `[[sean|션]]` — per-person file, with display alias. |
| Reference an index page | Only from `index.md` for navigation. Don't link from daily into an index. |

## 6. Changelog

- 2026-04-19: initial ratified version. Promoted from `shared/upstream-candidates/2026-04-19-wiki-graph-build-rules.md` §§1–3. Rollout plan (§5 of candidate) kept as operational task list in that file; runtime policy canonicalized here. Audit-override clause added.
