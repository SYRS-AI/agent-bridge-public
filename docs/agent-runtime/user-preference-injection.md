# Agent Runtime — User Preference Auto-Injection

> Canonical SSOT for promoting user feedback into agent runtime overhead (`ACTIVE-PREFERENCES.md`). Defines detection, scoping, lifecycle, and the `CLAUDE.md` pointer integration.
>
> Promoted from `shared/upstream-candidates/2026-04-19-user-preference-auto-overhead-injection.md`.
>
> Related: [`common-instructions.md`](common-instructions.md), [`admin-protocol.md`](admin-protocol.md), [`memory-schema.md`](memory-schema.md).

## 1. Problem

When a user tells an agent "from now on do X" (a *persistent preference*, not a one-shot instruction), today's pipeline only captures that inside the current session's memory. Next session — possibly a different agent on the same host — loses the instruction. Claude Code auto-memory (`~/.claude/projects/<slug>/memory/`) is agent-home-scoped and not auto-loaded unless `CLAUDE.md` references it.

Real incident (2026-04-19 patch session, ref evidence in the candidate file): Sean said "if a question needs an answer and there's no answer, escalate via Discord." That is a persistent comms protocol. Today it lives only in patch's local feedback memory. Next session on patch or any other agent re-learns nothing.

## 2. Solution — the third layer

Add a promotion layer between feedback memory and runtime overhead:

```
feedback memory (short-term, agent-local)
        ↓  promote (detected or explicit)
ACTIVE-PREFERENCES.md (middle — overhead-injected rule)
        ↑  loaded every session via CLAUDE.md pointer
```

Two scopes:

- **Agent-local**: `agents/<agent>/ACTIVE-PREFERENCES.md`. Loaded only by that agent's `CLAUDE.md` pointer.
- **Team-wide**: `docs/agent-runtime/active-preferences.md`. Loaded by `common-instructions.md` pointer (i.e., by every agent).

Team-wide promotion **requires admin approval** — see §6.

## 3. Detection heuristics

A feedback memory entry becomes a promotion candidate when any of these signals fire:

### 3.1 Explicit user signal

- User says "앞으로", "항상", "계속", "매번", "이후로", "from now on", "whenever", "always do", "never do", "이거 앞으로 계속 해" or semantically equivalent.
- User uses imperative future tense with no scope limiter ("do X when Y happens" where Y is generic, not "today's task").

### 3.2 Structural signal

- `bridge-memory capture --kind feedback` entry has a non-empty `## How to apply` section.
- The feedback body has a "rule" shape: single-sentence directive + reasoning.

### 3.3 Frequency signal

- `agent-bridge memory reconcile` detects the same preference has been captured ≥ 2 times across days or sessions.

Any of the three above creates a **candidate**. Admin (or the agent itself, for agent-local scope) confirms before writing to `ACTIVE-PREFERENCES.md`.

## 4. Entry format

Every preference entry (agent-local or team) follows this structure:

```markdown
## <short rule title> (YYYY-MM-DD, scope: agent|team)

**Rule:** <one-line rule, imperative>
**Why:** <reason / incident / user quote>
**How to apply:** <trigger condition + action>
**Source:** memory/feedback_<slug>.md
```

- The `## <title>` is the grep-able anchor. Keep it short.
- `Rule` is a single line; if multiple actions needed, use bullets under it.
- `Source` points at the original feedback file. Never lose provenance.

## 5. CLAUDE.md pointer integration

After PR 1 (pointer-only template), the `CLAUDE.md` read-order list includes `ACTIVE-PREFERENCES.md` as an optional pointer. If the file does not exist yet (no preferences promoted), `CLAUDE.md` silently skips it.

```markdown
## 세션 시작 시 읽을 파일 (순서)

1. `COMMON-INSTRUCTIONS.md`
2. (admin 세션만) `ADMIN-PROTOCOL.md`
3. `MEMORY-SCHEMA.md`
4. `ACTIVE-PREFERENCES.md` (있으면)                          ← 새 pointer
5. `SOUL.md`
6. `MEMORY.md` 및 `memory/`
7. `NEXT-SESSION.md` (있을 때만)
8. `SESSION-TYPE.md`
```

Team-wide preferences are pulled in automatically because `common-instructions.md` includes a pointer to `active-preferences.md` at the same level. Each agent only sees:

- The team-wide `docs/agent-runtime/active-preferences.md` (via `COMMON-INSTRUCTIONS.md`).
- Its own `agents/<agent>/ACTIVE-PREFERENCES.md`.

Other agents' agent-local preferences are **not** visible — that's the point.

## 6. Admin gate for team-wide promotion

An agent-local preference becomes team-wide only through admin.

Steps:

1. Non-admin agent detects candidate → files it under its own local `ACTIVE-PREFERENCES.md` (no admin needed).
2. If it judges the preference should be team-wide, it creates a task to admin: `agent-bridge task create --to <admin> --title "[preference-promote] <rule>" --body "<entry>"`.
3. Admin reviews. If approved, admin appends to `docs/agent-runtime/active-preferences.md` (edits the file directly — it's a canonical doc).
4. Admin removes the team-scoped duplicate from the originating agent's local file (keep `canonical_from` pointer in a comment).
5. Admin posts a short team note in the relevant shared channel so other agents pick it up on their next session.

Direct-edit by non-admin agents of `docs/agent-runtime/active-preferences.md` is prohibited.

## 7. Lifecycle

### 7.1 Write

- On promotion, mark the original feedback memory file:

  ```yaml
  ---
  promoted_to: agents/<agent>/ACTIVE-PREFERENCES.md#<rule-title>
  promoted_at: 2026-04-19T11:45:00Z
  ---
  ```

  This prevents re-detection of the same preference.

### 7.2 Review (90 days)

- Every preference has an implicit 90-day review window. `agent-bridge memory lint` flags entries older than 90 days for admin review.
- Default disposition on no-response: keep active. Explicit admin action to archive/remove.
- Archive: move to `agents/<agent>/ARCHIVED-PREFERENCES.md` with `archived_at: <ts>` line.

### 7.3 Conflict (reconcile)

- If a new preference contradicts an active one, `agent-bridge memory reconcile` flags both for admin.
- Default: latest wins (activate newest, archive older). Admin can override.
- Archive entries keep `conflict_with: <new-rule-title>` for audit.

### 7.4 Remove

- User says "stop doing X" → remove the rule immediately + archive with reason.
- Rule becomes obsolete (system/product no longer exists) → admin archives on quarterly review.

## 8. Detection CLI (to land with Track 3 PR)

```sh
agent-bridge memory promote-candidates --kind feedback
    # scans all feedback memory for promotion signals; outputs candidate list

agent-bridge memory promote --kind feedback --target overhead --scope agent <slug>
agent-bridge memory promote --kind feedback --target overhead --scope team <slug>
    # --scope team requires --admin-approved flag

agent-bridge memory lint
    # lists preferences older than 90 days + flagged conflicts
```

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Over-promotion (one-shot captured as persistent) | Heuristics conservative. Default: present candidate; require agent or admin to confirm. Never auto-promote without confirmation. |
| Agent-local ↔ team scope confusion | `scope:` field in every entry is mandatory. CLI rejects entries without scope. |
| Unintended reach of team-wide preference | Admin-only gate. Post-promotion team note. Any agent can flag via `reconcile`. |
| Stale preferences accumulate | 90-day lint + quarterly admin review. |
| Claude Code auto-memory vs bridge-memory ambiguity | Canonical source is bridge-memory (`memory/feedback_*.md`). Claude Code auto-memory is mirrored from it. See open question below. |

## 10. Open questions (tracked in upstream candidate)

- Does Claude Code auto-memory need to be read-only mirrored from bridge-memory, or does it stay a separate system with a boundary doc? Current bias: boundary doc, let the two coexist.
- 90-day window — configurable per agent? Default yes, override via `agent.json`.
- Preference templates for common classes (escalation, reporting format, language, tone) — stretch goal; not in initial ratification.

## 11. Changelog

- 2026-04-19: initial ratified version. Promoted from `shared/upstream-candidates/2026-04-19-user-preference-auto-overhead-injection.md`. Integrated into the `docs/agent-runtime/` canonical set with cross-references to `common-instructions.md`, `admin-protocol.md`, and `memory-schema.md`. `CLAUDE.md` pointer integration spec'd. Admin gate for team scope promotion made explicit.
