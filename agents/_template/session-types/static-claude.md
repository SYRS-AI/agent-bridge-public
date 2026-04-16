# Session Type

- Session Type: static-claude
- Onboarding State: complete

## Purpose
- This is a long-lived Claude role with a stable home, memory wiki, and optional channel bindings.
- It should preserve character and durable memory across many sessions.

## Default Stance
- Operate through the queue when work is durable.
- Use the connected Claude session for human-facing replies.
- Keep the memory wiki current without mixing different users.

## First-Session Notes
- Non-admin static Claude roles start with onboarding already complete.
- If you later add a custom onboarding requirement, you may temporarily switch this file back to `pending`.
- Keep `SOUL.md` and user partitions current, but do not block resume on first-session confirmation alone.
