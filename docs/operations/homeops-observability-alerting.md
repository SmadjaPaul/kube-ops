# HomeOps observability: rollout and alert-delivery gates

## Current state verified in Git (2026-10-10)

- kube-prometheus-stack 88.3.0: alert rules are enabled; **no Alertmanager receiver override is declared in `prometheus-stack/values.yaml`**. Its upstream chart default receiver is `null`. Treat notifications as **NOT PROVEN**, even if Grafana shows firing alerts.
- The most recent operator report counted **43 firing alerts, zero critical**. Do not connect an unfiltered receiver until warnings are classified and grouping/inhibition have been reviewed; avoid an alert storm.
- Blackbox, Velero, CNPG, Argo orphan and Kubernetes mixin rules already exist. Do not duplicate them.
- `prometheus.prometheusSpec.storageSpec` is absent in Git; upstream default is emptyDir (non-durable across Pod re-creation). Confirm the **live** Prometheus StatefulSet and volume before planning any PVC change.
- `Loki` is a single monolithic instance backed by `longhorn-bulk` on the HDD tier. Alloy is one Deployment using Kubernetes API pod logs and Kubernetes events, not node-file reading.

## HomeOps dashboards (provisioned by the Grafana dashboard sidecar)

- `HomeOps — Operations Overview`: node Ready, alerts firing, synthetic checks, Argo health, PVC pending/usage, cluster CPU/RAM, failing scrapes. No hardware telemetry is inferred.
- `HomeOps — Logs & Collection Cost`: Loki per-namespace bytes/s and lines/s, Kubernetes event throughput, Loki+Alloy CPU/RAM. Existing `source=kubernetes` / `source=kubernetes-events` labels and the existing Loki datasource are reused.
- `HomeOps — Boot, CPU & Guest I/O`: continue using for cAdvisor, Prometheus cost and guest virtual disks.

Dashboard queries run when viewed; refresh is 1m for Overview and 2m for Logs. Validate datasource variable `DS_LOKI` against the actual Grafana instance after Argo reconciliation. A *No data* panel is **not** proof of zero errors or a healthy system.

## Alertmanager → ntfy activation contract (intentionally **not** deployed yet)

We should use the upstream, built-in ntfy template `?template=alertmanager`, not a custom bridge. Do not configure an anonymous publisher, an admin token or a public unauthenticated webhook.

Activation requires the following **preflight** from a trusted operator:

1. Read the live Alertmanager configuration (with any credentials redacted). Ensure no effective receiver is already provided via `AlertmanagerConfig` or out-of-band configuration. Inventory **43 currently firing warnings** and triage/silence non-actionable ones before turning on delivery.
2. Confirm ntfy is healthy, reachable from monitoring network, and that a phone/browser subscriber actually receives messages. Ntfy has `NTFY_AUTH_DEFAULT_ACCESS=deny-all`; do not assume an open topic.
3. Create a **non-admin** `alertmanager-publisher` account in ntfy. Restrict it with ntfy topic ACLs to **write-only** `homeops-critical` and `homeops-warning`; create a publisher token, save it exclusively in Doppler, and never put it in a PR or message. The ntfy CLI supports `ntfy user add`, `ntfy access` and `ntfy token add`. Check for existing users to avoid replacing passwords.
4. In Git, create an ESO `ExternalSecret` in `monitoring` for the token; include its Secret name under `alertmanager.alertmanagerSpec.secrets`. Alertmanager webhook `http_config.authorization.credentials_file` must point to the mounted token file. Avoid interpolating the token into Helm values or URLs.
5. Extend the existing ntfy CiliumNetworkPolicy **only** for the Alertmanager pod selector / monitoring namespace on TCP/8080, after verifying source labels. The configured ingress currently permits the Gateway/host but **not** an Alertmanager pod.
6. Preserve the upstream Alertmanager inhibition and null Watchdog route, then route `severity=critical` to the critical topic and an intentionally **curated**, deduplicated subset of warnings to warning topic. Keep repeat intervals long. Use the internal Service address `http://ntfy.ntfy.svc.cluster.local/homeops-critical?template=alertmanager` to avoid public ingress; do not expose additional services.
7. Test end to end from a synthetic **test alert** with short TTL, verify **firing and resolved** notifications and Alertmanager HTTP response, verify unauthenticated publisher cannot publish, then remove the synthetic alert. Check no existing alerts storm the phone. Only then merge/activate this receiver.

Official contracts:
- https://docs.ntfy.sh/publish/#message-templating
- https://docs.ntfy.sh/config/#access-control
- https://prometheus.io/docs/alerting/latest/configuration/

**This dashboard PR adds no Alertmanager credentials or receiver: it is safe to reconcile before this activation.**

## Prometheus persistence: migration gate

No `storageSpec` is declared. Before modifying the StatefulSet:
- Capture live volume type, retention flags, actual TSDB disk usage and safe available capacity on `longhorn-fast`.
- Choose a bounded persistent PVC and retention size with operator approval; verify existing data migration or explicitly accept history loss.
- The in-cluster TSDB is not DR; preserve original historic data expectations and avoid deleting the old volume casually.
- Validate Prometheus rules, scrapes, compaction and alerting after the migration. No PVC migration is authorized by this document.

## Pending hardware / availability

- Physical Proxmox `node_exporter` and temperatures remain gated on host-owner approval (#408). Do not attribute Talos virtual `sd*` disk I/O to physical HDDs.
- For a full cluster outage, use an external N100/Uptime Kuma probe and an out-of-cluster notification path. Alertmanager and ntfy sharing this Kubernetes runtime cannot page during complete cluster failure.

## Rollout acceptance

1. `just check` and GitHub CI PASS.
2. Argo `infra-monitoring` Synced/Healthy at the merged SHA.
3. Grafana dashboard sidecar recognizes both new ConfigMaps; Overview panels render and Loki datasource resolves.
4. Grafana SSO, existing dashboards, Prometheus scrapes and KPS default alerts unchanged.
5. Confirm before claiming delivery: `ALERTS` existence != Alertmanager-to-ntfy success.
