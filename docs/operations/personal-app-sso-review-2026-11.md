# Personal applications — upstream OIDC and operability audit (2026-11-04)

Scope: GitHub draft PRs #843 (Polyfin), #844 (BookOrbit),
#845 (RustiCal), #846 (SparkyFitness), #847 (La Suite Docs/Drive/Office).
All are staged, **not admitted** and not production proof. Authentication
requires **both** an Authentik application/provider AND application-side
configuration and, for OIDC confidential clients, the **same secret value**
from Doppler on both sides. Never print the secrets or hand-write one in Git.

## Exact redirect matrix

| App | Authentik slug / expected client ID | Browser redirect registered at Authentik | App configuration |
| --- | --- | --- | --- |
| Polyfin 0.59 | `polyfin` / `polyfin` | `https://media.smadja.dev/admin/api/provider/callback` | Admin Settings > Notifications: Public address; Security: Identity provider, issuer/client/secret and claim/group; stored in PG |
| BookOrbit 3.6 | `bookorbit` / `bookorbit` | `https://bookorbit.smadja.dev/oauth2-callback` and `bookorbit://oauth2-callback` (iOS) | Settings > OIDC / SSO: discover, test, set group mapping and local-account linking |
| RustiCal 0.18 | `rustical` / `rustical` | `https://calendar.smadja.dev/frontend/login/oidc/callback` | `RUSTICAL_OIDC__*` env; web login OIDC; DAV clients use personal app tokens |
| SparkyFitness 1.11 | `sparkyfitness` / `sparkyfitness` | `https://fitness.smadja.dev/api/auth/sso/callback/authentik` | Helm env-backed Better Auth; group `authentik-admins`, NO auto-registration while global signup is disabled |
| La Suite Docs 6.0.4 | `lasuite-docs` / `lasuite-docs` | `https://docs.smadja.dev/api/v1.0/callback/` | `OIDC_OP_*`, `OIDC_RP_*` backend variables; JWKS and logout must use `lasuite-docs` |
| La Suite Drive 0.25.3 | `lasuite-drive` / `lasuite-drive` | `https://drive.smadja.dev/api/v1.0/callback/` | Same as Docs with separate client and secret |
| Collabora CODE | N/A; WOPI trust | N/A | User authenticates to Drive first; Collabora trusts signed WOPI sessions and scoped host aliases |

Sources: Polyfin https://github.com/moodiness/polyfin/blob/v0.59.0/docs/administration.md ;
BookOrbit https://bookorbit.app/oidc ;
RustiCal https://github.com/lennart-k/rustical/blob/v0.18.0/docs/setup/oidc.md ;
Sparky https://github.com/CodeWithCJ/SparkyFitness/blob/v1.11.0/SparkyFitnessServer/auth.ts ;
La Suite OIDC URL composition
https://github.com/suitenumerique/django-lasuite/blob/main/src/lasuite/oidc_login/urls.py ;
Collabora chart
https://github.com/CollaboraOnline/online/blob/main/kubernetes/helm/collabora-online/values.yaml .

## Security and identity rules

1. Keep exact redirect URIs; no wildcard/regex redirect approvals.
2. Use authorization code flow and issuer discovery with real TLS trust;
   do not disable certificate verification or forward OAuth secret via URL.
3. Map `openid profile email`, plus `groups` only when the app uses it.
   Existing Authentik `email` scope maps `email_verified: false`:
   explicitly test the app's verification/auto-link semantics, never
   mark emails verified without a verification workflow.
4. Reserve admin privilege to `authentik-admins` in the app itself.
   Being able to log into an app is not authorization to administer it.
5. Restrict Authentik app access to `family` and `authentik-admins`;
   test member and non-member flows, including a revoked member.
6. Keep local emergency login until successful two-user login/logout and
   restoration. Do not force SSO before the browser/mobile flows pass.
7. Register app providers and their secrets in Authentik separately:
   the staged blueprints are NOT imported into the active
   `authentik-blueprints` ConfigMap generator and the staged ESO manifests
   are NOT imported into its active Kustomization. Authentik deploy envFrom
   also needs review. This is intentional: absent Doppler keys would risk
   breaking authentication for *existing* applications.
8. On BookOrbit, ensure no automatic group mapping can grant superuser
   without an explicit independent decision; local linking must be
   tested against a real existing user.
9. User-agent SSO and protocols differ: a CalDAV phone may require an app
   token; a Jellyfin client may use Quick Connect, not OIDC; a WOPI editor
   inherits Drive authorization.

## Runtime & state admission checklist (NO-GO until proven)

- **Polyfin:** new image digest verified, Trivy and signed provenance, DB
  pre-migration backup/restore, official web client + Jellyfin app, no proxying
  CDN media without an explicit user playback need. `media.smadja.dev`
  does not replace AIOStreams at `tv.smadja.dev`.
- **BookOrbit:** dedicated scoped S3 credentials, CNPG and Velero restore,
  local filesystem contract on Longhorn, protected Decypharr categories,
  real iOS login and stable data.
- **RustiCal:** stable SQLite file and WAL-consistent backup/restore,
  auth token revocation, Apple Calendar/Contacts and DAVx5, no world egress.
- **SparkyFitness:** initialization of separate `sparky_admin` and
  `sparky_app` DB roles, user-creation policy limitation in v1.11.0,
  the preprovisioned owner, full chart image verification and mobile sync.
- **La Suite:** backend Docs/Drive + Yhub databases, durable Valkey streams,
  separate scoped Hetzner S3 buckets, content/media reverse proxy,
  Cilium allowlists and restored WOPI sessions. A bare HTTPRoute is not
  evidence that file previews or downloads work.
- **Collabora:** stable RSA WOPI proof keys from ESO (never chart random
  `lookup`), a WOPI-compliant discovery, actual collaborative editing
  and correct `SupportsRename: false`. The draft office HTTPRoute is
  intentionally **EXCLUDED** because its catch-all route exposes admin
  and metrics endpoints. Build a filtered route before admission.

No automatic action on the live cluster, no Argo root imports, and no
Homelab/Factory changes are authorized by this audit. Treat a green GitHub
contract CI as STATIC only; it is never an OIDC login proof.
