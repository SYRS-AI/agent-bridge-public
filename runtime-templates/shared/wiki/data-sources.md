# Data Sources

This page is the registry for structured data ownership. It tells agents where
facts live and how to query them. Do not duplicate large tables into the wiki.

## Canonical Data Rule

- Operational records such as customers, orders, inventory, ads, accounting,
  tickets, and calendar events belong in their source database or API.
- The wiki stores ownership, query paths, freshness expectations, and approval
  rules only.
- If a data source has both a database and a UI, record which one is canonical
  for writes.
- If the same fact appears in multiple systems, name the tie-breaker here.

## Registry Schema

Use one card per data source.

```markdown
### <data-source-name>

- Owner: <person/team/agent responsible for correctness>
- Canonical system: <database/API/SaaS/app>
- Structured scope: <tables/resources/entities covered>
- Read path: <command/API/query helper; link to tool card if available>
- Write path: <command/API/manual process; write "none" if read-only>
- Credentials: <runtime credential filename or "user-provided"; never paste secrets>
- Approval: <none/read-only/writes require approval/destructive requires approval>
- Freshness: <real-time/hourly/daily/manual; include sync job if any>
- Failure mode: <what agents should do when unavailable>
- Notes: <edge cases, source conflicts, rate limits>
```

## Default Entries

### agent-bridge-queue

- Owner: local admin agent
- Canonical system: `~/.agent-bridge/state/tasks.db`
- Structured scope: inter-agent tasks, claims, status transitions, events
- Read path: `~/.agent-bridge/agb inbox|show|summary`
- Write path: `~/.agent-bridge/agent-bridge task create|claim|done|handoff|cancel`
- Credentials: none
- Approval: normal queue operations need no approval; destructive queue repair requires user approval
- Freshness: real-time local SQLite
- Failure mode: inspect `bridge-queue.py` errors and daemon status before editing the database

### shared-wiki

- Owner: local admin agent
- Canonical system: `~/.agent-bridge/shared/wiki/`
- Structured scope: people, agents, operating rules, data sources, tools, decisions, projects, playbooks
- Read path: `~/.agent-bridge/agent-bridge knowledge search --query "<query>"`
- Write path: `~/.agent-bridge/agent-bridge knowledge capture|promote`
- Credentials: none
- Approval: no approval for non-sensitive operational notes; user approval required before recording private or external-facing facts
- Freshness: updated by agents when durable facts are discovered
- Failure mode: if search/index fails, read markdown files directly and rebuild index later
