# Memory Log

Use this file to record meaningful memory maintenance events.

This file is append-only.

- add new entries at the bottom
- do not silently rewrite prior history
- if a prior entry was wrong, append a correction note

Preferred entry shape:

```text
- 2026-04-15T03:12:00+09:00 kind=ingest target=`users/owner/memory/2026-04-15.md` source=`capture-id`
- 2026-04-15T03:13:10+09:00 kind=promote target=`users/owner/MEMORY.md` source=`capture-id` summary="User prefers concise morning updates."
```

Examples:

- promoted a stable user preference into long-term memory
- merged duplicate notes into one shared page
- corrected a contradictory fact
- created a new project or decision page
