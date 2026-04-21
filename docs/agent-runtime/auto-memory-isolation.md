# Per-agent auto-memory isolation

> Status: landed in PR 1A (scaffold only). PR 1B will add the migration
> CLI for existing installs.

## Why

Claude Code's **auto memory** is scoped per git repository: all sessions
that run under the same git root share one `~/.claude/projects/<slug>/memory/`
directory. Anthropic documents this behaviour explicitly:

> "The `<project>` path is derived from the git repository, so all worktrees
> and subdirectories within the same repo share one auto memory directory."
> — <https://code.claude.com/docs/en/memory>

Agent Bridge places every agent home under a single git repo
(`~/.agent-bridge`), so by default `agents/patch`, `agents/syrs-*`,
`agents/huchu`, etc. all write to the same shared auto-memory folder. That
breaks the "one agent's memory is private to that agent" expectation and
allows last-write-wins conflicts between concurrent agents.

## Fix

Anthropic exposes an official override: `autoMemoryDirectory`. It is
accepted only from **policy / user / local** settings, not from project
`settings.json` (Anthropic deliberately refuses the project scope to stop a
shared repo from redirecting auto-memory writes).

Bridge now seeds `.claude/settings.local.json` inside each agent's home
with a per-agent path:

```json
{
  "autoMemoryDirectory": "~/.claude/auto-memory/<bridge-home-slug>/<agent>"
}
```

`<bridge-home-slug>` is the resolved bridge install path with `/` and `.`
replaced by `-`, matching Anthropic's `~/.claude/projects/` convention.
For a default install at `/Users/you/.agent-bridge` the slug is
`-Users-you--agent-bridge`, so two bridge installs on the same machine
keep their auto-memories separate even when they share agent ids.

## When it runs

The scaffold calls `bridge_ensure_auto_memory_isolation` at the end of
`bridge-agent create` for **claude** engines. Codex agents are skipped:
codex does not consume Anthropic's auto-memory.

The seed only touches `settings.local.json`. `.gitignore` already hides
this file (`agents/*/.claude/`), so the per-agent path never leaks into
commits.

## Merge policy (fail-closed)

| existing state                                      | action                                  |
| --------------------------------------------------- | --------------------------------------- |
| no file                                             | create with `{autoMemoryDirectory: …}`  |
| valid JSON, no `autoMemoryDirectory`                | upsert; preserve other keys             |
| valid JSON, same value                              | no-op                                   |
| valid JSON, different `autoMemoryDirectory` value   | **fail** — operator must resolve        |
| invalid JSON                                        | **fail** — operator must inspect/repair |

The function never silently overwrites a local setting and never resets a
broken JSON file to `{}`. If it complains, the fix is to read the file
yourself and decide.

## Operator checklist

**New agents (after this PR is live):** nothing to do — scaffolding seeds
the setting automatically.

**Existing agents (pre-PR state):** the seed won't backfill automatically;
that work belongs to PR 1B. Until then you can opt in manually. Set
`BRIDGE_HOME` to the install you're operating on (the snippet below
defaults to `~/.agent-bridge` but you **must** override it when running
against a checkout, worktree, or alternate install — the slug depends on
the real path). The snippet preserves any other keys already in
`settings.local.json`; an empty or malformed file is rejected rather
than silently rewritten:

```bash
# Point this at the install you want to patch — different paths produce
# different per-agent slugs, so this value matters.
BRIDGE_HOME="$(cd -P "${BRIDGE_HOME:-$HOME/.agent-bridge}" && pwd -P)"
AGENT=<agent>
SLUG="$(printf '%s' "$BRIDGE_HOME" | tr '/.' '--')"
SETTINGS="$BRIDGE_HOME/agents/$AGENT/.claude/settings.local.json"
TARGET="~/.claude/auto-memory/$SLUG/$AGENT"

python3 - "$SETTINGS" "$TARGET" <<'PY'
import json
import sys
from pathlib import Path

path, target = Path(sys.argv[1]), sys.argv[2]
if path.exists():
    raw = path.read_text(encoding="utf-8")
    if not raw.strip():
        sys.exit(f"error: {path} is empty; inspect or remove before running")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.exit(f"error: {path} is not valid JSON ({exc}); fix or remove before running")
    if not isinstance(data, dict):
        sys.exit(f"error: {path} is not a JSON object")
    current = data.get("autoMemoryDirectory")
    if current == target:
        sys.exit(0)
    if current:
        sys.exit(f"error: {path} already sets autoMemoryDirectory={current!r}; resolve manually")
else:
    data = {}
    path.parent.mkdir(parents=True, exist_ok=True)
data["autoMemoryDirectory"] = target
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY

# The slug also picks the physical dir Claude will write into.
mkdir -p "$HOME/.claude/auto-memory/$SLUG/$AGENT"
```

Claude Code picks up the new value on the next session start. Existing
files in the shared parent dir stay where they are until PR 1B's migration
CLI ships.

**Requirements.** Claude Code **v2.1.59+** (the release that introduced
auto memory). Check with `claude --version`.

## Rollback

To revert a single agent back to the shared behaviour:

1. Remove the `autoMemoryDirectory` key from `~/.agent-bridge/agents/<agent>/.claude/settings.local.json`
   (leave other keys in place; delete the file only if it's empty afterwards).
2. Restart the agent. Auto-memory resumes at `~/.claude/projects/<repo-slug>/memory/`.

No data moves during rollback: PR 1A does not touch existing memory files.
Migration and restore flows land in PR 1B.

## Related

- PR 1B — migration CLI, `originSessionId` → agent routing, manifest-based
  restore, doctor drift checks.
- PR 2 — session-primary daily note (`/wrap-up` command + hooks + cron
  reconcile). Independent of this change, but shares the
  "agent-local memory is the right default" direction.
