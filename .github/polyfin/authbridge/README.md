# Polyfin/AuthentiK: minimal native Jellyfin-session bridge

**PROTOTYPE ONLY — OFF BY DEFAULT, NOT DEPLOYED.** Its purpose is to avoid
re-implementing OAuth/OIDC *inside Polyfin*. Authentik remains the identity
provider, and the existing Polyfin `accounts.SignInDevice()` issues normal
Jellyfin tokens. No Jellyfin .NET plugin or user-password impersonation.

This is built against upstream
[`v0.50.0`](https://github.com/moodiness/polyfin/tree/v0.50.0) at
`e2cf9f08ac60400fdab20726671fa2e08fd09e1e` to match the **existing,
already signed** downstream Dockerfile candidate. The current production digest
and [temporary CVE admission](../private-pilot-admission.json) are unchanged.

## Files and patch footprint

- `authbridge.go`: a single dormant Go file, placed beside Polyfin's main
  entrypoint, that validates a browser's Authentik cookie **server-to-server**
  with an Authentik Proxy Provider's forward-auth outpost endpoint; only the
  outpost response's `X-Authentik-Uid` is considered.
- `authbridge_test.go`: positive native-token and negative spoof, CSRF,
  unmapped-user and unsafe-configuration tests.
- `web-login.js`: a small addition to Polyfin's existing injected
  `/web/polyfin.js`; no modifications to third-party jellyfin-web bundles.
- `apply.py`: strictly matches the upstream main handler and adds a
  one-expression wrapper around `server.New(...)`. Refuses fuzzy patching.
- `../../workflows/polyfin-authbridge-prototype.yaml`: read-only clone,
  overlay, compile and test; it cannot publish or promote images.

## Data flow

1. The Jellyfin Web login page displays a link to
   `/polyfin-sso/complete`. This path is implemented only if
   `POLYFIN_AUTHBRIDGE_ENABLED=true`.
2. Polyfin sends the **browser's Authentik proxy cookie** to the fixed
   `/outpost.goauthentik.io/auth/nginx` endpoint in its configured internal
   Authentik Outpost service. The bridge **ignores any X-authentik-* header
   received from the browser**. It trusts only the response to its own
   server-to-server authorization call.
3. When unauthenticated, a GET redirects to the *fixed* Authentik start URL
   on the same host. That path must be routed to the Authentik Outpost, which
   starts authentication/MFA and returns to `/polyfin-sso/complete`.
4. The completed page contains **no token**. Its same-origin POST performs a
   fresh Outpost check, maps the authenticated immutable Authentik UID to an
   explicitly provisioned Polyfin user ID, and uses `accounts.SignInDevice`
   to mint a normal Jellyfin device session.
5. The browser receives the token over same-origin HTTPS in a
   `Cache-Control: no-store` response, stores it in Jellyfin Web's
   existing `jellyfin_credentials` structure and opens `/web/`.
6. The existing local admin login remains available as break-glass; TV/mobile
   devices keep Polyfin's unmodified Quick Connect workflow.

There is no auto-provisioning, no automatic email/username matching, no
group-driven admin grants and no Authentik middleware in front of video/API.

## Expected configuration (not provisioned by this PR)

These environment variables are required **only** when enabling the bridge:

| Variable | Meaning |
| --- | --- |
| `POLYFIN_AUTHBRIDGE_ENABLED` | `true` explicitly enables; absent means no wrapper or routes |
| `POLYFIN_AUTHBRIDGE_ORIGIN` | Exactly `https://tv.smadja.dev` |
| `POLYFIN_AUTHBRIDGE_CHECK_URL` | Fixed trusted Outpost nginx forward-auth endpoint: `http://<outpost-service>.<namespace>.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx`, or `https://auth.smadja.dev/outpost.goauthentik.io/auth/nginx` |
| `POLYFIN_AUTHBRIDGE_START_URL` | `https://tv.smadja.dev/outpost.goauthentik.io/start?rd=https%3A%2F%2Ftv.smadja.dev%2Fpolyfin-sso%2Fcomplete` |
| `POLYFIN_AUTHBRIDGE_IDENTITIES` | Secret JSON map: **exact** `X-Authentik-Uid` → existing Polyfin user UUID, one-to-one; managed only in Doppler/ESO |

**Mandatory routing prerequisite:** `tv.smadja.dev/outpost.goauthentik.io/*`
must reach only the Authentik Outpost, while
`tv.smadja.dev/polyfin-sso/complete` reaches the Polyfin backend.
The Authentik Proxy Provider's external host and cookie domain must match.
No SSO route may be exposed via Cloudflare. The bridge's backchannel must be
authorized **only** to the actual Outpost service via Cilium; never add
`world:443` or trust incoming `X-Authentik-Uid`. Validate the outpost's
actual response headers and cookie flow before enabling this code.

The outpost supports NGINX-style auth checks, but **the exact session
cookie semantics have not yet been verified in this cluster**. If the
check does not provide an authenticated user header, do not work around it
by trusting a header sent directly by the client. Use the appropriate
upstream Authentik proxy integration instead.

## Production safety gates

**Not passed yet**:
- Real in-cluster Outpost host, route, cookie, and authenticated
  `X-Authentik-Uid` verified from Polyfin.
- At least one manually linked account, plus second-user isolation and
  session revocation; screen-reader/SPA button behavior; client sign-out
  and cached Jellyfin Web state after switching accounts.
- Browser-origin and CSP end-to-end (especially Brave), and no tokens in
  redirects, query strings, logs, histories or telemetry.
- New downstream OCI digest, fixed source + patch hash, new SPDX SBOM,
  GitHub/BuildKit provenance and keyless Cosign signature, *then*
  exact-digest Trivy and **new** per-digest CVE risk admission.
- CNPG backup/restore of the added state where applicable.
- Verify that SSO remains local LAN/VPN-only; no access to IPTV or video
  via public Cloudflare; fallback admin login preserved.

**Important:** Do NOT reuse the current image risk exception for a new digest.
Do not merge SSO activation manifests from this prototype. A successful
`go test` means only the patch compiles and security boundaries pass mock
checks, not that Authentik, Jellyfin Web or the TV clients work in runtime.

## Minimal local spike command

```bash
git clone --branch v0.50.0 https://github.com/moodiness/polyfin.git /tmp/polyfin-sso-spike
test "$(git -C /tmp/polyfin-sso-spike rev-parse HEAD)" = "e2cf9f08ac60400fdab20726671fa2e08fd09e1e"
python3 .github/polyfin/authbridge/apply.py /tmp/polyfin-sso-spike
cd /tmp/polyfin-sso-spike
gofmt -w cmd/polyfin/authbridge.go cmd/polyfin/authbridge_test.go
go test ./cmd/polyfin -run '^TestBridge' -count=1 -v
```

During implementation, minimize and retain the patch as upstream + small,
atomic commits. Propose the generalizable portion to upstream
[issue #217](https://github.com/moodiness/polyfin/issues/217).
