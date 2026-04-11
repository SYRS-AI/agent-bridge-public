---
name: patch
description: Call the admin repair role from shell automation and route the result back into queue or channel delivery. Use when cron or another runtime helper needs patch to inspect or repair the bridge.
type: shell-script
category: operations
entry: scripts/call-patch.sh
---

# Patch Call Wrapper

Wrapper that invokes the patch admin role with bridge-native context and returns the result through queue or channel delivery.

## Usage

```bash
bash ~/.agent-bridge/runtime/skills/patch/scripts/call-patch.sh --from <agent> "request"
```
