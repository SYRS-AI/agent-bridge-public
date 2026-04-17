# Security Policy

## Supported Versions

The `main` branch is the supported line for security fixes.

## Reporting A Vulnerability

Do not open a public issue for a suspected security vulnerability.

Preferred process:

1. Use the repository host's private vulnerability reporting feature if it is enabled.
2. If that is not available, contact the maintainers through a private channel before public disclosure.
3. Include reproduction steps, impact, and any suggested mitigation.

## What To Expect

Maintainers should acknowledge a valid report, confirm scope, and work toward a fix before coordinated disclosure.

## Current Guardrails

- Optional prompt guard is available behind `BRIDGE_PROMPT_GUARD_ENABLED=1`.
- When enabled, Agent Bridge scans inbound channel text, queue task bodies, intake triage raw captures, Claude prompt submission, MCP output, and outbound bot replies/notifications.
- Static Claude sessions also install hook-based tool policy controls that deny direct access to other agents' homes, `agent-roster.local.sh`, and `state/tasks.db`, then record tool activity into `audit.jsonl`.
- These controls are containment and audit layers for the shared-user runtime. They are not a substitute for OS-level tenant isolation.

## Out Of Scope

The bridge is intended for trusted local environments. Reports that depend entirely on a user granting an agent access to an untrusted directory may be treated as documentation or threat-model issues rather than product vulnerabilities.
