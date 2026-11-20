# Polyfin image admission

The Polyfin deployment runs the official upstream image, pinned by digest in
`k8s/applications/media/polyfin/deployment.yaml`. This directory holds the
admission policies that `scripts/polyfin-admission-check.sh` applies to it.

- `private-pilot-admission.json`: the active policy (image, digest, accepted
  findings, expiry). Read by `.github/workflows/polyfin-image-audit.yaml`,
  `.github/workflows/polyfin-private-pilot-expiry.yaml` and the harness tests.
- `private-pilot-admission-v060.json`: the policy that the
  `polyfin-admission-check.sh --self-test` cases use.

The downstream v0.50.0 builder (Dockerfile patch and manual build workflow) was
removed: the deployment no longer uses a downstream image.
