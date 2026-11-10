# Personal AI pilot — OpenClaw, Hindsight, LibreChat (10 November 2026)

Status: **HINDSIGHT RUNTIME QUALIFIED / OPENCLAW USER JOURNEY PENDING**. The
Hindsight child is Argo `Synced/Healthy` at chart 1.2.1; all three Hindsight
ExternalSecrets are `SecretSynced=True`, CNPG is running with pgvector, the
API retain/recall/reflect journey passes on a synthetic isolated bank, and an
isolated CNPG restore is proven. OpenClaw and LibreChat remain unadmitted, so
the personal assistant is not yet USER-qualified. LibreChat NetworkPolicies
and identity admission remain fail-closed.

## Scope and provenance

Rebuild the *personal assistant* role only. Never resurrect OpenClaw Talos Ops,
Open WebUI, Qdrant, LiteLLM, Paperclip or the old OpenClaw operator without a
separate architectural review. Mastra Factory remains the engineering orchestrator.
Past references: kube-ops PR #295 (isolated cells), #401 (suspended test),
#407 (delegation unproven), #459 (retirement). Existing optional
`hermes-personal` foundation is unchanged.

Pinned first-pilot components:
- OpenClaw **2026.11.2** official GHCR base, wrapped in the private
  `openclaw-personal` image with the official Hindsight plugin, direct
  upstream-style K8s Deployment, no Operator/Enterprise, single writer and
  port-forward only.
- Hindsight **1.2.1** official OCI Helm chart + dedicated CNPG 17.7 standard
  (pgvector) with Barman/Hetzner and no HTTPRoute. Chart's control plane disabled.
  The originally qualified 1.2.0 runtime is retained as historical evidence;
  1.2.1 is the corrective release for the MiniMax-compatible reflect schema.
- LibreChat **0.8.8**, official chart **3.0.0**, bundled authenticated MongoDB,
  no Meilisearch/RAG at first, and intentionally **no login method** until an
  Authentik per-user OIDC review. Never expose this state to the family.
- Hermes tenant ApplicationSet stays empty and is not migrated by this change.

Supply-chain verification recorded on 10 November 2026 (linux/amd64):

| Artifact | Version | OCI/chart digest or platform manifest | Verification |
|---|---:|---|---|
| OpenClaw upstream base | 2026.11.2 | `sha256:c764f17ed94b725599043f0548ece6297f1fe4409e6dd1133b1d2fb1f8d2b599` | `docker buildx imagetools inspect` |
| OpenClaw personal image | 2026.11.2 + Hindsight 1.2.0 | `sha256:b88dd76140907b1cf32f8675b8fd4b2321806a1066bd3cc1e6689bfaf90c5717` | GHCR main build `42845211135`, linux/amd64 manifest |
| Hindsight OpenClaw plugin | 1.2.0 | npm integrity `sha512-5UCvNOU12K3aKHwYaSrCFaeXGrfpuw6ZQ67+OJqV9WUgDx1X9Xp/S9rlNVzPKYf2y5S0n7tl02e3gQfb6bQntw==` | committed `images/openclaw-personal/package-lock.json` |
| Hindsight chart | 1.2.1 | `sha256:4781a117dcafa4e776218a5988f8047a30379d2e195130cf44cc2055dc028258` | `helm pull oci://ghcr.io/vectorize-io/charts/hindsight --version 1.2.1` |
| Hindsight API image index | 1.2.1 | `sha256:662109ece429871a81e036427fb93fbb09ba9dc4b01d320d356f114c0e1aedd8` | `docker buildx imagetools inspect` |
| LibreChat chart | 3.0.0 | `sha256:5d50ecaf2685295fb5d28da016a964b03610e7897d6e366c0b573086fb23775a` | `helm pull oci://ghcr.io/librechat-ai/librechat-chart/librechat --version 3.0.0` |
| LibreChat image | v0.8.8 | `sha256:1e3bd3ac2cdbbcd64bdc4ef04c850d6fef5392d1fcb22cea46c5dcba17da7b95` | `docker buildx imagetools inspect` |
| CNPG PostgreSQL image | 17.7-standard-trixie | `sha256:44c64899a6fb61c01b56a91322cb9cfdc955aa5fd1c8f34ff3a0a9f51664a202` | `docker buildx imagetools inspect` |

The LibreChat chart currently has no digest value in its upstream image
values, so its chart and image digests are recorded here while the Helm
release remains tag-based. The direct OpenClaw and CNPG images are pinned to
the verified amd64 manifests in Git.

## Provisioning before activation

1. Verify all **OCI image and Helm chart digests**, architectures, upstream helm
   templates, CRDs and exact `just check` results. Tags are immutable *names*
   here, not digest-verified supply-chain proofs. Ensure Argo can fetch OCI charts.
2. Create fresh Doppler keys (names in each ExternalSecret). Never reuse Factory
   credentials. Verify ESO Ready; no raw secrets in code or logs.
3. CNPG `hindsight-db`: validate vector extension on the selected standard
   image, app credential compatibility, PostgreSQL password field used by the
   Helm chart, and backup bucket. Take a backup and execute an **isolated restore**
   BEFORE storing non-reconstructible personal memories.
4. Hindsight: check dedicated memory bank for one owner; MCP/API has **no
   trusted multi-user boundary by default**. Do not expose admin MCP nor grant
   all-bank permissions to LibreChat. Test rate limits, reflect cost, retention,
   duplicates and destructive delete behavior.
5. OpenClaw: test gateway 2026.11.2 config against exact schema, `/readyz` and
   `/healthz` JSON, agentgateway bearer audience/model, DNS/Cilium labels,
   read-only filesystem/UID 1000 and PVC permissions. ConfigMap copied on every
   restart to ensure GitOps authority; workspace survives. No HTTPRoute or
   elevated tools; do not restore an old operator, kubectl credentials or
   Docker socket.
6. The pinned and audited OpenClaw image is now built by kube-ops #1169 from
   the qualified 2026.11.2 base and the exact
   `@vectorize-io/hindsight-openclaw@1.2.0` lockfile. Wire only the dedicated
   `openclaw-personal` bank and approved endpoint; test recalled memory,
   corrections, secrets redaction and plugin fallback before declaring USER.
   The pilot tool policy explicitly allows only `read` plus the three
   Hindsight memory tools (`hindsight_retain`, `hindsight_recall` and
   `hindsight_reflect`); terminal, browser, code execution and elevated tools
   remain disabled.
7. LibreChat: validate Helm 3.0.0 render, MongoDB auth and PVC policy, backup and
   restore, then configure Authentik OIDC with user-specific MFA/callback and
   permissioned MCP. Current chart is **fail-closed** with all login methods off.
   Meilisearch/RAG, public routes and background agents are out of scope.
8. Run 2-user A/B deny tests before any family expansion. Existing
   `hermes-personal` tenant isolation contracts provide reference scenarios.
9. Once each component is ready, prefer **independent Argo Applications**
   with explicit PR admission. Do not blindly import this entire root with
   Argo automated prune. Check AppProject sourceRepos for OCI chart repos and
   the policy for Applications from a managed Application before activation.

## Hindsight-only activation delta

The Hindsight activation PR admits only the Hindsight subtree through the active
AI root. It adds a Hindsight-only AppProject, a dedicated Agentgateway API key,
an internal ClusterIP API, CNPG pgvector initialization, a one-shot initial
Barman backup plus the weekly schedule, and a Cilium FQDN allowlist limited to
`fsn1.your-objectstorage.com:443`. The official Hindsight API image is built
with the default local embedding and reranker models; activation sets
`BAAI/bge-small-en-v1.5`, `HF_HUB_OFFLINE=true` and
`TRANSFORMERS_OFFLINE=true`, and disables the model-cache PVC so a hidden empty
PVC cannot trigger an unreviewed Hugging Face download.

## Historical staging evidence — superseded

The admission correction in kube-ops #1154 was merged as
`b8801f3c487e05e9dcdc87f84d83c5368c882399`. At observation time, `root` was
Argo `Synced/Healthy`, `apps-ai` was `Synced/Degraded`, and
`personal-hindsight` was `Synced/Progressing`; Argo accepted the Namespace,
AppProject, child Application, CNPG, ObjectStore, Backup, ScheduledBackup,
ExternalSecrets and Cilium policy.

The CNPG data and WAL PVCs were both Longhorn `Bound` (`10Gi` and `5Gi`). The
Hindsight API Service was private ClusterIP `hindsight-api:8888`. The S3
ExternalSecret was `SecretSynced=True`, but the database bootstrap and runtime
ExternalSecrets were not Ready. The exact ESO event observed at
`2026-11-10T13:43:59Z` was that Doppler could not find
`APP_HINDSIGHT_DB_PASSWORD`; CNPG consequently reported
`secret "hindsight-db-bootstrap" not found`.

This is a delivery blocker, not a Hindsight application success: the
Terraform declaration was merged in homelab-infra #294, but Atlantis denied
its pre-workflow admission because
`terraform/doppler/generated-app-secrets.tf` is outside the server allowlist.
No secret value was read or injected manually. The owner-controlled Atlantis
allowlist/procedure must be repaired before the CNPG, API, backup, restore and
user checks can run.

The Hindsight child Application uses automated self-heal with pruning disabled.
The delivery blocker above was cleared by the controlled local Doppler apply
recorded below; this section remains only to preserve the earlier timestamped
staging observation.

## Hindsight runtime evidence — 2026-11-10

### Credential delivery and state continuity

On homelab-infra `main` at `d6780b37698fc46dba828d18ce9d360eac9816e0`, the
existing `scripts/live-tofu.sh` wrapper was used under the authenticated
Doppler session with the existing OCI credentials. The saved plan SHA-256 was
`679f1e71b76061f7af8a24d80d07a7d6e9cf865336f7a089ac111b759c72922f` and its
sanitized `tofu show -json` action set was exactly four creates:

- `random_password.v1_generated_app_secret["APP_HINDSIGHT_DB_PASSWORD"]`
- `random_password.v1_generated_app_secret["APP_HINDSIGHT_AGENTGATEWAY_KEY"]`
- `doppler_secret.cluster_v1_generated_app_secret["APP_HINDSIGHT_DB_PASSWORD"]`
- `doppler_secret.cluster_v1_generated_app_secret["APP_HINDSIGHT_AGENTGATEWAY_KEY"]`

There were no deletes, changes, replacements or rotations. The exact saved
plan was applied without recalculation. State lineage remained
`b6e9eeb7-0d29-6be9-6eee-3f204556ad95`, serial advanced from `58` to `59`, and
the post-apply plan SHA-256 was
`5c3d78be7796de847b4b9c7e0dfb2cf3a7680a927b23c7f6251caaf0a8474620` with no
actions. Doppler presence was verified for both names above without reading
their values. Plans and temporary files were removed.

### Reconciled and runtime proof

At `2026-11-10T15:11:32Z`, `personal-hindsight` was Argo `Synced/Healthy`,
reconciled at `1.2.1`, with operation `Succeeded`. The source API pod was
`1/1 Running` on `ghcr.io/vectorize-io/hindsight-api:1.2.1`; its migrations
completed and it reported the pgvector extension. The three ExternalSecrets
(`hindsight-cnpg-s3`, `hindsight-db-bootstrap`, `hindsight-runtime`) were
`SecretSynced=True`/Ready. The source data and WAL PVCs were Longhorn
`Bound` at `10Gi` and `5Gi`; the initial CNPG backup
`hindsight-db-initial-20261110` was `completed`, backup ID `20261110T142602`,
from `2026-11-10T14:26:02Z` to `2026-11-10T14:26:08Z`.

The synthetic bank `plt165-synthetic-20261110` proved retain `200`, recall
`200` with two results, correction through the same document ID with
`update_mode=replace`, and reflect `200` after the 1.2.1 upgrade. Recall still
returned two results after an API rollout restart. The first reflect failure
on 1.2.0 was the upstream MiniMax nullable-schema defect; 1.2.1 contains the
official fix. No personal data was used.

### Isolated restore proof

PRs #1165, #1166 and #1167 admitted a private
`hindsight-restore-20261110` drill. Argo created no HTTPRoute and no
application writer; only CNPG internal ClusterIP services exist. The recovery
job `hindsight-db-restore-1-full-recovery` succeeded at
`2026-11-10T15:09:22Z` from backup ID `20261110T142602`. The restored pod was
`1/1 Running`, both fresh Longhorn PVCs were `Bound` (`10Gi` and `5Gi`), SQL
returned database `hindsight`, extension `vector`, `25` public tables and `2`
synthetic memory rows. The source cluster remained running and untouched.

CNPG's controller still reports the pre-existing `Instance Status Extraction
Error: HTTP communication issue` condition on both source and restore
clusters even while the pods and SQL are usable; this is recorded, not
masked. It prevents claiming a clean CNPG `Ready=True` condition until the
underlying controller condition is separately repaired.

## Static tests / evidence

- Protected tests/workflow edits need a separate exact-base owner admission PR.
- `kustomize build k8s/optional/personal-ai-2026`
- `just check` (when the repository's toolchain and secrets are available)
- The one-time Doppler apply was performed only through the homelab-infra
  wrapper and is documented above; no Kubernetes `apply`, Helm install, manual
  Argo sync, secret-value read, prune or delete was used for activation.
- Post-merge levels remain separate: STATIC → RECONCILED → RUNTIME → USER.

## LibreChat preparation evidence — 2026-11-10

LibreChat remains `STATIC` preparation only. Its optional subtree is not
imported by an active Argo root, and the candidate HTTPRoute is deliberately
not in the subtree kustomization. The existing `chat.smadja.dev` hostname is
owned by Matrix, so the candidate private hostname is
`librechat.smadja.dev`; no public Gateway parent is declared.

The official chart 3.0.0 rendered 14 resources with bundled authenticated
MongoDB, Longhorn persistence, no Ingress, and the OIDC environment contract.
The LibreChat subtree rendered 4 resources. `kubeconform -strict` reported 15
valid objects and 3 external CRD schemas skipped across those renders. The
chart Service name was verified as `librechat-librechat`; the dormant route
targets that Service on port 3080.

The candidate ExternalSecret declares the six existing application keys plus
`APP_LIBRECHAT_OIDC_CLIENT_SECRET` and
`APP_LIBRECHAT_OPENID_SESSION_SECRET`, without values. A dormant Authentik
blueprint uses one strict callback, `sub_mode: user_email`, and only the
`LibreChat Users` group. The Authentik Secret contract is optional and wired
to `envFrom`, while the provider blueprint is not in the active ConfigMap.
No Authentik provider, route or LibreChat workload is admitted by this
preparation change. Hindsight egress is absent
because the current Hindsight API has no trusted per-user bank boundary; a
dedicated non-admin Agentgateway key/policy remains a separate admission gate.

The active Velero schedules now include a daily `librechat` namespace schedule
at `05:50 UTC`, with filesystem volume backup enabled and a 14-day retention.
The required MongoDB isolated-restore and two-identity deny journeys remain
unexecuted until credentials and the application are admitted. See
`docs/operations/librechat-activation-2026.md` for the exact activation order.

## Rollback and storage

As the root is not imported, closing/removing it is zero runtime delta.
If later deployed, never remove a PVC/CNPG database or S3 backups as collateral
of a config rollback. Preserve the original ChatGPT archive outside Hindsight.
Measure Longhorn daily writes before and after enabling the pilot.
