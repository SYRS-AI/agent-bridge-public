# Agent Runtime — Wiki System Onboarding

> Step-by-step for a fresh Agent Bridge install (or an existing one that
> just upgraded to v0.4.0+) to bring up the full wiki-graph automation
> pipeline end to end. Treat this as the canonical onboarding checklist.
>
> Related: [`wiki-graph-rules.md`](wiki-graph-rules.md), [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md), [`wiki-mention-index.md`](wiki-mention-index.md), [`memory-schema.md`](memory-schema.md).

## Who runs this

Admin-agent-class: this is patch's job on the SYRS reference install,
but any admin role with access to `agb cron`, `agb agent`, and write
access to `<bridge-home>/scripts/` is valid. A per-team analog to
patch.

## What it assumes

- Agent Bridge v0.4.0 or later is installed at `<bridge-home>` (default
  `~/.agent-bridge/`).
- At least one Claude-engine agent is active. The wiki pipeline works
  with Codex-engine agents too, but the librarian + watchdog flow
  currently expects Claude for the promote step.

## Steps

### 1. Run bootstrap

```bash
<bridge-home>/bootstrap-memory-system.sh --dry-run    # preview
<bridge-home>/bootstrap-memory-system.sh --apply       # commit
```

This does five things, all idempotent:

1. **Scripts install** — copies every wiki/librarian/sync script from
   the ships dir into `<bridge-home>/scripts/`.
2. **PreCompact hook** — registers the compact-time capture hook on
   every active Claude agent (Track 2).
3. **V2 hybrid index** — rebuilds each agent's `bridge-wiki-hybrid-v2`
   search index (Track 3).
4. **Librarian provision** — creates the dynamic `librarian` agent
   if it is not already provisioned. The librarian drains the Lane B
   `[librarian-ingest]` queue; without it, `wiki-daily-ingest` would
   fall back to queueing the admin directly. Idempotent: running
   bootstrap twice never creates a duplicate agent.
5. **Crons** — registers the full cron set on the admin agent (default
   `patch`, override with `BRIDGE_ADMIN_AGENT` env):
    - `wiki-weekly-summarize` (Sun 22:00 KST)
    - `wiki-monthly-summarize` (1st 02:00 KST)
    - `wiki-repair-links` (Sat 05:00 KST)
    - `wiki-v2-rebuild` (Sat 06:00 KST)
    - `wiki-dedup-weekly` (Sun 04:00 KST)
    - `wiki-daily-ingest` (03:00 KST daily)
    - `wiki-mention-scan` (hourly :17)
    - `librarian-watchdog` (*/10 min)
    - `wiki-hub-audit` (Thu 23:00 KST)
6. **Report** — writes `state/bootstrap-memory/report-<stamp>.json`
   with per-step status. Re-running shows `already-registered` for
   cron rows once the install is in the desired state.

If any step says `conflict`, the existing cron schedule differs from
the expected one. Inspect with `agb cron show <id>` and decide whether
to update or leave as is.

### 2. First full mention scan

```bash
<bridge-home>/scripts/wiki-mention-scan.py --full-rebuild
<bridge-home>/scripts/wiki-mention-scan.py --report --out \
  <bridge-home>/shared/wiki/_index/distribution-report-$(date +%Y-%m-%d).md
```

The full rebuild is only needed once. After that the hourly cron
(:17) keeps `<bridge-home>/shared/wiki/_index/mentions.db` incremental.

### 3. Inspect the distribution

Open the distribution report. The five sections tell you:

- §1 cross-agent reach — who/what is mentioned across the most agents.
- §2 cross-agent + no hub — **Phase 2 candidacy candidates.** These
  are the entities that deserve a shared canonical hub in
  `<bridge-home>/shared/wiki/entities/`.
- §3 unresolved wikilinks — stubs to create, or link typos to fix.
- §4 orphan slugs — declared entities that no one references. Review
  for deletion per [`wiki-entity-lifecycle.md`](wiki-entity-lifecycle.md) §3.6.
- §5 agent activity — sanity check that daily notes are flowing.

### 4. Build the initial canonical hubs

The weekly `wiki-hub-audit` cron (Thu 23:00 KST) emits a
`[wiki-hub-candidates]` task to the admin agent with a pre-filtered
list of entities that meet the cross-agent threshold but lack a shared
hub. You can trigger it manually the first time:

```bash
<bridge-home>/scripts/wiki-hub-audit.py \
  --emit-task \
  --admin-agent patch \
  --bridge-bin <bridge-home>/agent-bridge \
  --out <bridge-home>/shared/wiki/_audit/hub-candidates-$(date +%Y-%m-%d).md
```

The admin agent's processing contract for this task is documented in
[`admin-protocol.md`](admin-protocol.md) — "Wiki Canonical Hub
Curation". In short: review the candidate list, decide per entity
whether to promote / skip / defer, then author hubs for the approved
ones.

For each promoted candidate, author a canonical hub at
`shared/wiki/entities/<slug>.md` (or `shared/wiki/people/<slug>.md`
for a person). Follow the lifecycle doc:

- `type: entity` (or `person`) in the frontmatter
- `slug: <ascii-kebab>` matching the filename
- `aliases: [...]` covering every surface form (original script +
  romanized + casing variants)
- `canonical_from: [...]` listing the agent-scoped pages that this hub
  consolidates
- Body: concise role/summary, key facts, fanout links to the relevant
  agent-scoped daily/entities/concepts pages

If one or more agent namespaces already hold rich content about the
entity, convert the agent-scoped file into a redirect stub:

```markdown
---
type: redirect
slug: <same-slug>
redirect_to: entities/<slug>
---

# <title> (moved)

Canonical: [[<slug>]]
```

The L1 scanner's alias resolver (added 2026-04-19) automatically treats
redirects as pointers to `redirect_to`, so all `[[<slug>]]` references
route to the canonical without you touching each callsite.

### 5. Update `<bridge-home>/shared/wiki/index.md`

Add a `## Canonical Entity Hubs` section with links to the new hubs.
This becomes the entry point humans and agents use to browse the team
knowledge graph.

### 6. Daily-note hygiene propagation

Every agent reads `<bridge-home>/agents/<agent>/MEMORY-SCHEMA.md` on
session start. As of v0.4.0, the template's **Daily Note Hygiene**
section tells agents to close each daily note with a
`## Related (auto-wiki)` footer + tag line.

- On `agb upgrade`, `bridge-docs.sync_agent_docs()` now propagates the
  template schema to every agent home automatically. No manual run
  needed.
- If you need an out-of-cycle sync (e.g. right after editing the
  template), run:
    ```bash
    <bridge-home>/scripts/sync-memory-schema.py --apply
    ```
    It keeps per-agent pre-sync backups.

### 7. Verify end-to-end

```bash
# Daily files in wiki match agent memory homes?
<bridge-home>/scripts/wiki-daily-ingest.sh    # Lane A copy + Lane B queue

# Scanner picks up any new files?
<bridge-home>/scripts/wiki-mention-scan.sh

# Librarian drains any non-daily captures?
agb inbox librarian
```

## Phase status

- **Phase 1 observation (L1)** — **shipped.** `wiki-mention-scan`
  runs hourly, `mentions.db` stays fresh, distribution report
  regenerates every tick.
- **Phase 2 candidacy (L2)** — **shipped.** `wiki-hub-audit` runs
  weekly (Thu 23:00 KST), emits `[wiki-hub-candidates]` tasks to the
  admin agent with pre-filtered hub candidates + sample source paths.
  Default thresholds `min_agents=2, min_mentions=5` are conservative
  on purpose; per-install operators can tune them at the cron payload
  level once they have two weeks of distribution data.
- **Phase 3 enrichment** — deferred. Librarian LLM-synthesizes
  current-state summaries into existing hubs instead of static
  pointer pages. Needs a rate-limit + quality gate design before it
  can ship.

A stub hub ("Agent X is our content editor, see daily/ for details") is
already useful; full synthesis is an upgrade, not a blocker.

## Troubleshooting

- **Bootstrap `conflict` on cron rows**: an existing cron has a
  different schedule than the canonical value. Inspect with `agb cron
  show <id>`. If intentional (e.g. local tz override), no action. If
  unintentional, `agb cron update <id> --schedule "<expected>"`.
- **Daily notes not appearing in wiki**: check the Lane A copy output
  (`wiki-daily-ingest` cron log in `shared/wiki/_audit/ingest-*.md`).
  Agent memory files must be named `memory/YYYY-MM-DD.md` exactly.
- **`operating-rules.md` growing**: symptom of the pre-2026-04-19 bug
  where librarian fallback routed daily notes here. The v0.4.0
  librarian has two reject gates (Rule #8 for daily-shaped paths, Rule
  #9 for ambiguous kinds). Check librarian's audit log for unexpected
  promotes.
- **Mention scan shows lots of unresolved**: top unresolved surface
  forms are either typos or genuinely missing entities. For real
  entities, author a stub + add aliases. For typos, use `agb wiki
  repair-links --apply`.
