# Resilience Roadmap

This document consolidates the remaining runtime issues into a single
architecture and implementation order.

## Scope

The open runtime issues overlap heavily:

- `#74` audit log coverage
- `#71` resilience umbrella
- `#67` Claude account rotation / automatic login
- `#77` usage polling and 90% alerts
- `#75` stall detection and recovery
- `#66` repeated unanswered question escalation

They should not be implemented independently. The correct order is:

1. Observe
2. Detect
3. Recover
4. Escalate
5. Only then consider automated account or engine failover

## Current State

Already in place:

- Structured audit log with broader daemon/task coverage
- Crash-loop reports and admin alerts
- Stall detection and recovery first slice
- Usage monitoring first slice
- Linux systemd bootstrap support
- Smart upgrade first slice with backup and migration

Still open:

- `#74`: complete audit surface and query ergonomics
- `#71`: unify recovery policy and escalation ladder
- `#67`: account rotation research and scope decision
- `#78`: public release track
- `#31`: backlog routing work

## Architecture

### Layer 0: Boot and Upgrade Hygiene

Before recovery logic matters, the system has to start reliably and survive
upgrades.

- macOS LaunchAgent and Linux systemd user service
- upgrade backup snapshots
- managed agent-home migration
- strict/custom-safe merge policy

Primary issues:

- `#79` Linux systemd
- `#60` smart upgrade
- `#78` public release track

### Layer 1: Audit and Telemetry

Every automated action must leave a machine-readable trace.

Required events:

- daemon lifecycle
- session nudges and refreshes
- cron sync / dispatch / cancel / completion
- watchdog findings
- crash-loop detection
- stall nudges / recoveries / escalations
- usage threshold alerts

Primary issue:

- `#74`

This layer is foundational. Recovery without audit is opaque and difficult to
debug.

### Layer 2: Detection

The daemon should continuously detect:

- crash loops
- stalled sessions
- channel delivery failures
- usage approaching provider limits

Primary issues:

- `#75`
- `#77`

Detection must be daemon-poll based. Stop-hook-driven recovery should not be
the primary signal path because it overlaps with inbox/nudge behavior.

### Layer 3: Local Recovery

Once something is detected, the daemon attempts the smallest safe repair first.

Examples:

- resend nudge
- session refresh
- restart a failed static role
- hold an always-on role down if manually stopped
- retry a memory-daily refresh when the prompt is available

This is the first practical subset of `#71`.

### Layer 4: Admin Escalation

If local recovery fails, the system must escalate clearly to the admin role or
admin channel.

Examples:

- repeated unanswered question escalation (`#66`)
- crash-loop escalation to admin
- stall escalation after bounded retries
- usage 90% alert so the user can switch accounts manually

Primary issues:

- `#66`
- `#77`
- parts of `#71`

### Layer 5: Account and Engine Failover

This is the most speculative layer.

For subscription-based Claude Code, fully automated account rotation is not a
safe default because:

- official non-interactive OAuth login is not documented
- session state may depend on more than a single file token
- session continuity for long-lived roles is easy to break

Therefore `#67` should currently be scoped as:

- monitor usage
- alert early
- support manual switching
- optionally explore pre-authenticated profile pools as an experimental,
  unsupported path

Automatic subscription OAuth rotation should not be a core assumption in the
resilience architecture until a supported path exists.

## Recommended Issue Order

### Runtime / Operations

1. `#74` finish audit surface and audit query ergonomics
2. `#71` refine the umbrella around the already-implemented crash/stall/usage
   signals
3. `#67` keep as research / experimental until a supported login path exists

### Distribution / Release

1. `#78` public repo split and release workflow

### Backlog

1. `#31` cross-channel mention routing

## Practical Guidance

- Do not build new recovery behavior without audit events first.
- Do not rely on prompt hooks as the only recovery signal.
- Prefer manual-switch alerting over brittle account automation.
- Keep long-lived admin/static roles stable; avoid experimental profile
  switching there.
- Treat public release work (`#78`) as a separate stream from runtime
  resilience.
