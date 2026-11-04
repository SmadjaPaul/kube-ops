# BookOrbit v3.6.0 synthetic pilot

Status: `ADMISSION_PAUSED` / design-only. This document is the bounded pilot
contract for the staged manifests in `k8s/applications/media/bookorbit`.

## Upstream qualification

The upstream `v3.6.0` tag resolves to commit `a96ff0c85a4c25e9126dfa4c71ea87537a3baf7a`.
The release notes add first-class comic/manga series discovery and EPUB plus
audiobook read-aloud editions; the published `linux/amd64` image digest is
`sha256:bbb5da52e96dbbff1dd36f55454f9845e6cde264b4b3428a3ea783124a4ca62e`.
The upstream compose contract keeps the app read-only with a tmpfs and drops
capabilities, while requiring PostgreSQL and the app URL.

The upstream OIDC contract requires the exact web callback
`https://bookorbit.smadja.dev/oauth2-callback` and the iOS callback
`bookorbit://oauth2-callback`. The test plan must verify discovery, login,
local-account linking, group claims, logout, and recovery before considering
`DISABLE_LOCAL_AUTH=true`; upstream requires an active linked superuser first.

Sources:

- https://github.com/bookorbit/bookorbit/releases/tag/v3.6.0
- https://github.com/bookorbit/bookorbit/blob/v3.6.0/docker-compose.yml
- https://bookorbit.app/oidc

## Synthetic-only pilot boundary

- The package remains excluded from the active Media root and has no external
  Gateway attachment.
- `bookorbit-pilot-data` and `bookorbit-pilot-library` are dedicated PVCs.
  The library must contain only generated or freely redistributable fixtures;
  no `media-share`, existing library, or production download path is allowed.
- The Barman destination is a synthetic bucket/prefix contract only. The
  `.invalid` endpoint is deliberate: it makes accidental runtime activation
  fail closed until an operator supplies a dedicated least-privilege endpoint
  and ESO keys outside this repository.
- No Decypharr ingress, indexer, source, automatic search, public route, or
  production backup identity is part of the pilot.

## Fixture and restore matrix

| Gate | Synthetic evidence required | Current status |
| --- | --- | --- |
| Web | Private browser login, library browse, reader open, logout | `NOT_EXECUTED` — no runtime admitted |
| iOS | OIDC callback `bookorbit://oauth2-callback`, token return, library browse, logout | `NOT_EXECUTED` — device/app not available |
| OIDC | Authentik discovery, browser callback, local linking, family/admin claim separation, recovery login | `NOT_EXECUTED` — dedicated client/secret not provisioned |
| EPUB | Generated EPUB imports from Book Dock and opens in reader | `NOT_EXECUTED` — no pilot PVC or runtime |
| PDF | Generated PDF imports and opens without mutating source fixture | `NOT_EXECUTED` — no pilot PVC or runtime |
| Audiobook | Rights-cleared/generated audio imports, chapters and resume position persist | `NOT_EXECUTED` — no pilot PVC or runtime |
| CBZ | Generated image archive imports as a series and opens in reader | `NOT_EXECUTED` — no pilot PVC or runtime |
| CNPG restore | Synthetic Barman backup restores to a new disposable cluster; database, four extensions, sentinel row/checksum match | `NOT_EXECUTED` — no dedicated object-store credential |
| PVC restore | Both pilot PVCs restore to new claims; sentinel, UID/GID 2501, `/appdata`, Book Dock and library paths match | `NOT_EXECUTED` — no Velero/Kopia runtime evidence |

The pilot is complete only when the independent web/iOS/OIDC and all four file
format gates are green, followed by CNPG and PVC restore evidence with RPO/RTO.
Those results are prerequisites for a separate exact-SHA admission PR; this
design PR does not import BookOrbit into Argo.

## Blockers

- `AUTHORITY_REQUIRED`: an explicit architecture/admission decision is needed
  after the reading-stack comparison.
- `EXTERNAL_DEPENDENCY`: `homelab-infra` must provision synthetic-only,
  prefix-scoped object-store credentials and the isolated OIDC client. Values
  must never be copied into this repository or agent output.
- `TECHNICAL_FAILURE`: none observed in offline checks; runtime behavior is
  intentionally untested.
- `SECURITY_NO_GO`: runtime admission is a no-go until dedicated credentials,
  CNPG/PVC restore coverage, identity isolation, and private-only routing are
  proven. Production/Hetzner credentials and production media are forbidden.
