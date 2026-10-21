# Atlantis pilot: declared versus runtime

**Evidence date:** 2026-10-21
**Source revision:** `kube-ops` base `b578b6e81c0e0100e1e1669f32f3be276363b9a8`, qualification PR `bb64e8be077af242b26ad87ccda51e42e6073e0f`
**Related merged change:** #506 `b678a78e21007564978ed4cceca6bb1955c22209`
**Status:** plan-only pilot declared in Git; runtime qualification pending

## Runtime observation — 2026-10-16

The canonical operator access harness passed against Kubernetes `v1.36.3`.
The observation was metadata-only and did not read Secret data. The cluster
reported 22 Argo Applications, all `Synced`; `infra-controllers` was
`Healthy` at reconciled revision
`af405362217e2cb75b15cc599306aedc8268c6dc`. This is platform evidence only,
not Atlantis evidence.

Atlantis-specific runtime discovery returned:

- namespace `atlantis-system`: **not found**;
- Argo Application/ApplicationSet matching Atlantis: **none**;
- Atlantis ExternalSecret, HTTPRoute, pod, Service and PVC: **none**.

Therefore `RECONCILED=NO` and `RUNTIME=NO` for Atlantis. The absence is a
positive safety result: no GitHub App credential, backend identity, provider
egress or Atlantis API endpoint is currently active. No plan, lock, provider
call or apply can be qualified until the declared pilot is reconciled and
qualified.

The Git declaration is wired into the infrastructure ApplicationSet and
infrastructure AppProject. PR #632 supplies the GitHub App identity while
preserving plan-only controls. Its merge is therefore an intentional request
for Argo reconciliation of the pilot, not an accidental activation. The
post-merge state must still be classified separately as `RECONCILED` and
`RUNTIME`; no such evidence is claimed by this document.

## Exact difference

| Surface | Declared in Git | Runtime conclusion |
| --- | --- | --- |
| Namespace and StatefulSet | `k8s/poc/atlantis-plan-only` renders a pinned Atlantis fixture and is declared by the infrastructure ApplicationSet | Runtime reconciliation and workload readiness still require post-merge observation |
| Image/chart | Atlantis `v0.48.1` with digest and chart `6.16.1` | Static pin only; no pod/image pull evidence |
| GitHub identity | ExternalSecret references `atlantis-github-app`; PR #632 binds the App ID, installation ID and slug | Secret synchronization and runtime authentication still require post-merge observation; values remain outside Git |
| Webhook | private route declarations for `/events` and UI | No DNS, Gateway, TLS, signature or delivery evidence |
| Repository policy | server-side exact allowlist, deny catch-all, plan-only workflow | Not loaded by an Atlantis process |
| Root selection | only `terraform/atlantis-pilot` is allowed | No privileged root is admitted; the 12 existing roots remain outside the pilot |
| Backend/provider | placeholder pilot backend; no OCI/provider egress | No pilot state, identity or provider access provisioned; existing OCI states untouched |
| Apply | `disableApply: true`, `disableApplyAll: true`, workflow apply fails | No apply capability is reconciled or exercised |
| Mastra dispatch | offline admission contract only | No dispatcher workload, token, receipt database, replay guard or audit sink exists |
| Evidence | static checks and contracts | No RECONCILED or RUNTIME evidence; `PLAN_SHA` is unset and no privileged plan ran |

The distinction is intentional. A checked-in manifest is not a deployed
Atlantis server, and a server that receives a webhook would not by itself
prove provider, state, lock, identity or post-apply safety.

## Activation delta, pilot only

An operator-authorized activation must be a separate PR and must include all
of the following before any privileged plan:

1. Reconcile the already-declared path through the infrastructure
   ApplicationSet and namespace entry in the infrastructure AppProject, with
   the exact post-merge revision recorded.
2. Replace only the GitHub App placeholders through the approved secret
   delivery path; verify repository installation, webhook signature and private
   route without exposing values.
3. Provision a dedicated pilot provider/backend identity and prove its policy
   cannot read any of the twelve existing state keys. The pilot state key and
   lock must be recorded without reading or publishing state contents.
4. Deploy the separately reviewed Mastra dispatcher with a dedicated identity,
   durable receipt/replay/audit store and no OpenTofu credentials. Prove exact
   plan artifact digest support; otherwise retain apply disabled.
5. Qualify Argo reconciliation, webhook authenticity, GitHub admission,
   provider/registry egress, backend lock contention, budget/change policy and
   independent post-apply evidence using the negative scenarios in the
   dispatch contract.
6. Only then enable pilot plan. A real plan needs a separate operator
   confirmation of the admitted code SHA, pilot root, identity and backend.
   Apply remains a later explicit gate under PLT-91 and is not authorized by
   this document.

The 12 existing roots cannot be activated as a side effect of this pilot PR.
Each requires its own toolchain, identity, backend, budget, recovery and
post-apply qualification.

## Evidence classification

- **STATIC:** `npm run check` passes, including the declared plan-only pilot and
  dispatcher negative tests.
- **RECONCILED:** not established; no Argo sync evidence was collected.
- **RUNTIME:** not established; no Atlantis pod, webhook, provider, state or
  lock operation was performed.
- **USER/apply:** not applicable; no apply was attempted.

No state, secret value, cloud resource or privileged plan was accessed while
producing this evidence.
