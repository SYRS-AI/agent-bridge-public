# Tools

This page is the registry for reusable tools. It tells agents what each tool can
do, who owns it, which credentials it needs, and when human approval is
required.

## Tool Card Schema

Use one card per tool or script.

```markdown
### <tool-name>

- Owner: <person/team/agent responsible for keeping this usable>
- Purpose: <what the tool is for>
- Access path: <command/API/script/MCP tool>
- Read scope: <what it can read>
- Write scope: <what it can modify or send>
- Credentials: <runtime credential filename(s) or "none"; never paste secrets>
- Credential policy: <where credentials live and who may edit them>
- Approval: <none/read-only/writes/external-send/destructive>
- Safe examples:
  - `<command that is safe to run>`
- Dangerous examples:
  - `<command requiring approval>`
- Failure modes: <auth/rate limit/network/schema drift/etc.>
- Recovery: <how agents should retry, degrade, or escalate>
```

## Approval Levels

- `none`: safe local read-only inspection.
- `read-only`: reads external systems or private data; summarize minimally.
- `writes`: changes local files, databases, SaaS records, or agent memory.
- `external-send`: sends messages, emails, tickets, social posts, or customer-visible output.
- `destructive`: deletes, overwrites, deploys, rotates secrets, or changes billing/security.

When in doubt, treat the action as the higher approval level.

## Credential Policy

- Runtime credentials live under `~/.agent-bridge/runtime/credentials/`.
- Runtime secrets live under `~/.agent-bridge/runtime/secrets/`.
- Source-controlled examples may use `.example.json` or placeholder names only.
- Never paste credential values into this wiki, task bodies, logs, issues, or commits.
- Missing credential diagnostics should name the expected file and redacted
  search roots, not the secret value.

## Default Entries

### agent-bridge-cli

- Owner: local admin agent
- Purpose: manage local Agent Bridge agents, tasks, cron, upgrade, memory, and knowledge
- Access path: `~/.agent-bridge/agent-bridge` or `agb`
- Read scope: local bridge status, queue, roster, logs, runtime metadata
- Write scope: agent lifecycle, queue status, cron jobs, local runtime files
- Credentials: none by default
- Credential policy: command-specific setup writes credentials into agent-local state directories
- Approval: normal diagnostics are `none`; destructive repair/rollback and external issue filing require user approval
- Safe examples:
  - `agb status`
  - `agb inbox <agent>`
  - `agb upgrade --check`
- Dangerous examples:
  - `agb kill <agent>` when user work may be in progress
  - `agb upgrade` without reviewing local customizations
- Failure modes: daemon stopped, tmux session missing, stale roster, SQLite lock, missing channel credentials
- Recovery: run `agb status`, `bash ~/.agent-bridge/bridge-daemon.sh status`, then choose targeted repair

### credential-loader

- Owner: local admin agent
- Purpose: load runtime credentials for scripts without hardcoding secrets
- Access path: `from creds import load_creds`
- Read scope: files under runtime credential and secret roots
- Write scope: none
- Credentials: requested filename under `credentials/` or `secrets/`
- Credential policy: filenames may be documented; secret values must never be documented
- Approval: read-only, but summarize diagnostics without exposing secret contents
- Safe examples:
  - `load_creds("service-account.json")`
- Dangerous examples:
  - printing loaded credential values
- Failure modes: missing file, invalid JSON, path traversal rejection
- Recovery: ask the user/admin to create the expected credential file or run the relevant `agb setup ...` command
