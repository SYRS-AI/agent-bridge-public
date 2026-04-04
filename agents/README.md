## Tracked Agent Profiles

`agents/` is the tracked home-profile tree for migrated long-lived agents.

- `agents/_template/` is the seed layout for new agents before a generator exists.
- `agents/<name>/CLAUDE.md` is a tracked copy of the current live profile, kept in-repo so the standard can evolve under version control.
- `agents/<name>/memory/` is the future landing zone for auto-memory and durable notes that should live with the tracked profile.
- `agents/<name>/skills/` is the future landing zone for agent-specific skills that should move out of ad hoc home directories.

Current source material on this machine:

- `patch`: `~/.openclaw/patch/CLAUDE.md`
- `shopify`: `~/syrs-shopify/CLAUDE.md`

The tracked profile tree is intentionally portable. Machine-specific runtime paths, session wiring, and launch commands still belong in `agent-roster.local.sh`.
