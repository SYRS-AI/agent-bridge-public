# Huchu Migration Readiness Audit

Updated: 2026-04-05
Scope: Phase 3 entry slice for `huchu` only
Status: audit complete, scaffold not started

## Recommendation

Do not jump straight to live cutover.

Use this order:

1. readiness audit
2. tracked `agents/huchu/CLAUDE.md` scaffold
3. live deploy smoke for `huchu`
4. short stabilization window
5. only then continue with the next SYRS agents

`main` is already cut over, so `huchu` is now the right next migration target. It is simpler than `main` in one important way: no Telegram surface. But it is also more tightly coupled to orchestration rules, Discord-side human-in-the-loop reporting, and cron-driven supervision. That means the cutover should preserve behavior, not just tone.

## Current Live Surfaces

### Workspace / Prompt Stack

Current live workspace: `/Users/soonseokoh/.openclaw/workspace-huchu`

Current prompt and operating files in that workspace:

- `AGENTS.md`
- `SOUL.md`
- `HEARTBEAT.md`
- `MEMORY.md`
- `STATUS.md`
- `USER.md` -> symlink to `../shared/SYRS-USER.md`
- `TOOLS.md` -> symlink to `../shared/TOOLS.md`
- `ROSTER.md` -> symlink to `../shared/ROSTER.md`
- `SYRS-CONTEXT.md` -> symlink to `../shared/SYRS-CONTEXT.md`
- `SYRS-RULES.md` -> symlink to `../shared/SYRS-RULES.md`
- `memory/WORKFLOW.md`

Observed startup contract from `AGENTS.md`:

1. read `SOUL.md`
2. read `USER.md`
3. read `MEMORY.md`
4. read `memory/syrs/CONTEXT.md`
5. read `memory/WORKFLOW.md`
6. read `ROSTER.md`
7. read `SYRS-RULES.md`

Operational note:

- `STATUS.md` is not part of the bootstrap stack, but it is still an active runtime surface because `AGENTS.md` explicitly tells `huchu` to use it as the live orchestration board while leaving `MEMORY.md` for session-end updates.

Implication: `huchu` is also a prompt-stack migration, not a single-file migration. In addition to identity and rules, it depends on a split operating model across `MEMORY.md`, `STATUS.md`, and `memory/WORKFLOW.md`.

### Agent Runtime State

Current agent runtime state exists under:

- `/Users/soonseokoh/.openclaw/agents/huchu/agent/`
- `/Users/soonseokoh/.openclaw/agents/huchu/sessions/`

Observed:

- per-agent auth/model state exists under `agent/`
- session archive is large: `sessions.json` currently tracks `201` session keys
- the archive is overwhelmingly cron-heavy:
  - `cron`: `197`
  - `discord:channel`: `2`
  - `discord:direct`: `1`
  - `main`: `1`

Implication: `huchu` is more schedule-driven than conversation-driven. The cutover must preserve cron-triggered orchestration and not disturb the existing session archive until the new CLI path is proven.

### Memory

Current memory dependencies:

- vector DB: `/Users/soonseokoh/.openclaw/memory/huchu.sqlite` (`1.2G`)
- workspace memory tree: `/Users/soonseokoh/.openclaw/workspace-huchu/memory/`
- curated current-state file: `/Users/soonseokoh/.openclaw/workspace-huchu/MEMORY.md`
- live status board: `/Users/soonseokoh/.openclaw/workspace-huchu/STATUS.md`

Implication: the Phase 2 read-only memory path is enough to avoid a memory blocker, but the cutover must preserve both the workspace memory tree and the status-board workflow.

## Communication Surfaces

### Discord

`huchu` is primarily a Discord-facing orchestrator.

Observed live session keys include:

- `agent:huchu:discord:channel:1476851878586482759`
- `agent:huchu:discord:direct:1476877944625565746`
- one additional historical Discord channel session key

Relevant config facts from `openclaw.json`:

- agent id `huchu` has `groupChat.mentionPatterns` for `@후추` and `@huchu`
- `channels.discord.accounts.huchu` exists with its own token
- `allowFrom` includes Sean (`313462920564703232`) and Myo (`1476877944625565746`)
- channel `1476851878586482759` is explicitly allowed with `requireMention=false`

Operational meaning:

- unlike `main`, `huchu` already has a dedicated Discord account configured
- the main Discord bot split problem is not a blocker for `huchu`
- the important migration risk is not token ownership, but preserving the reporting rules that currently depend on `openclaw message send`

### Telegram

No primary Telegram surface was observed for `huchu`.

Operational meaning:

- `huchu` is simpler than `main` because it does not need a family-facing Telegram cutover
- this reduces channel complexity, but not orchestration complexity

## Gateway / Skill Dependencies

### Huchu-Specific Skills From Registry

Current assigned skill set from `shared/TOOLS-REGISTRY.md`:

- `brand-assets`
- `clarity-api`
- `customer-master`
- `ga4-api`
- `gsc-api`
- `google-calendar`
- `meta-api`
- `production-db`
- `shopify-api`
- `syrs-commerce-db`
- `syrs-kpi-snapshot`
- `task-log`
- `team-pulse`
- `vendor-db`

### Dependency Classes

The important distinction is not just skill names, but how `huchu` currently uses them:

1. gateway-mediated messaging
   - `openclaw message send` to Discord channels and DMs
   - `sessions_send` for task delegation and direct A2A
2. orchestration state files
   - `MEMORY.md` as the stable board
   - `STATUS.md` as the live progress cache
   - `memory/WORKFLOW.md` as the routing / delegation ruleset
3. cron + reconciliation tooling
   - `approval-reminder`
   - `task-reconcile`
   - memory-daily / digest / weekly insight jobs
   - `task-log` reconciliation and Myo activity scanning

### Migration Notes By Dependency

- `openclaw message send`
  Current state: mandatory in `AGENTS.md` for #huchu channel output and Myo DM routing
  Migration path: translate to Claude Code Discord channel behavior and Bridge-native reporting rules

- `sessions_send`
  Current state: the core orchestration transport
  Migration path: replace durable delegation with Agent Bridge tasks and keep urgent paths explicit

- `task-log`
  Current state: part of the approval and reconciliation safety net
  Migration path: keep using the underlying scripts during first cutover; do not redesign logging and orchestration in the same slice

- analytics / data skills
  Current state: capability dependencies, not migration blockers
  Migration path: continue using the existing scripts and APIs from the same workspace during initial cutover

## Scheduled Workload

### Huchu Cron Footprint

Current `huchu` cron inventory:

- total filtered jobs for `huchu`: `8`
- recurring: `8`
- future one-shot: `0` in the filtered set
- current errors: `1`

Recurring families:

- `approval-reminder`
- `task-reconcile`
- `morning-briefing`
- `evening-digest`
- `memory-daily`
- `huchu-weekly-marketing-review`
- `team-weekly-insights`
- `monthly-highlights`

Current recurring error:

- `memory-daily-huchu` (`3` consecutive errors, last error `2026-04-05 00:17 KST`)

Important shape:

- `approval-reminder` and `task-reconcile` are not just content jobs; they are orchestration-control jobs
- `task-reconcile` explicitly scans for missed Myo activity and unreported events, then updates `MEMORY.md`
- `HEARTBEAT.md` also depends on the current project queue and pending states

Implication: `huchu` has fewer jobs than `main`, but more of them are structurally important to how the orchestrator stays correct. Do not bundle full cron migration into the first scaffold slice.

### Heartbeat

Current OpenClaw config declares:

- `huchu.heartbeat.every = 1h`

And `workspace-huchu/HEARTBEAT.md` contains:

- incomplete-task monitoring
- business-hours-only follow-up logic
- silence rules when there is no active project

Implication:

- `huchu` heartbeat is behaviorally important, not just informational
- treat workload heartbeat as cron/task migration work, not as part of the initial profile scaffold

## Relationship To Main

`huchu` should go after `main`, not before.

Reasons:

- `main` is already the newly stabilized family-facing endpoint
- `huchu` still has a historical `agent:huchu:main` session path in the archive
- some escalation / reporting expectations were shaped around the old gateway relationship to `main`

Now that `main` is live on Agent Bridge, the next migration question is whether `huchu` should report to `main`, to Myo directly, or to both through bridge-native rules. That belongs in the scaffold.

## Key Risks

### 1. Prompt Stack Spread With Operational Files

`huchu` depends on more than identity files:

- `SOUL.md`
- `AGENTS.md`
- `MEMORY.md`
- `STATUS.md`
- `memory/WORKFLOW.md`
- `SYRS-CONTEXT.md`
- `SYRS-RULES.md`
- `ROSTER.md`

Missing any of these would change orchestration behavior.

### 2. Deep Orchestration Coupling

`huchu` is built around:

- `sessions_send`
- direct A2A supervision
- approval tracking
- reconciliation
- human-in-the-loop reporting in Discord

This is the main migration risk. A weak scaffold would preserve the tone but break the operating model.

### 3. Cron Dependency

Most of `huchu`'s session archive is cron. This means behavioral regressions may first appear through scheduled workflows, not human conversation.

### 4. Discord Reporting Semantics

The current system depends on explicit channel / DM delivery rules, mention policy, and anti-duplication rules. Replacing the transport without preserving the reporting semantics would produce noisy or missing updates.

## Recommended Cutover Strategy

### Preferred

Keep the first `huchu` slice narrow:

1. readiness audit
2. tracked `agents/huchu/CLAUDE.md` scaffold
3. identify the bridge-native replacement rules for:
   - task delegation
   - urgent interrupts
   - #huchu progress reporting
   - Myo DM escalation
4. perform live deploy smoke only after the reporting model is explicit

### Phase 3 Next Slice

Create `agents/huchu/CLAUDE.md` from the audited prompt stack with these goals:

1. preserve `SOUL.md` identity and the orchestration gates
2. preserve the bootstrap order from `AGENTS.md`
3. explicitly translate gateway-era `sessions_send` / `openclaw message send` rules into Agent Bridge rules
4. call out `STATUS.md` as an operational file even though it is not bootstrap-loaded
5. keep cron migration out of the first scaffold slice

Candidate live profile target for the first scaffold:

- workdir: `/Users/soonseokoh/.openclaw/workspace-huchu`
- profile target candidate: `/Users/soonseokoh/.openclaw/workspace-huchu`

### Not In The First Scaffold Slice

Do not try to solve all of this at once:

- full cron transport migration
- replacement of every `task-log` / reconciliation behavior
- redesign of `team-pulse`
- the next SYRS agents

## Exit Criteria For Audit Slice

This audit slice is complete when:

- live prompt stack is identified
- live workspace and auth/session homes are identified
- channel dependencies are identified
- cron scale is identified
- the unique `STATUS.md` + workflow coupling is called out
- next slice is narrowed to `huchu` profile scaffold, not full cutover
