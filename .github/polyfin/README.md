# Polyfin downstream image builder (quarantined)

This directory holds a **minimal, Dockerfile-only patch** of the exact upstream
[Polyfin v0.50.0](https://github.com/moodiness/polyfin/releases/tag/v0.50.0)
commit `e2cf9f08ac60400fdab20726671fa2e08fd09e1e`.

- `Dockerfile.v0.50.0.patch` updates Go 1.27.1 → 1.27.3 and refreshes the
  Debian runtime's libpcre2/OpenSSL packages. It modifies **no application code**.
- `.github/workflows/polyfin-downstream-build.yaml` has a **read-only PR**
  verification job and a **manual-only** (`workflow_dispatch`) image build
  that runs from the default branch.
- The manual job publishes an immutable candidate reference to GHCR, writes
  SBOM/provenance and verifies a keyless Cosign signature, then scans the
  published digest with Trivy. It **intentionally fails** if ANY HIGH or
  CRITICAL remains, even if all six targeted CVEs disappear.
- **Published candidate != approved for deployment.** No Pod, secret,
  Kustomization, image reference or external route is modified by this workflow.
- A manually published candidate with residual vulnerabilities is strictly
  quarantined: never promote by tag, deploy, or suppress the scan.
- If the upstream release changes, make a new standalone patch with its
  new source SHA and adjust the expected diff before using the workflow.
  Do not silently retarget `latest`.

At the 2026-10-27 local test, all six *targeted* CVEs were gone, but there were
**17 remaining distinct CVEs**, so the manual build's OCI gate must remain
NO-GO. Runtime-specific risk acceptance requires a separate explicit decision.

**First use:** after this builder-only PR is merged, Codex may start the
GitHub Actions **Polyfin downstream candidate build** workflow on `main`
using `workflow_dispatch`. Review signed digest, SBOM, Trivy JSON, source
commit and the action identity in the workflow evidence. Keep Polyfin
activation in PR #781 dormant.
