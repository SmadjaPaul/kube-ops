# Vikunja 2.7.0

Vikunja's native MCP server is available at:

`https://tasks.smadja.dev/api/v2/mcp`

The endpoint is provided by the official Vikunja image. It uses Streamable HTTP
and requires a Vikunja API token with the `mcp:access` permission. No custom
MCP wrapper or separate deployment is used.

## R1 posture

The 2.7.0 image upgrade is staged without a token, Kubernetes Secret,
ExternalSecret, or client configuration. The endpoint therefore remains
uncredentialed for automation: requests without a valid API token are rejected
by Vikunja. Creating the bot, minting its token, sharing a project, and
delivering the credential are R2 actions.

## BOT_SECRET_CONTRACT (R2)

- Owner: Paul Personal.
- Vikunja bot username: `bot-talos-vikunja-bot`.
- Doppler key: `APP_VIKUNJA_BOT_TALOS_TOKEN`.
- Future ESO target: `vikunja-mcp-bot`, key `VIKUNJA_MCP_TOKEN`.
- Intended access: only the Paul Personal project, shared with project rights
  `1` (read/write), never admin rights.
- Required token permissions: `mcp:access`; `tasks:read_all`,
  `tasks:read_one`, `tasks:create`, and `tasks:update`.
- The intended task operations are read, create, set due date, set priority,
  and complete. Native Vikunja token permissions are route-scoped, so
  `tasks:update` cannot be narrowed to only those fields without a custom
  wrapper; task deletion and project/team administration are not granted.
- Token expiry, rotation, and the eventual MCP client consumer must be
  explicitly chosen before the secret is created.

Do not create the bot, token, project grant, or secret as part of the R1 image
upgrade.
