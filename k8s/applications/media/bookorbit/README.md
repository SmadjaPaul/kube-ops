# BookOrbit — staged application, NOT deployed by Media root

> **PLT-122 — ON HOLD (2026-10-27): maintainer trust/governance review.**
> BookOrbit was **never imported into the active Media root**. Do not create
> BookOrbit credentials, dedicated S3 identity, CNPG cluster or runtime resources,
> and do not begin an admission PR while the application choice is under review.
> This is a pause, **not** permission to delete staging, shared data or any PVC.
> A future selection requires an explicit go decision and an independent supply-
> chain/maintainer-risk review. The video AIOStreams work (PLT-121) is independent.
>
> Context: The BookOrbit maintainer publicly confirmed having maintained
> BookLore; its temporary repository deletion in March 2026 caused concern
> about continuity. Do not conflate project governance risk with a demonstrated
> malware issue. References:
> https://www.reddit.com/r/selfhosted/comments/1w9h1b4/bookorbit_v290_automated_book_requests_from/
> https://www.reddit.com/r/selfhosted/comments/1rvmpnv/booklore_is_gone/
> https://selfh.st/weekly/2026-09-18/


Updated staged candidate: **BookOrbit v3.5.0** (published 2026-10-20).
The default Media root intentionally does not include `- bookorbit`.
A dedicated admission PR, image digest and runtime tests are mandatory.

## Current qualification boundary (2026-10-25)

- **STATIC PASS:** the v3.5.0 image is digest-pinned, the workload is
  non-root, the inactive package renders, and the staged contract passes.
- **RECONCILED/RUNTIME:** not applicable yet. `bookorbit` is not imported by
  the Media root and no BookOrbit Deployment, PVC, CNPG Cluster,
  ExternalSecret, ObjectStore or HTTPRoute is present in the cluster.
- **CNPG baseline:** the cluster currently runs CloudNativePG 1.29.1 and the
  Barman Cloud plugin v0.11.0; BookOrbit PostgreSQL health, extension
  availability and backup status remain unexecuted until admission.
- **PVC backup gate:** `bookorbit-data` needs an explicit Velero/Kopia
  filesystem-backup schedule and a restore probe in the admission change.
  The current media schedules do not provide a BookOrbit-specific selector.
- **Identity gate:** the staged Barman manifest requires
  `APP_BOOKORBIT_CNPG_S3_ACCESS_KEY_ID` and
  `APP_BOOKORBIT_CNPG_S3_SECRET_ACCESS_KEY`. These names are a contract for a
  dedicated, prefix-scoped credential that must be provisioned and qualified
  in `homelab-infra` before admission; the shared `HETZNER_S3_*` identity is
  explicitly forbidden. No secret value belongs in this repo.
- **Private admission:** the staged HTTPRoute attaches only to
  `Gateway/internal`. Adding `Gateway/external` is a separate reviewed
  exposure decision and is not part of BookOrbit admission.
- **Path gate:** upstream v3.5 creates `APP_DATA_PATH` and its Book Dock
  directory at startup. The configured `/data/book-dock` path is therefore
  a runtime check, not a reason to mutate the shared media-layout job.

The admission PR must sequence the dedicated backup identity, PVC backup and
restore proof, ESO readiness, CNPG health/extensions, and only then the
Argo import. Decypharr ingress remains closed until the dedicated
no-category authentication and protected category requests are proven.

## Private restore/admission procedure (prepared, not executed)

The following evidence is required before a separate admission PR may import
this directory into the Media root. It is intentionally a runbook contract;
this staged PR performs no Kubernetes mutation and no credentialed probe.

1. **Static:** run `kustomize build k8s/applications/media/bookorbit`, the
   staged contract, and `just check`. Confirm that the root still omits
   `bookorbit`, the route has only `Gateway/internal`, and `backup.yaml` has
   only the two dedicated BookOrbit CNPG key names.
2. **ESO/CNPG readiness:** with the canonical operator access harness, verify
   only metadata/status: `doppler-cluster` Ready, both dedicated remote key
   names present, `bookorbit-runtime` and the CNPG credential Secret Ready,
   CNPG healthy, PostgreSQL 18 extensions installed, WAL archiving active,
   ObjectStore healthy, and a completed ScheduledBackup. Never print Secret
   values or use the shared `HETZNER_S3_*` keys as a fallback.
3. **CNPG restore probe:** restore the newest completed BookOrbit Barman
   backup into an isolated, disposable namespace/cluster using the same
   dedicated identity and `cnpg` recovery procedure. Verify the cluster is
   Ready, the `bookorbit` database opens, all four required extensions exist,
   and a sentinel row/checksum matches. Record RPO/RTO and delete only the
   disposable restore after evidence capture.
4. **PVC restore probe:** create a disposable Velero/Kopia filesystem backup
   of `bookorbit-data`, restore it to a new claim with a distinct name, and
   verify a sentinel file, UID/GID 2501 ownership, `/appdata` readability,
   and the `/data/book-dock` plus `/data/media/books` path contract. Do not
   delete or reinitialize the production claim.
5. **Private admission:** add only `- bookorbit` to the Media root in a
   separate exact-SHA PR after the preceding gates pass. Keep Decypharr
   ingress, external HTTPRoute attachment, indexer/source egress and automatic
   searching disabled until their independent tests pass.

## Upstream-verified features

- Books / comics / audiobooks in user libraries. Requests is labelled Beta:
  user requests -> human moderation -> enabled permitted source -> download
  client -> Book Dock -> library. There are no bundled indexers/sources.
- Torrent download clients include qBittorrent. BookOrbit 3.2.0 source
  (reconfirmed before 3.5.0 upgrade) sends POST to `/api/v2/auth/login`
  WITHOUT category, then calls other endpoints with a SID cookie. This
  matches the **known Sonarr ↔ Decypharr v2.5 category-auth incompatibility**.
  Do not assume it works solely because qBittorrent `/app/version` is 200.
- BookOrbit demands a path mapping even for shared filesystems.
  Both applications mount `media-share` at `/data`, so choose:
  `/data/decypharr-downloads -> /data/decypharr-downloads`.
- Book Dock staging: `BOOK_DOCK_PATH=/data/book-dock`, library:
  `/data/media/books`. Parent `/data` on same filesystem => hardlinks
  possible, but only a real hardlink test can prove it.
- `BOOK_REQUEST_ENCRYPTION_KEY` is mandatory to store client credentials
  securely; it already has an ESO **key-name** contract, not a proven value.
- SSO Authentik staged blueprint is intentionally not imported. Bootstrap a
  local admin first, configure browser OIDC, verify claims and superuser login,
  and only then consider `DISABLE_LOCAL_AUTH=true`.
- Metadata, book indexer and Prowlarr egress are NOT opened yet. A deliberate
  narrow policy change is required when an authorized source is selected.
- NetworkPolicy adds *only a dormant BookOrbit egress* to Decypharr 8282,
  while the Decypharr ingress policy currently DOES NOT authorize BookOrbit.
  Admit matching ingress only after auth regression tests are green.
- No category changes after import or calls to `setCategory`: v2.5 and
  v2.7 implement it with a null filter, risking mutation of the entire queue.
- Existing SABnzbd, audiobook app, Jellyfin libraries, PVCs and live
  Decypharr state remain unchanged by this staging PR.

## Admission gates

1. Resolve + pin immutable image digest for v3.5.0, check upgrade-specific
   API, health route, extension/Postgres dependencies and supported CPU arch.
2. Verify CNPG 1.29+, PostgreSQL 18 `uuid-ossp`, `pg_trgm`,
   `unaccent`, `vector` and Barman Cloud backup ObjectStore, with
   real restore probe or report it NOT_EXECUTED.
3. Provision/qualify (names only) Doppler `cluster/prd` ESO BookOrbit keys,
   CNPG app secret and ingress/tls; no plaintext secrets.
4. Render inactive Kustomize folder and run offline V1 checks. A separate
   exact-SHA PR imports BookOrbit to Media root, after explicit go gate.
5. Bootstrap local superuser, hardening, Authentik/OIDC browser test with
   user/admin isolation and recovery login before disabling local.
6. Qualify Decypharr no-category qBittorrent login for a **dedicated
   BookOrbit identity** without bypassing `use_auth=true`. Verify protected
   `/api/v2/torrents/info?category=bookorbit` not just `/app/version`.
   Do not send BookOrbit credentials as argv, logs or PR content.
7. Cilium BookOrbit->Decypharr 8282 and explicit Decypharr ingress
   from BookOrbit only; prove allow/deny with runtime tests.
8. Confirm configured category `bookorbit`, file ownership + identity path
   mapping + hardlink test. Keep automated searching off and queue
   non-destructive until safe, authorized source exists.
9. End-to-end with freely redistributable fixture: request, approve, search
   using authorized indexer/source, TorBox cloud completion, file on shared
   PVC, Book Dock import, metadata and reader. No content speculation.
10. Update Linear with STATIC/RECONCILED/RUNTIME per gate.

## Sources

- https://bookorbit.app/installation/
- https://bookorbit.app/book-requests/
- https://bookorbit.app/oidc
- https://github.com/bookorbit/bookorbit/releases/tag/v3.5.0
- https://github.com/bookorbit/bookorbit/blob/v3.2.0/server/src/modules/book-request/download-clients/adapters/qbittorrent.adapter.ts
- https://github.com/nourez/klusty-krab-home-lab/pull/57
- https://github.com/bookorbit/bookorbit/issues/1805
- https://github.com/sirrobot01/decypharr/blob/v2.5/pkg/server/qbit/http.go
