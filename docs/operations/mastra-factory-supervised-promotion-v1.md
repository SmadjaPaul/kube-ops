# Factory V1 — supervised digest promotion (PLT-74 / PLT-19)

**Decision:** For a routine application-only Factory release, do not require
a second fully functioning Factory/Better Auth/PostgreSQL stack just to
promote an already built and supply-chain-qualified OCI image. Qualify the
real deployment **after** a controlled GitOps promotion and retain a proven
rollback path. This is **not** an unattended auto-rollback or a canary.

## Scope and non-negotiable gates

This policy applies only to changes that preserve all of:

- A **single** dispatcher (`replicas: 1`, `Recreate`), the existing
  ServiceAccount, NetworkPolicies and production database; no dual-active
  candidate or traffic-split canary.
- No destructive DB migration or schema incompatible with the previous
  digest; no auth/credential model or privilege changes.
- No change to sandbox claim ownership, leases, checkpoint persistence,
  irreversible side effects or destructive GC.
- Image provenance bound to an exact 40-hex source SHA, an immutable
  `ghcr.io/smadjapaul/mastra-factory@sha256:<64-hex>` ref, SBOM, scan
  result and explicit vulnerability disposition. A WARN is not an
  implicit PASS; the versioned advisory policy must permit it.
- Existing rollback image and GitOps revision known and pullable.

**Deep isolated E2E is still required** before a change touching
authentication, schema/migrations, sandbox lifecycle, recovery or
irreversible behavior. Fail closed on uncertainty about scope. Readiness,
HTTP 401, or a successful image pull alone do not prove functionality.

## Promotion procedure (supervised, no paid rebuild)

1. Capture the current `main` GitOps SHA, live image digest and rollout
   state, the previous valid image/rollback commit, the candidate source
   SHA, digest, SBOM, provenance and Trivy report. Verify CNPG health and
   current incident status. Confirm no other rollout or dispatcher work
   is already underway.
2. Confirm the application's image artifact exists, its source SHA and
   candidate/release digest match, and required gates are satisfied.
   If an isolated smoke exists and passes, keep its evidence; if not,
   record `PREDEPLOY_ISOLATED_SMOKE=NOT_EXECUTED` rather than fabricating
   a PASS. Do not spin up a production-secret-bearing parallel Factory.
3. Generate a **PR** against kube-ops with
   `scripts/promote-mastra-factory-digest.sh <source-sha> <digest>`.
   Only the deployment image digest and source-SHA annotation may change.
   Require the actual GitHub checks and an independent review, and
   inspect the final HEAD. No direct `kubectl set image`.
4. For the first use of this policy, have an operator supervising the
   rollout and ready to revert the **GitOps commit**. After merge,
   require Argo `Synced/Healthy`, rollout success, the **live** imageID
   corresponding to the expected digest, and successful `/health`.
   Check that only one dispatcher pod is active throughout transition.
5. Run bounded, read-only application checks: protected endpoint
   rejects anonymous request, configured Better Auth/session flow is
   operable with a **dedicated permitted test identity**, database
   connectivity and lease/dispatcher diagnostics are healthy, and
   no new recurring 5xx or crash loops. Distinguish authentication
   negative-only checks from a positive authorized session test.
   No real task dispatch, migration, or destructive claim operation.
6. Watch the candidate for an operator-selected, bounded observation
   window long enough for its readiness and liveness probes to cycle
   and for meaningful requests to arrive. Record the duration and
   sampled metrics. A lack of traffic is **not** proof of functionality.
7. **On critical regression:** stop or inhibit further dispatch by
   existing approved controls where possible, revert the GitOps
   promotion commit through a reviewed revert PR, then verify Argo
   reconciles the previous digest and health recovers. Do not invoke
   `argocd app rollback` as a substitute while auto-sync is enabled.
   If a migration has broken backward compatibility, stop: image
   rollback alone cannot revert database state.

## Rollback decisions

**Rollback trigger**: rollout fails or exceeds its approved deadline,
process crashes, persistent health failure, inability to authenticate,
database errors introduced by the new digest, wrong live digest or
new sustained critical 5xx. Use thresholds grounded in existing metrics;
do not invent numerical SLOs or a timer in this V1 runbook.

**Observe rather than rollback**: isolated transient errors without
confirmed regression or a versioned, accepted Trivy advisory finding.

**No-go before deployment**: suspected incompatible state change,
missing rollback reference, compromised credentials, unauthorized
permissions, unknown image provenance, already active concurrent
dispatcher, or missing required review/CI.

## Why not blue/green yet?

With one dispatcher using shared leases, Kubernetes blue/green or a
classic 10/90 canary could run two controllers on the same database and
sandbox claims. Do not deploy parallel active Factory replicas just
for health checks. A future standby candidate requires an explicit
**non-dispatching** mode, verified lease exclusion and an external
controller (e.g. Argo Rollouts); do not make the old Factory its own
rollback authority.

## Recording and closure

Report separately:
`CI`, `SOURCE_SHA`, `IMAGE_DIGEST`, `PROVENANCE`, `SBOM`,
`TRIVY_DISPOSITION`, `PREDEPLOY_ISOLATED_SMOKE`,
`DEPLOYMENT_GATE`, `ARGO_REVISION`, `LIVE_DIGEST`,
`HEALTH`, `AUTH_NEGATIVE`, `AUTH_POSITIVE`,
`DB_CONNECTIVITY`, `DISPATCHER_UNIQUENESS`,
`OBSERVATION_WINDOW`, `ROLLBACK_REFERENCE`,
`ROLLBACK_TEST`, `PLT_74`, `PLT_19`.

**Initial change is docs/tests only**: it neither promotes an image nor
provisions any runtime component. Qualify a supervised, one-off promotion
before allowing unattended releases or claiming automatic rollback.
