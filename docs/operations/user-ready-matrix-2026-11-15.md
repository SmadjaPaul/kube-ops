# USER_READY matrix — critical applications (PLT-49, 2026-11-15)

Dated snapshot, not live state. Level reached: **RUNTIME** (read-only, LAN client, no user identity).
Anything that needs a user identity or an external client is `NOT_TESTED`; nothing is inferred.
Levels follow [acceptance-levels.md](acceptance-levels.md): Ready/Healthy proves a workload, not a user journey.

## Method

Client: macOS on the LAN. DNS from UniFi (`@10.0.20.1`) and a public resolver (`@1.1.1.1`).
HTTPS with the system trust store (no `-k`, `ssl_verify_result=0` on every host). Only unauthenticated
`GET` requests; no login, no POST, no credential, no Secret value read.
Cluster: `scripts/kubectl-ro.sh` only. No scale, no exposure, no install.

| Command | Result |
|---|---|
| `just kube-access-check` | `KUBE_ACCESS=PASS`, Kubernetes v1.36.3 |
| `just runtime-smoke` | `TESTED=37 FAILURES=0 SKIPPED=0 VERIFY=PASS` |
| `just backup-audit` | `PRODUCTION_PVC_COVERAGE=FAIL (14/44)`, `CNPG_BACKUP_CONFIGURATION=FAIL (14/16)`, `CNPG_RESTORE_PROOF=UNPROVEN` |
| `just status-app apps-media` | `ARGO=OutOfSync/Unknown`, `PODS=17/17`, `LAST_ERROR=Application has 34 orphaned resources`, `VERIFY=FAIL` |
| `just status-app mealie` | `ERROR: Argo Application not found: mealie` (the Application is `apps-catalog`; pass the ApplicationSet name) |
| Pods outside Running/Completed (all namespaces) | none |

Argo: `apps-catalog`, `apps-platform`, `apps-tools` Synced/Healthy; `apps-media` OutOfSync/Unknown; `apps-ai` Synced/Unknown.

## Reading guide

- Route/DNS: LAN name resolves to the internal Gateway VIP in all cases. `Ext` = HTTPRoute also attached to `Gateway/external`.
  External reachability from a real external client is `NOT_TESTED` for every row.
- TLS: certificate chain verified by the client. HTTP code is the unauthenticated response of `/`.
- OIDC: only what the app publishes without login (config endpoints, login page) plus the Authentik discovery document
  `/application/o/<slug>/.well-known/openid-configuration` (HTTP 200 = provider exists). No login flow was run, so
  OIDC end to end is `NOT_TESTED` everywhere.
- Backup: CNPG = latest completed Barman backup (UTC); Velero = latest schedule result 2026-11-14 (daily).
  A completed backup is not a restore proof; `backup-audit` reports `CNPG_RESTORE_PROOF=UNPROVEN`.
- Durable user action (create, reload, restart pod, still there): `NOT_TESTED` everywhere (needs an identity).

## Matrix

| App | Host (Ext) | Route/DNS, TLS, HTTP / | Pods | OIDC (observed, public) | Init admin | Backup (data class) | Durable action |
|---|---|---|---|---|---|---|---|
| Mealie | mealie (Ext) | OK, valid, 200 | 1/1, 0 restarts | Mealie 3.28.0: `enableOidc=true`, `oidcRedirect=true`, provider Authentik, `allowSignup=false`, password login on; Authentik slug 200 | NOT_TESTED (no public signal) | Velero OK 11-14; PVC `mealie-data` IRREPLACEABLE; restore NOT_PROVEN | NOT_TESTED |
| Immich | immich (Ext) | OK, valid, 200; `/api/server/ping` 200 | server, ML, redis, PG Running | `oauth=true`, `oauthAutoLaunch=true`, `passwordLogin=false`; Authentik slug 200 | `isInitialized=true`, `isOnboarded=true` (PASS, public config) | CNPG 11-13 15:55 + Velero 11-14; photos IRREPLACEABLE; restore NOT_PROVEN | NOT_TESTED |
| Paperless | paperless (internal only) | OK, valid, 302 to `/accounts/login/` | app, PG, redis Running | Login page shows a username form only; no OIDC variable in `k8s/applications/catalog/paperless`; Authentik slug exists (200) but is not wired in Git: local login only | NOT_TESTED (no admin env in Git; state unknown) | CNPG 11-13 17:21 + Velero 11-14; IRREPLACEABLE; restore NOT_PROVEN | NOT_TESTED |
| Polyfin (media) | media (internal only) | OK, valid, 302 to `/web/`; `/health` 404 | polyfin, DB Running | Authentik slug 200; callback registered per [personal-app-sso-review-2026-11.md](personal-app-sso-review-2026-11.md) | NOT_TESTED | CNPG last 11-08 (stale 7 days); PVC `polyfin-data` USEFUL | NOT_TESTED (earlier Brave USER pass in rollout JSON is a past claim, not re-proven) |
| Family TV (AIOStreams) | tv (Ext), aiostreams (internal) | OK, valid, tv 302 to `/web/`, aiostreams 200 | Running | n/a observed | NOT_TESTED | Velero OK 11-14 (`aiostreams-data` USEFUL) | NOT_TESTED |
| Sure (budget) | sure (internal only) | OK, valid, 302 to `/sessions/new` | web, worker, PG, redis Running | Login page contains `openid_connect` and Authentik; slug 200; "Create account" link also present (self sign-up exposure NOT_TESTED) | NOT_TESTED | CNPG 11-13 18:48 + Velero 11-14; IRREPLACEABLE; restore NOT_PROVEN | NOT_TESTED |
| Karakeep | karakeep (Ext) | OK, valid, 307 to `/signin` | web, meilisearch, chrome Running | `/api/auth/providers` lists `credentials` and `custom` (authentik, oauth); slug 200 | NOT_TESTED | Velero OK 11-14; `data-web-0` IRREPLACEABLE; no CNPG; restore NOT_PROVEN | NOT_TESTED |
| Trilium | trilium (Ext) | OK, valid, 302 to `/login` | Running | Login page mentions SSO/password; Authentik slug for trilium returns 404 (no provider) | NOT_TESTED | Velero OK 11-14; IRREPLACEABLE; restore NOT_PROVEN | NOT_TESTED |
| Vikunja (tasks) | tasks (Ext) | OK, valid, 200; `/api/v1/info` 200 | app, PG Running | `openid_connect.enabled=true` (Authentik); **`local.registration_enabled=true`** on an Ext route; slug 200 | NOT_TESTED | CNPG 11-12 23:24 + Velero 11-14; IRREPLACEABLE; restore NOT_PROVEN | NOT_TESTED |
| RomM | romm (Ext) | OK, valid, 200 | app, PG Running | `OIDC.ENABLED=true`, provider authentik, `SHOW_SETUP_WIZARD=false`; slug 200 | setup wizard not shown (PASS, public) | CNPG 11-12 21:06 + Velero 11-14; USEFUL | NOT_TESTED |
| PinePods | pinepods (Ext) | OK, valid, 200 | app, PG, valkey Running (2 restarts) | slug 200; `self_service_status` `status=false` | `first_admin_created=true` (PASS, public) | CNPG 11-12 22:10 + Velero 11-14; USEFUL | NOT_TESTED |
| SparkyFitness | fitness (internal only) | OK, valid, 200; `/api/auth/ok` 200 | server, frontend, garmin, DB Running | slug 200 | NOT_TESTED | CNPG 11-12 20:05; Velero schedule never ran; IRREPLACEABLE class; restore drill documented in [plt-221](plt-221-sparkyfitness-r2-restore-drill.md) | NOT_TESTED |
| RustiCal (calendar) | calendar (internal only) | OK, valid, 303 to `/frontend`, then `/frontend/login` 200 | Running | slug 200 | NOT_TESTED | Velero schedule never ran; `rustical-data-bulk` IRREPLACEABLE: gap | NOT_TESTED |
| BookOrbit | bookorbit (internal only) | OK, valid, 200 | app 3 restarts; PG Running | slug 200 | NOT_TESTED | CNPG: none, instance status error (`HTTP communication issue`); Velero schedule never ran: gap | NOT_TESTED |
| Element / Synapse / MAS (Matrix) | chat, matrix, account (Ext) | OK, valid; chat 200; account 200; matrix `/` 404 (expected), `/_matrix/client/versions` 200; well-known client 200 | all Running | MAS discovery 200 | NOT_TESTED | CNPG 11-13/11-14 + Velero 11-12 (matrix schedule 11-14); IRREPLACEABLE | NOT_TESTED |
| LibreChat | librechat (internal only) | OK, valid, 200 | app 2 restarts; Mongo Running | slug 200 | NOT_TESTED | Velero OK 11-14; USEFUL | NOT_TESTED |
| Authentik | auth (Ext) | OK, valid, 302 to default authentication flow | n/a | identity authority | NOT_TESTED | CNPG 11-13 00:05 | NOT_TESTED |
| Grafana | grafana (internal only) | OK, valid, 302 to `/login`; login page references `generic_oauth` / Authentik | n/a | present | NOT_TESTED | n/a | NOT_TESTED |
| IT-Tools / Stirling-PDF / SearXNG / ntfy / Home Assistant | various | OK, valid, 200 | Running | n/a | NOT_TESTED | per class | NOT_TESTED |

## Ready/Healthy versus usable

- Evidence collected: no pod outside Running/Completed in any namespace; the pod listing of the apps above shows every
  container ready; `apps-media` reports `PODS=17/17`; the smoke ran 37 routes with 0 failures. No row reaches USER.
  HTTP 200/302 only proves route, TLS and a backend answer.
- Argo `apps-media` is `OutOfSync/Unknown` with 34 orphaned resources; `apps-ai` health is Unknown. Pods in `media` are
  ready, so Argo status and workload readiness disagree for `apps-media`. The `apps-ai` pods were not inspected.
- Public DNS (`@1.1.1.1`) resolves every `smadja.dev` host to Cloudflare IPs, including hosts attached to the internal
  Gateway only. Resolving is not proof of external access.

## Reproduced error codes (LAN, unauthenticated, TLS verified)

| Request | Result | Meaning |
|---|---|---|
| `GET paperless/api/documents/` | 401 `Authentication credentials were not provided.` | API requires auth, expected |
| `GET media/health` | 404 | Polyfin has no `/health`; use `/web/` |
| `GET matrix/` | 404 | Synapse has no root page; `/_matrix/client/versions` is 200 |
| `GET auth/application/o/trilium/.well-known/openid-configuration` | 404 | no Authentik provider for Trilium |
| `GET auth/application/o/mas/...` | 404 | wrong slug; MAS is `matrix-mas` (200) |

The previous 14/11 timeout on `ittools` did not reproduce (HTTP 200 now); that pod had just restarted.

## Findings to qualify

1. AudioBookRequest: retired (decision of Paul, 2026-11-15: replaced by BookOrbit). Removed from Git by PLT-46;
   see "Decommission check" below.
2. Vikunja: local registration open on an external route; confirm intent.
3. Backup gaps: BookOrbit (no CNPG backup, instance status error), SparkyFitness, RustiCal, the BookOrbit Velero schedule never ran;
   Polyfin CNPG last backup 11-08.
4. `CNPG_RESTORE_PROOF=UNPROVEN` is the audit aggregate: it counted no accepted proof. It does not prove absence per
   dataset. SparkyFitness has an isolated restore on 2026-11-12 ([plt-221](plt-221-sparkyfitness-r2-restore-drill.md))
   that the audit did not count; reconcile that gap. For the other IRREPLACEABLE apps no restore proof was found in
   this review (matrix rows say restore NOT_PROVEN).
5. Paperless has no SSO wiring in Git; Trilium has no Authentik provider. Confirm whether that is intended.
6. `just status-app` takes the Argo Application name, not the app name; the docs do not say so.

## NOT_TESTED, with the exact action required

- OIDC end to end, init admin where not published, and durable action for every row: needs a test user in Authentik
  (`family` group) and a login by Paul or a test identity he provides. No identity was used.
- Apps without OIDC wiring (Paperless local login only; Trilium has no Authentik provider): an
  Authentik test user is not enough. Paul must provide a local test account per app (Paperless, Trilium) (username and password supplied by
  him, never written to Git or Linear), or claim the admin account himself, before login and durable action can be tested.
- External authorized client: needs a device outside the LAN (or a Cloudflare Access service token that Paul grants).
- Restore of any IRREPLACEABLE dataset: needs the isolated restore drill (separate mutation, not run here).

## Decommission: AudioBookRequest (2026-11-15)

Paul decided AudioBookRequest is replaced by BookOrbit, and authorized deleting its PVC. PLT-46 removes it from Git only
(no live delete): `k8s/applications/media/audiobookrequest/` (Deployment, Service, HTTPRoute on `Gateway/internal` and
`Gateway/external`, PVC `audiobookrequest-config` 5Gi), the media kustomization entry and the Velero schedule
`daily-audiobookrequest`. Argo prunes the objects. The PV has reclaimPolicy Retain and becomes Released: it is not deleted
here and belongs to the next PLT-46 Released-PV batch. Last Velero backup before removal: `velero-daily-audiobookrequest-20261115020028`,
Completed, location `r2`. Runtime proof is recorded in PLT-46, not here.

## Attempt 2 (2026-11-15): user level still `NOT_TESTED`, BLOCKED

Paul approved creating dedicated `agent-e2e-` test accounts. No legitimate admin path exists to create them:

- Authentik: the PLT-57 service account `agent-e2e` is a non-superuser member of `test-users` with no role, so it cannot create users.
  Its key `APP_AGENT_E2E_TOKEN` is also absent from Doppler `infrastructure/prd` and `apps/prd` (names listed with `doppler-safe.sh`), although the
  cluster Secret `auth/authentik-blueprint-core-secrets` holds `AGENT_E2E_TOKEN`. `AUTHENTIK_TOKEN` is expired. `AUTHENTIK_BOOTSTRAP_TOKEN` and the admin
  password are root credentials and were not used.
- Paperless and Trilium: `scripts/kubectl-rw.sh` has no `exec` verb, so no account can be created through the repository wrapper; no admin token is available.
- Nothing was created, so nothing needed deletion.
