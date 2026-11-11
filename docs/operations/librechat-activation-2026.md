# LibreChat activation contract — PLT-165

This document is the activation contract for the single Draft PR. Before that
PR is merged, the desired state has no runtime effect; after merge, Argo is the
only activation path. The existing `chat.smadja.dev` hostname belongs to
Matrix; LibreChat uses the private-only hostname `librechat.smadja.dev`.

## Admission order

### Pre-merge gates

1. Create, outside this repository, `APP_LIBRECHAT_CREDS_KEY`,
   `APP_LIBRECHAT_CREDS_IV`, `APP_LIBRECHAT_JWT_SECRET`,
   `APP_LIBRECHAT_JWT_REFRESH_SECRET`, `APP_LIBRECHAT_LLM_KEY`,
   `APP_LIBRECHAT_OIDC_CLIENT_SECRET` and
   `APP_LIBRECHAT_OPENID_SESSION_SECRET` in the application Doppler project.
   This is the seven-key contract. Meilisearch is disabled and has no
   `MEILI_MASTER_KEY` dependency. `CREDS_KEY` must be exactly 64 hexadecimal
   characters (32 bytes); `CREDS_IV` must be exactly 32 hexadecimal
   characters (16 bytes). The remaining five values are stable, non-empty
   opaque secrets, with no additional encoding requirement in this contract.
   The owner can run `CREDS_KEY=... CREDS_IV=... bash
   tests/harness/librechat-credential-format-test.sh`; it prints only
   `PASS`, `FAIL` or `NOT_EXECUTED`, never a value. Values are never copied to
   Git or read by the coding agent.
2. Before merge, verify the seven names are available to the
   `ClusterSecretStore/doppler-cluster` source and that the format checker
   returns `CREDS_KEY=PASS`, `CREDS_IV=PASS` and
   `LIBRECHAT_CREDENTIAL_FORMAT=PASS`. A missing input is `NOT_EXECUTED`, not
   a pass. No ESO, Argo, OIDC, user, restart or restore result is a pre-merge
   result.
3. In the activation PR, include the Authentik ExternalSecret and blueprint
   in the same reviewed change. The provider has one exact callback,
   `https://librechat.smadja.dev/oauth/openid/callback`, `sub_mode: user_email`,
   and only the existing `family` group (D-2026-11-11-19). No global administrator group is bound
   to the application.
4. Render the official chart with MongoDB authentication, Longhorn PVCs and
   all local login/registration methods and shared conversation links disabled.
   The static MongoDB contract must show the chart-managed credential Secret,
   `MONGODB_ROOT_PASSWORD` from `secretKeyRef`, an indirect `MONGO_URI`, and
   `helm.sh/resource-policy: keep` on the MongoDB PVC. It must not contain an
   inline password.
5. In the same activation PR, update the single active `personal-ai-pilot`
   AppProject at `k8s/optional/personal-ai-2026/hindsight/project.yaml` to
   allow the LibreChat chart and namespace. Do not admit the dormant duplicate
   `k8s/optional/personal-ai-2026/project.yaml`.
6. Add the dedicated Agentgateway client key and a non-admin model policy in a
   separate reviewed change. The existing `APP_LIBRECHAT_LLM_KEY` dependency
   is the client key for this policy, not a direct provider key. The activation
   change must add a secret key such as `LIBRECHAT_AGENTGATEWAY_KEY`, allow only
   `factory/fast` with a LibreChat-owned budget, and add only the LibreChat
   namespace to the Agentgateway ingress policy. Do not reuse Factory
   administrator credentials. Hindsight is intentionally not connected: its
   API currently lacks a trusted per-user bank boundary.
7. Only after the previous checks pass, include `httproute.dormant.yaml` in the
   LibreChat kustomization and add the LibreChat subtree to the active AI
   kustomization. The normal GitHub admission may merge only after the
   pre-merge gates above pass; this is not an Argo sync instruction.

### Post-merge runtime gates

After the normal Git merge, prove in order: ESO `Ready=True`, Argo
`Synced/Healthy`, ready pods, Service/EndpointSlice, private Gateway route,
DNS/TLS and Agentgateway access. These are runtime results and cannot be
substituted by a render or a merged PR.

For MongoDB stability, record only resource names, UIDs, phases and UTC
timestamps. Confirm the application can authenticate and read the synthetic
marker, perform one approved GitOps rollout/restart, wait for MongoDB and
LibreChat to become ready, and read the marker again. Then observe one normal
Helm/Argo reconciliation and repeat the authentication/read check. The
marker must survive both transitions and the MongoDB PVC and generated
credential Secret must remain the same resources. Never print or hash Secret
data. If a post-merge gate fails, roll back GitOps without deleting or
reinitializing the PVC.

The activation PR must change these Git paths together or leave the service
dormant: `k8s/infrastructure/auth/authentik/extra/kustomization.yml` (the
ExternalSecret and blueprint ConfigMap),
`k8s/optional/personal-ai-2026/hindsight/project.yaml` (AppProject source and
destination), `k8s/optional/personal-ai-2026/librechat/kustomization.yaml`
(the private route), and `k8s/applications/ai/kustomization.yaml` (the active
subtree import). The Agentgateway key/policy change is a separate admission
gate and must not be approximated with the existing Factory key.

## Required user and recovery evidence

- Two separate Authentik identities can log in; identity A cannot read or
  alter identity B conversations, credentials, or memory banks.
- A conversation survives a new session and a LibreChat deployment restart.
- A Velero backup for namespace `librechat` completes with a PodVolumeBackup
  for the image/PVC data. MongoDB restore is performed into a fresh isolated
  namespace and validated before any source PVC is touched.
- Logs contain no OIDC client secret, session secret, JWT material, or model
  key. Longhorn write volume and RAM/CPU remain within the admission budget.

## Two-identity E2E contract

Use two separate Authentik identities in separate private browser profiles.
Do not copy cookies, bearer tokens, URLs containing tokens or Secret output
between profiles. Record only HTTP status, resource identifiers, UTC
timestamps and pass/fail results.

1. Identity A signs in through the private Gateway and creates a conversation
   containing a synthetic marker `plt165-user-a-<UTC-ID>`.
2. A logs out through LibreChat and Authentik's end-session endpoint. A new
   private session must require authentication again.
3. Identity B signs in, creates marker `plt165-user-b-<UTC-ID>`, and must not
   see A's conversation in the list or through a direct conversation lookup.
   A direct lookup of an A identifier from B must be rejected with the
   application's normal not-found/forbidden response and must not return
   message content.
4. Restart LibreChat through the approved GitOps rollout procedure. After the
   pods are `Ready`, A signs in again and must recover only A's conversation;
   B must recover only B's conversation.
5. Repeat the direct cross-access checks in both directions. Check application
   and Gateway logs for the absence of OIDC client secret, session secret,
   JWT, model key and Authorization header values.
6. Assert that no Hindsight request or Hindsight network flow is required for
   the journey. Hindsight remains disabled until a real per-user bank
   authorization contract is proven.

Until the pre-merge gates are complete, the PR remains Draft. Until the
post-merge checks are recorded with exact UTC timestamps, LibreChat is not
`RECONCILED`, `RUNTIME`, or `USER` ready.
