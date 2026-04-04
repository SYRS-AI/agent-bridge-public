# Main (쭈쭈) Profile Draft

This scaffold is Phase 3 start: preserve the current OpenClaw prompt stack while translating the flows into an Agent Bridge-friendly document. Replace *only* after we validate this text with live smoke.

## Identity (from `workspace/SOUL.md`)

- Be helpful without filler (“Great question” etc.).
- Have opinions, stay resourceful, read files before asking.
- Remember privacy, admit “모르겠다” when unsure, treat the log as trust.
- First steps each session: SOUL → USER → today/yesterday memories → `MEMORY.md` (main only) → `ROSTER.md`.
- Pass the DB preflight and compaction recovery gates before touching shared state.
- Keep the tone friendly, first message is optional as long as there’s value (“먼저 말 걸기”).

## Inputs

- Prompt files: `AGENTS.md`, `SOUL.md`, `MEMORY.md`, `TOOLS.md`, `ROSTER.md`, `USER*.md`.
- Memory DB: `~/.openclaw/memory/main.sqlite` (2 GB) and live workspace `~/.openclaw/workspace/`.
- A2A signals: `sessions_send(sessionKey="agent:{id}:main", …)` and patch Discord webhook.
- Cron surfaces: 19 jobs (see `cron inventory --agent main`), especially morning/evening digests, memory-daily, monthly-highlights, event reminders.
- Heartbeat still defined in OpenClaw config (1h) but we already cover health checks via `agent-bridge status`.

## Outputs / tasks

- Telegram: send to `7670324081` (Sean) / `8089687974` (Myo), maintain style guidance from `TOOLS.md` and `SYRS-RULES.md`.
- Discord: ensure Agent Bridge team can replicate the current channel flows before retiring gateway channels; existing session keys cover multiple guild channels plus direct `1476877944625565746`.
- Cron: keep the recurring jobs running via their scripts for now but note `iran-crisis-monitor` and `memory-daily-sean` errors; plan later how to enqueue via bridge.

## Migration notes

1. Keep the prompt stack intact; do not drop any of the linked files.
2. Keep training data path constant: workspace `/Users/soonseokoh/.openclaw/workspace`.
3. Provide bridge alternatives for:
   - `sessions_send`: replace with `agent-bridge task create` + ClaudE queue + inbox.
   - Patch/Discord webhook: describe how patch static role is the new handler.
4. Highlight maintenance-window cutover plan and note the need to shut down other gateway agents briefly.

## Next steps for scaffold

1. Turn this draft into a polished `CLAUDE.md` in `agents/main/`.
2. Document key tool paths: scripts under `~/.openclaw/scripts/` for digests, reminders, watchlists.
3. Cross-reference `agents/main/MIGRATION-AUDIT.md` and `shared/TOOLS-REGISTRY.md`.
4. Once reviewed, deploy via `agent-bridge profile deploy main` into live home, then run smoke.
