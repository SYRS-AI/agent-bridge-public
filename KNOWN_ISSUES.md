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

## 7. Claude custom channel wake is currently disabled

Current behavior:

- the repo still contains `bridge-channel-server.py`, `bridge-channels.py`, and `lib/bridge-channels.sh`
- the active runtime path does not use them
- Claude wake currently relies on `Stop` hook idle markers plus short idle-only `tmux` sends

Reason:

- `--dangerously-load-development-channels` is not suitable for unattended setup or OSS onboarding because it introduces an interactive trust step

Operator guidance:

- treat the channel helpers as backlog / future capability
- restart Claude sessions after bridge deploys that change idle wake behavior

## 8. `bridge-knowledge search` default auto-switches to hybrid when a v2 index exists

Current behavior:

- with no index present the default path stays legacy regex for backwards compatibility
- once an operator runs `bridge-memory rebuild-index --index-kind bridge-wiki-hybrid-v2`, `bridge-knowledge search` automatically prefers the hybrid engine for that agent
- `--legacy-text` is the explicit opt-out flag that forces the regex path regardless

Reason:

- the hybrid engine is higher quality when the index is available; the auto-switch saves operators from having to remember `--hybrid` on every call

Operator guidance:

- treat "did I build a v2 index?" as the effective toggle
- if result shape changes after an index rebuild, that is expected — rerun with `--legacy-text` to compare

## 9. Teams `/auth/callback` endpoint authenticates by state-token possession alone

Current behavior:

- the Teams plugin exposes `/auth/callback` for the ms365 authorization-code pairing flow
- incoming requests are validated only by the tight state regex (`^[A-Za-z0-9_-]{8,128}$`) and written atomically under `$BRIDGE_HOME/shared/ms365-callbacks/<state>.json`
- there is no separate check that a matching `pair_start` is currently pending

Reason:

- the ms365 plugin generates state as a random UUID with a 15-minute expiry, and `pair_poll` consumes and unlinks the callback file on success or error
- for the hosted/local-only deployment targets this is sufficient in practice, and the atomic file write keeps the endpoint safe against concurrent/partial writes

Operator guidance:

- do not expose the Teams plugin's `/auth/callback` to the public internet without additional ingress-level auth (mTLS, ingress token, IP allowlist)
- if you operate a multi-tenant hosted Teams plugin, layer your own `state` allowlist or HMAC before this handler
