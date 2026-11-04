# Factory v0.1.9 — temporary Trivy deployment exception

**Decision:** operator-approved, digest-specific deployment exception. This is
not a vulnerability fix and does not change the default T1 security policy.

## Exact scope and expiry

- Workload: Mastra Factory in `SmadjaPaul/kube-ops`.
- Release tag: `factory-v0.1.9`.
- Source commit: `68d8be297776f5bf12e4a60f29f8f44a084a829d`.
- OCI image: `ghcr.io/smadjapaul/mastra-factory@sha256:c3afb1dc7e6023e8aa482eae37879305ad413e4b61d19e5e15286cb19a44d083`.
- Cloud Build: `13227811-0d87-4538-9c18-aca59456ff25`.
- Approved: 2026-11-04. Expires: **2026-11-18 23:59:59 UTC**.
- Rollback image: `ghcr.io/smadjapaul/mastra-factory@sha256:e7482fde895bc19218031e6275ec538e954c65a2da2bb1ddd69988c5347a8cc5`.

This exception applies only to the exact image digest above. It does not
authorize another digest, tag, source commit, exposure, permission, or future
release. It is not automatically renewable. Reassess or replace the image
before expiry; do not extend this exception implicitly.

## Scan evidence

The complete Trivy JSON and SPDX SBOM are retained in the existing build
evidence bucket:

`gs://perso-stockage-factory-build-evidence-754441152177/factory/68d8be297776f5bf12e4a60f29f8f44a084a829d/13227811-0d87-4538-9c18-aca59456ff25/candidate/`

Trivy report: `trivy.json` (2,784,922 bytes; object generation
`1793816304675261`; SHA-256
`ec1f8517c09964724d0f07761e4bfbd9eda9e0d2f928bfca64c943f88a41ef9b`).
The report contains **97 HIGH findings** across 18 unique CVE identifiers,
as well as the CRITICAL finding discussed below. The full report is the
authoritative per-package/version record; the HIGH findings are accepted only
for this digest and only until the expiry above. This document does not mark
them fixed or establish that they are harmless.

The 18 HIGH identifiers in the retained report are:

`CVE-2025-69720`, `CVE-2026-102990`, `CVE-2026-109383`,
`CVE-2026-12151`, `CVE-2026-1526`, `CVE-2026-16742`,
`CVE-2026-19481`, `CVE-2026-19693`, `CVE-2026-2229`,
`CVE-2026-41992`, `CVE-2026-4800`, `CVE-2026-53613`,
`CVE-2026-53615`, `CVE-2026-54369`, `CVE-2026-56876`,
`CVE-2026-78410`, `CVE-2026-87018`, `CVE-2026-9538`.

## CRITICAL finding applicability

Trivy reports `CVE-2023-45853` against Debian `zlib1g` version
`1:1.2.13.dfsg-1`, with no fixed version reported. The vulnerability is an
integer overflow and heap buffer overflow in MiniZip's
`zipOpenNewFileInZip4_64` writer API when processing attacker-controlled ZIP
entry metadata. The vulnerable operation requires a caller to use the
MiniZip archive-writing API; it is not a generic zlib decompression path.

For this exact image, the retained SPDX SBOM and source review show the
`zlib1g` runtime library but no `minizip`, `libminizip`, or `pyminizip`
package/library, and no call to `zipOpenNewFileInZip4_64` or equivalent
MiniZip writer API. The Debian `zlib1g` package file list contains the zlib
shared library, not the separately packaged MiniZip implementation. The
Factory runtime's ZIP handling is through JavaScript packages and does not
expose the affected native writer API. Therefore this scan mapping does not
establish an accessible RCE, authentication bypass, or credential exposure in
the deployed Factory image. This applicability determination is specific to
the image and evidence above.

Debian tracks the CVE under MiniZip; its Bookworm standalone `minizip` package
has a fixed release, while Bookworm's `zlib1g` binary does not ship that
MiniZip component. Upstream zlib 1.3.1 also records rejection of ZIP header
field overflows. Re-evaluate if MiniZip is added, the image changes, or the
runtime begins calling the affected API.

## Operating conditions

- Keep autonomous admission OFF and Delivery ON as currently authorized.
- Keep PLT-126 and its bindings unchanged.
- Preserve NetworkPolicies, service-account permissions, and existing
  ingress boundaries.
- No new agent dispatch is part of this exception.
- If the runtime fails after promotion, revert through the normal reviewed
  GitOps path to the rollback digest above.
- At expiry, this release must be replaced or separately reassessed before
  further promotion decisions. No automatic renewal is permitted.

Primary references:

- [Debian Security Tracker — CVE-2023-45853](https://security-tracker.debian.org/tracker/CVE-2023-45853)
- [Debian Bookworm `zlib1g` package](https://packages.debian.org/bookworm/zlib1g)
- [Debian Bookworm `zlib1g` file list](https://packages.debian.org/bookworm/amd64/zlib1g/filelist)
- [Upstream zlib releases](https://github.com/madler/zlib/releases)
