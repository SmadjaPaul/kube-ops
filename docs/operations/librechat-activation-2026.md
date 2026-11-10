# LibreChat activation contract — PLT-165

This is a preparation contract only. The LibreChat subtree remains outside the
active Argo root and the HTTPRoute and Authentik blueprint are deliberately
dormant. The existing `chat.smadja.dev` hostname belongs to Matrix; LibreChat
uses the private-only candidate hostname `librechat.smadja.dev`.

## Admission order

1. Create, outside this repository, `APP_LIBRECHAT_CREDS_KEY`,
   `APP_LIBRECHAT_CREDS_IV`, `APP_LIBRECHAT_JWT_SECRET`,
   `APP_LIBRECHAT_JWT_REFRESH_SECRET`, `APP_LIBRECHAT_MEILI_MASTER_KEY`,
   `APP_LIBRECHAT_LLM_KEY`, `APP_LIBRECHAT_OIDC_CLIENT_SECRET` and
   `APP_LIBRECHAT_OPENID_SESSION_SECRET` in the application Doppler project.
   Values are never copied to Git or read by the coding agent.
2. The Authentik kustomization already carries the optional Secret contract;
   admit the dormant blueprint into its `authentik-blueprints` ConfigMap only
   in the same reviewed change as the credentials. The
   provider has one exact callback, `https://librechat.smadja.dev/oauth/openid/callback`,
   `sub_mode: user_email`, and only the `LibreChat Users` group. No global
   administrator group is bound to the application.
3. Admit the LibreChat ExternalSecret and wait for ESO `Ready=True`. Render
   the official chart with MongoDB authentication, Longhorn PVCs and all
   local login/registration methods disabled.
4. Add the dedicated Agentgateway client key and a non-admin model policy in a
   separate reviewed change. Do not reuse Factory administrator credentials.
   Hindsight is intentionally not connected: its API currently lacks a
   trusted per-user bank boundary.
5. Only after the previous checks pass, include `httproute.dormant.yaml` in the
   LibreChat kustomization and admit the child Application. Prove Argo
   `Synced/Healthy`, ready MongoDB and `/health` through the internal Gateway.

## Required user and recovery evidence

- Two separate Authentik identities can log in; identity A cannot read or
  alter identity B conversations, credentials, or memory banks.
- A conversation survives a new session and a LibreChat deployment restart.
- A Velero backup for namespace `librechat` completes with a PodVolumeBackup
  for the image/PVC data. MongoDB restore is performed into a fresh isolated
  namespace and validated before any source PVC is touched.
- Logs contain no OIDC client secret, session secret, JWT material, or model
  key. Longhorn write volume and RAM/CPU remain within the admission budget.

Until these checks are recorded with exact UTC timestamps, LibreChat is
`STATIC` preparation only, not `RECONCILED`, `RUNTIME`, or `USER` ready.
