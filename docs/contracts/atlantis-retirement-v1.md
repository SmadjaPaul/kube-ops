# Atlantis retirement contract v1

**Status:** retired from the active Kubernetes desired state after the ARC
Polyfin no-op qualification, with recovery storage retained.

The infrastructure ApplicationSet still reconciles
`k8s/poc/atlantis-plan-only`, but that path now renders only the existing
`atlantis-system` namespace and `atlantis-pilot-data` PVC. It does not render a
workload, Service, route, ExternalSecret, Secret, admission hook, network
policy or monitoring object.

The PVC is deliberately retained with `Delete=false`, Longhorn off-site backup
labels and `recovery-only` metadata. No state, volume or OCI credential is
deleted by this retirement. `scripts/live-tofu.sh` in `homelab-infra` remains
the operator emergency path.

## Guarantees and difference from Atlantis

Pull requests continue to receive secret-free static validation. After merge,
ARC can run the authenticated root-specific plan and admission workflow. This
is not identical to an Atlantis pre-merge plan: the ARC plan is main-only and
therefore observes the merged tree, while Atlantis evaluated a pull-request
checkout before merge. The post-merge plan is the authoritative drift and
apply-candidate check; no production apply is enabled by this retirement.

The former Mastra-to-Atlantis dispatcher contract was offline-only and had no
deployed workload or credential. Its code and contract were removed to avoid
maintaining a dead transport surface.
