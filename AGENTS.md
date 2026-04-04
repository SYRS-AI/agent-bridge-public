# Repository Guidelines

## Project Structure & Module Organization
The repository is a Bash-based bridge for managing Claude and Codex agents through `tmux`. Core entry points live at the root: `agent-bridge`, thin wrapper `agb`, `bridge-start.sh`, `bridge-run.sh`, `bridge-send.sh`, `bridge-action.sh`, `bridge-task.sh`, `bridge-sync.sh`, and `bridge-daemon.sh`. `bridge-lib.sh` is now a thin loader; shared shell implementation lives under `lib/`. Queue state lives in `bridge-queue.py` with SQLite data under `state/tasks.db`. Treat `shared/` as handoff notes for humans or agents, and treat `state/` plus `logs/` as generated runtime artifacts, not hand-edited source.

## Build, Test, and Development Commands
There is no build step; scripts run directly with Bash.

- `bash bridge-start.sh --list`: show registered agents and session metadata.
- `bash bridge-start.sh tester --dry-run`: verify roster lookup and launch command without starting `tmux`.
- `bash bridge-daemon.sh status|sync|start|stop`: inspect or manage roster sync, queue heartbeats, and idle nudges.
- `./agent-bridge status` or `./agent-bridge status --watch`: show the bridge dashboard with queue totals, agent load, and open tasks.
- `bash bridge-task.sh create --to tester --title "retest" --body-file shared/report.md`: enqueue work instead of interrupting another agent.
- `./agent-bridge inbox tester`, `./agent-bridge claim 12 --agent tester`, `./agent-bridge done 12 --agent tester`: inspect and advance queued work.
- `bash bridge-send.sh --urgent tester "prod issue" --wait 5`: send a direct interrupt only when the queue cannot wait.
- `./agent-bridge --codex --name smoke --workdir /path --no-attach`: create an ad hoc dynamic agent.
- `./agent-bridge --codex --name worker-a --prefer new`: create an isolated git worktree worker when a shared repo already has dormant static roles.
- `./agent-bridge worktree list`: inspect managed worktree workers and their repo paths.
- `./scripts/install-shell-integration.sh --shell zsh --apply`: install zsh integration so `agent-bridge`, `agb`, and bridge aliases work without `./`.
- `./scripts/smoke-test.sh`: run an isolated end-to-end bridge smoke test without touching live bridge state.
- `shellcheck *.sh agent-bridge agb`: lint the shell entry points before submitting changes.

## Coding Style & Naming Conventions
Use Bash with `#!/usr/bin/env bash` and `set -euo pipefail` unless a loop intentionally handles non-zero exit codes, as in `bridge-run.sh`. Indent with two spaces inside functions and `case` arms. Keep reusable helpers under `lib/` and prefix them `bridge_`. Use uppercase names for exported configuration such as `BRIDGE_*`, and lowercase names for local variables. Follow the existing naming pattern: `bridge-<verb>.sh` for primary commands.

## Testing Guidelines
This snapshot does not include a full unit test suite, so rely on linting plus manual smoke checks. At minimum, run `shellcheck`, `./scripts/smoke-test.sh`, one `--dry-run` path for the script you changed, and one daemon pass via `bash bridge-daemon.sh sync`. Test heartbeat-sensitive changes in an isolated `BRIDGE_HOME` with temporary tmux sessions so live agents are not interrupted.

## Commit & Pull Request Guidelines
This working copy does not include `.git`, so there is no local history to infer conventions from. Use short imperative commit subjects such as `bridge: add task queue heartbeat`. Keep pull requests narrow, list the scripts touched, include the exact manual verification commands you ran, and call out any changes to queue semantics, roster behavior, `tmux` session handling, or generated `state/` file formats.
