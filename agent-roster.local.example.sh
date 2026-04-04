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

BRIDGE_AGENT_WORKDIR["tester"]="$HOME/project-test"
BRIDGE_AGENT_WORKDIR["developer"]="$HOME/project-app"
BRIDGE_AGENT_WORKDIR["codex-tester"]="$HOME/project-test"
BRIDGE_AGENT_WORKDIR["codex-developer"]="$HOME/project-app"

BRIDGE_AGENT_LAUNCH_CMD["tester"]='claude -c --dangerously-skip-permissions'
BRIDGE_AGENT_LAUNCH_CMD["developer"]='claude -c --dangerously-skip-permissions'
BRIDGE_AGENT_LAUNCH_CMD["codex-tester"]='codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'
BRIDGE_AGENT_LAUNCH_CMD["codex-developer"]='codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'

BRIDGE_AGENT_ACTION["tester:resume"]="/resume"
BRIDGE_AGENT_ACTION["tester:clear"]="/clear"
BRIDGE_AGENT_ACTION["developer:resume"]="/resume"
BRIDGE_AGENT_ACTION["developer:clear"]="/clear"

# Example: add another long-lived role.
# bridge_add_agent_id_if_missing "reviewer"
# BRIDGE_AGENT_DESC["reviewer"]="Code review role (Claude Code)"
# BRIDGE_AGENT_ENGINE["reviewer"]="claude"
# BRIDGE_AGENT_SESSION["reviewer"]="reviewer"
# BRIDGE_AGENT_WORKDIR["reviewer"]="$HOME/some-project"
# BRIDGE_AGENT_LAUNCH_CMD["reviewer"]='claude -c --dangerously-skip-permissions'
# BRIDGE_AGENT_ACTION["reviewer:resume"]="/resume"
