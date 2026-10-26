# PLT-121 — AIOStreams effective egress verification

**Status: candidate static fix only, runtime NOT_EXECUTED.**

The shared Cilium `media-access` policy previously used `endpointSelector: {}`
and allowed every Media pod egress TCP/443 to `0.0.0.0/0`.
The narrow workload policy on AIOStreams cannot negate this additive allow.
Previous operator evidence showed a successful request to `example.com`.

This PR excludes endpoints with `app.kubernetes.io/name=aiostreams` from
the shared policy via `NotIn`. All other Media endpoints retain their prior
selection (including ones without this label). AIOStreams' own policy still
allows DNS and `auth.smadja.dev:443` only.

Before merge: independently check `NotIn` selector semantics for installed
Cilium version, render all active policies and verify no unrelated policy
allows egress for this endpoint. The exclusion also removes the global
policy's ingress grants; the AIOStreams-specific ingress from Gateway
must be sufficient and must be tested. Preserve the internal-only route.

After GitOps reconciliation, verify from the *real* AIOStreams pod:

- Positive: DNS, TLS/discovery to exact Authentik issuer, admin OIDC login.
- Negative: `https://example.com/`, unexpected public HTTPS hosts/IPs,
  HTTP outside allowed endpoints; include direct IP test and DNS-based test.
- Hubble or equivalent Cilium flow verdicts corroborate deny/allow.
- Check other Arr, Jellyfin, Seerr, BookOrbit staging is unaffected.
- Verify local recovery login and `/api/v1/health` remain operational.
- Do not add world:443 to make TorBox work. Metadata/addon egress
  needs a separately reviewed set of scoped, evidenced destinations.

Do not report EFFECTIVE_EGRESS=PASS from Kustomize, CI or a single network
failure if the connection never reached Cilium. Record policy revision,
Pod labels, endpoint identity, test commands and results in PLT-121.
