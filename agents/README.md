## Tracked Agent Profiles

`agents/` is the public-facing profile scaffold and migration-doc tree.

- `agents/_template/` is the seed layout for new long-lived roles.
- The public repository intentionally does **not** ship live production
  profiles for private agents.
- Migration planning documents stay here because some installations still need
  to move from a legacy OpenClaw layout into Agent Bridge.

Recommended public workflow:

1. Copy `agents/_template/` into a private companion repo or a local untracked
   directory.
2. Customize `CLAUDE.md`, optional `skills/`, and any private notes there.
3. Use `agent-bridge profile status|diff|deploy` to promote approved profile
   files into the live agent home.

Machine-specific runtime paths, session wiring, credentials, and launch
commands still belong in `agent-roster.local.sh`.
