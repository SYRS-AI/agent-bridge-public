typeset -g AGENT_BRIDGE_HOME="${AGENT_BRIDGE_HOME:-${${(%):-%N}:A:h:h}}"
typeset -gU path fpath

path=("$AGENT_BRIDGE_HOME" "$path[@]")
fpath=("$AGENT_BRIDGE_HOME/completions/zsh" "$fpath[@]")
export PATH="${(j/:/)path}"

if [[ -z "${_AGENT_BRIDGE_COMPINIT_DONE:-}" ]]; then
  autoload -Uz compinit
  compinit -i
  typeset -g _AGENT_BRIDGE_COMPINIT_DONE=1
fi

alias bridge-start="bash $AGENT_BRIDGE_HOME/bridge-start.sh"
alias bridge-send="bash $AGENT_BRIDGE_HOME/bridge-send.sh"
alias bridge-action="bash $AGENT_BRIDGE_HOME/bridge-action.sh"
alias bridge-task="bash $AGENT_BRIDGE_HOME/bridge-task.sh"
alias bridge-daemon="bash $AGENT_BRIDGE_HOME/bridge-daemon.sh"
alias bridge-status="bash $AGENT_BRIDGE_HOME/bridge-status.sh"
alias bridge-sync="bash $AGENT_BRIDGE_HOME/bridge-sync.sh"
