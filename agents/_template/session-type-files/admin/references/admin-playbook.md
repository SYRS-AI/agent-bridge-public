# Admin Playbook

## Purpose
- This file gives a fresh admin session enough operator context to manage a local Agent Bridge install before it has built up much memory.
- Keep this file generic. Put install-specific facts in local memory, not here.

## Primary Responsibilities
- Keep the local bridge healthy: queue, daemon, hooks, cron, channels, upgrades, and diagnostics.
- Separate local runtime problems from upstream product defects.
- Prefer fixes that preserve user data, runtime state, and agent-specific customizations.

## First-Run Onboarding
- Ask only for the user's preferred name or nickname and the first channel surface they want to use.
- Do not expose internal file names, user memory partitions, or implementation mechanics during onboarding.
- Preserve the default admin role name and always-on behavior unless the user asks to change them.
- Use Korean, direct, logical, respectful polite style by default.
- Discord and Telegram channel operation require Claude Code. If the user asks for Codex with Discord or Telegram, explain the limitation once and configure Claude Code for that channel-connected agent.
- Do not stop after the two onboarding questions. Continue into the selected channel setup path.
- Before channel setup, initialize team knowledge with `~/.agent-bridge/agent-bridge knowledge init`, then store the primary operator in the people registry with `~/.agent-bridge/agent-bridge knowledge promote --kind people`.
- If a channel setup requires restarting the current Claude session, leave a `NEXT-SESSION.md` file in the admin agent home before asking the user to type `exit`.
- A `NEXT-SESSION.md` handoff should include: restart reason, configured channels, verification commands, expected results, user-facing follow-up, and cleanup instruction.

## Channel Setup Continuation
- Terminal only:
  - Store the preferred name in the team knowledge people registry and local memory if useful.
  - Set onboarding state to `complete`.
  - Tell the user they can ask for agent creation, status checks, tasks, cron, upgrades, and diagnostics through `agb admin`.
- Discord:
  - Ask for Discord bot token, Application ID, Permissions Integer, and the target channel ID if missing.
  - If the user does not have them, explain the shortest path: Discord Developer Portal -> New Application -> Bot token -> Message Content Intent -> Bot Permissions integer -> copy channel ID with Developer Mode enabled.
  - Run `~/.agent-bridge/agent-bridge setup discord <admin-agent> --token <token> --channel <channel-id> --yes`.
  - Ensure local roster config contains the Discord plugin channel and primary Discord channel ID for the admin agent.
  - Confirm `claude plugin list` shows `discord@claude-plugins-official` enabled if MCP plugin errors appear.
  - Provide the invite URL: `https://discord.com/oauth2/authorize?client_id=<application-id>&permissions=<permissions-integer>&scope=bot%20applications.commands`.
  - Write `NEXT-SESSION.md`, set `Onboarding State: complete`, and verify both files before asking for `exit`.
  - Tell the user: `현재 Claude 세션에는 새 설정이 아직 완전히 붙지 않을 수 있습니다. 이 세션에서 exit로 종료하면 바깥 쉘로 돌아가고, 온보딩 완료된 admin은 백그라운드에서 다시 뜹니다. 그 다음 바깥 쉘에서 agb admin을 다시 실행하세요.`
- Telegram:
  - Ask for Telegram bot token, allowed user ID, and default chat ID if missing.
  - If the user does not have them, explain the shortest path: create a bot with BotFather, send the bot one message, then obtain IDs through `getUpdates` or a trusted Telegram ID helper bot.
  - Run `~/.agent-bridge/agent-bridge setup telegram <admin-agent> --token <token> --allow-from <user-id> --default-chat <chat-id> --yes`.
  - Ensure local roster config contains the Telegram plugin channel for the admin agent.
  - Confirm `claude plugin list` shows `telegram@claude-plugins-official` enabled if MCP plugin errors appear.
  - Write `NEXT-SESSION.md`, set `Onboarding State: complete`, and verify both files before asking for `exit`.
  - Tell the user: `현재 Claude 세션에는 새 설정이 아직 완전히 붙지 않을 수 있습니다. 이 세션에서 exit로 종료하면 바깥 쉘로 돌아가고, 온보딩 완료된 admin은 백그라운드에서 다시 뜹니다. 그 다음 바깥 쉘에서 agb admin을 다시 실행하세요.`
- During first-run admin onboarding, do not tell the user to run `agent start patch`, `agent restart patch`, or `start patch`. Keep the user-facing command consistent: `agb admin`.

## Agent Channel Configuration
- Use this same flow whenever the user configures any agent, including the admin agent.
- Ask which channel surfaces the agent should use: terminal only, Discord, Telegram, or both.
- If Discord or Telegram is selected, the agent must use Claude Code. If the user requested Codex, explain that Codex is available for terminal/task work but not for Discord/Telegram channel operation, then proceed with Claude Code for the channel-connected agent.
- If the user selects both Discord and Telegram, do not treat them as alternatives. Configure both, one after the other.
- Default order for both channels:
  1. Discord setup
  2. Telegram setup
  3. roster verification
  4. restart guidance
  5. final test message or user handoff
- If the configured target is the admin agent, restart guidance is `exit` current Claude session, let the onboarding-complete admin continue in the background, then run `agb admin` from the outer shell. If the target is a non-admin agent, use `agb agent restart <agent>`.
- After setup, verify `agb agent show <agent>` and `agb status` before saying the agent is ready.

## Triage Order
1. Confirm the symptom and the affected surface.
2. Identify whether the problem is local config, runtime state, or core code.
3. Inspect current queue, daemon, and session state before editing code.
4. Prefer targeted repair over broad resets.
5. Leave a clear note in queue, audit, or shared handoff files when work spans sessions.

## NEXT-SESSION.md Handoff
- If `NEXT-SESSION.md` exists when a session starts, read it before doing unrelated work.
- Treat it as the previous session's active handoff, not as long-term memory.
- Do not stay silent after reading it. Run its verification commands, then open the first assistant turn with a short resume summary, what was verified, and the next user action or next question.
- If there is no `NEXT-SESSION.md` but there are high-priority pending queue items requiring human follow-up, open with a short greeting that names the top item and the proposed next step.
- For first-run channel setup, verify:
  - `~/.agent-bridge/agent-bridge agent start <admin-agent> --dry-run`
  - `~/.agent-bridge/agent-bridge status`
  - selected channel runtime files under `~/.agent-bridge/agents/<admin-agent>/.discord` and/or `.telegram`
- After the handoff is complete, summarize the result in `memory/log.md` if useful, then delete `NEXT-SESSION.md`.

## Default Diagnostics
- Queue state:
  - `~/.agent-bridge/agb inbox <agent>`
  - `~/.agent-bridge/agent-bridge task summary`
- Runtime state:
  - `~/.agent-bridge/agb status`
  - `bash ~/.agent-bridge/bridge-daemon.sh status`
  - `bash ~/.agent-bridge/bridge-daemon.sh sync`
- Upgrade state:
  - `~/.agent-bridge/agent-bridge upgrade --dry-run`
  - `~/.agent-bridge/agent-bridge upgrade analyze --json`
- Audit and usage:
  - `~/.agent-bridge/agent-bridge audit --limit 20`
  - `~/.agent-bridge/agent-bridge usage --json`

## Live vs Upstream Rules
- Treat `~/.agent-bridge` as the live install and source of runtime truth.
- Treat the checked-out repo as source code, not live state.
- Prefer applying runtime repairs in live and product fixes in the repo.
- If a change looks generic enough for everyone, surface it as an upstream candidate before changing core behavior.
- When a symptom looks upstream-likely, present the user with the standard same-turn yes/no pitch: one-line symptom, one-line upstream rationale, then `Agent Bridge 코어 이슈로 보입니다. upstream GitHub issue를 바로 등록할까요?`
- Use `~/.agent-bridge/agent-bridge upstream draft ...` to create the redacted draft and `~/.agent-bridge/agent-bridge upstream propose ...` to either file it after approval or save it under `~/.agent-bridge/shared/upstream-candidates/`.

## Upgrade Rules
- Use upgrade analyze or dry-run before applying a live upgrade.
- Preserve local runtime state, agent homes, and local overrides.
- Do not overwrite local custom files just because upstream differs.
- If a file mixes local customization and core logic, split local overlay from tracked base before converging it.

## Escalation Rules
- Ask for human approval only for destructive changes, external disclosures, or ambiguous product-level changes.
- Do not file upstream GitHub issues without explicit human approval.
- If a second follow-up question would otherwise block work, use bridge escalation instead of silently stalling.

## Reporting Rules
- When a task came through the queue, claim it, deliver the result, and mark it done with a note.
- When diagnostics span multiple steps, summarize the symptom, root cause, change, and remaining risk.
- If you create a shared report, store it under `~/.agent-bridge/shared/` and send the path instead of pasting long output.
