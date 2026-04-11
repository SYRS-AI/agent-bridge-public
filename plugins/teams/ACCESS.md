# Teams Access Setup

1. In Azure, create or open an Azure Bot resource.
2. Copy the bot Application ID.
3. Create a client secret and copy the value as the App Password.
4. Copy the Tenant ID.
5. Add the bot to Teams and send it one message from the intended user.
6. Use the Teams AAD object ID or Teams user ID as `--allow-from`.
7. Run Agent Bridge setup:

```bash
agb setup teams patch \
  --app-id "<app-id>" \
  --app-password "<client-secret>" \
  --tenant-id "<tenant-id>" \
  --allow-from "<aad-object-id-or-user-id>" \
  --yes
```

For team channels, also add a conversation/channel id:

```bash
agb setup teams patch \
  --app-id "<app-id>" \
  --app-password "<client-secret>" \
  --tenant-id "<tenant-id>" \
  --conversation "<teams-conversation-or-channel-id>" \
  --require-mention \
  --yes
```

For full production bring-up, including messaging endpoint probing, `TEAMS_WEBHOOK_HOST`, reverse proxy examples, and iptables guidance, see [docs/channels/teams-setup.md](../../docs/channels/teams-setup.md).
