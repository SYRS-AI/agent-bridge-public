#!/bin/bash
# shellcheck shell=bash
#
# Agent Bridge roster
# - Add the agent id to BRIDGE_AGENT_IDS
# - Fill the metadata maps below
# - Optional actions are defined in BRIDGE_AGENT_ACTION using "<agent>:<action>"

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/agent-bridge}"
BRIDGE_LOG_DIR="${BRIDGE_LOG_DIR:-$BRIDGE_HOME/logs}"
BRIDGE_SHARED_DIR="${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}"
BRIDGE_MAX_MESSAGE_LEN="${BRIDGE_MAX_MESSAGE_LEN:-500}"

# shellcheck disable=SC2034
declare -ag BRIDGE_AGENT_IDS=(
  tester
  developer
  codex-tester
  codex-developer
)

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_DESC=(
  [tester]="CRM 테스트 에이전트 (Claude Code)"
  [developer]="CRM 개발 에이전트 (Claude Code)"
  [codex-tester]="CRM 테스트 에이전트 (Codex)"
  [codex-developer]="CRM 개발 에이전트 (Codex)"
)

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_ENGINE=(
  [tester]="claude"
  [developer]="claude"
  [codex-tester]="codex"
  [codex-developer]="codex"
)

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_SESSION=(
  [tester]="tester"
  [developer]="developer"
  [codex-tester]="codex-tester"
  [codex-developer]="codex-developer"
)

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_WORKDIR=(
  [tester]="/home/sean/crm_test"
  [developer]="/home/sean/cosmax-crm-cli"
  [codex-tester]="/home/sean/crm_test"
  [codex-developer]="/home/sean/cosmax-crm-cli"
)

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_LAUNCH_CMD=(
  [tester]='claude -c --dangerously-skip-permissions'
  [developer]='claude -c --dangerously-skip-permissions'
  [codex-tester]='codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'
  [codex-developer]='codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'
)

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_ACTION=(
  ["tester:resume"]="/resume"
  ["tester:clear"]="/clear"
  ["developer:resume"]="/resume"
  ["developer:clear"]="/clear"
)
