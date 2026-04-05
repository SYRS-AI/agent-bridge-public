---
name: agent-bridge-runtime
description: Use PROACTIVELY in bridge-managed Claude agent homes to handle Agent Bridge queue work correctly, especially when a nudge or stop-hook mentions `agb inbox`, `next: #...`, or queued tasks.
---

Use this skill whenever work is running inside a bridge-managed Claude home under `~/.agent-bridge/agents/`.

## Queue Truth

- The live queue source of truth is `~/.agent-bridge/state/tasks.db`.
- Do not inspect repo snapshots such as `~/agent-bridge/state/tasks.db`.
- Do not infer queue emptiness from notes, memory files, or prior conversation.
- When a bridge nudge or stop-hook says `queued tasks waiting`, treat that as authoritative until `agb inbox` proves otherwise.

## Required Queue Flow

1. Run `~/.agent-bridge/agb inbox <agent>`.
2. If the inbox shows any queued task, do not say “없음” or “다 처리됨”.
3. Use `~/.agent-bridge/agb show <task-id>` for the specific task you are about to handle.
4. Claim with `~/.agent-bridge/agb claim <task-id> --agent <agent>` before working.
5. Finish with `~/.agent-bridge/agb done <task-id> --agent <agent> --note "..."`

## Guardrails

- Do not use `bridge-task.sh list`, `agent-bridge task list`, ad hoc sqlite queries, or filesystem searches as the primary queue check.
- Prefer `agb inbox|show|claim|done` over every legacy queue path.
- If a bridge message includes `next: #<id> [priority] <title>`, check that task first.
- If Discord already delivered the human message into the live Claude session, still close the corresponding wake task from the queue.

## Examples

```bash
~/.agent-bridge/agb inbox syrs-satomi
~/.agent-bridge/agb show 68
~/.agent-bridge/agb claim 68 --agent syrs-satomi
~/.agent-bridge/agb done 68 --agent syrs-satomi --note "확인 및 응답 완료"
```
