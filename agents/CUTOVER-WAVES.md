# Agent Cutover Waves

## Goal

Define a practical cutover order for migrating legacy long-lived agents into
Agent Bridge without switching every role at once.

This is a deployment-planning document, not an approval to cut over everything
at once.

## Wave Design Principles

- Migrate low-surface or low-blast-radius agents first.
- Keep approval-gated external senders late.
- Keep orchestration-heavy or auto-action agents late.
- Prefer one cutover per functional cluster, not all-at-once.
- After each wave, run smoke checks before moving on.

## Proposed Waves

### Wave 1: Lowest external risk

- advisory or background-only roles
- read-mostly researchers
- roles with no direct external send surface

Why:

- Minimal outward surface.
- Good first validation for profile deploy, roster, and session startup without
  major operational risk.

### Wave 2: Operational specialists with bounded scope

- operational specialists with a narrow domain
- report-or-advise roles that do not autonomously send customer-facing output

Why:

- Dedicated domain ownership and clearer reporting loops.
- Strong dependencies on business data, but their behavioral boundary is
  relatively explicit.

### Wave 3: Creative and execution support

- brand-sensitive execution helpers
- QA or review roles coupled to creative workflows
- roles whose tone and handoff quality matter more than raw computation

Why:

- Higher brand risk than Wave 2.
- Strong cross-role QA and asset-handoff coupling.
- Approval gates are clear, but prompt tone and handoff quality matter more.

### Wave 4: High-risk external or auto-action surfaces

- direct customer communication roles
- paid traffic or financially sensitive operators
- approval-gated senders and orchestrators

Why:

- The highest-risk roles can affect customers, inboxes, spend, or approval
  chains immediately.

## Standard Cutover Checklist Per Agent

1. Confirm tracked `agents/<id>/CLAUDE.md` is approved in the private profile
   source.
2. Add or update the roster entry with correct `BRIDGE_AGENT_PROFILE_HOME`,
   workdir, engine, session, and channel launch semantics.
3. Run `agent-bridge profile status <id>`.
4. Run `agent-bridge profile deploy <id> --dry-run`.
5. Run `agent-bridge profile deploy <id>`.
6. Run `bash bridge-start.sh <id> --dry-run`.
7. Start the agent in a maintenance window if a live legacy counterpart still
   exists.
8. Run a role-specific smoke.
9. Confirm no duplicate responders and no missing channel/report surface.

## Role-Specific Smoke Examples

- advisory role: enqueue one analysis task and verify queue delivery
- reporting role: simulate one report and verify it lands in the correct owner
- approval-gated role: verify the role refuses to send or mutate without an
  explicit approval signal
- external-send role: test draft/preview first, not actual customer-facing send

## Recommendation

Use this as the default migration sequence unless the operator reprioritizes for
a live operational need.
