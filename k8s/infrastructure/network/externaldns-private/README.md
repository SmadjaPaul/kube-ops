# external-dns-private

Private ExternalDNS controller that watches `Gateway/internal` `HTTPRoute`
resources and synchronises A records into the **UniFi** local DNS for the
`*.smadja.dev` domain.

This controller is part of the **local-first** contract: applications attached
to `Gateway/internal` must resolve on the LAN even when the WAN (and Cloudflare
Tunnel) are down.

## Roles and responsibilities

| Component | Role |
| --------- | ---- |
| `external-dns` controller | Reconciles `HTTPRoute` objects attached to `Gateway/internal`, builds the desired DNS endpoint set, and POSTs every change to the webhook sidecar over HTTP. |
| `external-dns-unifi-webhook` sidecar | Translates external-dns `records` calls into UniFi Integration API calls against `/proxy/network/integration/v1/sites/{siteId}/dns/policies/*`. The webhook listens on `:8080` (`/healthz`) and `:8888` (negotiation endpoint). |

## Source of truth

`HTTPRoute.spec.hostnames` for routes with a `parentRef` to
`gateway/internal` in the `gateway` namespace. Only the `internal` gateway is
considered (`--gateway-name=internal`), so routes that only have `external`
as a parent (`argocd-webhook`, `kubechecks`) are excluded.

The desired IP target is the `Gateway/internal` `LoadBalancer` address. The
records will not resolve correctly until Cilium `l2announcements.enabled=true`
and a `CiliumLoadBalancerIPPool` are configured (Workstream D — separate PR).

## Records managed

Every hostname declared on a HTTPRoute attached to `Gateway/internal` ends up
as an A record in UniFi pointing at the LAN LoadBalancer VIP.

| Currently observed attached routes | 30 (out of 32) |
| ---------------------------------- | -------------- |

The two routes without an `internal` parentRef (`argocd-webhook`,
`kubechecks`) intentionally produce no LAN record.

The TXT registry ownership records are created under the
`externaldns-internal-` prefix so that future public ExternalDNS instances do
not collide with these records.

## UniFi controller

| Setting | Source |
| ------- | ------ |
| `UNIFI_HOST` | Doppler `UNIFI_API` |
| `UNIFI_API_KEY` | Doppler `EXTERNALDNS_UNIFI_API_KEY` *(proposed key, must be added to `infrastructure/prd`)* |
| `UNIFI_SITE` | Doppler `UNIFI_SITE` (default `default`) |
| `UNIFI_VERIFY_SSL` | Doppler `UNIFI_VERIFY_SSL` (do not bypass TLS) |

Required UniFi controller version: **Network ≥ 10.3.58** and **UniFi OS ≥ 5.x**.
The live controller is on Network ≥ 10.5.67 (per `homelab-infra`
`docs/migration/convergence-report.md`), so the provider is supported.

## Argo wiring is automatic

`k8s/infrastructure/network/kustomization.yaml` now includes this directory,
so the existing `infra-network` Application (AppProject `infrastructure`,
which has `*` wildcards for namespaces and resources) reconciles it without
any new AppProject / Application manifest.

The unused `k8s/infrastructure/network/project.yaml` AppProject (legacy
scaffolding) does not need an update — `infra-network` uses
`project: infrastructure`.

## Required pre-flight: Doppler key

The webhook requires **API key** authentication. The current Doppler project
`infrastructure / config prd` only has `UNIFI_USERNAME` / `UNIFI_PASSWORD`
(via `terraform/unifi`). Add a new key:

```
EXTERNALDNS_UNIFI_API_KEY=<integration-api-key>
```

Generate the Integration API key in the UniFi UI under
`Settings → System → Integrations` with at least `DNS policies` scope.

## Rotation path

1. Create a new Integration API key in the UniFi UI.
2. Update `EXTERNALDNS_UNIFI_API_KEY` in Doppler project `infrastructure / prd`.
3. ESO will refresh the Kubernetes Secret within one hour (the `refreshInterval`
   configured on the `ExternalSecret`).
4. The webhook sidecar reads the Secret on every start; rollout the
   `external-dns-private` Deployment to force the new key to take effect
   immediately:
   `kubectl rollout restart deployment/external-dns-private -n external-dns-private`.
5. Revoke the old key in the UniFi UI once the Deployment reports
   `Ready 1/1` and `hubble observe --namespace external-dns-private --verdict DENIED` is empty.

## Test

After Workstream D has enabled Cilium `l2announcements` and an LB IP exists:

```bash
# ExternalDNS logs
kubectl logs -n external-dns-private deploy/external-dns-private -c external-dns --tail=200 -f

# TXT ownership registry
dig @10.0.20.53 externaldns-internal-auth.smadja.dev TXT

# A record resolution through UniFi local DNS
dig @10.0.20.53 auth.smadja.dev A

# UniFi-side view (UI only — Terraform no longer owns app records)
```

Without Workstream D the records still appear in UniFi, but resolve to the
gateway's pending IP, so DNS will return a stale or empty result. This is
expected behaviour.

## Hard rules

- AdGuard stays the LAN DNS cache/filter only. Application records are not
  AdGuard rewrites (see `homelab-infra` INV-DNS-02).
- Terraform in `homelab-infra` must not re-add the static `*.smadja.dev`
  records this controller manages (it owns only `adguard.smadja.dev` and
  `forgejo.smadja.dev` → `10.0.20.53`).
- Secrets only flow through Doppler → ESO. No Helm value, no inline `Secret`,
  no `kind: Secret` in this directory carries the API key.