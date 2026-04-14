# Human Outbound Identity Policy

This policy exists to prevent confusion when an Agent Bridge-managed workflow
sends messages under a real human operator account.

## Scope

Apply disclosure only when all of the following are true:

- The outbound message leaves through a human-owned identity or delegated
  operator principal.
- A recipient could reasonably interpret the sender as the human directly.
- The channel implementation is under Agent Bridge control or can be configured
  by Agent Bridge.

Do not auto-apply disclosure when the sender is already visibly an agent-owned
bot identity, for example:

- Discord bot users
- Telegram bot users
- Azure Bot / Teams bot identities

## Default rule

- Human-profile email: prepend disclosure on every outbound message body.
- Human-profile chat or thread messaging: prepend disclosure only to the first
  outbound message per conversation/thread and per human principal.

The canonical tag wording is `[AI Agent]`.

## Configuration contract

Agent Bridge exposes a generic env fallback:

- `BRIDGE_HUMAN_OUTBOUND_DISCLAIMER`

Integrations may define channel-specific overrides:

- `MS365_MAIL_DISCLAIMER`
- `MS365_CHAT_DISCLAIMER`

If both are present, the channel-specific value wins over the generic bridge
value.

Disclosure text may contain `{operator}`. Integrations should resolve that token
from the authoritative human profile for the active principal when possible.

## State contract

Conversation-first-contact disclosure state should be stored inside the
integration state dir, not in global shared files.

Required properties:

- keyed by human principal
- keyed by conversation/thread identifier
- atomic write behavior
- safe default on missing/corrupt file

Current ms365 implementation stores this in:

- `human-outbound-disclosures.json`

## Rollout guidance

- Existing human-profile senders should adopt this contract.
- New integrations should decide first whether they send as a human or as a bot.
- If they send as a bot, disclosure is not required by this policy.
- If they send as a human, they must implement the email-or-first-contact rule
  before being considered complete.
