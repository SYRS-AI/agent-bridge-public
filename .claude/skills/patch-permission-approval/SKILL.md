---
name: patch-permission-approval
description: MANDATORY when an inbox task title begins with `[PERMISSION]`. The admin agent (patch) MUST invoke this skill immediately on any `[PERMISSION] <agent> needs approval for <tool>` task — it parses the escalation body, asks the human operator to approve-once / approve-always / deny, applies the decision to the requesting agent's `settings.local.json` and the origin queue task, and writes a `permission_decision` audit entry. Trigger phrases: `[PERMISSION]`, `permission_escalation_requested`, `needs approval for`, `permission approval`, `approve tool use`.
---

# patch-permission-approval

This skill is the admin-side half of the auto-mode permission escalation flow landed in PR #93 (hooks/permission_escalation.py). When a non-admin agent hits a `PermissionDenied` event, the hook enqueues an urgent `[PERMISSION]` task to the admin agent (`BRIDGE_ADMIN_AGENT_ID`, typically `patch`) and marks the origin task as `blocked`. You, the admin Claude session, consume that task here.

## When to invoke

Invoke **immediately** whenever `agb inbox` or a task notification surfaces a task whose title starts with `[PERMISSION]`. Do not defer, do not batch with unrelated work — the requesting agent is blocked and waiting.

## Task body shape

The hook writes the body in a fixed `key=value` line format. Parse these fields:

```
agent=<requesting-agent-id>
tool=<tool-name>                 # e.g. Bash, Edit, WebFetch, mcp__github__create_pr
tool_use_id=<id-from-hook>
args=<redacted-json-summary>      # already sanitized by bridge_guard_common
task_id=<origin-task-id | 'none'>
reason=<truncated-denial-reason>
```

Always read the full body with `agb show <permission-task-id>` before acting.

## Workflow

### Step 1 — Claim the permission task

```bash
agb claim <permission-task-id> --agent patch
```

### Step 2 — Propose a rule for approve-always

Generalize the denied tool call into a permissions-list pattern. The v1 heuristics (keep simple; operator can override):

| Tool family          | Input                                      | Proposed rule                         |
|----------------------|--------------------------------------------|---------------------------------------|
| `Bash`               | `gh repo create foo/bar --public`          | `Bash(gh repo create:*)`              |
| `Bash` (1 token)     | `make`                                     | `Bash(make:*)`                        |
| `Edit` / `Write`     | `file_path=/repo/src/x.py`                 | `Edit(/repo/src/**)` / `Write(...)`   |
| `Read`               | `file_path=/repo/src/x.py`                 | `Read(/repo/src/**)`                  |
| `WebFetch`           | `url=https://docs.example.com/x`           | `WebFetch(domain:docs.example.com)`   |
| `mcp__<srv>__<tool>` | any                                        | `mcp__<srv>__<tool>`                  |
| anything else        | any                                        | bare tool name                        |

Show the proposed rule to the operator alongside the decision prompt so they can see exactly what approve-always would grant. Never approve-always a rule the operator did not explicitly see and confirm.

### Step 3 — Ask the human operator

Use whichever connected channel is available. Prefer the bridge's existing notify path so the prompt flows through the same Discord/Telegram integration as `bridge-escalate`:

```bash
bash "$BRIDGE_SCRIPT_DIR/bridge-notify.sh" send \
  --agent patch \
  --title "[PERMISSION] <agent> → <tool>" \
  --task-id <permission-task-id> \
  --priority urgent \
  --message "$(cat <<'EOM'
Agent <agent> wants to run: <tool>(<redacted-args>)
Reason: <reason>

Proposed always-rule: <proposed-rule>

Reply with one of:
  approve once      → one-shot retry, no settings change
  approve always    → add <proposed-rule> to <agent>/settings.local.json
  deny              → close with "find alternative"
EOM
)"
```

If direct channel tools (e.g. a Discord send tool) are exposed in the session, use those instead and skip the bridge-notify call — the message content is the same.

Then wait for the operator's reply. The reply arrives through whatever channel relay is wired up (Discord relay → queue, Telegram → queue, or an operator reply in the same chat turn). Re-read `agb inbox patch` and any channel message queue. Do NOT fabricate the decision.

### Step 4 — Apply the decision

Let `ORIGIN=<origin-task-id from body>`, `PERM=<permission-task-id>`, `AGENT=<requesting agent>`, `RULE=<proposed or operator-edited rule>`.

#### Path A — approve once

```bash
agb task update "$ORIGIN" --status queued \
  --note "permission approved: one-shot for <tool>"
agb done "$PERM" --agent patch --note "approved once: <tool>"
```

No settings.local.json change. The requesting agent re-claims the origin task on its next queue loop and retries. If the denial classifier fires again, the flow repeats — that is expected.

#### Path B — approve always

Before writing the allowlist, echo the exact rule back to the operator one more time and wait for a final `confirm` / `cancel`. A typo like `Bash(*)` could silently allow everything. Never skip this double-check.

Merge the rule into `$BRIDGE_HOME/agents/$AGENT/.claude/settings.local.json` using a Python heredoc (atomic-ish: load → mutate → write with `0o600`):

```bash
SETTINGS="$BRIDGE_HOME/agents/$AGENT/.claude/settings.local.json"
python3 - "$SETTINGS" "$RULE" <<'PY'
import json, os, stat, sys
from pathlib import Path

path = Path(sys.argv[1])
rule = sys.argv[2]

path.parent.mkdir(parents=True, exist_ok=True)
try:
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    if not isinstance(data, dict):
        data = {}
except json.JSONDecodeError:
    data = {}

perms = data.setdefault("permissions", {})
if not isinstance(perms, dict):
    perms = {}
    data["permissions"] = perms
allow = perms.setdefault("allow", [])
if not isinstance(allow, list):
    allow = []
    perms["allow"] = allow

if rule not in allow:
    allow.append(rule)

tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)  # 0600
os.replace(tmp, path)
print(f"merged rule into {path}")
PY

agb task update "$ORIGIN" --status queued \
  --note "permission granted always: $RULE"
agb done "$PERM" --agent patch --note "approved always: $RULE"
```

The heredoc handles:
- missing file / missing `permissions` / missing `allow` branch,
- non-dict / non-list contamination (replaces with a clean structure),
- duplicate rules (append-if-absent),
- atomic write via `.tmp` + `os.replace` with `0600` perms.

Scope is agent-local only (per issue #90). Peer agents are NOT updated.

#### Path C — deny

```bash
agb done "$ORIGIN" --note "permission denied: find alternative"
agb done "$PERM" --agent patch --note "denied: <tool>"
```

The requesting agent treats the origin task as complete with a denial note and picks its next queue item.

### Step 5 — Record audit

After **every** decision path, write an audit entry so the trail is queryable:

```bash
python3 "$BRIDGE_SCRIPT_DIR/bridge-audit.py" write \
  --file "$BRIDGE_HOME/logs/audit.log" \
  --actor patch \
  --action permission_decision \
  --target "$AGENT" \
  --detail "tool=<tool>" \
  --detail "decision=<approve_once|approve_always|deny>" \
  --detail "rule=<rule-or-empty>" \
  --detail "origin_task=$ORIGIN" \
  --detail "permission_task=$PERM"
```

## Safety rules (do not skip)

1. **Show the exact rule before approve-always.** Operator must see the literal allowlist string. A misfired `Bash(*)` grants full shell access.
2. **Never approve-always without a second confirm.** One round trip for the decision, a second for rule confirmation.
3. **Never edit a peer agent's settings.local.json** from this skill. Agent-local only.
4. **Never silently drop malformed settings.local.json** — the heredoc replaces a non-dict root with `{}`, which is intentional for recovery, but log the event in the audit `--detail` if you observe it (e.g. `--detail "settings_recovered=true"`).
5. **Do not fabricate an operator reply.** If no reply arrives within the session budget, leave the task claimed and hand off / wait — the `#91` daemon-timeout-fanout is the fallback.
6. **Preserve file mode 0600** on `settings.local.json` — the heredoc enforces this via `os.chmod` before the atomic rename.

## Quick sanity check

To dry-run the settings merge without touching a real agent home:

```bash
FAKE="$(mktemp -d)/settings.local.json"
echo '{"permissions":{"allow":["Read(~/**)"]}}' > "$FAKE"
python3 - "$FAKE" 'Bash(gh repo create:*)' <<'PY'
# (paste the heredoc body from Path B above)
PY
cat "$FAKE"
# Expect: permissions.allow contains both Read(~/**) and Bash(gh repo create:*).
```

Run the same with a missing file, an empty file, and a non-dict root (`"[]"` or `"null"`) to confirm each recovery branch.
