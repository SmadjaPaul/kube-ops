# Oracle A1 (D-2026-11-11-07) — STAGED, not in any ApplicationSet

Two independent kustomizations. Neither is listed in
`k8s/bootstrap/argocd-root`, so merging this directory deploys nothing.

- `argo/` (home cluster, namespace `argocd`): ExternalSecret that builds the
  Argo cluster Secret for the Oracle A1 k3s, an AppProject limited to that
  destination, and a MANUAL-sync Application. Activate by adding `argo/` to
  `bootstrap/argocd-root` only after Doppler holds `ORACLE_A1_API_SERVER` and
  `ORACLE_A1_ARGO_BEARER_TOKEN` (otherwise the ExternalSecret errors).
- `workloads/` (Oracle A1 k3s, namespace `media`): AIOStreams, Polyfin, plain
  Postgres, cloudflared (dedicated Oracle A1 tunnel) and the idle-reclamation
  memory floor. arm64 images (manifest lists verified 2026-11-11); tags are
  pinned, digests to be recorded on Oracle A1 (existing digests are amd64).

Prerequisites on the Oracle A1 cluster (homelab-infra bootstrap, not Git-synced
from here): External Secrets Operator and a `ClusterSecretStore/doppler-cluster`
backed by a Doppler token Secret injected once by the operator.

No Gateway API / Cilium objects are used: cloudflared reaches Polyfin directly
through its Service; AIOStreams has no route at all (cluster-internal, Polyfin
only). `tv.smadja.dev` is not referenced; only `tv-pilot.smadja.dev` is served.

## Auth boundaries

| Path | Protection |
| --- | --- |
| Polyfin client API (Jellyfin-compatible, `/healthz`) on `tv-pilot` | app-native token auth, deliberately NOT behind an OIDC proxy so TV/mobile clients keep working. Polyfin native OIDC is blocked upstream (see media/polyfin README), so family login is native. |
| AIOStreams dashboard + `/api/v1/auth/oidc/*` | Authentik OIDC native to the app, reachable only over NetBird (no public route). |
| AIOStreams addon/stream paths | token-in-URL, consumed by Polyfin in-cluster only. |
