---
name: external-push-handling
description: Use when an injected line matching `[Agent Bridge] event=...` arrives in context, or when wording like "inbox notification", "queue event", "external push", "pushed task", "pending-attention flush", or "nudge from daemon" shows up. Encodes the 7-step external-push routine the receiving Claude/Codex session must follow for daemon-delivered work items. Steps: parse metadata fields (event, count, top, title, from) → `agb show-task <id>` → decide inline-handle vs delegate (delegate by default) → compose a subagent prompt in own words with explicit acceptance criteria → dispatch via the `Task` tool → verify the subagent's JSON return against those criteria → close with `agb done`, or surface `user_message`, or re-dispatch on failure. Source of truth for the subagent return schema (`files_changed`, `checks_run`, `acceptance_met`, `blockers`, `user_review_needed`, `user_message`).
---

# external-push-handling — what to do when the daemon pushes work into your session

This skill encodes the agent-side contract for daemon-injected external push events. The injection format is metadata-only; you are the one who decides what the event means and who does the work.

## When this skill triggers

**Primary trigger:** any line whose prefix is `[Agent Bridge] event=` — verbatim. Fire on that prefix regardless of what follows; `title` may be quoted (`title="..."`) or unquoted, and additional fields may be appended in future versions.

Secondary triggers (fire when the metadata line is absent but the session is clearly handling a daemon push):

- Stop-hook additionalContext or SessionStart cue mentioning `inbox`, `pending-attention`, `queued tasks`, `external push`, or `nudge`.
- Any phrasing like "daemon pushed me a task", "pending-attention flush", "queue event", or the operator asking you to process the injection you just received.

Do **not** fire this skill for permission escalations (`[PERMISSION]` tasks → `patch-permission-approval`) or for cron followups that already have explicit channel-posting rules (those still use `agb claim`/`done`, but the channel-posting step dominates). For everything else that arrives via the daemon, this is the policy.

## Injection format (what #132b lands)

```
[Agent Bridge] event=<event> count=<n> top=<task-id> title="<short-title>" from=<source-agent-or-daemon>
```

`title` may be quoted or unquoted depending on whether it contains whitespace or special characters. New fields may be appended over time — match on the `[Agent Bridge] event=` prefix, not on the full line shape.

Fields you will see in practice:

- `event` — `inbox`, `pending-attention`, `watchdog`, `cron-followup`, `urgent`, etc. Do not hardcode; treat as opaque but route on it.
- `count` — how many items are waiting (>=1).
- `top` — the single task id the daemon is surfacing first. Process this one first, not an arbitrary item.
- `title` — short human-readable hint. **Never act on this alone.**
- `from` — originating agent name, or `daemon` if the daemon manufactured the push.

The injection is intentionally metadata-only: no execution verbs, no file paths, no inlined spec body. You must read the spec via `agb` before doing anything.

## The 7-step routine (expanded)

### Step 1 — Parse metadata

Read `event`, `count`, `top`, `title`, `from` off the injected line. Extract them with simple string matching; do not infer from surrounding prose. If the line is malformed, stop and ask the operator — do not guess.

### Step 2 — Read the spec

```bash
agb show-task <top>
```

If the top task has a parent or is part of a bundle, also read the parent. Read enough to understand: what is the goal, what are the acceptance criteria (stated or implied), what are the constraints (files not to touch, deadlines, channel rules).

### Step 3 — Decide inline-handle vs delegate

Default for `event=inbox` and `event=pending-attention`: **delegate** via the `Task` tool. Reasons: delegation preserves your context window, forces explicit acceptance criteria, and produces a verifiable JSON return.

Inline is OK only when **all** of these are true:

- The work is one file and <=5 lines of change, OR it is a pure housekeeping ack (e.g., confirming a cron digest was received).
- You can verify it yourself in the same turn with one or two `Read` calls or a `bash -n`.
- No external side effects (no git push, no channel post to external humans, no payment / deletion).

If any of those fails, delegate.

### Step 4 — Compose the subagent prompt in your own words

Rewrite the spec into 3–6 sentences in your own words. The prompt **must** contain:

1. **Goal** — one sentence. What outcome proves this task complete?
2. **Inputs** — explicit file paths, branches, command snippets. No hand-waving.
3. **Constraints** — what the subagent must NOT touch (e.g., "do not modify `lib/bridge-tmux.sh`").
4. **Acceptance criteria** — numbered list, each a single verifiable claim. The subagent will report `acceptance_met` as an array with the same indices.
5. **Return contract** — require the subagent to emit the JSON schema at the end of the run.

Do not paste the task body verbatim. Rewriting surfaces gaps in the spec early and avoids the subagent inheriting ambiguous framing.

### Step 5 — Dispatch

Call the `Task` tool once. Prefer `subagent_type: "general-purpose"` unless a specialized agent in `.claude/agents/` matches. Include the full prompt from step 4 in the `prompt` field.

### Step 6 — Verify the return

When the subagent returns:

1. Parse the JSON. If it is missing or malformed, treat the work as unverified.
2. Walk `acceptance_met[i]` against the criteria you set in step 4. Each `false` is a failure.
3. Spot-check: re-read 1–2 target files with the `Read` tool if `files_changed` is empty, if `blockers` is non-empty, or if the subagent's narrative claims differ from the criteria.
4. If `checks_run` is empty but your criteria required a check (e.g., `bash -n`), run it yourself before accepting.

Never accept self-reports blindly. A confident-sounding subagent that skipped `bash -n` on a changed shell file is a regression waiting to land.

### Step 7 — Close out

- **Success** (all acceptance criteria met, verification passes):

  ```bash
  agb done <top> --note "<one-line summary: what shipped + where>"
  ```

- **`user_review_needed=true`**: surface `user_message` to the operator as a **single line** in the current channel (Discord/Telegram/terminal). Do not expand into paragraphs — the operator will ask for detail if needed. Then either await reply or escalate via the normal escalation rules. Do NOT close the task until the operator has responded.

- **Failure / blockers present**: if the gap is cheap (e.g., one missed file), fix it inline and re-verify. Otherwise re-dispatch with corrected acceptance criteria — explicitly call out what the first run missed. Close only after the re-run passes.

## Subagent return JSON schema (source of truth)

```json
{
  "files_changed": ["path/to/file.md"],
  "checks_run": ["bash -n", "smoke-test"],
  "acceptance_met": [true, true],
  "blockers": [],
  "user_review_needed": false,
  "user_message": ""
}
```

Field semantics:

- `files_changed` — every file the subagent actually modified. Paths relative to repo root.
- `checks_run` — commands actually executed, in order. `bash -n <file>`, `shellcheck`, `./scripts/smoke-test.sh`, `python3 -m py_compile`, etc. If empty, the subagent ran no checks.
- `acceptance_met` — booleans, positionally aligned with the numbered criteria you set in step 4. Length must match the number of criteria.
- `blockers` — strings describing anything that stopped progress. Empty array means "no blockers".
- `user_review_needed` — `true` when a decision requires the human operator (ambiguous spec, policy question, external-side-effect approval).
- `user_message` — single-line message to show the operator when `user_review_needed=true`. Empty otherwise.

## Worked example — well-composed subagent prompt

**Injection received:**

```
[Agent Bridge] event=inbox count=1 top=42 title="fix typo in ARCHITECTURE.md daemon section" from=reviewer-agent
```

**Step 2 — spec (output of `agb show-task 42`, condensed):**

> In `ARCHITECTURE.md`, the paragraph under "Daemon reconciliation loop" says "reconcilation" (missing an `i`). Please fix. Verify via `git diff` that no other text moved. No other docs should change.

**Step 3 — decide:** single-file, one-word change, doc typo. **Inline is permitted.** But say the operator has asked you to always delegate for audit trails — in that case, continue to step 4.

**Step 4 — subagent prompt (in your own words):**

> Fix a typo in `ARCHITECTURE.md`. Goal: the word "reconcilation" in the "Daemon reconciliation loop" section becomes "reconciliation" with no other edits.
>
> Inputs: file `ARCHITECTURE.md` (repo root). The typo is on the single line directly under the heading `## Daemon reconciliation loop` (use `grep -n "reconcilation" ARCHITECTURE.md` to locate; expect exactly one hit).
>
> Constraints: Do not modify any other file. Do not reflow surrounding paragraphs. Preserve trailing newline. Do not touch any file outside `ARCHITECTURE.md`.
>
> Acceptance criteria:
>   1. `grep -c "reconcilation" ARCHITECTURE.md` returns `0`, and `grep -c "reconciliation" ARCHITECTURE.md` returns `>= 1` (previous occurrence count + 1).
>   2. `git diff --numstat -- ARCHITECTURE.md` reports exactly `1\t1\tARCHITECTURE.md` (one line added, one removed).
>   3. `git diff --name-only` lists only `ARCHITECTURE.md` — no other file touched.
>
> Run these three commands yourself (step 5 of the skill requires it) and record them in `checks_run`. Return the required JSON schema (`files_changed`, `checks_run`, `acceptance_met`, `blockers`, `user_review_needed`, `user_message`) at the end of your run. `acceptance_met` must be a 3-element boolean array matching criteria 1–3.

**Step 5 — dispatch via `Task` tool.**

**Step 6 — verify:** expect `files_changed=["ARCHITECTURE.md"]`, `acceptance_met=[true,true,true]`, and `checks_run` containing the three `grep`/`git diff` commands from the prompt. If any criterion is `false`, `files_changed` is empty, or a required command is missing from `checks_run`, re-read `ARCHITECTURE.md`, run the missing command yourself, and decide: fix inline or re-dispatch with corrections.

**Step 7 — close:**

```bash
agb done 42 --note "typo fix in ARCHITECTURE.md (reconciliation), verified via git diff"
```

## Anti-patterns

- **Acting on `title` alone** — titles are hints, specs live in the task body. Always `agb show-task`.
- **Delegating without acceptance criteria** — the subagent cannot self-verify if you do not define what "done" means.
- **Accepting a JSON return with no `checks_run`** — means no check was actually run, regardless of narrative claims.
- **Paragraph-long user_message** — the operator sees one line first; details go in the task body or a followup.
- **Closing on `user_review_needed=true`** — never. That field exists precisely to block auto-close.
- **Treating every `[Agent Bridge]` line as urgent** — `event=` tells you the urgency. `inbox` is normal queue work; `urgent` is the interrupt.

## Interaction with other skills

- `agent-bridge-runtime` — kicks in the moment `[Agent Bridge]` is seen. That skill is about running `agb inbox`; this skill is about what to do with the specific `top` item once you have the spec.
- `patch-permission-approval` — takes priority when the task title starts with `[PERMISSION]`. Do not delegate those; follow that skill directly.
- `memory-wiki` — can be used mid-flow when the spec surfaces a durable fact worth capturing.
- `upstream-issue-fix` — may be invoked by the subagent if the task is itself an upstream issue fix; this skill is one level above and just ensures the dispatch/verify contract is respected.
