# BookOrbit V1 — staged

This package is intentionally **not** referenced by
`k8s/applications/media/kustomization.yaml` yet.

Activation is a one-line root change after all gates below pass:

- homelab-infra BookOrbit secrets are merged and applied to `cluster/prd`;
- `bookorbit-runtime` ExternalSecret is Ready;
- CloudNativePG 1.29+ is healthy;
- PostgreSQL 18 standard image exposes `uuid-ossp`, `pg_trgm`, `unaccent`,
  and `vector`;
- the shared media PVC is healthy and writable by UID/GID 2501;
- Cilium render validates;
- backup ObjectStore credentials are Ready.

The package uses BookOrbit 3.2.0, PostgreSQL 18 via CloudNativePG, the existing
Barman Cloud plugin, and the shared media PVC. Local auth remains enabled during
bootstrap. OIDC is configured only after the first administrator is created and
a real Authentik flow is verified; do not set `DISABLE_LOCAL_AUTH=true` before
that proof.

The library picker is bounded to `/data/media/books`. The full shared media
PVC is mounted at `/data` only to preserve the single-filesystem media layout;
BookOrbit should own the books subtree, while Audiobookshelf remains the primary
audiobook playback service.
