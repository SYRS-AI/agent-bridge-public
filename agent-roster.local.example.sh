#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# Copy this file to agent-roster.local.sh and adjust it for your machine.
# This file is sourced after agent-roster.sh, so you can add roles here.

# Example: add a common four-role setup.
bridge_add_agent_id_if_missing "tester"
bridge_add_agent_id_if_missing "developer"
bridge_add_agent_id_if_missing "codex-tester"
bridge_add_agent_id_if_missing "codex-developer"

BRIDGE_AGENT_DESC["tester"]="Test role (Claude Code)"
BRIDGE_AGENT_DESC["developer"]="Development role (Claude Code)"
BRIDGE_AGENT_DESC["codex-tester"]="Test role (Codex)"
BRIDGE_AGENT_DESC["codex-developer"]="Development role (Codex)"

BRIDGE_AGENT_ENGINE["tester"]="claude"
BRIDGE_AGENT_ENGINE["developer"]="claude"
BRIDGE_AGENT_ENGINE["codex-tester"]="codex"
BRIDGE_AGENT_ENGINE["codex-developer"]="codex"

BRIDGE_AGENT_SESSION["tester"]="tester"
BRIDGE_AGENT_SESSION["developer"]="developer"
BRIDGE_AGENT_SESSION["codex-tester"]="codex-tester"
BRIDGE_AGENT_SESSION["codex-developer"]="codex-developer"

# Optional: standard long-lived roles can live under $BRIDGE_HOME/agents/<agent>.
# If you follow that layout, you can omit BRIDGE_AGENT_WORKDIR entirely and the
# bridge will default to $BRIDGE_AGENT_HOME_ROOT/<agent>.
# BRIDGE_AGENT_HOME_ROOT="$HOME/.agent-bridge/agents"

# Optional: override workdirs when a role should launch inside another repo or
# directory instead of the standard live home root.
# BRIDGE_AGENT_WORKDIR["tester"]="$HOME/project-test"
# BRIDGE_AGENT_WORKDIR["developer"]="$HOME/project-app"
# BRIDGE_AGENT_WORKDIR["codex-tester"]="$HOME/project-test"
# BRIDGE_AGENT_WORKDIR["codex-developer"]="$HOME/project-app"

# Optional: tracked profile deploy target. If omitted for a tracked agent, the
# bridge defaults to $BRIDGE_AGENT_HOME_ROOT/<agent>. Override this only when
# the live CLI home differs from the workdir.
# BRIDGE_AGENT_PROFILE_HOME["tester"]="$HOME/project-test"
# BRIDGE_AGENT_PROFILE_HOME["developer"]="$HOME/project-app"

# Optional external notification transport for Claude Code agents. Prefer
# `discord-webhook` for Discord-backed Claude sessions; plain `discord` bot
# posts are not a reliable delivery surface for Claude Code.
# BRIDGE_AGENT_NOTIFY_KIND["tester"]="discord-webhook"
# BRIDGE_AGENT_NOTIFY_TARGET["tester"]="<discord-webhook-url>"
# BRIDGE_AGENT_NOTIFY_ACCOUNT["tester"]="default"
# BRIDGE_AGENT_NOTIFY_KIND["developer"]="telegram"
# BRIDGE_AGENT_NOTIFY_TARGET["developer"]="<telegram-chat-or-thread-id>"
# BRIDGE_AGENT_NOTIFY_ACCOUNT["developer"]="default"
# BRIDGE_AGENT_DISCORD_CHANNEL_ID["tester"]="123456789012345678"
# The channel id is still useful for Discord wake relay / metadata, but not for
# bot-authored Claude delivery.
#
# After setting the primary channel id, scaffold the runtime Discord files with:
#   agent-bridge setup discord tester
#   agent-bridge setup agent tester

# Optional: map OpenClaw cron agent ids to bridge agents for cron enqueue.
# BRIDGE_OPENCLAW_AGENT_TARGET["legacy-agent"]="tester"
# BRIDGE_OPENCLAW_AGENT_TARGET["legacy-ops"]="developer"

# Optional: enable the bridge-owned recurring OpenClaw scheduler on machines
# that are actively migrating legacy cron jobs. Keep this off for fresh installs.
# BRIDGE_OPENCLAW_CRON_SYNC_ENABLED=1

BRIDGE_AGENT_LAUNCH_CMD["tester"]='claude -c --dangerously-skip-permissions'
BRIDGE_AGENT_LAUNCH_CMD["developer"]='claude -c --dangerously-skip-permissions'
BRIDGE_AGENT_LAUNCH_CMD["codex-tester"]='codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'
BRIDGE_AGENT_LAUNCH_CMD["codex-developer"]='codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'

# Optional: on-demand auto-stop timeout in seconds. Leave unset for long-lived
# developer roles that should stay up continuously. Set this only for roles you
# explicitly want the daemon to stop after inactivity.
# BRIDGE_AGENT_IDLE_TIMEOUT["tester"]="900"
# BRIDGE_AGENT_IDLE_TIMEOUT["codex-tester"]="300"

BRIDGE_AGENT_ACTION["tester:resume"]="/resume"
BRIDGE_AGENT_ACTION["tester:clear"]="/clear"
BRIDGE_AGENT_ACTION["developer:resume"]="/resume"
BRIDGE_AGENT_ACTION["developer:clear"]="/clear"

# Optional: dashboard health-check thresholds for active sessions.
# BRIDGE_HEALTH_WARN_SECONDS=3600
# BRIDGE_HEALTH_CRITICAL_SECONDS=14400

# Example: add another long-lived role.
# bridge_add_agent_id_if_missing "reviewer"
# BRIDGE_AGENT_DESC["reviewer"]="Code review role (Claude Code)"
# BRIDGE_AGENT_ENGINE["reviewer"]="claude"
# BRIDGE_AGENT_SESSION["reviewer"]="reviewer"
# BRIDGE_AGENT_WORKDIR["reviewer"]="$HOME/some-project"
# BRIDGE_AGENT_LAUNCH_CMD["reviewer"]='claude -c --dangerously-skip-permissions'
# BRIDGE_AGENT_ACTION["reviewer:resume"]="/resume"
