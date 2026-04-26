# Handoff Protocol — `NEXT-SESSION.md`

Agent Bridge auto-consumes exactly **one** handoff filename: `<agent-home>/NEXT-SESSION.md`.

- SessionStart hook (`hooks/bridge_hook_common.py`, `next_session_marker`) computes a SHA-1 marker for that file and surfaces "new handoff present" to the agent on the next session.
- The hook does **NOT** scan for `handoff-*.md`, `NEXT-SESSION-*.md` (with extra suffix), `next-session.md` (lowercase), or any other naming variant. Such files are **private notes** that bridge cannot see.
- For cross-session continuity, write to exactly `<agent-home>/NEXT-SESSION.md`. Delete the file after the next session has consumed it (the role spec and the existing template instruction already say this).

## Why this matters

On 2026-04-25, an agent wrote a handoff to `~/migration-logs/.../handoff-next-session-v2.md` — a self-chosen path the bridge does not look at on session start. The next session would have idled until the next inbound message, even though a handoff existed.

For static agents (where the end-user is on Discord/Telegram/Teams and cannot run any CLI), this is a silent failure mode: the operator never sees that handoff was supposed to land. The filename contract is the only thing keeping handoffs reliable across the static-agent population.

## Optional future hardening

The SessionStart hook can be extended to scan the agent home for `handoff-*.md` or `NEXT-SESSION-*.md` (with suffix) on first turn and emit a one-line warning if any are present. This is **not** done in this PR — the warning would be noisy without a contract first, and the filename contract here is the contract.
