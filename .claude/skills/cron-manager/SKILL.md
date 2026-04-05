---
name: cron-manager
description: Create, inspect, update, and delete Agent Bridge native cron jobs with `agb cron`.
---

Use this skill when an agent identifies recurring work that should be scheduled through Agent Bridge instead of being remembered manually.

## Rules

- Prefer bridge-native cron jobs via `agb cron create|list|update|delete`.
- Keep payloads short and operator-facing. Put the actual recurring instruction in the payload.
- Use the owning bridge agent id in `--agent`.
- Do not create a cron when a one-off queue task or existing cron is sufficient.
- Update or delete stale jobs instead of creating duplicates.

## Commands

```bash
agb cron list --agent <agent>
agb cron create --agent <agent> --schedule "0 9 * * *" --title "Daily check" --payload "..."
agb cron update <job-id> --schedule "0 10 * * *"
agb cron delete <job-id>
```

## Guidance

- Default timezone is the local system timezone unless `--tz` is set.
- If the recurring work only matters after explicit human approval, do not schedule it automatically.
- If the job routinely produces "no change" results, the disposable cron worker should return `needs_human_followup=false`.
