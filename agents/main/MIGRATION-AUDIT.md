# Main Migration Readiness Audit

Updated: 2026-04-05
Scope: Phase 3 entry slice for `main` only
Status: audit complete, scaffold not started

## Recommendation

Do not start with a direct live cutover.

Use this order:

1. readiness audit
2. tracked `agents/main/CLAUDE.md` scaffold
3. live deploy smoke for `main`
4. short stabilization window
5. `huchu` migration after `main` is stable

Given Sean already allows a temporary full-agent maintenance window, a short planned cutover is safer than a parallel half-migrated `main`. `main` is the highest-risk agent because it combines family messaging, orchestration, memory curation, and the densest cron set.

## Current Live Surfaces

### Workspace / Prompt Stack

Current live workspace: `/Users/soonseokoh/.openclaw/workspace`

Current prompt and memory files in that workspace:

- `AGENTS.md`
- `SOUL.md`
- `HEARTBEAT.md`
- `MEMORY.md`
- `USER.md` -> symlink to `../shared/SYRS-USER.md`
- `USER-MYO.md`
- `TOOLS.md` -> symlink to `../shared/TOOLS.md`
- `ROSTER.md` -> symlink to `../shared/ROSTER.md`
- `BOOTSTRAP.md`

Observed startup contract from `AGENTS.md`:

1. read `SOUL.md`
2. read `USER.md`
3. read daily memory files
4. read `MEMORY.md` in the main session
5. read `ROSTER.md`
6. pass DB preflight / compaction recovery gates

Implication: `main` is not just a single prompt file migration. It is a prompt stack migration.

### Agent Runtime State

Current agent runtime state exists under:

- `/Users/soonseokoh/.openclaw/agents/main/agent/`
- `/Users/soonseokoh/.openclaw/agents/main/sessions/`

Observed:

- per-agent auth/model state exists under `agent/`
- session archive is large: `sessions.json` currently tracks `187` session keys

Implication: the prompt/profile migration should not disturb the existing OpenClaw auth/session store until the new CLI path is proven.

### Memory

Current memory dependencies:

- vector DB: `/Users/soonseokoh/.openclaw/memory/main.sqlite` (`2.0G`)
- workspace memory tree: `/Users/soonseokoh/.openclaw/workspace/memory/`
- curated long-term file: `/Users/soonseokoh/.openclaw/workspace/MEMORY.md`

Implication: memory is not a blocker because Phase 2 already produced a read-only bridge search path. But the cutover must preserve the existing workspace memory files and the `main.sqlite` DB.

## Communication Surfaces

### Telegram

`main` currently acts on at least these direct Telegram sessions:

- `agent:main:telegram:direct:7670324081`
- `agent:main:telegram:direct:8089687974`
- `agent:main:telegram:direct:@seanssoh`

Relevant config facts from `openclaw.json`:

- `channels.telegram.accounts.default` exists
- allowlist includes `7670324081` and `8089687974`

Operational meaning:

- `main` is a family-facing agent, not just an internal orchestrator
- many cron/system-event jobs directly send Telegram reminders and digests

### Discord

Session history shows many `main` Discord channel sessions plus one direct session, including:

- `agent:main:discord:direct:1476877944625565746`
- multiple `agent:main:discord:channel:<id>` session keys

But current `openclaw.json` `channels.discord.accounts.default` does not clearly expose a matching allowlist for those guild channels.

Implication:

- Discord routing for `main` is a migration risk
- current config and historical session usage are not obviously aligned
- Phase 3 scaffold should treat Discord mapping as an explicit checklist item, not an assumption

## Gateway / Skill Dependencies

### Main-Specific Skills From Registry

Current assigned skill set from `shared/TOOLS-REGISTRY.md`:

- `agent-db`
- `agent-factory`
- `discord-reader`
- `naver-maps`
- `naver-search`
- `navi-waypoint`
- `openclaw-config`
- `patch`
- `pinchtab`

### Dependency Classes

The important distinction is not just the skill names, but how `main` currently uses them:

1. direct gateway messaging
   - `sessions_send(sessionKey="agent:{id}:main", ...)`
   - patch Discord webhook
2. gateway-managed channels
   - Telegram sends through `openclaw message send`
   - historical Discord channel sessions
3. shared scripts and databases
   - calendar / reminder / watch scripts under `~/.openclaw/scripts/`
   - agent DB and memory DB access

### Migration Notes By Dependency

- `patch`
  Current state: gateway webhook / sessions-based interaction
  Migration path: replace with Agent Bridge queue or direct `patch` static role usage

- A2A via `sessions_send`
  Current state: heavily embedded in `TOOLS.md` and `AGENTS.md`
  Migration path: replace internal handoffs with Agent Bridge tasks

- `agent-db`, `naver-*`, `pinchtab`
  Current state: capability dependencies, not bridge blockers
  Migration path: keep using the underlying scripts/tools from the same workspace during initial cutover

- `agent-factory`
  Current state: gateway-era infrastructure skill
  Migration path: likely needs a later bridge-native redesign, so do not make `main` cutover depend on it on day one

- `discord-reader`
  Current state: historical Discord inspection utility
  Migration path: may still be useful post-cutover, but not required to unblock initial CLI migration

## Scheduled Workload

### Main Cron Footprint

Current `main` cron inventory:

- total jobs: `19`
- recurring: `18`
- future one-shot: `1`
- current errors: `2`

Major recurring families:

- `morning-briefing` x2
- `evening-digest` x2
- `memory-daily` x2
- `monthly-highlights` x2
- `calendar-sync`
- `event-reminder`
- `daily-medicine-reminder`
- `weekly-review`
- `iran-crisis-monitor`
- `google-watch-renewal`
- multiple personal reminder jobs

Important shape:

- some jobs are `systemEvent` with `session_target=main`
- many jobs directly send Telegram outputs
- some jobs are already good candidates for bridge-based enqueue
- some jobs are still better left on existing scripts during initial cutover

Current recurring errors:

- `iran-crisis-monitor`
- `memory-daily-sean`

Implication: do not bundle full cron migration into the first `main` scaffold slice. That would make rollback and fault isolation too hard.

### Heartbeat

Current OpenClaw config still declares:

- `agents.defaults.heartbeat.every = 1h`
- `main.heartbeat.every = 1h`

And `workspace/HEARTBEAT.md` contains proactive checks plus spontaneous reach-out logic.

Implication:

- there are two distinct concerns to preserve:
  1. proactive workload trigger behavior
  2. periodic health/freshness visibility
- Phase 2 already covered the health-check surface
- workload heartbeat should be treated as cron/task migration work, not as part of the initial `main` profile scaffold

## Relationship To Huchu

`huchu` should not go first.

Reasons:

- `huchu` is an orchestrator that still reports/escalates into `main`
- `main` is the family-facing endpoint for many outcomes
- `main` stabilization reduces ambiguity for later `huchu` handoff rules

Observed `huchu` footprint for comparison:

- workspace: `/Users/soonseokoh/.openclaw/workspace-huchu`
- memory DB: `/Users/soonseokoh/.openclaw/memory/huchu.sqlite` (`1.2G`)
- recurring jobs: `8`
- current recurring errors: `1` (`memory-daily-huchu`)
- Discord surface is clearer than `main`, but dependency order still favors migrating `main` first

## Key Risks

### 1. Prompt Stack Spread

`main` depends on multiple files and symlinks, not just one identity prompt. Missing any of `AGENTS.md`, `SOUL.md`, `MEMORY.md`, `TOOLS.md`, `ROSTER.md`, or the user files would change behavior.

### 2. Multi-Surface Messaging

`main` mixes:

- Telegram direct messaging
- historical Discord sessions
- A2A sessions
- cron/system-event sends

This is the single biggest cutover risk.

### 3. Central-Orchestrator Blast Radius

If `main` is wrong after migration, the failure is user-visible immediately and can also break downstream agent reporting.

### 4. Cron Coupling

Too many `main` jobs currently assume gateway messaging/session behavior. A first cutover should keep cron scope narrow.

## Recommended Cutover Strategy

### Preferred

Use a short maintenance-window migration for `main`.

Why:

- Sean already allows temporary global agent offline time
- `main` is central enough that split-brain behavior is worse than a short outage
- it simplifies Telegram/Discord route validation

### Phase 3 Next Slice

Create `agents/main/CLAUDE.md` from the audited prompt stack with these goals:

1. preserve `SOUL.md` identity and safety rules
2. preserve the operational gates from `AGENTS.md`
3. explicitly translate gateway-era A2A guidance into Agent Bridge task guidance where possible
4. keep remaining gateway-only commands called out as temporary compatibility paths
5. define candidate live deploy target before touching production

Candidate live profile target for the first scaffold:

- workdir: `/Users/soonseokoh/.openclaw/workspace`
- profile target candidate: `/Users/soonseokoh/.openclaw/workspace`

### Not In The First Scaffold Slice

Do not try to solve all of this at once:

- full Discord route migration
- all 19 cron jobs
- `huchu`
- bridge-native replacement of every gateway skill
- final retirement of gateway A2A/session flows

## Exit Criteria For Audit Slice

This audit slice is complete when:

- live prompt stack is identified
- live workspace and auth/session homes are identified
- major channel dependencies are identified
- cron scale is identified
- main-before-huchu order is justified
- next slice is narrowed to `main` profile scaffold, not full cutover
