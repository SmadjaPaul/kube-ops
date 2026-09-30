---
title: Local-first access and private DNS
description: Canonical contract for LAN-first service access, public Cloudflare exposure, and GitOps-managed private DNS.
---

# Local-first access and private DNS

The homelab is local-first: a WAN outage must not make self-hosted applications unreachable from the LAN merely because their normal public path uses Cloudflare.

## Ownership

`homelab-infra` owns the physical LAN, UniFi, DHCP/firewall policy, and the network capability Kubernetes consumes. It does not own application hostnames.

`kube-ops` owns application exposure through Gateway API. Application DNS follows the same desired state so adding or removing a user-facing application does not require an application-specific infrastructure change.

## Exposure classes

| Class | Gateway API | Private DNS | Public edge |
| --- | --- | --- | --- |
| Cluster only | No HTTPRoute | None | None |
| LAN only | `internal` | Yes | No attached external route |
| LAN and remote | `internal` + `external` | Yes | Cloudflare wildcard tunnel |
| Remote only | `external` only | No | Cloudflare wildcard tunnel |

User-facing self-hosted applications should normally attach to the `internal` Gateway. Attaching to `external` is an explicit additional capability, not the default.

Backend-only services such as databases, Redis, and vector stores should use Kubernetes Services directly unless an operator-facing route has a demonstrated need.

## Private DNS target

The target private DNS flow is:

```text
HTTPRoute
  -> Gateway/internal
  -> private ExternalDNS
  -> UniFi local DNS
  -> internal Gateway VIP
```

Private ExternalDNS must derive names from Gateway API desired state and select only routes attached to `Gateway/internal`. This keeps application hostnames in `kube-ops`.

The public flow remains:

```text
public *.smadja.dev
  -> Cloudflare DNS
  -> Cloudflare Tunnel
  -> Gateway/external
```

The same FQDN can therefore resolve to the internal Gateway on the LAN and to Cloudflare from the Internet.

## Internal Gateway

The internal Gateway needs a stable, LAN-reachable address. The target implementation uses upstream Cilium primitives:

- LoadBalancer IPAM for a bounded LAN address pool;
- L2 announcement for the internal Gateway address;
- Gateway API listeners for required HTTP/TCP protocols.

The concrete address and pool must be selected from live network evidence. Do not guess or hard-code an unverified free address.

## UniFi and AdGuard

UniFi is the target local DNS data plane for application records synchronized from Kubernetes.

AdGuard remains useful for DNS filtering and caching, but application-specific DNS rewrites must not become a second application registry. Legacy rewrites may remain during migration and are removed only after the private ExternalDNS path is proven.

## Offline contract

A WAN outage should preserve:

- local DNS for self-hosted applications;
- TLS to the internal Gateway;
- Authentik login for applications using local OIDC;
- access to local application data;
- Home Assistant and local automation paths.

Features that inherently require external services can still degrade, such as SaaS LLM calls, Internet search, external SMTP, or third-party cloud APIs.

## Migration gates

Do not remove an existing external route merely to make a service private until the replacement LAN path has been proven.

The migration order is:

1. prove a stable internal Gateway VIP;
2. prove private ExternalDNS writes the expected UniFi records;
3. prove LAN TLS and Authentik callbacks using the normal FQDN;
4. prove representative applications on LAN;
5. only then remove unnecessary external Gateway attachments;
6. run an offline/WAN-loss acceptance test.

DNS is discovery and routing. The security boundary remains Gateway attachment, application authentication, and network policy.
