# Personal AI pilot — OpenClaw, Hindsight, LibreChat (10 November 2026)

Status: **STATIC STAGING ONLY / NO LIVE DEPLOYMENT**. The Kustomization under
`k8s/optional/personal-ai-2026` is **not** imported into the active platform or AI roots. Do not claim
Argo Synced, Secret Ready, a running gateway or a usable user-facing service.

## Scope and provenance

Rebuild the *personal assistant* role only. Never resurrect OpenClaw Talos Ops,
Open WebUI, Qdrant, LiteLLM, Paperclip or the old OpenClaw operator without a
separate architectural review. Mastra Factory remains the engineering orchestrator.
Past references: kube-ops PR #295 (isolated cells), #401 (suspended test),
#407 (delegation unproven), #459 (retirement). Existing optional
`hermes-personal` foundation is unchanged.

Pinned first-pilot components:
- OpenClaw **2026.11.2** official GHCR image, direct upstream-style K8s Deployment,
  no Operator/Enterprise, single writer and port-forward only.
- Hindsight **1.2.0** official OCI Helm chart + dedicated CNPG 17.7 standard
  (pgvector) with Barman/Hetzner and no HTTPRoute. Chart's control plane disabled.
- LibreChat **0.8.8**, official chart **3.0.0**, bundled authenticated MongoDB,
  no Meilisearch/RAG at first, and intentionally **no login method** until an
  Authentik per-user OIDC review. Never expose this state to the family.
- Hermes tenant ApplicationSet stays empty and is not migrated by this change.

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
6. Build a *pinned and audited* OpenClaw image with
   `@vectorize-io/hindsight-openclaw` plugin at a version proven compatible
   with 2026.11.2. Wire only a dedicated bank and approved endpoint;
   test recalled memory, corrections, secrets redaction and plugin fallback.
   The plugin is **NOT** enabled in this staging branch.
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

## Static tests / evidence

- `python3 -m unittest tests/harness/test_personal_ai_staging.py`
- `kustomize build k8s/optional/personal-ai-2026`
- `just check` (when the repository's toolchain and secrets are available)
- No live `kubectl apply`, Helm install, Argo sync, secrets read, prune or delete
  was performed by this preparation.
- Post-merge levels remain separate: STATIC → RECONCILED → RUNTIME → USER.

## Rollback and storage

As the root is not imported, closing/removing it is zero runtime delta.
If later deployed, never remove a PVC/CNPG database or S3 backups as collateral
of a config rollback. Preserve the original ChatGPT archive outside Hindsight.
Measure Longhorn daily writes before and after enabling the pilot.
