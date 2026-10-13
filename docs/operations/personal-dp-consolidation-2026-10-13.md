# Personal DP consolidation — coordinated cutover (2026-10-13)

**Status: DIRECT CUTOVER AUTHORIZED, CANDIDATES INACTIVE.** The operator explicitly authorized retiring legacy AI services and their data before replacement E2Es. This is a desired-state cutover only: Agentgateway, Cube and Mastra currently have `replicas: 0`. Their availability must not be claimed.

## Repositories

- kube-ops: this coordinated GitOps change.
- factory-platform: [PR #33](https://github.com/SmadjaPaul/factory-platform/pull/33) makes personal Mastra LLM transport provider neutral and documents the sandbox decision. Merge that source change and publish verified images before activating Mastra.

## Decision map

- **Keep:** Argo CD, Cilium Gateway, Authentik, CNPG, ESO, Doppler, Longhorn, Velero, Prometheus, Grafana, Loki, Alloy, Tempo and Hubble. The gateway for LLM/MCP is distinct from Kubernetes HTTPRoute ingress.
- **Candidate replacement:** agentgateway OSS standalone for LiteLLM and dedicated MCP proxy. Migrate virtual-key lifecycle, model aliases, budgets, OpenAI-compatible embeddings and per-run key revocation. Use the upstream `agentgateway import --from litellm --file ...` tool and inspect all `manual` / `unsupported` findings before cutover. This tool does NOT import LiteLLM's DB-managed keys, users, spend records or budgets.
- **Candidate semantic serving:** Cube Core + CubeStore from an existing Factory dbt mart using a read-only PostgreSQL role. No household data or multi-user access until authenticated row-level policies are tested. Cube's official hosted MCP agent is *not* assumed to be Cube Core OSS.
- **Agent runtime:** Mastra with upstream Kubernetes SIG Apps Agent Sandbox, not an additional kagent 1.x installation. The Talos gVisor runtime extension remains unverified; RuntimeClass alone is not evidence.
- **Connection plane:** retain OpenConnector, initially with only read-scoped Paperless actions. It cannot yet be mounted as a household-wide MCP tool using one operator token. Need Authentik principal grants and upstream token propagation.
- **Document search:** Paperless native API first; PostgreSQL FTS + pgvector if cross-source indexing is required. No automatic direct Qdrant deletion before inventory.
- **UI:** CopilotKit / AG-UI desired, *not implemented in this PR*. Retiring Open WebUI removes the current production chat surface, so deployment without an authenticated replacement is not acceptable.
- **Research, code execution, security:** Mastra's personal agent is developer-only. The main Factory is gated behind Authentik/BetterAuth integration, real isolated sandbox E2E and a scoped GitHub App. No synthetic success claim.

## Blockers (all must pass before draft becomes ready)

1. Provision `APP_AGENTGATEWAY_CLIENT_KEY`, `MINIMAX_API_KEY` and `APP_FACTORY_CUBE_API_SECRET` in Doppler; validate ExternalSecrets Ready and model provider requests.
2. Verify agentgateway v1.6.0 schema with `agentgateway -f /config/config.yaml --validate-only`; check the OTLP target, Minimax chat + streaming + embeddings + precise cost, model discovery, budget and denied key tests. The current gateway Cilium egress is deliberately restrictive: allow the exact provider FQDN only after verification. Pin images to immutable digests.
3. Authorize each MCP target with Authentik-verified user/delegated service principal and enforce document, query and tool ACLs *in the backend* too. Test cross-user denials, revoked credentials and cache isolation. Do not use a shared OpenConnector admin token.
4. Enable CubeStore and Cube only after schema and read-only database credential tests. Verify the Factory mart, API JWT/row policy, the effect of a malicious SQL query, and memory footprint. Pin image digests.
5. Merge verified factory-platform source, enable the Mastra production identity grants, prove Talos gVisor on a disposable VM, and run sandbox lifecycle + GitHub issue-to-PR E2E before increasing `mastra-factory` replicas above zero.
6. Build/test/deploy an Authentik-protected CopilotKit / AG-UI chat surface as the final chat UI. Open WebUI is removed immediately by explicit operator decision; no old chat history or collection export is required. The chat endpoint will remain unavailable until then.
7. Replicate LiteLLM model aliases for every consumer (Paperclip, OpenClaw migration, Web UI, factory tools, embeddings) and test cost and credentials. Model aliases presently staged are only `factory/fast` and `factory/code`.
8. Qualify single-node memory, disk pressure, CPU requests, backups and refresh/worker costs against the actual node headroom.
9. Validate `kustomize build`, server-side dry run, secret schema, network policies, image digests, deny E2E and OTel traces end-to-end. No live cluster proof is claimed.
10. After Argo reconciliation, run `scripts/ops/audit-retired-ai-resources.sh`, classify and manually remove old PVC/PV, CNPG clusters, app secrets, stale jobs, backup schedules, HTTPRoutes and orphaned Argo Apps. A Git revert does **not** recreate deleted data-bearing resources.

## OpenTelemetry

Reuse the current Alloy OTLP/HTTP receiver port 4318 -> Tempo; Loki receives Kubernetes logs, Prometheus scrapes metrics and Grafana queries all three. Reuse existing exporter paths. Do not create a second OTLP Collector, Jaeger, Langfuse or LangSmith automatically. Avoid recording prompts, documents, key material or raw tool arguments. Long-lived cost/materialization statistics belong in redacted structured marts, not Tempo's ephemeral seven-day volume.

## Exact rollback / cleanup contract

As a bundle the Git revert restores the desired *resource declarations* after Argo reconciliation. It does not revert IAM/auth changes, OAuth callbacks, rotated keys, removed Longhorn volumes, deleted CNPG state or external integrations. No backup/export of the retired application's data is required by the operator; verify ownership and restore targets rather than assuming that all volumes belong to the retired service. Legacy service data retention is not required: delete residual PVC/PV, CNPG, Secret and backup objects **after** confirming ownership and dependent controllers/finalizers; do not delete unrelated workloads or restore-drill resources. `StatefulSet.volumeClaimTemplates` may leave PVCs behind despite prune.

## Do not confuse staged with implemented

OpenConnector is already in the platform parent. This PR does not add a new generic OAuth provider, a deployed MCP security bridge, a CopilotKit app, document indexing or a complete personal-data ontology. Those need real code, user-scoped auth and tests. This document keeps the missing work visible instead of representing a partial migration as a complete working DP.
