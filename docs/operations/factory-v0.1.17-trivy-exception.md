# Factory v0.1.17 — digest-scoped Trivy exception

**Disposition:** accepted for deployment under the operator's requested,
digest-specific exception, based on the applicability evidence below. This is
not a fix and does not alter global scanner policy or acceptance rules.

## Exact scope and expiry

- Workload: Mastra Factory in `SmadjaPaul/kube-ops`.
- Release tag: `factory-v0.1.17`.
- Source commit: `f337e62ae7a2c7d55db9e8362ac92ce3cf1a0687`.
- Cloud Build: `25f2ee82-8f08-4cda-a15e-d2671c15ced3`.
- OCI image: `ghcr.io/smadjapaul/mastra-factory@sha256:b41a2d19923c1d3438dffaecfac12cd6af32b9190d424900b320d80975b7acb8`.
- Disposition date: 2026-11-08. Expires: **2026-11-18 23:59:59 UTC**.
- Rollback image: `ghcr.io/smadjapaul/mastra-factory@sha256:1b0303339dde64adae2b02b0cb2da54dd6721188944488674ae1de0dd764d18c`.

This exception applies only to the CVE and exact image digest above. It does
not accept the report's 99 HIGH findings, another image/tag/source, a changed
exposure or permission, or any later release. It is not renewable implicitly.

## Evidence and applicability

The exact-image Trivy JSON and SPDX SBOM are retained at:

`gs://perso-stockage-factory-build-evidence-754441152177/factory/f337e62ae7a2c7d55db9e8362ac92ce3cf1a0687/25f2ee82-8f08-4cda-a15e-d2671c15ced3/candidate/`

Trivy maps the finding to Debian `zlib1g` `1:1.2.13.dfsg-1`, with status
`will_not_fix` and no fixed version. The reported bug is in MiniZip's
`zipOpenNewFileInZip4_64` archive-writing function, handling attacker-controlled
long ZIP entry metadata; it is not a generic zlib compression/decompression
path. [Debian's tracker](https://security-tracker.debian.org/tracker/CVE-2023-45853)
distinguishes the MiniZip component from zlib. The Debian Bookworm
[`zlib1g` file list](https://packages.debian.org/bookworm/amd64/zlib1g/filelist)
contains `libz.so.1` and documentation, not the separate MiniZip implementation.

The SBOM for this digest lists `zlib1g` and the JavaScript package `minizlib`,
but no `minizip`, `libminizip`, or `pyminizip` package. A source scan of the
Factory v0.1.17 tree found no MiniZip writer symbol or call site. The runtime
image is assembled from the generated application output and its runtime
dependencies; the build-stage toolchain is not copied into it. On this
evidence, the affected native writer code is absent from the runtime image and
no remotely reachable Factory call path to the vulnerable operation was
identified. The finding is a source-package mapping, not demonstrated
exploitation of this image. No evidence indicates a Factory RCE,
authentication bypass, or credential exposure from this CVE.

## Operating conditions

- Keep autonomous admission OFF and Delivery ON.
- Keep PLT-126 and its bindings unchanged.
- Do not change ingress, NetworkPolicies, ServiceAccount permissions, or
  scanner policy under this exception.
- Reassess or replace the image before expiry; do not extend this exception
  implicitly.
- If rollout or runtime health regresses, revert by a reviewed GitOps change
  to the rollback digest above.

