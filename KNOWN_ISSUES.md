# Known Issues

This file tracks operational caveats that matter when extending the bridge.

## 1. Claude trust prompt on first run

Symptom:

- A fresh Claude session in a new folder may stop at a trust prompt before it accepts normal bridge input

Impact:

- The first interaction may require manual confirmation

Workaround:

- Confirm the trust prompt once in that folder
- Future resume flows can then proceed normally

## 2. Urgent sends still depend on prompt state

Current behavior:

- Claude urgent sends now use literal typing plus submit
- Codex urgent sends still use paste plus submit

Residual risk:

- If the target session is in an unusual TUI state or nonstandard input mode, submit behavior may still vary

Operator guidance:

- Keep urgent messages short
- Prefer queue-based work handoff
- If an urgent send looks stuck, inspect the pane before retrying

## 3. Fresh installs have no static roles

This is intentional.

Impact:

- `bridge-start.sh --list` will show no static roles until a user creates `agent-roster.local.sh`

Operator guidance:

- Use `agent-bridge --codex|--claude --name ...` immediately
- Add local static roles only when they add value

## 4. Runtime state is local and untracked

The following are not committed:

- `state/`
- `logs/`
- `shared/`
- `agent-roster.local.sh`

Impact:

- Another machine will not inherit your live sessions, queue history, or local static roles

Operator guidance:

- Treat these as local runtime state, not deployable source

## 5. Smoke test is synthetic

`scripts/smoke-test.sh` validates:

- shell syntax
- optional shellcheck
- isolated daemon startup
- isolated static role launch
- queue create/claim/done
- list, summary, status, and sync paths

It does not validate:

- real Claude CLI behavior
- real Codex CLI behavior
- model-side resume semantics

Use live smoke sessions for those.

## 6. macOS requires non-system Bash

macOS ships Bash `3.2`, but the bridge uses associative arrays.

Operator guidance:

- Install Homebrew Bash
- Put Homebrew `bin` ahead of `/bin` in your shell `PATH`
