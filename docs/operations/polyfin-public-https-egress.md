# Polyfin media egress: public IPv4 HTTPS with private-network isolation

## Motivation (PLT-133)

Polyfin 0.60 resolves dynamic Eclipse/Nebula/TorBox music streams and
remote artwork. A resolved TorBox URL can point to a changing public
CDN host and IP. The previous FQDN-by-FQDN Cilium policy required
frequent manual changes and real Brave/Safari playback failed while
Polyfin timed out on an external TCP/443 destination.

## Scope of the change

Only the **active media root** Kustomization adds a sixth egress entry
to `media/CiliumNetworkPolicy/polyfin-pilot`:

- `toCIDRSet` `0.0.0.0/0` excluding RFC1918, CGNAT, localhost,
  link-local, and reserved/documentation/multicast/future ranges.
- `toPorts`: exactly `TCP/443`.
- **No IPv6 allow**, TCP/80, UDP/443, new ingress permissions, or other
  namespace/workload policy changes.
- Existing `media -> kube-dns`, `media -> polyfin-db`, Gateway VIP
  `10.0.20.192:443`, Authentik backend `auth:9000` and named
  explicit FQDN rules remain intact.
- `k8s/applications/media/polyfin/networkpolicy.yaml` is intentionally
  unchanged: it is a protected historical admission fixture with
  four baseline egress rules. The active media root overlays Authentik
  and this public-HTTPS egress instead.

Cilium's documented default behavior is that CIDR selectors do **not**
match Cilium-managed Pod identities. Verify that
`policyCIDRMatchMode` remains at the default and confirm runtime
intra-cluster isolation, especially if this setting is ever changed.

The egress is broad for public HTTPS **and deliberately reduces the
ability of destination allowlists to prevent data exfiltration**.
TCP/443 is not a guarantee of TLS or benign traffic. Existing public
FQDN selectors become redundant for many public destinations, but
are retained to avoid unrelated changes.

## CI/local static qualification

```sh
kustomize build k8s/applications/media > /tmp/polyfin-public-egress-render.yaml
yq -r 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "polyfin-pilot") | .spec.egress | length' /tmp/polyfin-public-egress-render.yaml
# Expected active root count: 6
yq -r 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "polyfin-pilot") | .spec.egress[-1]' /tmp/polyfin-public-egress-render.yaml
# Check all exclusion CIDRs, single TCP/443, and no world:443 or IPv6.
# Historical static gate must remain unmodified:
bash tests/harness/polyfin-private-pilot-contract-test.sh
```

Check that the active CNP selects only `app.kubernetes.io/name:
polyfin`, and that none of the removed/excluded CIDRs are allowed
by the **new** rule. Other explicit existing allows, e.g. Gateway VIP,
remain deliberately additive. Do not confuse CIDR `except` with a
global egress deny across all other rules.

## Runtime acceptance after merge

1. Argo `apps-media` observed/synced/healthy on the **exact merge SHA**.
   Policy `Valid=True`, Cilium endpoint selector only Polyfin.
2. Without credentials or signed URLs in output, test the previously
   failing Brave track. Compare fresh Nebula hostname and observed IP
   with the failing `67.159.44.74:443` timeout; use Hubble verdicts.
3. Verify a **public HTTPS** destination previously unavailable can
   be reached from Polyfin's network namespace; verify **new rule does
   not permit** private/LAN/host/Pod traffic, while approved DB/Gateway/
   Authentik access still works. Do not use a known-approved endpoint
   to test the negative case, as existing allows are additive.
4. Verify real Brave and Safari playback separately: actual sound,
   progression, pause/resume; 302 to CDN and CDN bytes in the client
   wherever direct play is selected. A 200 from the server alone does
   not prove usability or direct play.
5. Confirm favorites and artwork behavior; measure bytes/CPU/RAM/I/O
   where metrics exist, label unmeasured otherwise.
6. Track public egress destinations with **bounded** Hubble metadata.
   Do not log requests, full signed URLs, session tokens or cookies.

## Rollback and caveats

A new PR reverting only this active-root add operation restores the
previous FQDN-only CDN policy. No database, Secret, Service, Deployment,
image or PVC changes are involved.

A connection timeout **may persist** despite allowing public CIDRs
because upstream service, DNS, TCP routing or TLS can fail independently.
Revert/diagnose from evidence; never mask a failure with global
allow-all or by opening private address ranges.

References:
- https://docs.cilium.io/en/stable/security/policy/layer3/
- https://docs.cilium.io/en/stable/security/policy/layer4/
