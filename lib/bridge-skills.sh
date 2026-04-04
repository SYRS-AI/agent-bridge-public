#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2153

bridge_project_skill_dir_for() {
  local engine="$1"
  local workdir="$2"

  case "$engine" in
    codex)
      printf '%s/.agents/skills/agent-bridge-project' "$workdir"
      ;;
    claude)
      printf '%s/.claude/skills/agent-bridge-project' "$workdir"
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_legacy_project_skill_dir_for() {
  local engine="$1"
  local workdir="$2"

  case "$engine" in
    codex)
      printf '%s/.agents/skills/cc-bridge-project' "$workdir"
      ;;
    claude)
      printf '%s/.claude/skills/cc-bridge-project' "$workdir"
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_is_managed_markdown() {
  local file="$1"
  grep -Fq "$BRIDGE_MANAGED_MARKER" "$file" || grep -Fq "$BRIDGE_LEGACY_MANAGED_MARKER" "$file"
}

bridge_migrate_legacy_project_skill_dir() {
  local engine="$1"
  local workdir="$2"
  local new_dir legacy_dir legacy_skill_file

  new_dir="$(bridge_project_skill_dir_for "$engine" "$workdir")"
  legacy_dir="$(bridge_legacy_project_skill_dir_for "$engine" "$workdir")"
  legacy_skill_file="${legacy_dir}/SKILL.md"

  if [[ ! -d "$legacy_dir" || -e "$new_dir" || ! -f "$legacy_skill_file" ]]; then
    return 0
  fi

  if ! bridge_is_managed_markdown "$legacy_skill_file"; then
    return 0
  fi

  mkdir -p "$(dirname "$new_dir")"
  mv "$legacy_dir" "$new_dir"
}

bridge_render_project_bridge_reference() {
  local bridge_home="$1"

  cat <<EOF
# Agent Bridge Quick Reference

<!-- ${BRIDGE_MANAGED_MARKER} -->

Use this guide when a task involves tmux-based agent coordination through \`${bridge_home}\`.

## Roster

- Bridge dashboard: \`${bridge_home}/ab status\`
- Live dashboard watch mode: \`${bridge_home}/ab status --watch\`
- Active bridge agents with numeric indexes: \`${bridge_home}/ab list\`
- Agent inbox and claimed counts are included in \`ab list\`
- Static roster: \`bash ${bridge_home}/bridge-start.sh --list\`
- Live roster with active sessions: \`cat ${bridge_home}/state/active-roster.md\`
- Static definitions: \`cat ${bridge_home}/agent-roster.sh\`

## Start Or Resume Agents

- Start a rostered agent: \`bash ${bridge_home}/bridge-start.sh codex-developer\`
- Wake a rostered role through \`ab\` by using the static agent name directly: \`${bridge_home}/ab --codex --name codex-developer\`
- Start an ad hoc Codex agent from the current folder: \`${bridge_home}/ab --codex --name dev\`
- Start an ad hoc Claude agent from the current folder: \`${bridge_home}/ab --claude --name reviewer\`
- Create an isolated git worktree worker from the current folder: \`${bridge_home}/ab --codex --name reviewer-a --prefer new\`
- Trigger a predefined resume action: \`bash ${bridge_home}/bridge-action.sh tester resume --wait 5\`

## Task Queue

- Create a queued task: \`${bridge_home}/ab task create --to developer --title "재테스트" --body-file ${bridge_home}/shared/report.md\`
- Check an inbox: \`${bridge_home}/ab inbox developer\`
- Claim a task: \`${bridge_home}/ab claim 12 --agent developer\`
- Mark a task done: \`${bridge_home}/ab done 12 --agent developer --note "재현 불가"\`
- Hand off a task: \`${bridge_home}/ab handoff 12 --to tester --note "수정 반영 후 재확인 부탁"\`

## Urgent Interrupts

- Send a direct urgent message only when interrupting is necessary: \`bash ${bridge_home}/bridge-send.sh --urgent developer "[TESTER] 프로덕션 장애 확인 필요" --wait 5\`
- List available slash-style actions: \`bash ${bridge_home}/bridge-action.sh --list tester\`
- Trigger a predefined action: \`bash ${bridge_home}/bridge-action.sh tester resume --wait 5\`

## Stop Sessions

- Kill one active bridge session by index: \`${bridge_home}/ab kill 1\`
- Kill every active bridge session managed by the current roster: \`${bridge_home}/ab kill all\`
- List managed worktrees: \`${bridge_home}/ab worktree list\`

## Share Larger Files

- Put long notes or QA reports in \`${bridge_home}/shared/\`
- Prefer task queue entries plus file paths over direct message pastes
- Runtime state under \`${bridge_home}/state/\` and logs under \`${bridge_home}/logs/\` are generated files and should not be hand-edited
EOF
}

bridge_render_codex_project_skill() {
  local bridge_home="$1"

  cat <<EOF
---
name: agent-bridge-project
description: Use when work needs tmux-based multi-agent coordination through \`${bridge_home}\`, including reading the roster, starting ad hoc workers with \`ab\`, sending messages between agents, triggering predefined actions, or sharing long reports through \`${bridge_home}/shared/\`.
---

<!-- ${BRIDGE_MANAGED_MARKER} -->

Use this skill when the task depends on the shared agent bridge in \`${bridge_home}\`.

## Workflow

1. Read the live roster in \`${bridge_home}/state/active-roster.md\` before coordinating with another agent.
2. Use \`bridge-start.sh\` for static roster entries and \`ab\` for ad hoc workers tied to the current folder.
3. If \`ab --name <agent>\` matches a static roster role, it wakes that role instead of creating a new dynamic worker.
4. If the current path belongs to a git project that already has dormant static roles, prefer \`ab --prefer new\` to create an isolated worktree worker rather than sharing the same checkout.
5. Use \`ab status\` for an at-a-glance dashboard, or \`ab status --watch\` for the live TUI.
6. Use the task queue first: \`ab task create\`, \`ab inbox\`, \`ab claim\`, \`ab done\`, and \`ab handoff\`.
7. Reserve \`bridge-send.sh --urgent\` for true interrupts and use \`bridge-action.sh\` only for predefined actions.
8. Store long reports in \`${bridge_home}/shared/\` and send only the path.

## Reference

- Load [references/bridge-commands.md](references/bridge-commands.md) for command patterns and examples.

## Guardrails

- Do not hardcode agent metadata into bridge scripts; static roster data belongs in \`${bridge_home}/agent-roster.sh\`.
- Prefer the live roster over guesswork when identifying active tmux sessions.
- Treat \`${bridge_home}/state/\` and \`${bridge_home}/logs/\` as generated runtime artifacts.
- Prefer queued tasks over direct messages so agents can pull work at task boundaries.
EOF
}

bridge_render_claude_project_skill() {
  local bridge_home="$1"

  cat <<EOF
---
name: agent-bridge-project
description: Use PROACTIVELY when a task involves tmux-based multi-agent coordination through \`${bridge_home}\`, including roster lookup, inter-agent messaging, ad hoc worker startup with \`ab\`, predefined bridge actions, or shared handoff files.
---

<!-- ${BRIDGE_MANAGED_MARKER} -->

Use this skill when work depends on the shared agent bridge in \`${bridge_home}\`.

## Workflow

1. Inspect \`${bridge_home}/state/active-roster.md\` for active agents and session ids.
2. Use \`bridge-start.sh\` for static roster roles and \`ab\` for ad hoc workers in the current folder.
3. If \`ab --name <agent>\` matches a static roster role, it wakes that role instead of creating a new dynamic worker.
4. In git projects with dormant static roles, prefer \`ab --prefer new\` so concurrent workers use isolated worktrees instead of the shared checkout.
5. Use \`ab status\` for a one-shot dashboard or \`ab status --watch\` for the live TUI.
6. Use the queue first: \`ab task create\`, \`ab inbox\`, \`ab claim\`, \`ab done\`, and \`ab handoff\`.
7. Use \`bridge-send.sh --urgent\` only for interruptions that cannot wait for queue pickup, and use \`bridge-action.sh\` for predefined actions.
8. Put long notes in \`${bridge_home}/shared/\` and send the path instead of pasting large blocks.

## Reference

- Read [references/bridge-commands.md](references/bridge-commands.md) for examples and guardrails.

## Guardrails

- Do not edit generated runtime files under \`${bridge_home}/state/\` or \`${bridge_home}/logs/\`.
- Check the static roster in \`${bridge_home}/agent-roster.sh\` before assuming an agent name or action exists.
- Keep urgent interrupts short and move details into task queue entries or shared files.
EOF
}

bridge_write_managed_markdown() {
  local file="$1"
  local label="$2"
  local tmp

  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp)"
  cat >"$tmp"

  if [[ -f "$file" ]] && ! bridge_is_managed_markdown "$file"; then
    bridge_warn "${label} already exists and is not managed by agent-bridge: $file"
    rm -f "$tmp"
    return 1
  fi

  if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$file"
  bridge_info "[info] ${label}: ${file}"
}

bridge_bootstrap_project_skill() {
  local engine="$1"
  local workdir="$2"
  local skill_dir skill_file reference_file

  bridge_migrate_legacy_project_skill_dir "$engine" "$workdir"

  if ! skill_dir="$(bridge_project_skill_dir_for "$engine" "$workdir")"; then
    return 0
  fi

  skill_file="${skill_dir}/SKILL.md"
  reference_file="${skill_dir}/references/bridge-commands.md"

  case "$engine" in
    codex)
      bridge_render_codex_project_skill "$BRIDGE_HOME" | bridge_write_managed_markdown "$skill_file" "project Codex bridge skill" || return 1
      ;;
    claude)
      bridge_render_claude_project_skill "$BRIDGE_HOME" | bridge_write_managed_markdown "$skill_file" "project Claude bridge skill" || return 1
      ;;
    *)
      return 0
      ;;
  esac

  bridge_render_project_bridge_reference "$BRIDGE_HOME" | bridge_write_managed_markdown "$reference_file" "project bridge reference" || return 1
}
