# Linux Per-UID Isolation Acceptance Runbook

Step-by-step checklist an operator runs on a fresh Linux host to validate the
per-UID isolation mode shipped by issue `#68` and its sub-issues. Each check
has an exact command, the output you should see, and an explicit
**PASS / FAIL** signal.

Run the whole sequence end-to-end on a host with at least two isolated static
agents configured side by side (`agentA`, `agentB` below — substitute your
real ids).

> Scope: this runbook validates `BRIDGE_AGENT_ISOLATION_MODE=linux-user` on a
> Linux host. macOS installs remain in `shared` mode and are out of scope
> here (see the macOS scope doc for rationale).

## 0. Pre-flight

Before running any check, confirm the host is actually set up for per-UID
isolation. Running these checks against a `shared`-mode install will produce
false passes.

### 0.1 Host platform

```bash
uname -s
```

Expected output:

```
Linux
```

- **PASS** if output is `Linux`.
- **FAIL** if output is `Darwin` or anything else. The runbook does not apply.

### 0.2 Sudo and setfacl available

```bash
command -v sudo && command -v setfacl
```

- **PASS** if both print an absolute path.
- **FAIL** if either is missing — `linux-user` isolation requires both
  (see `lib/bridge-agents.sh: bridge_linux_require_setfacl`).

### 0.3 Roster declares each agent as isolated

Each agent under test must set `AGENT_ISOLATION_MODE=linux-user` and a
non-empty `AGENT_OS_USER`. Inspect the active roster:

```bash
grep -E 'BRIDGE_AGENT_(ISOLATION_MODE|OS_USER)\["(agentA|agentB)"\]' \
  ~/.agent-bridge/agent-roster.local.sh
```

Expected output (values may differ, but both keys must be present for both
agents and the mode must be `linux-user`):

```
BRIDGE_AGENT_ISOLATION_MODE["agentA"]="linux-user"
BRIDGE_AGENT_OS_USER["agentA"]="agent-bridge-agenta"
BRIDGE_AGENT_ISOLATION_MODE["agentB"]="linux-user"
BRIDGE_AGENT_OS_USER["agentB"]="agent-bridge-agentb"
```

- **PASS** if every agent under test has both keys set and the mode is
  exactly `linux-user`.
- **FAIL** if any agent is missing either key, or the mode is `shared`.

### 0.4 OS users exist

```bash
getent passwd agent-bridge-agenta agent-bridge-agentb
```

Expected output (one line per user, non-empty):

```
agent-bridge-agenta:x:...:/home/agent-bridge-agenta:/bin/bash
agent-bridge-agentb:x:...:/home/agent-bridge-agentb:/bin/bash
```

- **PASS** if `getent` prints one line for every agent's OS user.
- **FAIL** if any line is missing — the user was never provisioned. Run
  the isolation setup flow for that agent before continuing.

### 0.5 Agent Bridge status clean

```bash
agb status
```

- **PASS** if the dashboard renders and lists the isolated agents as known
  roles.
- **FAIL** on any error — do not trust downstream checks until status is
  clean.

---

## 1. Cross-agent filesystem read is denied

Under per-UID isolation each agent's managed home
(`/home/agent-bridge-<slug>`) is mode `700` owned by that OS user. Any
attempt by another isolated user to read those files must return
`Permission denied` (EACCES).

Pick a file that is known to exist in `agentB`'s home. `SOUL.md` is a good
choice because the managed agent profile always drops one; substitute any
other file under that home if yours differs.

```bash
sudo -u agent-bridge-agenta cat /home/agent-bridge-agentb/SOUL.md
echo "exit=$?"
```

Expected output:

```
cat: /home/agent-bridge-agentb/SOUL.md: Permission denied
exit=1
```

- **PASS** if stderr contains `Permission denied` and `exit=1`.
- **FAIL** if the file contents print, or if exit is `0`.

Also verify the containing directory itself is unreadable:

```bash
sudo -u agent-bridge-agenta ls /home/agent-bridge-agentb/
echo "exit=$?"
```

- **PASS** if `Permission denied` and non-zero exit.
- **FAIL** if the directory listing succeeds.

### 1.3 Scoped roster snapshot is readable; global roster is not

Under isolation each agent loads roster state from a per-agent scoped
snapshot at
`~/.agent-bridge/state/agents/<agent>/agent-env.sh` instead of the shared
`agent-roster.local.sh` (which is `0600`, controller-only, and contains
every agent's tokens). `bridge_load_roster` picks the snapshot up
automatically when `BRIDGE_AGENT_ID` is exported, which bridge-run.sh and
the hook runtime always set. See issue `#116`.

```bash
sudo -u agent-bridge-agenta bash -lc \
  'cat ~/.agent-bridge/state/agents/agentA/agent-env.sh >/dev/null; echo own_exit=$?'
sudo -u agent-bridge-agenta bash -lc \
  'cat ~/.agent-bridge/state/agents/agentB/agent-env.sh >/dev/null 2>&1; echo other_exit=$?'
sudo -u agent-bridge-agenta bash -lc \
  'cat ~/.agent-bridge/agent-roster.local.sh >/dev/null 2>&1; echo roster_exit=$?'
```

Expected output:

```
own_exit=0
other_exit=1
roster_exit=1
```

- **PASS** if `own_exit=0` (the isolated UID can read its own snapshot),
  `other_exit=1` (cannot read any other agent's snapshot), and
  `roster_exit=1` (cannot read the shared roster with everyone's tokens).
- **FAIL** on any other combination — especially `other_exit=0` (cross-agent
  snapshot leak) or `roster_exit=0` (token leak via the shared roster).

### 1.4 Claude credentials reachable via per-UID symlink

Under isolation the isolated UID's `$HOME/.claude/.credentials.json` is
a symlink back to the operator's credentials file, with `u:<os_user>:r--`
ACL on the target and a default ACL on the operator's `.claude/` so
atomic-rename re-auths (new inode) still inherit the grant. Without
this, Claude on the isolated UID lands at the first-launch login
picker and the agent cannot process work. See issue `#125`.

```bash
sudo -u agent-bridge-agenta bash -lc \
  'readlink ~/.claude/.credentials.json'
sudo -u agent-bridge-agenta bash -lc \
  'test -r ~/.claude/.credentials.json && echo own_read=ok || echo own_read=fail'
sudo -u agent-bridge-agenta bash -lc \
  'test -r /home/agent-bridge-agentb/.claude/.credentials.json 2>/dev/null && echo other_read=leak || echo other_read=blocked'
```

Expected output (substitute your operator home for the first line):

```
/home/<operator>/.claude/.credentials.json
own_read=ok
other_read=blocked
```

- **PASS** if `own_read=ok` (isolated UID follows the symlink and reads
  the operator's credentials) and `other_read=blocked` (cannot reach
  another agent's home chain).
- **FAIL** if `own_read=fail` (Claude will land at the login picker) or
  `other_read=leak` (cross-agent home leak that the mode-0700 on
  `/home/agent-bridge-<slug>/` should have prevented).

---

## 2. Queue gateway round-trip

Normal queue work must still succeed from inside the isolated agent's
session. The gateway routes `agb` invocations through
`bridge-queue-gateway.py` (see `lib/bridge-core.sh: bridge_queue_cli`) so
that the isolated UID never touches the SQLite DB directly.

### 2.1 Own inbox works

Run `agb inbox` as the isolated user, for its own id:

```bash
sudo -u agent-bridge-agenta agb inbox agentA
echo "exit=$?"
```

Expected output: a human-readable inbox listing (possibly empty), followed
by `exit=0`.

- **PASS** if exit code is `0` and the command prints the normal inbox
  output (even if the inbox is empty).
- **FAIL** on any non-zero exit, or if stderr contains gateway errors.

### 2.2 Cross-agent inbox is blocked

The gateway's per-agent request directory is ACL-scoped so the isolated UID
can only write requests into its own `state/queue-gateway/<agent>/requests/`
folder. Asking `agb` to act on another agent must fail — either the gateway
refuses to route (preferred) or the direct SQLite fallback hits EACCES.

```bash
sudo -u agent-bridge-agenta agb inbox agentB
echo "exit=$?"
```

Expected output: non-zero exit with an error (one of: permission denied,
gateway rejection, or a queue cli error mentioning the unavailable DB).

- **PASS** if exit code is non-zero.
- **FAIL** if the command prints agentB's inbox — that means isolation is
  not effective and the cross-agent read containment has broken.

### 2.3 Direct DB write from isolated UID is denied

The canonical DB lives under `~/.agent-bridge/state/tasks.db` owned by the
admin UID. An isolated user must not be able to mutate it directly:

```bash
sudo -u agent-bridge-agenta sqlite3 \
  ~/.agent-bridge/state/tasks.db \
  "UPDATE tasks SET title='pwned' WHERE id='bogus';"
echo "exit=$?"
```

Expected output:

```
Error: unable to open database file
exit=1
```

(Or `Permission denied` — either message is acceptable; the key signal is
a non-zero exit and no UPDATE landing.)

- **PASS** if exit is non-zero and the DB is untouched.
- **FAIL** if the UPDATE succeeds (verify by running
  `sqlite3 ~/.agent-bridge/state/tasks.db 'SELECT id,title FROM tasks LIMIT 3;'`
  as the admin UID afterwards).

### 2.4 Claim / done round-trip

End-to-end queue path from the isolated agent:

```bash
# As admin: enqueue a task to agentA.
agb task create --to agentA --title "isolation smoke" --body "runbook check"
# Capture the returned task id, then as the isolated user:
sudo -u agent-bridge-agenta agb claim <task-id> --agent agentA
sudo -u agent-bridge-agenta agb done  <task-id> --agent agentA --note "ok"
```

- **PASS** if all three calls exit `0` and `agb inbox agentA` (as admin)
  no longer lists the task as pending.
- **FAIL** if any step errors or the task stays pending.

---

## 3. Audit attribution carries the acting UID

Hooks write structured audit records that, as of `#83` / PR `#92`, carry
three extra fields: `acting_os_uid`, `acting_os_user`, and `isolation_mode`.
Under `linux-user` isolation every record produced from an isolated agent's
session must carry that agent's UID, not the admin UID.

### 3.1 Trigger a hook

From the running tmux session for `agentA` (or via a fresh send that causes
the agent to run a Bash tool), run any trivial Bash tool call — for
example, `ls /tmp`. This drives a `PreToolUse` / `PostToolUse` pass
through `hooks/bridge_hook_common.py: write_audit`.

### 3.2 Read the per-agent audit log

```bash
tail -n 1 ~/.agent-bridge/logs/agents/agentA/audit.jsonl | python3 -m json.tool
```

Expected shape (abbreviated):

```json
{
  "action": "...",
  "target": "...",
  "detail": { ... },
  "pid": 12345,
  "host": "...",
  "acting_os_uid": 998,
  "acting_os_user": "agent-bridge-agenta",
  "isolation_mode": "linux-user"
}
```

Verify the UID matches what `id -u agent-bridge-agenta` reports:

```bash
EXPECTED_UID=$(id -u agent-bridge-agenta)
ACTUAL_UID=$(tail -n 1 ~/.agent-bridge/logs/agents/agentA/audit.jsonl \
  | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['acting_os_uid'])")
echo "expected=$EXPECTED_UID actual=$ACTUAL_UID"
```

- **PASS** if `expected` equals `actual` AND `isolation_mode` is
  `linux-user` AND `acting_os_user` equals `agent-bridge-agenta`.
- **FAIL** if the UID belongs to the admin user, if `isolation_mode` is
  `shared`, or if any of the three fields is missing. A mismatch means the
  hook ran under the wrong UID and the audit trail is not forensically
  sound.

### 3.3 Repeat for the second agent

Run the same trigger in agentB's session and confirm the tail record in
`~/.agent-bridge/logs/agents/agentB/audit.jsonl` carries `agentB`'s UID.

- **PASS** if both agents produce correctly-attributed records.
- **FAIL** if either agent's records carry the other's UID, or the admin's.

---

## 4. Operator-facing audit tools

These are the commands the operator will actually use day-to-day to confirm
audit integrity. They are listed in the `agent-bridge` help and wrap
`bridge-audit.py`.

### 4.1 Follow mode

```bash
agent-bridge audit follow --agent agentA --follow
```

- **PASS** if the command attaches and starts streaming new records as
  they land; records include the three attribution fields.
- **FAIL** if the command errors, or streams records without the new
  fields.

Stop with Ctrl-C before moving on.

### 4.2 Hash-chain verification

```bash
agent-bridge audit verify
```

Expected output: either `ok: ...` confirming the chain, or a clear error
pointing at the offending line.

- **PASS** on an `ok:` line with a non-zero record count (or the explicit
  "no hashed audit records" message for a fresh install).
- **FAIL** on any verification error — the audit log has been tampered
  with or a write was truncated, and isolation cannot be trusted until
  it's resolved.

---

## 5. Teardown

After the run, remove the smoke task if it was created in step 2.4, and
note the pass/fail outcome of each numbered section in the issue where this
validation was requested. Attach the `audit.jsonl` tail records from step
3.2 and 3.3 as evidence.

If any check failed, do **not** mark issue `#68` as validated — open a
follow-up against the subsystem whose containment broke (queue-gateway,
ACL setup, or hook attribution).
