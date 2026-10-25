# BookOrbit — staged application, NOT deployed by Media root

Updated staged candidate: **BookOrbit v3.5.0** (published 2026-10-20).
The default Media root intentionally does not include `- bookorbit`.
A dedicated admission PR, image digest and runtime tests are mandatory.

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
