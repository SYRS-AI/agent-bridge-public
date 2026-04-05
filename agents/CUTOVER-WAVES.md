# Agent Cutover Waves

## Goal

Define a practical cutover order for the remaining migrated agent profiles after `main`, `huchu`, `patch`, and `shopify`.

This is a deployment-planning document, not an approval to cut over everything at once.

## Already Live

- `patch`
- `shopify`
- `main`
- `huchu`

## Remaining Profiles

- `reedy`
- `mailbot`
- `newsbot`
- `max`
- `syrs-creative`
- `syrs-meta`
- `syrs-cs`
- `syrs-calendar`
- `syrs-sns`
- `syrs-video`
- `syrs-satomi`
- `syrs-warehouse`
- `syrs-fi`
- `syrs-production`
- `syrs-trend`
- `syrs-derm`
- `syrs-buzz`

## Wave Design Principles

- Migrate low-surface or low-blast-radius agents first.
- Keep approval-gated external senders late.
- Keep orchestration-heavy or auto-action agents late.
- Prefer one cutover per functional cluster, not all-at-once.
- After each wave, run smoke checks before moving on.

## Proposed Waves

### Wave 1: Lowest external risk

- `reedy`
- `max`
- `newsbot`
- `syrs-buzz`

Why:

- No dedicated Discord bot cutover complexity, or minimal outward surface.
- Mostly advisory / curation / background behavior.
- Good first validation for profile deploy + roster + session startup without major brand risk.

### Wave 2: Operational specialists with bounded scope

- `syrs-calendar`
- `syrs-trend`
- `syrs-derm`
- `syrs-production`
- `syrs-warehouse`
- `syrs-fi`

Why:

- Dedicated domain ownership and clearer reporting loops.
- Mostly report / advise / monitor, with fewer direct customer-facing sends.
- Strong dependencies on business data, but their behavioral boundary is relatively explicit.

### Wave 3: Creative and marketing execution support

- `syrs-creative`
- `syrs-sns`
- `syrs-video`
- `syrs-satomi`

Why:

- Higher brand risk than Wave 2.
- Strong cross-agent QA and asset-handoff coupling.
- Approval gates are clear, but prompt tone and handoff quality matter more.

### Wave 4: High-risk external or auto-action surfaces

- `syrs-meta`
- `mailbot`
- `syrs-cs`

Why:

- `syrs-meta` has limited autonomous action authority and can affect paid traffic.
- `mailbot` is the email routing + send gatekeeper.
- `syrs-cs` is direct customer communication and approval-sensitive.

## Per-Agent Notes

### `reedy`

- Personal-agent style.
- Strong privacy boundary.
- No shell/system command behavior allowed.

### `max`

- Business assistant with `main` overlap.
- Needs careful A2A boundary with `main`.

### `newsbot`

- Delivery still routes through `main`.
- Good candidate for low-risk smoke once `main` is stable.

### `syrs-buzz`

- Background-only.
- No Discord channel.
- Clean bridge-task reporting to `huchu` is the key smoke.

### `syrs-calendar`

- Customer intelligence, not CS.
- Reports to `huchu`; approval boundary is clear.

### `syrs-trend`

- Source quality and reporting discipline matter most.
- Low execution risk.

### `syrs-derm`

- Needs strong memory preload discipline.
- Medical / formulation certainty boundaries should be smoke-tested.

### `syrs-production`

- Calendar and supplier timing behavior matters.
- Approval gates around MOQ / PO / cost changes must survive cutover.

### `syrs-warehouse`

- Direct tracking handoff from `syrs-cs`.
- Manual stock update parsing should be smoke-tested.

### `syrs-fi`

- Highest data sensitivity in Wave 2.
- Numeric verification discipline is the core smoke target.

### `syrs-creative`

- Approval gate + real product reference rule are the main risks.

### `syrs-sns`

- Depends on strong collaboration with creative + Satomi.

### `syrs-video`

- Approval gate + one-message output rule are the main smoke targets.

### `syrs-satomi`

- QA-only role boundary must remain sharp.
- Should not drift into PM behavior.

### `syrs-meta`

- Auto-action envelope must be preserved exactly.
- Needs extra smoke on reporting cleanliness and approval boundaries.

### `mailbot`

- Email send approval gate is critical.
- Routing correctness and no-send-without-approval should be explicitly smoke-tested.

### `syrs-cs`

- Highest conversational risk.
- Must preserve Myo send approval gate, Satomi QA loop, and no-duplicate-reminder discipline.

## Standard Cutover Checklist Per Agent

1. Confirm tracked `agents/<id>/CLAUDE.md` is approved.
2. Add or update roster entry with correct `BRIDGE_AGENT_PROFILE_HOME`, workdir, engine, session, and channel launch semantics.
3. Run `~/.agent-bridge/agb profile status <id>`.
4. Run `~/.agent-bridge/agb profile deploy <id> --dry-run`.
5. Run `~/.agent-bridge/agb profile deploy <id>`.
6. Run `bash ~/.agent-bridge/bridge-start.sh <id> --dry-run`.
7. Start the agent in a maintenance window if a live gateway counterpart still exists.
8. Run a role-specific smoke.
9. Confirm no duplicate responders and no missing channel/report surface.

## Role-Specific Smoke Examples

- `newsbot`: enqueue a curation task and verify delivery path to `main`.
- `syrs-buzz`: simulate a report and verify it lands in `huchu`.
- `syrs-warehouse`: test a tracking handoff path and a stock-alert path.
- `syrs-fi`: test a report-only finance summary without write actions.
- `syrs-creative`: test concept-only flow without generation, then an approval-gated generation path.
- `mailbot`: test routing plus rejected send without explicit approval.
- `syrs-cs`: test draft/QA/approval path without actual external send first.

## Recommendation

Use this as the default migration sequence unless Patch or Sean explicitly reprioritizes for a live operational need.
