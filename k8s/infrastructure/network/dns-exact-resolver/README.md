# dns-exact-resolver (PLT-149)

Small CoreDNS that answers **exact** internal names for the split-DNS
local-first contract. It is deployed by GitOps (`infra-network`) in its own
namespace, with one fixed address from `internal-gateway-pool`.

## Contract

For each listed name (no wildcard, no apex, `tv.smadja.dev` excluded):

| Type | Answer |
| ---- | ------ |
| A | `10.0.20.192` (Gateway/internal VIP), TTL 300 |
| AAAA, HTTPS (65), SVCB (64) | NOERROR with no record (NODATA) |

Any other name falls through to `forward . 10.0.20.1` (UniFi).

Address: `10.0.20.194` port 53 (LB IP pinned by `lbipam.cilium.io/ips`; the pod
listens on 1053 as non-root, the Service maps 53 to it). `.192` is the
Gateway/internal VIP and `.193` the Gateway/external VIP.

## Why it exists

UniFi answers `A` correctly through ExternalDNS, but cannot return NODATA for
AAAA/HTTPS/SVCB (its record types are A, AAAA with a real IPv6, CNAME, MX, TXT,
SRV and FORWARD_DOMAIN). Browsers then receive the public Cloudflare AAAA and
HTTPS records. UniFi delegates the listed names here through a FORWARD_DOMAIN
policy (`homelab-infra#642`, disabled by default).

## No loop

- The resolver forwards only to UniFi (`10.0.20.1`), never to kube-dns
  (`10.96.0.10`). The pod uses `dnsPolicy: Default`.
- kube-dns forwards to UniFi, and UniFi forwards only the listed names here.
- The resolver answers listed names itself and never forwards them.
- Invariant: the UniFi FORWARD_DOMAIN list must be a subset of the names in
  this resolver. A name forwarded by UniFi but missing here would bounce between
  UniFi and the resolver.

## Lists to keep in sync

The name list lives in the four `template` blocks of the Corefile (one regex,
identical in each block). The contract test checks that. The UniFi list
(`split_dns_forward.domains` in `homelab-infra`) must be a subset of it.
`tests/harness/dns-exact-resolver-contract-test.sh` checks the rendered manifests.

The list is static. Adding an internal route means editing this list and the
UniFi list by hand, which does not satisfy the PLT-149 lifecycle requirement
(dynamic list derived from the HTTPRoutes). That remains an open item.

## Activation order (never reverse)

1. Merge this root and let it reconcile. Prove the resolver directly on its IP,
   with TYPE65 and TYPE64 queries (macOS dig 9.10 does not query them correctly):
   `dig @10.0.20.194 -t A media.smadja.dev +short` -> `10.0.20.192`
   `dig @10.0.20.194 -t AAAA media.smadja.dev` -> NOERROR, no answer
   `dig @10.0.20.194 -t TYPE65 media.smadja.dev` -> NOERROR, no answer
   `dig @10.0.20.194 -t TYPE64 media.smadja.dev` -> NOERROR, no answer
   `dig @10.0.20.194 -t A example.com +short` -> a non-empty public answer
2. Only then set `enabled = true` for `media.smadja.dev` in `homelab-infra#642`.
3. Check `scripts/plt149/check_expected_records.py target` from LAN and VPN,
   Brave with DoH, and a WAN-down test.

## Rollback

Set `enabled = false` in `homelab-infra#642` (UniFi drops only the FORWARD_DOMAIN
policy). Then revert this root if needed. ExternalDNS A records and TXT ownership
are not touched.

## Limits

- The cluster is powered off at night. Forwarded names do not resolve during
  that window. Declared accepted limitation for PLT-149.
- Single node and single replica: a restart gives a short LAN DNS gap for the
  listed names.
- No ServiceMonitor is declared. Metrics are exposed on the pod (9153) for
  Prometheus through the NetworkPolicy.
