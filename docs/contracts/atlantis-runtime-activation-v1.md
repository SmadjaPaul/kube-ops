# Atlantis pilot: declared versus runtime

**Evidence date:** 2026-10-16
**Source revision:** `kube-ops` `2acb4752ac6f173be387a254dd422affd49a4e95`
**Related merged change:** #506 `b678a78e21007564978ed4cceca6bb1955c22209`
**Status:** prepared, not activated

## Exact difference

| Surface | Declared in Git | Runtime conclusion |
| --- | --- | --- |
| Namespace and StatefulSet | `k8s/poc/atlantis-plan-only` renders a pinned Atlantis fixture | Not reconciled: the directory is not referenced by an Argo ApplicationSet/Application |
| Image/chart | Atlantis `v0.48.1` with digest and chart `6.16.1` | Static pin only; no pod/image pull evidence |
| GitHub identity | ExternalSecret references `atlantis-github-app` keys | Placeholder App ID/installation ID and secret values absent; no installed identity proven |
| Webhook | private route declarations for `/events` and UI | No DNS, Gateway, TLS, signature or delivery evidence |
| Repository policy | server-side exact allowlist, deny catch-all, plan-only workflow | Not loaded by an Atlantis process |
| Root selection | only `terraform/atlantis-pilot` is allowed | No active root; the 12 existing roots remain inactive and untested by Atlantis |
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

1. Add the dormant path to the intended Argo ApplicationSet and namespace to
   the infrastructure AppProject, with the ADR and exact revision recorded.
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

- **STATIC:** `npm run check` passes, including the dormant fixture and
  dispatcher negative tests.
- **RECONCILED:** not established; no Argo sync evidence was collected.
- **RUNTIME:** not established; no Atlantis pod, webhook, provider, state or
  lock operation was performed.
- **USER/apply:** not applicable; no apply was attempted.

No state, secret value, cloud resource or privileged plan was accessed while
producing this evidence.
