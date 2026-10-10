# Alertmanager → ntfy: scoped critical-only activation

## Status

**DRAFT — DO NOT MERGE UNTIL TOKEN EXISTS AND THE NTfy ACL/NETWORK PREFLIGHT PASS.**

This PR stages the smallest supported integration. It changes only:
- the kube-prometheus-stack Alertmanager Helm receiver configuration;
- an ExternalSecret for a scoped ntfy token;
- ntfy's existing CiliumNetworkPolicy ingress selector;
- Helm Kustomize inclusion.

Existing 43 firing warnings are intentionally **not** delivered. The `null` receiver remains the default; only `severity=critical` is routed to `homeops-critical`. The `Watchdog` alert remains null. Default upstream inhibition is preserved. Once critical notifications work, curate selected actionable warnings in a **separate PR**.

## Prerequisites (operator with live cluster and Doppler access)

1. Confirm `ntfy` is Ready, `NTFY_AUTH_DEFAULT_ACCESS=deny-all`, subscription access works for the intended phone, and its auth database survives redeployment. Do not change the existing admin's password or privilege.
2. Check the user `alertmanager-publisher` does not already exist. Create only when absent, using the ntfy server-side CLI with its configured `NTFY_AUTH_FILE=/var/lib/ntfy/auth.db`. This is a regular (non-admin) user. Avoid leaving a reusable plaintext password in shell history/logs.
3. Restrict the publisher to **write-only** topic `homeops-critical`. Example **run inside the ntfy container**, with the correct auth-file environment:

   ```sh
   ntfy access alertmanager-publisher homeops-critical write
   ntfy access alertmanager-publisher
   ```

   Verify no global or wildcard access. Ntfy **access tokens inherit the user's ACL**; ntfy currently has no per-token ACL. Never reuse an admin token. See https://docs.ntfy.sh/config/#access-control-list-acl
4. Create a publisher token with `ntfy token add --label=alertmanager alertmanager-publisher`. Store the token **directly in Doppler**, `cluster/prd:APP_ALERTMANAGER_NTFY_PUBLISHER_TOKEN`, without putting it in chat, GitHub, terminal logs or URL. If token rotation is configured, ensure the replacement token is also synchronized before revocation.
5. Confirm the Alertmanager pod has labels `app.kubernetes.io/name=alertmanager` and Cilium's source namespace identity `monitoring`, and that `ntfy` receives traffic on TCP/8080 from the monitoring namespace. Network traffic uses the internal Kubernetes Service `ntfy.ntfy.svc.cluster.local:80` (service targetPort 8080), never the public hostname.
6. Inspect the **loaded**, effective Alertmanager config and check for other receiver sources such as `AlertmanagerConfig`. Review critical alerts already firing, plus 43 warnings (which are not forwarded). Do not silently change out-of-band managed config.

## Merge & rollout sequence

- CI/just check must pass on PR HEAD, and pinned chart `88.3.0` must render.
- Token must exist in Doppler **before merging this PR**. There is no permission to relax ntfy auth or expose a public topic.
- Merge PR. After Argo reconciliation, verify `ExternalSecret` **Ready** and Secret `alertmanager-ntfy-publisher` has key `token`, **without printing its value**. Alertmanager Operator mounts Secret at `/etc/alertmanager/secrets/alertmanager-ntfy-publisher/token`.
- Confirm Alertmanager pods Ready, config reload successful, and `alertmanager_config_last_reload_successful=1` (if exposed) or equivalent loaded-config check with credentials redacted. Verify the `ntfy-critical` webhook is present. Verify default receiver remains `null`.
- Do a direct **authorized** ntfy publish test from within the permitted network path with a synthetic test message. Test **unauthenticated** publish is denied. Do not log tokens.
- Inject one short-lived synthetic test alert with `severity=critical` through the Prometheus/Alertmanager normal ingestion path. Verify phone gets FIRING, then RESOLVED after expiration. Remove the test rule and ensure no residual alerts. A successful direct publish alone is not E2E alerting.
- Check `alertmanager_notifications_failed_total` and alert deliveries/suppression; ensure no webhook 401/403/timeouts. If any fail, revert the receiver change; do not expose topics publicly.
- Link the receiving subscription to a human with authenticated **read** rights; the publisher's write-only ACL cannot subscribe to read the topic.

## Security and availability caveats

- Alerts sent in HTTP POST bodies are **cleartext inside Kubernetes**, protected by namespace/Cilium policy. Use the internal Service; review whether messages contain sensitive annotations. If transport confidentiality is a requirement, configure verified TLS without relaxing certificate validation.
- This is **not** independent host supervision. Prometheus + Alertmanager + ntfy all reside in Kubernetes, so a Talos/Proxmox outage stops the pipeline. Keep external N100/Uptime Kuma alerting independent.
- Unattended running after a failed storage/Secret reconciliation is not acceptable; monitor Argo and alertmanager health.
- If ntfy is down, webhook sends will retry only according to Alertmanager's own retry semantics. This is not durable independent paging.
- Do **not** change Prometheus emptyDir TSDB, Loki storage, Proxmox, or unrelated scrape intervals in this PR.

## Expected facts after E2E

```text
NTFY_PUBLISHER_ACL=WRITE_ONLY_HOMEOPS_CRITICAL
NTFY_SECRET=READY
ALERTMANAGER_CONFIG=LOADED
ALERTMANAGER_DEFAULT_RECEIVER=NULL
ALERTMANAGER_CRITICAL_RECEIVER=NTFY
ALERTMANAGER_FIRING_E2E=PASS
ALERTMANAGER_RESOLVED_E2E=PASS
ALERTMANAGER_WARNINGS_SILENT=PASS
OUT_OF_CLUSTER_MONITORING=SEPARATE
```
