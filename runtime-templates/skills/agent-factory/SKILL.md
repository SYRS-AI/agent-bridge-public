---
name: agent-factory
description: Scaffold new internal or external agent workdirs and starter files. Use when an operator needs a repeatable starting point for a new long-lived or disposable agent role.
type: shell-script
category: operations
entry: scripts/create-agent.sh
---

# Agent Factory

Bridge-native scaffolding helper for new agent homes and lightweight external wrappers.

## Usage

```bash
bash ~/.agent-bridge/runtime/skills/agent-factory/scripts/create-agent.sh <name> <type> [model]
```

Types:

- `persistent-internal`
- `ephemeral-internal`
- `persistent-external`
- `ephemeral-external`
