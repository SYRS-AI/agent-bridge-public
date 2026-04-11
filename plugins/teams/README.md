# Microsoft Teams Channel

This Claude Code channel plugin connects a Teams bot to a Claude agent through Agent Bridge.

## Runtime Files

By default the plugin reads:

- `~/.claude/channels/teams/.env`
- `~/.claude/channels/teams/access.json`
- `~/.claude/channels/teams/state.json`

When Agent Bridge starts an agent with `plugin:teams@agent-bridge`, it sets `TEAMS_STATE_DIR` to the agent-local directory, for example:

```bash
~/.agent-bridge/agents/patch/.teams
```

## Environment

```dotenv
TEAMS_APP_ID=<azure-bot-app-id>
TEAMS_APP_PASSWORD=<azure-bot-client-secret>
TEAMS_TENANT_ID=<azure-tenant-id>
TEAMS_WEBHOOK_HOST=0.0.0.0
TEAMS_WEBHOOK_PORT=3978
```

Expose `http://<host>:3978/api/messages` through HTTPS and set it as the Azure Bot Service messaging endpoint.

For the full operator guide, including ALB / nginx / iptables paths and setup validation, see [docs/channels/teams-setup.md](../../docs/channels/teams-setup.md).

## Tools

- `reply`: send a message back to a Teams conversation that has already passed access control.
- `fetch_messages`: read the local rolling message log captured by the plugin.

## Access

`access.json` is allowlist-first:

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["<aad-object-id-or-teams-user-id>"],
  "groups": {
    "<conversation-id-or-channel-id>": {
      "requireMention": true,
      "allowFrom": []
    }
  },
  "pending": {},
  "routes": {}
}
```

Agent Bridge writes this file through:

```bash
agb setup teams <agent> --app-id ... --app-password ... --tenant-id ... --allow-from ... --messaging-endpoint https://bot.example.com/api/messages --webhook-host 0.0.0.0
```

## Current Scope

This is the Phase 1 channel implementation: webhook receive, access gate, Claude channel notification, reply, and local message fetch. Multi-tenant user-to-agent routing is intentionally left to the Agent Bridge relay layer so one Teams bot can map many users to many timeout agents without mixing conversation state.
