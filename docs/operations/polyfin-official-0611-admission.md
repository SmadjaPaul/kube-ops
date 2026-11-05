# Polyfin official 0.61.1 admission record

Date: 2026-11-05  
Scope: private LAN/VPN pilot only; no family promotion and no public route.

## Decision

The media overlay is prepared to use the official upstream image:

```text
ghcr.io/moodiness/polyfin:0.61.1@sha256:1e55720ea21bca9448ddbdd80a21251622d21448ee2e31974ad18ae2a9f6c975
```

This is the `linux/amd64` platform manifest for the official multi-platform
manifest list:

```text
manifest list: sha256:fdeb10f87e596fc04677b0801cbb8c0cc6728b2bb38d9fe89b9bf3685dbfdcc4
upstream tag: v0.61.1
upstream release commit: 2c1576329fba3546202a47f0f3a157cd7cb0623d
```

The release and digest were checked against the public upstream release and
GHCR registry metadata. The deployment uses the platform digest so the
Kubernetes workload cannot silently select another architecture.

The admission remains T2 and private. It expires at
`2026-12-05T23:59:59Z` and is revoked immediately if the digest, network
perimeter, upstream security state or approved finding set changes. No
upstream Cosign signature or GitHub artifact attestation was found for this
image digest; neither is claimed. The admission is based on the official
publisher, the immutable digest, complete scanner output and the explicit
perimeter controls.

## Security evidence

The exact read-only local scan was run against the `linux/amd64` platform
digest with OS and library scanners, `HIGH,CRITICAL` severity and
`ignore-unfixed=false`. The local Trivy version was 0.68.2; repository CI is
authoritative and pins Trivy 0.76.1.

Result from the local scan:

```text
68 HIGH/CRITICAL occurrences
29 unique CVEs
22 unique CVEs with an affected status after the fixed-status CVEs are separated
```

The complete raw JSON and normalized findings were kept outside the
repository for this qualification run. The checked-in policy records every
unique finding, keeps fixed-required findings visible, and does not use a
scanner exclusion. `CVE-2026-6653` (libxml2) and
`CVE-2026-76844` (zlib) remain explicit residual risks. No custom image,
Debian backport or automatic waiver is part of this change.

The upstream release workflow and its successful image smoke-test run are
evidence about the publisher's release, not a Kubernetes runtime test. CI
must rerun the repository's pinned Trivy audit before any promotion decision.

## Runtime and data safety gates

| Gate | Status | Evidence |
| --- | --- | --- |
| Upstream migration | PASS (source-level) | Upstream v0.61.1 release notes state that there is no database change. No application migration was applied. |
| Upstream image smoke test | PASS (upstream) | Upstream release workflow run `42065729982` completed successfully, including image build/smoke test. |
| Cluster startup | NOT_EXECUTED | The overlay remains unpromoted; no family workload was restarted. |
| Backup/restore | BLOCKED | `just backup-audit` reports `CNPG_RESTORE_PROOF=UNPROVEN`, `PRODUCTION_RECOVERY_STATUS=FAIL`, and incomplete production PVC/CNPG backup coverage. No destructive restore was attempted. |
| Rollback | NOT_EXECUTED | The reviewed rollback target is official v0.60.0 `linux/amd64` digest `sha256:3fd9c3ddeb79a93e2259592cfd83fdf925c196cffc99ee049ec4598276e143e0`; no rollback was applied. |
| AIOStreams / radios | NOT_EXECUTED | This change does not modify #997 or install an addon/source. |

Because restore proof and cluster startup evidence are not complete, this PR
must not be merged into a state that Argo would promote to the family. The
Polyfin route remains disabled, and existing Cilium, Authentik OIDC, secret
delivery and exposure restrictions are unchanged.

## Maintenance strategy

The former downstream build/backport work is historical evidence only. PR
[#1018](https://github.com/SmadjaPaul/kube-ops/pull/1018) is closed and its
workflow is not merged or reused. Future image changes are expected to come
from the official GHCR image and are pinned by digest. Renovate may prepare
digest/tag updates, but automerge remains conditional on the image audit,
policy evaluation and the repository's required checks.

Promotion requires a separate isolated runtime qualification proving startup,
safe migration/no-op behavior, backup restore and rollback before any family
deployment. No apply, import, restore, or production mutation was performed
for this change.
