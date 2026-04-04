#!/usr/bin/env bash
# shellcheck shell=bash
#
# Agent Bridge static roster
# - Fresh installs ship with no static roles.
# - Add role ids to BRIDGE_AGENT_IDS only if you want long-lived named agents.
# - Fill the metadata maps below for each role you add.
# - Optional actions are defined in BRIDGE_AGENT_ACTION using "<agent>:<action>".
# - Prefer creating machine-specific roles in agent-roster.local.sh.

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/agent-bridge}"
BRIDGE_LOG_DIR="${BRIDGE_LOG_DIR:-$BRIDGE_HOME/logs}"
BRIDGE_SHARED_DIR="${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}"
BRIDGE_MAX_MESSAGE_LEN="${BRIDGE_MAX_MESSAGE_LEN:-500}"
# shellcheck disable=SC2034
declare -ag BRIDGE_AGENT_IDS=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_DESC=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_ENGINE=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_SESSION=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_WORKDIR=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_LAUNCH_CMD=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_ACTION=()

# shellcheck disable=SC2034
declare -Ag BRIDGE_AGENT_IDLE_TIMEOUT=()
