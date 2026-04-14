# Microsoft 365 / Graph Plugin

This Claude Code MCP plugin exposes Microsoft Graph tools — mail, calendar,
directory, and Teams chat — to a Claude agent running under Agent Bridge.
Each user principal (UPN) gets its own delegated access + refresh token
stored under `~/.claude/channels/ms365/tokens/`.

Pairing happens through the authorization code flow, with the browser
redirect captured by the Teams plugin's `/auth/callback` handler — the
Teams plugin already runs an HTTPS-reachable listener for bot webhooks, so
this plugin piggybacks on that ingress rather than standing up a second
loopback server.

## Runtime Files

By default the plugin reads:

- `~/.claude/channels/ms365/.env`
- `~/.claude/channels/ms365/tokens/<slug-of-upn>.json`
- `~/.claude/channels/ms365/pending/<slug-of-upn>.json`

When Agent Bridge starts an agent with `plugin:ms365@agent-bridge`, it
sets `MS365_STATE_DIR` to the agent-local directory, for example:

```bash
~/.agent-bridge/agents/<agent>/.ms365
```

## Environment

```dotenv
MS365_TENANT_ID=<entra-tenant-id-guid>
MS365_CLIENT_ID=<app-registration-client-id>
MS365_CLIENT_SECRET=<app-registration-client-secret>
MS365_DEFAULT_UPN=<default-user-principal-name>
MS365_DEFAULT_SCOPES="openid profile offline_access User.Read Mail.Read Mail.Send Calendars.Read Calendars.ReadWrite People.Read User.Read.All Directory.Read.All Chat.ReadWrite"
MS365_REDIRECT_URI=http://localhost:3978/auth/callback
# Optional: if set, prepended to every outgoing mail_send/mail_reply/mail_reply_all body.
# Useful for AI-agent disclaimers. Plain text; HTML bodies get the disclaimer as an
# escaped blockquote-style div at the top.
#
# May contain the literal token `{operator}`, which is resolved at send time from
# Azure AD via Graph `/me` displayName (cached per UPN). Falls back to the UPN
# local-part if the lookup fails. This lets a single fleet-wide config line
# personalize the disclaimer per agent without hard-coding names.
#
# Example:
#   MS365_MAIL_DISCLAIMER="{operator}님의 에이전트가 대신 보내는 메시지입니다. 에이전트가 보내는 메시지에는 [AI Agent] 라고 태그가 붙어있고 실수를 할 수 있으니 참고 바랍니다."
MS365_MAIL_DISCLAIMER=
```

The Azure AD app registration must have `MS365_REDIRECT_URI` registered as
a redirect URI exactly (including scheme, host, and path) and must have a
client secret (confidential client — this plugin will not start without
`MS365_CLIENT_SECRET`).

For a hosted deployment where the Teams plugin sits behind a public
ingress, point `MS365_REDIRECT_URI` at the public URL (for example
`https://bot.example.com/auth/callback`) and make sure the ingress routes
both `/api/messages` (Teams bot webhook) and `/auth/callback` (this
plugin's redirect) to the Teams plugin listener.

## Pairing Flow

1. Call `pair_start(upn=user@tenant.com)`. The tool returns an
   `authorize_url` plus an opaque state.
2. The user opens the URL in a browser, signs in, and approves the scopes.
3. Microsoft redirects to `MS365_REDIRECT_URI?code=...&state=...`.
4. The Teams plugin's `/auth/callback` handler validates the state shape,
   atomically writes `{state, code, received_at}` into
   `$BRIDGE_HOME/shared/ms365-callbacks/<state>.json`, and shows a short
   success page.
5. Call `pair_poll(upn=user@tenant.com)`. The tool sees the callback
   file, POSTs `grant_type=authorization_code` to the token endpoint,
   saves the token, and cleans up the pending + callback files.
6. Tokens auto-refresh when within five minutes of expiry.

State expires 15 minutes after `pair_start`. Call `pair_start` again to
restart the flow. `logout(upn=...)` deletes the token.

## Tools

### Pairing / session
- `pair_start(upn, scopes?)`
- `pair_poll(upn)`
- `pair_status(upn)`
- `logout(upn)`

### Identity / directory
- `me(upn, select?)`
- `user_get(upn, lookup, select?)`
- `people_search(upn, query, top?)`

### Mail
- `mail_list(upn, folder?, top?, search?, filter?, select?)`
- `mail_get(upn, message_id)`
- `mail_send(upn, to, cc?, subject, body, body_type?)`
- `mail_reply(upn, message_id, body, body_type?)` — Graph-native `/me/messages/{id}/reply`. Preserves conversation threading.
- `mail_reply_all(upn, message_id, body, body_type?)` — Graph-native `/me/messages/{id}/replyAll`. Preserves conversation threading and the original To/Cc set.

### Calendar
- `calendar_upcoming(upn, days?, top?)` — `/me/calendarview` over the next N days
- `calendar_create(upn, subject, start, end, timezone?, attendees?, body?, location?, online?)`

### Teams chat
- `chat_list(upn, top?, filter?)` — `/me/chats` with member + last message preview
- `chat_messages(upn, chat_id, top?)`
- `chat_send(upn, chat_id, body, content_type?)`
- `chat_create(upn, targets, topic?)` — 1:1 or group; Graph returns the
  existing chat id if the same member set already has one, so this is
  find-or-create rather than always-create
- `chat_delete(upn, chat_id, message_id)` — `softDelete` via
  `/me/chats/{id}/messages/{id}/softDelete`
- `chat_undo_delete(upn, chat_id, message_id)` — mirror of `chat_delete`
- `joined_teams(upn)`

## Scopes

The plugin doesn't pin scopes — whatever the user consents to at
pair time ends up in the stored token. The default scope list above
covers every tool this plugin exposes. A minimal setup can drop
`Directory.Read.All`, `User.Read.All`, `Chat.ReadWrite` if the
corresponding tools are not used.

## Security Notes

- Tokens are stored with mode `0600` under `$MS365_STATE_DIR/tokens/`
  along with the refresh token. Agent sandboxing should isolate this
  directory to the owning agent.
- `MS365_CLIENT_SECRET` is required at startup. Rotate it through Azure
  AD and update `.env` as needed.
- The plugin never logs access tokens or refresh tokens; error messages
  include only the Graph API error body truncated to 500 characters.
- `MS365_REDIRECT_URI` validation is enforced by the Teams plugin's
  callback handler: the incoming `state` parameter must match
  `/^[A-Za-z0-9_-]{8,128}$/` before anything is written to
  `shared/ms365-callbacks/`.
