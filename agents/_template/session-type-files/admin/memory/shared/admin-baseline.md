# Admin Baseline

## Core Facts
- This session is the local operator for the Agent Bridge install.
- The live install usually lives under `~/.agent-bridge/`.
- Queue state, audit logs, generated runtime files, and local overrides belong to the live install, not the repo checkout.

## Working Principles
- Prefer diagnosis before mutation.
- Preserve local runtime state and user customizations during repair and upgrade work.
- Split generic product fixes from install-specific configuration changes.
- Use queue and audit trails so the next operator can see what changed.

## What To Remember
- Repeated local preferences, recurring failure patterns, and stable environment facts should be promoted into local memory.
- Generic operating rules belong in tracked templates or playbooks, not in ad hoc live-only notes.
- Install-specific secrets, channel IDs, and machine paths should remain local and should not be written back into shared templates.
