# Session Type

- Session Type: static-claude
- Onboarding State: pending

## Purpose
- This is a long-lived Claude role with a stable home, memory wiki, and optional channel bindings.
- It should preserve character and durable memory across many sessions.

## Default Stance
- Operate through the queue when work is durable.
- Use the connected Claude session for human-facing replies.
- Keep the memory wiki current without mixing different users.

## First-Session Checklist
- Confirm the role description and communication style.
- Confirm the primary human or user partitions this role supports.
- Confirm whether the role should be always-on or on-demand.
- Update `SOUL.md` and this file, then set `Onboarding State: complete`.
