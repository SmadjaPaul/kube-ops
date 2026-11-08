# BookOrbit 3.6.0 — native Authentik OIDC admission checklist (PLT-122)

The accepted target is BookOrbit 3.6.0, official digest already pinned in `k8s/applications/media/bookorbit/app.yaml`. Media remains private to `Gateway/internal`; this change does NOT import BookOrbit into the active media root or grant external exposure. The owner has explicitly chosen to retire Decypharr and wait for an **official** BookOrbit release containing native TorBox (upstream PR bookorbit/bookorbit#1819 is currently **unmerged**). Never deploy the PR image or a rolling `main` tag.

## GitOps-auth wiring

- The existing canonical Authentik blueprint `k8s/infrastructure/auth/authentik/extra/blueprints/apps-bookorbit.yaml` is now included in the active ConfigMap generator. Use **only** this blueprint; do not load both the `bookorbit-v36-staged` alternate and canonical `bookorbit` application.
- Provider: confidential authorization-code client; ID `bookorbit`, secret `!Env BOOKORBIT_CLIENT_SECRET`, Authentik issuer `https://auth.smadja.dev/application/o/bookorbit/`, group-gated application for `family` and `authentik-admins`.
- Callbacks (exact-match): `https://bookorbit.smadja.dev/oauth2-callback` and `bookorbit://oauth2-callback` (mobile).
- New `authentik-blueprint-bookorbit` ExternalSecret maps `APP_BOOKORBIT_OIDC_CLIENT_SECRET` from Doppler `cluster/prd` to `BOOKORBIT_CLIENT_SECRET` in the Authentik deployment. Optional `envFrom` makes a missing key non-fatal to the **entire** IdP; a missing key is still a **BLOCKED** BookOrbit provider and must not be called PASS.
- The BookOrbit workload resolves `auth.smadja.dev` through the existing internal Gateway VIP `10.0.20.192` (TLS validation stays on) and a narrow Cilium policy to the VIP on TCP443 and actual Authentik backend identity TCP9000. The dedicated private-issuer enablement is bounded to BookOrbit; do NOT use TLS verify=false or world-wide egress.
- Required BookOrbit runtime keys already staged separately: `APP_BOOKORBIT_JWT_SECRET`, `APP_BOOKORBIT_SETUP_BOOTSTRAP_TOKEN`, `APP_BOOKORBIT_PODCAST_ENCRYPTION_KEY`, `APP_BOOKORBIT_BOOK_REQUEST_ENCRYPTION_KEY`. CNPG backup keys `APP_BOOKORBIT_CNPG_S3_ACCESS_KEY_ID` / `APP_BOOKORBIT_CNPG_S3_SECRET_ACCESS_KEY` require a **dedicated** Hetzner isolation policy/negative test. Do not fall back to `HETZNER_S3_*`.

## Bootstrap and user sign-in (requires live execution)

1. Validate the exact owner/secret *names* exist in Doppler, ESO resources `Ready`, and the worker has `BOOKORBIT_CLIENT_SECRET` without printing values. Validate the blueprint status is successful and Authentik discovery `.../application/o/bookorbit/.well-known/openid-configuration` returns issuer matching the configured URI.
2. Confirm internal DNS, Gateway, real TLS, Service endpoints and OIDC discovery **from the BookOrbit Pod**, including Cilium/Hubble flows. An HTTP200 from the browser alone is insufficient.
3. After verified CNPG backup and isolated restore, admit BookOrbit via its parent media Kustomization. Startup must show healthy DB and persistent `/appdata` and `/data/book-dock`; no TorBox download client configured for now.
4. Bootstrap a **local superuser first**, privately, via BookOrbit's documented setup token. Open BookOrbit Settings → OIDC / SSO → Add Provider: slug `authentik`, issuer `https://auth.smadja.dev/application/o/bookorbit/`, client ID `bookorbit`, secret from the same Doppler key, scopes `openid profile email groups`. Use the app's **Test** button and save/enable. Never place the client secret in Git/Linear/logs.
5. Validate callbacks using a real authorized account, persistence after browser refresh, group claims, least privilege and a denied-account negative test. Configure user auto-provision deliberately and only map groups with explicit expected access. Keep local admin recovery until verified. Avoid automatic account linking by unverified email/username.
6. Only after `LOGIN_PASS` and read/import smoke on a freely redistributable EPUB and audiobook may `DISABLE_LOCAL_AUTH` be considered. A local admin recovery method must remain documented and tested before enforcing SSO-only.

## Proof matrix

- `STATIC` = Kustomize/Helm rendered + schema / CI PASS
- `RECONCILED` = Argo exact SHA Synced/Healthy + ESO/CNPG/blueprints Ready
- `RUNTIME` = Pod/Service/Gateway/TLS/OIDC discovery/storage PASS
- `USER` = BookOrbit OIDC session, roles, sample book/audiobook read, denied user PASS

No merged PR or prepared blueprint alone satisfies the last three gates. Log evidence in [PLT-122](https://linear.app/boule/issue/PLT-122) and the repo test-result v1 JSON. Pending upstream TorBox PR #1819 must not block **manual** Book Dock imports; nor should BookOrbit introduction reactivate Decypharr, Arr, Jellyfin or Audiobookshelf.
