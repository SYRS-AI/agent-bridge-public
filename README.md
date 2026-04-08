# Agent Bridge

[![CI](https://github.com/SYRS-AI/agent-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/SYRS-AI/agent-bridge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](./LICENSE)

Agent Bridge is a `tmux`-based coordination layer for running Claude Code and Codex side by side. It provides a shared roster, queue-first task handoff, live status views, urgent interrupts, and optional git worktree isolation for parallel workers.

The primary CLI is `agent-bridge`. A bundled shorthand wrapper, `agb`, calls the same entry point.

This repository is designed for trusted local projects. It assumes you are intentionally granting Claude Code or Codex access to the directory where you launch them.

If you hand this repository URL to another Claude or Codex agent, the preferred bootstrap is now AI-native: the helper agent installs the bridge, bootstraps one long-lived admin role, and then hands control to that admin role.

## Updating an existing live install

Use the repo checkout as source of truth, then update the live bridge while preserving local operator customizations:

```bash
./agent-bridge upgrade --pull --restart-daemon
```

This preserves:
- `agent-roster.local.sh`
- `state/`, `logs/`, `shared/`
- `backups/`, `worktrees/`
- live agent homes under `agents/<agent>/`

## AI-Native Install (한국어)

원하는 최종 상태는 이겁니다.

1. 사용자는 Claude Code만 설치한다.
2. Claude Code에게 이 레포를 설치하라고 시킨다.
3. 설치가 끝나면 Claude Code를 종료한다.
4. 사용자는 `agb admin`만 실행한다.
5. 이후부터는 관리자 에이전트가 나머지 온보딩과 운영을 안내한다.

즉 사용자가 `agent-roster.local.sh`, `setup discord`, `daemon ensure`, `cron create` 같은 세부 명령을 외우는 흐름이 아니라, 관리자 에이전트 중심 운영으로 바로 넘어가는 설치를 기준으로 한다.

### 추천 사용법

새 컴퓨터에서 Claude Code를 아무 폴더에서나 열고, 아래처럼 말하면 됩니다.

```text
Install Agent Bridge from https://github.com/SYRS-AI/agent-bridge.

Read the README and use the AI-native bootstrap flow.
Before you run any bridge script, detect the OS and verify prerequisites.

On macOS:
- if Homebrew is missing, install it first
- install or upgrade bash, tmux, python3, git, and shellcheck with Homebrew
- make sure Homebrew's bin directory is first in PATH
- do not continue until `bash --version` reports Bash 4 or newer

On Linux:
- install bash, tmux, python3, git, and shellcheck with the system package manager if needed

Create one long-lived admin role for me.
Do the shell integration, bridge bootstrap, and daemon setup, including the macOS LaunchAgent when supported.
Stop when the final handoff is: close this session and run `agb admin`.

If Telegram or Discord credentials are missing, explain exactly how to get them in beginner-friendly steps, then continue the install.
Do not ask me to type bridge commands manually unless you need a token, a user/channel/chat ID, login approval, or a 2FA step.
```

설치 에이전트는 내부적으로 아래 순서를 강하게 지키는 게 좋습니다.

1. OS 감지
2. 필수 도구 확인: `bash`, `tmux`, `python3`, `git`, 그리고 `claude` 또는 `codex`
3. macOS면 Homebrew Bash가 실제 기본 `bash`로 잡히는지 확인
2. 레포 clone
3. `./agent-bridge bootstrap ...`
4. shell integration 반영
5. 관리자 역할 생성 + 채널 설정 + preflight
6. daemon ensure
7. 마지막 handoff 안내: `agb admin`

When a channel plugin is already configured in Claude Code, bootstrap can reuse
the plugin token from `~/.claude/channels/<kind>/.env`. Otherwise, pass
`--channel-account <name>` or let the installer run interactively and paste the
token when prompted.

### macOS 클린 설치에서 특히 중요한 점

- macOS 기본 `/bin/bash` 는 `3.2`라서 그대로는 안 됩니다.
- Agent Bridge는 associative array를 쓰기 때문에 Bash `4+`가 필요합니다.
- 설치 에이전트는 반드시:
  1. `brew install bash tmux python shellcheck git`
  2. `export PATH="$(brew --prefix)/bin:$PATH"`
  3. `bash --version`
  순서로 확인하고, `bash`가 실제로 Homebrew Bash를 가리키는지 확인한 뒤에 bootstrap을 진행해야 합니다.

이 단계가 빠지면 "설치는 된 것 같은데 `agb admin`에서 갑자기 깨짐" 같은 증상이 나기 쉽습니다.

### 채널 자격 증명이 없을 때 설치 에이전트가 안내해야 할 내용

#### Telegram

가장 쉬운 경로는 Claude Code Telegram plugin이 이미 연결돼 있는 경우입니다. 그러면 bootstrap이 `~/.claude/channels/telegram/.env`를 재사용할 수 있습니다.

처음부터 만드는 경우에는 설치 에이전트가 아래 단계를 설명해야 합니다.

1. Telegram에서 `@BotFather`를 연다.
2. `/newbot` 을 보내고 봇 이름과 username을 만든다.
3. BotFather가 돌려준 bot token을 복사한다.
4. 그 봇에게 직접 메시지를 한 번 보낸다.
5. 브라우저에서 아래 URL을 열어 JSON을 확인한다.

```text
https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates
```

6. 응답 JSON에서 아래 두 값을 찾는다.
   - `message.from.id` → `--allow-from`
   - `message.chat.id` → `--default-chat`

초보자에게는 "토큰은 BotFather가 주고, user/chat ID는 `getUpdates` JSON에서 복사한다"라고 설명하는 게 가장 단순합니다.

#### Discord

가장 쉬운 경로는 Claude Code Discord plugin이 이미 연결돼 있는 경우입니다. 그러면 bootstrap이 기존 channel runtime을 재사용할 수 있습니다.

처음부터 만드는 경우에는 설치 에이전트가 아래 단계를 설명해야 합니다.

1. <https://discord.com/developers/applications> 에서 `New Application`
2. `Bot` 탭에서 봇을 만든다.
3. `Reset Token` 또는 token 표시 버튼을 눌러 bot token을 복사한다.
4. 필요하면 `Message Content Intent`를 켠다.
5. `OAuth2 -> URL Generator`에서 bot invite URL을 만들고 서버에 초대한다.
6. Discord 앱에서 `User Settings -> Advanced -> Developer Mode`를 켠다.
7. 원하는 채널을 우클릭해서 `Copy Channel ID`

초보자에게는 "bot token은 Discord Developer Portal, channel ID는 Developer Mode 켠 뒤 채널 우클릭"이라고 설명하면 됩니다.

### 핵심 명령

사람이 직접 브리지를 설치할 때도, `init`보다 `bootstrap`을 우선 권장합니다.

예시:

```bash
./agent-bridge bootstrap \
  --admin manager \
  --engine claude \
  --channels plugin:telegram@claude-plugins-official \
  --allow-from <telegram-user-id> \
  --default-chat <telegram-chat-id>
```

먼저 계획만 보고 싶으면:

```bash
./agent-bridge bootstrap --admin manager --engine claude --dry-run --json
```

bootstrap이 끝나면 handoff는 이것 하나입니다.

```bash
agb admin
```

만약 현재 터미널이 shell integration을 아직 reload하지 않았다면, 새 shell을 열거나 `exec zsh` / `exec bash` 한 번만 한 뒤 `agb admin`을 실행하면 됩니다.

For Claude plugin-backed channels, the explicit form is safest:

- `plugin:telegram@claude-plugins-official`
- `plugin:discord@claude-plugins-official`

The bridge will auto-qualify `plugin:telegram` and `plugin:discord` to the official Claude plugin marketplace ids, and it will also try to resolve other bare plugin names from `~/.claude/plugins/installed_plugins.json`.

Companion docs for maintainers:

- [`ARCHITECTURE.md`](./ARCHITECTURE.md)
- [`OPERATIONS.md`](./OPERATIONS.md)
- [`KNOWN_ISSUES.md`](./KNOWN_ISSUES.md)
- [`agents/README.md`](./agents/README.md)
- [`agents/SYNC-MODEL.md`](./agents/SYNC-MODEL.md)
- [`agents/WORKSPACE-MIGRATION-PLAN.md`](./agents/WORKSPACE-MIGRATION-PLAN.md)

## Highlights

- Start ad hoc Claude or Codex agents from the current directory with `agent-bridge`
- Keep long-lived named roles in a static roster
- Route normal collaboration through a durable SQLite task queue
- Reserve direct messages for urgent interrupts only
- Watch queue load, active sessions, stale health, and open work in a single dashboard
- Spawn isolated git worktree workers when one checkout is not enough

## Requirements

- Bash 4+ available in `PATH` for running the bridge scripts
- `tmux`
- `python3`
- `git`
- At least one agent CLI:
  - `claude`
  - `codex`

Optional but recommended:

- `shellcheck`
- GitHub CLI `gh`

## Install

### macOS

Your interactive shell can stay `zsh`. The bridge scripts themselves run with `bash`, so the only requirement is that a modern Bash is available in `PATH`.

Install the base tools:

```bash
brew install bash tmux python shellcheck
```

Make sure Homebrew Bash is first in `PATH`:

```bash
echo 'export PATH="$(brew --prefix)/bin:$PATH"' >> ~/.zshrc
exec zsh
bash --version
```

If `bash --version` shows the macOS system Bash `3.2`, the bridge will not work correctly.

### Linux

Install the same toolchain with your package manager. Example for Ubuntu:

```bash
sudo apt update
sudo apt install -y bash tmux python3 python3-venv shellcheck git
```

### Clone

If you have GitHub CLI:

```bash
gh repo clone SYRS-AI/agent-bridge ~/agent-bridge
cd ~/agent-bridge
```

Or use Git directly:

```bash
git clone https://github.com/SYRS-AI/agent-bridge.git ~/agent-bridge
cd ~/agent-bridge
```

### Agent CLIs

Install and authenticate the CLIs you want to use:

- `claude`
- `codex`

The bridge does not install those tools for you.

### Optional legacy migration

Some bridge features are kept for teams migrating from an older agent runtime:

- cron inventory / enqueue / cleanup helpers
- `tools/memory-manager.py`
- legacy workspace migration docs under [`agents/`](./agents/README.md)

Clean installs can ignore those features entirely.

### Optional static roster

Fresh installs ship with no static roles. You can use dynamic agents with `agent-bridge` immediately and ignore the roster entirely.

If you want long-lived named roles like `developer` or `tester`, create a local roster file:

```bash
cp ~/agent-bridge/agent-roster.local.example.sh ~/agent-bridge/agent-roster.local.sh
```

`agent-roster.local.sh` is git-ignored and is sourced after the default roster, so you can add your own workdirs, descriptions, launch commands, and actions without changing the tracked repo.

By default, static roles can live under the standard bridge-owned home root:

```bash
BRIDGE_AGENT_HOME_ROOT="$HOME/.agent-bridge/agents"
```

If `BRIDGE_AGENT_WORKDIR["agent"]` is omitted, the bridge now defaults that role to `$BRIDGE_AGENT_HOME_ROOT/<agent>`. For tracked profiles, `profile deploy` also defaults to that same target.

Only declare `BRIDGE_AGENT_PROFILE_HOME` when the live CLI home differs from the workdir:

```bash
BRIDGE_AGENT_WORKDIR["analyst"]="$HOME/project-analyst"
BRIDGE_AGENT_PROFILE_HOME["analyst"]="$HOME/.agent-bridge/agents/analyst"
```

If one static role should act as the bridge admin, set it explicitly:

```bash
BRIDGE_ADMIN_AGENT_ID="developer"
```

After that, `agent-bridge admin` and `agb admin` always open that role using
its configured engine and home, regardless of the current working directory.

For Claude static roles, keep `BRIDGE_AGENT_LAUNCH_CMD` free of `-c`,
`--continue`, or `--resume`. The bridge manages continue/resume itself so
subcommands like `agent-bridge admin --no-continue` can work predictably.

### Optional zsh shell integration

If you use `zsh` and do not want to type `./agent-bridge`, install the shell integration:

```bash
cd ~/agent-bridge
./scripts/install-shell-integration.sh --shell zsh --apply
exec zsh
```

After that you can run:

```bash
agent-bridge status
agb status
bridge-start --list
bridge-daemon status
```

The integration adds the repo to `PATH`, registers completion for `agent-bridge` and `agb`, and installs convenience aliases for the `bridge-*.sh` commands.

### Deploy into a live local install

If you develop in `~/agent-bridge` but run the bridge from `~/.agent-bridge`, use the deploy helper instead of copying files by hand:

```bash
cd ~/agent-bridge
./scripts/deploy-live-install.sh --dry-run
./scripts/deploy-live-install.sh --restart-daemon
```

The deploy helper copies every tracked file from the working tree, verifies the copied bytes, and preserves target-only runtime files such as `agent-roster.local.sh`, `state/`, `logs/`, and `shared/`.

### Claude idle wake

Claude roles now wake through the local tmux session only when the bridge has
explicitly marked them idle via the installed hooks:

- `Stop` hook writes `idle-since` and prints a short inbox summary as additional context
- `UserPromptSubmit` clears `idle-since`
- the daemon sends only a short line such as `agb inbox <agent>` when `idle-since` exists

For bridge-owned Claude homes under `BRIDGE_AGENT_HOME_ROOT`, the bridge now
keeps one shared settings file at `<agent-home-root>/.claude/settings.json`
and symlinks each `<agent-home>/.claude/settings.json` to it. Claude workdirs
outside the bridge-owned home root keep using a local settings file.

This keeps the durable payload in the queue and avoids mid-turn delivery.

### Optional external channel notifications

`bridge-notify.py` still supports explicit Discord webhooks or Telegram posts,
but that is not the core A2A delivery path for Claude roles.

Use these only when you intentionally want an out-of-band notification:

```bash
BRIDGE_AGENT_NOTIFY_KIND["tester"]="discord-webhook"
BRIDGE_AGENT_NOTIFY_TARGET["tester"]="<discord-webhook-url>"
BRIDGE_AGENT_NOTIFY_ACCOUNT["tester"]="default"
```

### Backlog: custom Claude channels

The repo still includes the dormant channel-webhook helpers:

- `bridge-channel-server.py`
- `bridge-channels.py`
- `lib/bridge-channels.sh`

They are currently disabled in the runtime path because
`--dangerously-load-development-channels` is not suitable for unattended setup
or OSS onboarding. If Claude later supports safe custom channels without that
prompt, the bridge can switch back to channel-based wake.

### Manual bootstrap (advanced)

If you are not using the AI-native installer flow above, use `bootstrap`
instead of wiring shell integration, `init`, and daemon setup by hand.

```bash
./agent-bridge bootstrap \
  --admin manager \
  --engine claude \
  --session manager \
  --channels plugin:telegram@claude-plugins-official \
  --allow-from <telegram-user-id> \
  --default-chat <telegram-chat-id>
```

The bootstrap flow can:

- install shell integration for `zsh` or `bash`
- create the static role if it does not exist yet
- scaffold the agent home from the public template
- run channel setup for Discord and/or Telegram
- save the chosen role as `BRIDGE_ADMIN_AGENT_ID`
- run the same `setup agent` preflight used by later manager operations
- hand off to the admin role with `agb admin`

Use `--dry-run --json` first if you want to inspect the planned changes without
writing files.

### Onboard a Discord-backed agent

If an agent should read and reply in Discord, set its primary channel metadata
in `agent-roster.local.sh` first:

```bash
BRIDGE_AGENT_CHANNELS["tester"]="plugin:discord@claude-plugins-official"
BRIDGE_AGENT_DISCORD_CHANNEL_ID["tester"]="<channel-id>"
```

Then run the guided setup:

```bash
./agent-bridge setup discord tester
./agent-bridge setup telegram tester --allow-from <telegram-user-id>
./agent-bridge setup agent tester
./agent-bridge agent create reviewer --engine claude
./agent-bridge agent start reviewer --dry-run
./agent-bridge setup admin tester
```

After `setup admin`, the expected handoff command is:

```bash
agb admin
```

`setup discord` writes the runtime Discord files into the agent workdir:

- `<workdir>/.discord/.env`
- `<workdir>/.discord/access.json`

The wizard can:

- reuse the existing `.discord` token
- import a bot token from a legacy runtime config during migration
- scaffold the allowlist for one or more channel IDs
- validate the bot token
- send a small write-access test message unless you pass `--skip-send-test`

`setup telegram` writes the runtime Telegram files into the agent workdir:

- `<workdir>/.telegram/.env`
- `<workdir>/.telegram/access.json`

The Telegram setup flow can:

- reuse the existing `.telegram` token
- import a bot token from a legacy runtime config during migration
- scaffold the allowlist of permitted user IDs
- set a default chat/thread target for notifications
- validate the bot token with `getMe`
- send a small write-access test message unless you pass `--skip-send-test`

For broader preflight, `setup agent` also checks:

- roster presence and workdir/session wiring
- Claude `Stop` + `UserPromptSubmit` hook installation into `<workdir>/.claude/settings.json`
  - bridge-owned Claude homes use the shared `<agent-home-root>/.claude/settings.json` symlink target
- Claude webhook channel entry in `<workdir>/.mcp.json` when a webhook port is enabled
- `CLAUDE.md` presence for Claude roles
- tracked profile status
- `bridge-start.sh --dry-run`

Use `--test-start` only when you want a real tmux launch smoke test:

```bash
./agent-bridge setup agent tester --test-start
```

### Optional: inspect and import existing cron jobs

If you are migrating existing cron jobs into Agent Bridge, start with the read-only inventory and then import them into the bridge-native store:

```bash
./agent-bridge cron inventory
./agent-bridge cron inventory --family memory-daily --limit 10
./agent-bridge cron inventory --mode one-shot --limit 20
./agent-bridge cron show <job-id>
./agent-bridge cron import --dry-run
./agent-bridge cron import
./agent-bridge cron enqueue <memory-daily-job-id> --slot 2026-04-05 --dry-run
./agent-bridge cron enqueue <monthly-highlights-job-id> --dry-run
./agent-bridge cron sync --dry-run
./agent-bridge cron errors report --limit 20
./agent-bridge cron cleanup report
./agent-bridge cron cleanup prune --dry-run
```

`cron inventory`, `show`, `enqueue`, `errors`, and `cleanup` prefer `~/.agent-bridge/cron/jobs.json` when it exists. Before the cutover import runs, they fall back to `BRIDGE_SOURCE_CRON_JOBS_FILE` so you can still inspect an older source snapshot. Use `cron import` once to copy that source into the bridge-native store.

`cron enqueue` now works for recurring jobs in general. It writes a materialized note under `shared/cron/`, records per-slot manifests under `state/cron/dispatch/`, and creates compact `[cron-dispatch]` queue tasks for the bridge daemon. The daemon claims those tasks, runs `agent-bridge cron run-subagent <run-id>` in a disposable child, then closes the dispatch task when the result artifact is ready.

Cron delivery targets are resolved against registered long-lived roles, not only currently running tmux sessions. A sleeping role can still receive cron work because the daemon auto-starts it when queued work appears. If a source job references an agent that is not mapped to any launchable long-lived role, set `BRIDGE_CRON_AGENT_TARGET["source-agent"]="bridge-role"` or configure `BRIDGE_CRON_FALLBACK_AGENT` so results go to a manager/admin role instead of hard-failing.

For `memory-daily` the default slot is `YYYY-MM-DD`. For `monthly-highlights` it is `YYYY-MM`. Other recurring jobs default to the current minute as an ISO timestamp, so repeated enqueue calls on the same day do not collapse into one slot.

`cron sync` is the bridge-owned recurring scheduler. It scans the bridge-native recurring job store, derives due occurrence slots, and enqueues each occurrence through the same disposable-child path. When `BRIDGE_CRON_SYNC_ENABLED=1`, the daemon also drains queued `[cron-dispatch]` tasks itself, so recurring jobs do not wake long-lived agent sessions unless a run explicitly needs a separate `[cron-followup]` task. `BRIDGE_LEGACY_CRON_SYNC_ENABLED` and the older `BRIDGE_OPENCLAW_CRON_SYNC_ENABLED` name still work as compatibility aliases.

If your daemon environment does not inherit the same `PATH` as your interactive shell, set `BRIDGE_CLAUDE_BIN` or `BRIDGE_CODEX_BIN` explicitly in `agent-roster.local.sh`. The cron runner also searches common install locations such as `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`.

`cron errors report` is the report-only view for recurring cron failures. It shows `lastErrorAt`, consecutive error counts, family and prefix summaries, and the highest-error outliers first so model-switch fallout is easy to separate from older failures.

`cron cleanup report` and `cron cleanup prune --dry-run` are the safe way to inspect stale one-shot jobs before deleting them. The current prune target is intentionally narrow: expired `schedule.kind=at` jobs with `deleteAfterRun=true` and `enabled=false`.

### Bridge-native cron jobs

For recurring work defined inside Agent Bridge itself, use the bridge-native cron store:

```bash
./agent-bridge cron list --agent <agent>
./agent-bridge cron create --agent <agent> --schedule "0 9 * * *" --title "Daily check" --payload "Review the daily queue and summarize anything that needs follow-up."
./agent-bridge cron update <job-id> --schedule "0 10 * * *"
./agent-bridge cron delete <job-id>
```

Bridge-native jobs live at `~/.agent-bridge/cron/jobs.json`. `cron import` is the one-shot cutover step for an older source snapshot; after that, `cron sync` reads the bridge-native store directly.

The status dashboard also includes a lightweight health check for active sessions. It classifies them as `ok`, `warn`, or `crit` from recorded session activity age. Inactive on-demand roles are not treated as stale. Defaults are `BRIDGE_HEALTH_WARN_SECONDS=3600` and `BRIDGE_HEALTH_CRITICAL_SECONDS=14400`, and you can override them in `agent-roster.local.sh`.

For static roles, an explicit `BRIDGE_AGENT_IDLE_TIMEOUT["agent"]="0"` means "always on": the daemon will not auto-stop that role, and it will restart the role automatically if its tmux session disappears.

### Optional: derived memory index

The memory wiki stores source-of-truth data in markdown files. If you want a
faster derived SQLite index on top of that wiki, you can rebuild and query it:

```bash
./agent-bridge memory rebuild-index --agent <agent-id>
./agent-bridge memory query --agent <agent-id> --query "recent incident summary"
```

The bundled compatibility helper can also read the derived index, plus older
legacy memory SQLite files when you are migrating an existing install:

```bash
python3 tools/memory-manager.py search --agent <agent-id> "recent incident summary"
```

### Start the daemon

```bash
bash bridge-daemon.sh ensure
```

The daemon keeps the live roster, queue heartbeats, and idle nudges in sync.

On macOS you can also register it as a `LaunchAgent` so crashes auto-restart:

```bash
./scripts/install-daemon-launchagent.sh --apply --load
launchctl print gui/$UID/ai.agent-bridge.daemon
```

## Quick Start

### Run an agent against the bridge repo itself

If you want an agent to work on `agent-bridge`:

```bash
cd ~/agent-bridge
./agent-bridge --codex --name dev
```

Or:

```bash
cd ~/agent-bridge
./agent-bridge --claude --name tester
```

### Run an agent against another project

From the target repo:

```bash
cd ~/some-project
~/agent-bridge/agent-bridge --codex --name dev
```

The current directory becomes the agent's workdir. `agent-bridge` will also install a small project-local bridge skill:

- Codex: `.agents/skills/agent-bridge/SKILL.md`
- Claude: `.claude/skills/agent-bridge/SKILL.md`
- Bridge-owned Claude homes also get:
  - `.claude/skills/agent-bridge-runtime/SKILL.md`
  - `.claude/skills/cron-manager/SKILL.md`

### Queue-first workflow

Start an agent:

```bash
./agent-bridge --claude --name tester
```

Create work:

```bash
./agent-bridge task create --to tester --title "check this" --body-file ~/agent-bridge/shared/note.md
```

Inspect or complete work:

```bash
./agent-bridge inbox tester
./agent-bridge claim 1 --agent tester
./agent-bridge done 1 --agent tester --note "done"
```

Send a direct interrupt only when waiting for the queue is not acceptable:

```bash
./agent-bridge urgent tester "Check your inbox now."
```

## Core Concepts

### Static roles

Static roles are optional. If you want long-lived names such as `developer`, `tester`, `codex-developer`, or `codex-tester`, define them in `agent-roster.local.sh`. Otherwise, just use dynamic agents with `agent-bridge`.

### Tracked agent profiles

If you are migrating existing long-lived agents, use [`agents/_template/`](./agents/_template/CLAUDE.md)
as the public scaffold and keep real production profiles in a private companion
repo or a local untracked tree.

- the public repo intentionally ships only the `_template/` profile scaffold
- `agent-bridge profile status|diff|deploy` still manages explicit copy-based promotion into the live home
- optional migration planning docs live under [`agents/`](./agents/README.md)

### Dynamic agents

Dynamic agents are created with `agent-bridge --codex|--claude --name ...` from the current directory. They are good for one-off workers and local experiments.

### Queue first, urgent second

Normal collaboration should go through the queue:

- `agent-bridge task create`
- `agent-bridge inbox`
- `agent-bridge claim`
- `agent-bridge done`
- `agent-bridge handoff`

Use `agent-bridge urgent` only when another agent must be interrupted immediately.

### Worktree workers

If one repository needs multiple active writers, prefer:

```bash
./agent-bridge --codex --name reviewer-a --prefer new
```

That creates an isolated git worktree under `~/.agent-bridge/worktrees/` instead of reusing the shared checkout.

## Common Commands

```bash
./agent-bridge status
./agb status
./agent-bridge status --watch
./agent-bridge list
./agent-bridge profile status --all
./agent-bridge profile diff <agent>
./agent-bridge profile deploy <agent> --dry-run
./agent-bridge setup discord tester
./agent-bridge setup telegram tester --allow-from <telegram-user-id>
./agent-bridge setup agent tester
./agent-bridge cron inventory --mode one-shot --limit 20
./agent-bridge cron list --agent <agent>
./agent-bridge cron create --agent <agent> --schedule "0 9 * * *" --title "Daily check"
./agent-bridge cron enqueue <memory-daily-job-id> --slot 2026-04-05 --dry-run
./agent-bridge cron enqueue <monthly-highlights-job-id> --dry-run
./agent-bridge cron errors report --limit 20
./agent-bridge cron cleanup report
./agent-bridge kill 1
./agent-bridge kill all
./agent-bridge worktree list
bash bridge-start.sh --list
bash bridge-daemon.sh status
bash ./scripts/oss-preflight.sh
```

## Repository Layout

- `agent-bridge`: primary operator entry point
- `agb`: shorthand wrapper for `agent-bridge`
- `bridge-start.sh`, `bridge-run.sh`: session startup paths
- `bridge-task.sh`, `bridge-queue.py`: queue API and SQLite backend
- `bridge-setup.sh`, `bridge-setup.py`: Discord/Telegram onboarding and agent preflight checks
- `bridge-cron.sh`, `bridge-cron.py`, `bridge-cron-scheduler.py`: bridge-native cron CRUD plus legacy cron inventory, scheduling, queue adapters, and cleanup helpers
- `bridge-send.sh`, `bridge-action.sh`: urgent interrupts and predefined actions
- `bridge-status.sh`, `bridge-daemon.sh`, `bridge-sync.sh`: status, background sync, and heartbeats
- `bridge-lib.sh`: thin loader for shared shell modules
- `lib/`: modular shell implementation split by concern (`core`, `agents`, `tmux`, `skills`, `state`)
- `agent-roster.sh`: static role definitions
- `shared/`, `logs/`, `state/`: runtime artifacts and handoff files

## Troubleshooting

### macOS uses Bash 3.2

Fix `PATH` so Homebrew Bash comes first:

```bash
echo 'export PATH="$(brew --prefix)/bin:$PATH"' >> ~/.zshrc
exec zsh
```

### Claude shows a trust prompt on first run

That is expected in a new folder. Confirm the prompt once, then future resumes will work normally.

### Discord replies fail with "channel is not allowlisted"

Run:

```bash
./agent-bridge setup discord <agent>
```

Make sure the intended channel ID is present in `<workdir>/.discord/access.json`
under `groups`, then restart the agent session if it was already running. If the
agent should always launch with Discord or Telegram attached, declare that in
`BRIDGE_AGENT_CHANNELS["<agent>"]` instead of relying on a hand-written raw
`--channels ...` launch command.

### The daemon is not running

```bash
bash ~/agent-bridge/bridge-daemon.sh ensure
bash ~/agent-bridge/bridge-daemon.sh status
```

If it keeps dying, inspect:

```bash
tail -n 80 ~/.agent-bridge/state/daemon.log
tail -n 80 ~/.agent-bridge/state/daemon-crash.log
tail -n 80 ~/.agent-bridge/state/launchagent.log
```

### You want to inspect everything at once

```bash
~/agent-bridge/agent-bridge status
~/agent-bridge/agent-bridge list
~/agent-bridge/agent-bridge summary
```

## Verification

For bridge changes, the minimum local check is:

```bash
bash -n *.sh agent-bridge agb
shellcheck *.sh agent-bridge agb
./scripts/smoke-test.sh
```

## Project Metadata

- License: [`MIT`](./LICENSE)
- Contributing guide: [`CONTRIBUTING.md`](./CONTRIBUTING.md)
- Code of conduct: [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md)
- Security policy: [`SECURITY.md`](./SECURITY.md)
