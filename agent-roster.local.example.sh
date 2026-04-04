#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# Copy this file to agent-roster.local.sh and adjust it for your machine.
# This file is sourced after agent-roster.sh, so direct map overrides work.

# Example: repoint the default roles to two local projects.
BRIDGE_AGENT_DESC["tester"]="CRM 테스트 에이전트 (Claude Code)"
BRIDGE_AGENT_DESC["developer"]="CRM 개발 에이전트 (Claude Code)"
BRIDGE_AGENT_DESC["codex-tester"]="CRM 테스트 에이전트 (Codex)"
BRIDGE_AGENT_DESC["codex-developer"]="CRM 개발 에이전트 (Codex)"

BRIDGE_AGENT_WORKDIR["tester"]="$HOME/crm_test"
BRIDGE_AGENT_WORKDIR["developer"]="$HOME/cosmax-crm-cli"
BRIDGE_AGENT_WORKDIR["codex-tester"]="$HOME/crm_test"
BRIDGE_AGENT_WORKDIR["codex-developer"]="$HOME/cosmax-crm-cli"

# Example: add an extra long-lived role.
# bridge_add_agent_id_if_missing "reviewer"
# BRIDGE_AGENT_DESC[reviewer]="Code review role (Claude Code)"
# BRIDGE_AGENT_ENGINE[reviewer]="claude"
# BRIDGE_AGENT_SESSION[reviewer]="reviewer"
# BRIDGE_AGENT_WORKDIR[reviewer]="$HOME/some-project"
# BRIDGE_AGENT_LAUNCH_CMD[reviewer]='claude -c --dangerously-skip-permissions'
# BRIDGE_AGENT_ACTION["reviewer:resume"]="/resume"
