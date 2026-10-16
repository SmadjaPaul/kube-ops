# Mastra → Atlantis dispatch contract v1

**Status:** implemented as an offline admission contract; not deployed and not
an activation approval (2026-10-16).

## Purpose and boundary

Mastra must not receive an Atlantis API token and must not execute Terraform or
OpenTofu. It may submit a request to a separately operated dispatcher. The
dispatcher is a thin authorization and audit boundary around the documented
Atlantis API; it does not replace Atlantis, OpenTofu, a provider, or the
backend lock.

The only target in this qualification contract is the disposable pilot:

| Field | Required value |
| --- | --- |
| repository | `SmadjaPaul/homelab-infra` |
| directory | `terraform/atlantis-pilot` |
| project | `atlantis-pilot` |
| workspace | `default` |
| backend state key | `atlantis-pilot/terraform.tfstate` |
| base branch | `main` |
| caller identity | `mastra-atlantis-dispatcher` |

The twelve existing roots remain outside this contract and cannot be selected
by a caller. Their states are not read, copied, migrated, or provisioned.

## Request flow

1. Mastra submits a signed/authenticated request to a future internal
   dispatcher using its dedicated workload identity. The request contains a
   repository, PR, immutable head SHA, exact root/workspace/project, backend
   state key, state lineage, policy revision, request ID, action and a
   server-obtained `admissionId`. The dispatcher requires code admission to be
   approved, mergeable and undiverged before it can request a plan.
2. The dispatcher performs the static target checks in
   `scripts/atlantis-dispatch.mjs`, records an audit event, and sends only the
   documented Atlantis request body to `/api/plan`.
3. A server-side plan receipt is created only after Atlantis reports success.
   It includes the exact PR/head SHA, root, workspace, backend state key and
   lineage, admission ID, policy revision, plan digest, creation time and
   expiry, plus passing change-policy and budget verdicts. It contains no state
   contents or secret values.
4. An apply request must reference that receipt. The dispatcher compares every
   binding and rejects stale SHA, root, workspace, backend lineage, policy
   revision, plan digest, expired receipt, unknown caller and duplicate request
   ID. A durable replay guard must claim the request before transport.
5. Only after those checks does the dispatcher send the Atlantis `/api/apply`
   request. The caller never chooses an arbitrary Atlantis project or path.

The implementation intentionally has no HTTP client, token, secret, storage
backend or Kubernetes workload. `authorizeApply` requires a server-owned
receipt store and replay guard, so an incomplete deployment fails closed. A
production implementation must use durable storage with atomic single-use
claims and append-only audit delivery; the in-memory fakes in the tests are
qualification fixtures only.

## Atlantis limitation and exact-plan requirement

Atlantis OSS v0.48.1 documents `/api/plan` and `/api/apply` as alpha APIs. The
API apply endpoint runs a plan phase before apply and accepts only repository,
ref, VCS type, project/path and PR selectors. It has no plan digest or backend
lineage parameter. Therefore this contract does **not** claim that Atlantis
itself automatically chains a plan into an exact-plan apply.

The receipt store and server-side policy are mandatory. Before activation, the
operator must prove how the digest is produced and checked against the plan
artifact retained by the Atlantis server for the same PR/lock. If the selected
Atlantis release cannot expose that artifact digest to the dispatcher, the
automatic apply path remains disabled; a receipt over plan text or a repeated
API plan is not equivalent evidence.

The native Atlantis approval requirements are not used as the final
authorization model. Code admission is a prerequisite for planning and is not
an apply approval. Technical change-policy and budget verdicts must both be
`pass` in the server-created receipt; the receipt/replay gate is a separate
control. The current fixture remains
`disableApply: true` until these controls and dedicated identities are
qualified.

## Identity, network and audit gates

- Mastra has no Atlantis credential, OCI credential, provider credential or
  state access.
- The dispatcher has a dedicated identity and a narrowly scoped Atlantis API
  credential delivered out of band; no credential is committed here.
- Atlantis has a separate pilot provider/backend identity and backend key; it
  has no access to the twelve existing state keys.
- Network policy allows only the explicitly reviewed dispatcher → Atlantis
  path and Atlantis → GitHub/provider endpoints needed by the pilot. It does
  not imply isolation between processes sharing a credential.
- Audit records contain request ID, actor identity, target tuple, head SHA,
  receipt ID/digest, policy revision, result and timestamps, never secrets,
  plan output containing sensitive values, or raw state.
- Post-apply verification and off-cluster recovery evidence are separate from
  the Atlantis response.

## Offline evidence

`tests/harness/atlantis-dispatch.test.mjs` proves positive plan/apply request
construction and rejects stale SHA, forbidden root, changed plan digest,
changed backend lineage, duplicate dispatch and missing server guards.
`scripts/check-atlantis-dispatch-contract.sh` also proves that the fixture is
still dormant, pinned and plan-only, and that this module contains no API
credential or execution client.

## Activation checklist

Activation is a separate operator-authorized change and must not be inferred
from this contract:

- approve PLT-89/90 security and architecture gates;
- provision and record the dedicated pilot GitHub App installation and signed
  webhook without committing values;
- reconcile the dormant namespace only through an explicit Argo PR;
- provision the dedicated pilot backend/provider identity and prove no existing
  root state is reachable;
- deploy the durable receipt/replay/audit service with its own identity;
- prove plan artifact digest support and exact-plan binding;
- enable only pilot apply after the operator approves the activation evidence;
- qualify webhook authenticity, stale SHA, forbidden-root, plan-change,
  duplicate-dispatch, lock contention and post-apply evidence;
- keep the twelve roots inactive until separately qualified.
