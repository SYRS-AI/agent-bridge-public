---
name: agent-db
description: Manage structured data in Railway PostgreSQL — emails, calendar events, tasks, facts, reminders, projects, and notifications. Use when tracking emails, scheduling reminders, managing tasks/todos, recording important facts from conversations, syncing calendar events, generating daily digests, or querying historical data.
type: shell-script
category: data
entry: scripts/email-sync.py
---

# Agent DB

Shared Railway PostgreSQL database for structured data management. Each agent uses `agent_id` to isolate data.

## Setup

- Credentials: `~/.agent-bridge/runtime/credentials/railway-db.json`
- Python: `import psycopg2` (already installed)
- Agent ID: use your own `agent_id` in all queries

## Quick Access

```python
import os
import sys
import psycopg2

sys.path.insert(0, os.path.expanduser("~/.agent-bridge/runtime/scripts"))
from creds import load_creds

def get_db():
    c = load_creds("railway-db.json")
    return psycopg2.connect(
        host=c["db_host"], port=c["db_port"],
        dbname=c["db_name"], user=c["db_user"], password=c["db_password"]
    )
```

## Tables

### emails
Track and manage email messages synced from Gmail.
- `agent_id, account, message_id, sender, subject, snippet, received_at`
- `importance` (`critical/high/medium/low/spam`), `category` (`legal/business/personal/newsletter/spam`)
- `status` (`new/notified/handled/ignored/archived`), `notified_at, notified_to, agent_note`

### events
Calendar events synced from Google Calendar.
- `agent_id, calendar_id, event_id, summary, description, start_at, end_at, location, attendees, all_day`
- `reminder_30min_sent, reminder_1h_sent, briefing_included`

### tasks
Track todos, requests, and action items from conversations.
- `agent_id, title, description, status` (`open/in_progress/done/cancelled`)
- `priority` (`critical/high/medium/low`), `category, assigned_to, due_date`

### facts
Record important facts, decisions, and preferences from conversations.
- `agent_id, category` (`person/project/decision/preference/deadline`)
- `subject, content, source` (`conversation/email/calendar`), `source_date, expires_at`

### reminders
Schedule reminders for users.
- `agent_id, title, description, remind_at, sent, sent_at, target`
- `recurring` (`daily/weekly/monthly/null`)

### projects
Track ongoing projects and their status.
- `agent_id, name, description, status` (`active/paused/completed/archived`), `owner`

### notifications
Log all sent notifications to prevent duplicates.
- `agent_id, type` (`email/calendar/system/walk/weather`), `reference_id, sent_to, channel, message`

### daily_digests
Track daily summary reports sent to users.
- `agent_id, date, type` (`morning/evening`), `sent_to, content, email_count, event_count`

### agent_state
Key-value store for agent operational state.
- `agent_id, key, value` (JSONB)

## Scripts

### Email Sync
Sync Gmail -> DB: `python3 ~/.agent-bridge/runtime/skills/agent-db/scripts/email-sync.py [hours] [agent_id]`
- Gmail API backend is `gws`
- default lookback: 2 hours
- default `agent_id`: `main`

### DB Query Helper
Quick queries: `python3 ~/.agent-bridge/runtime/skills/agent-db/scripts/db-query.py <query_type> [agent_id]`
- `new-emails`
- `today-events`
- `open-tasks`
- `pending-reminders`
- `stats`

## Privacy

- Always filter by your own `agent_id`
- Never query another agent's data
- Credentials file is shared but data is logically isolated by `agent_id`

## Usage Guidelines

- Email arrives -> sync, judge importance, update status, notify if needed
- Reply needed -> set `reply_needed=true`, remind after 24h if no action
- Meeting invite in email -> set `has_meeting_invite=true`, check calendar
- User says "remember X" -> insert into `facts`
- User says "remind me" -> insert into `reminders`
- User assigns task -> insert into `tasks`

## Example Queries

```sql
SELECT * FROM emails WHERE agent_id='main' AND status='new' AND importance IN ('critical','high');

SELECT * FROM events
WHERE agent_id='main'
  AND start_at::date = (NOW() AT TIME ZONE 'Asia/Seoul')::date
ORDER BY start_at;

SELECT * FROM tasks
WHERE agent_id='main' AND status IN ('open','in_progress')
ORDER BY priority;
```
