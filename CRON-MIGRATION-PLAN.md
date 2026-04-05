# Cron Migration Plan

## Goal

Migrate legacy OpenClaw recurring cron jobs into Agent Bridge so that:

1. schedule detection happens in Agent Bridge
2. due jobs become bridge queue tasks
3. heavy cron execution runs through disposable child workers
4. parent agents remain the authority for follow-up and delivery

This plan focuses on **recurring jobs first**.

Current snapshot on 2026-04-05:

- recurring jobs: 103
- enabled recurring jobs: 96
- disabled recurring jobs: 7
- schedule kinds in recurring set:
  - `cron`: 100
  - `every`: 3

## Execution Model

All migrated recurring jobs should use the same bridge shape:

1. `cron sync` detects a due occurrence
2. the bridge enqueues a `[cron-dispatch]` task with an explicit slot
3. the bridge daemon claims that dispatch task
4. the daemon runs `agent-bridge cron run-subagent <run-id>` in a disposable child
5. the disposable child returns a structured result artifact
6. the daemon closes the dispatch task and optionally emits a separate `[cron-followup]` task if human follow-up is still needed

This keeps recurring work out of long-lived agent contexts while still allowing
selective follow-up when a child run surfaces something a durable agent session
should inspect.

## Foundation Changes

These repo changes are required before broad rollout:

1. Remove the current family allowlist default so `cron enqueue` can bridge any enabled recurring job.
2. Add `agent-bridge cron sync` so Agent Bridge itself can detect due jobs from `~/.openclaw/cron/jobs.json`.
3. Add daemon integration so each daemon cycle can run `cron sync` before queue nudge / auto-start processing.
4. Add bridge-owned scheduler state under `state/cron/` so missed daemon cycles can catch up without duplicate enqueue.
5. Keep one-shot migration separate from this recurring rollout.

## Scheduler Design

### Source Of Truth

- Job definitions remain in legacy `jobs.json` during migration.
- Agent Bridge becomes the runtime that decides when to enqueue due recurring jobs.

### Supported Schedule Kinds

- `cron`
- `every`

One-shot `at` jobs are out of scope for this first recurring migration wave.

### Slot Rule

Every due occurrence gets an explicit slot derived from the scheduled occurrence
time, not from the family name.

Examples:

- daily/minutely cron: `2026-04-05T15:30+09:00`
- hourly `every`: `2026-04-05T16:00:00+09:00`

The existing manifest/request dedupe then prevents duplicate dispatch tasks.

### Catch-Up Rule

- The scheduler stores the last bridge scan time in bridge state.
- On each daemon cycle it scans the missed window between the previous scan and `now`.
- On first bootstrap, it uses a short lookback window only. It must not backfill months of historical jobs by default.

## Roster Mapping

The migration target is the **bridge roster id**, not the legacy OpenClaw session target.

Current enabled recurring jobs map cleanly by agent id:

- `huchu -> huchu`
- `mailbot -> mailbot`
- `main -> main`
- `max -> max`
- `newsbot -> newsbot`
- `patch -> patch`
- `reedy -> reedy`
- `syrs-buzz -> syrs-buzz`
- `syrs-calendar -> syrs-calendar`
- `syrs-creative -> syrs-creative`
- `syrs-cs -> syrs-cs`
- `syrs-derm -> syrs-derm`
- `syrs-fi -> syrs-fi`
- `syrs-meta -> syrs-meta`
- `syrs-production -> syrs-production`
- `syrs-satomi -> syrs-satomi`
- `syrs-shopify -> syrs-shopify`
- `syrs-sns -> syrs-sns`
- `syrs-trend -> syrs-trend`
- `syrs-video -> syrs-video`
- `syrs-warehouse -> syrs-warehouse`

If a future legacy job uses a divergent agent id, it should be handled through
`BRIDGE_OPENCLAW_AGENT_TARGET`.

## Rollout Waves

### Wave 0: Foundation

Implement first:

- generic recurring `cron enqueue`
- `cron sync`
- daemon integration
- scheduler state / catch-up
- no-op handling for missing legacy `jobs.json`

### Wave 1: Proven Shared Families

These already have strong adapter confidence and should move first:

- `memory-daily` (22 jobs)
- `monthly-highlights` (19 jobs)

Reason:

- already adapted
- already e2e tested through disposable child workers
- highest leverage across many agents

### Wave 2: Main / Huchu Orchestrator Families

These are higher risk because they drive family-facing follow-up or approvals:

- `morning-briefing` (3)
- `evening-digest` (3)
- `weekly-review` (1)
- `event-reminder` (1)
- `approval-reminder` (1)
- `task-reconcile` (1)
- `team-weekly-insights` (1)
- `calendar-sync` (1)
- `daily-medicine-reminder` (1)
- `huchu-weekly-marketing-review` (1)
- `google-watch-renewal` (1)
- `iran-crisis-monitor` (1)
- `쭈책 알림 (오전)` (1)
- `쭈책 알림 (저녁)` (1)
- `🍚 쌀 주문 리마인더 (묘님)` (1)

Reason:

- these are the most user-visible and orchestration-heavy
- they should move only after the scheduler path itself is stable

### Wave 3: Vertical SYRS Operations Families

Move the business-agent recurring families next:

- `abandoned-checkout-sync`
- `campaign-dday-alerts`
- `cs-daily-summary`
- `cs-line-poll-5m`
- `daily-fi-sync`
- `daily-formulation-research`
- `derm-daily-research`
- `fi-auto-match`
- `granter-vendor-sync`
- `judgeme-review-monitor`
- `memory-enforce`
- `meta-ads-hourly-monitor`
- `meta-db-daily-sync`
- `monthly-close`
- `monthly-event-research`
- `monthly-inventory-snapshot`
- `sentry-daily-errors`
- `shopify-daily-monitor`
- `sns-ugc-monitor-3x`
- `stock-reconciliation`
- `sync-abandoned-audience`
- `sync-customer-audience`
- `tax-invoice-check`
- `token-refresh`
- `tracx-d4-fallback`
- `warehouse-daily-monitor`
- `weekly-customer-health`
- `weekly-fi-report`
- `weekly-unpaid-alert`
- `미처리 주문 알림`
- `📡 소문이 일일 브랜드 모니터링`

Reason:

- these are mostly single-agent operational jobs
- they benefit from the same child-worker isolation without requiring family-facing delivery logic

### Wave 4: Research / Feed Families

Move lower-frequency or less coupled content jobs after the core ops are stable:

- `Enterprise SW & AI 뉴스 리서치 (점심 12시)`
- `SpaceX IPO 모니터링`
- `점심 트렌드 피드 - 묘님`
- `점심 트렌드 피드 - 션`

### Wave 5: Disabled Legacy Recurring Jobs

Do not auto-enable these during the first migration.

Keep them explicitly disabled and document them as archived / operator-review:

- `Enterprise SW & AI 뉴스 리서치 (오전 8시)`
- `fi-payment-matcher`
- `gog-sync`
- `metabot-ads-monitor-4x`
- `봄캠페인-1h정기체크`
- `이란 사태 속보 모니터링`
- `한국 증시 브리핑`

## Migration Order By Agent

If validation is easier agent-by-agent after the shared waves, use this order:

1. `main`
2. `huchu`
3. `patch`
4. `mailbot`
5. `syrs-shopify`
6. `syrs-meta`
7. `syrs-fi`
8. `syrs-warehouse`
9. `syrs-cs`
10. `syrs-calendar`
11. `syrs-derm`
12. `syrs-sns`
13. `syrs-buzz`
14. `syrs-trend`
15. `syrs-video`
16. `syrs-creative`
17. `syrs-production`
18. `syrs-satomi`
19. `reedy`
20. `max`
21. `newsbot`

## Validation Plan

Per wave:

1. `cron sync --dry-run`
2. one real enqueue via bridge
3. `run-subagent` result artifact check
4. target agent dispatch task closure
5. parent follow-up verification by Patch

Per scheduler rollout:

1. daemon cycle creates due dispatch task without operator intervention
2. duplicate daemon cycles do not create duplicate dispatch tasks
3. on-demand target auto-start still works
4. daemon restart catch-up works within the configured bootstrap window

## Out Of Scope For This First Review

- automatic migration of one-shot `at` jobs
- rewriting legacy `jobs.json` into a bridge-native cron config format
- replacing all legacy delivery semantics in one sweep

Those should come after recurring migration is stable.
