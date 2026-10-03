# Grafana MCP

Read-only machine interface to the existing Grafana/Prometheus/Loki stack.

## Security contract

- image pinned to Grafana MCP v2.0.0;
- streamable HTTP is authenticated with `MCP_GRAFANA_SERVER_TOKEN`;
- the outbound Grafana credential must belong to a dedicated service account
  with Viewer-only permissions;
- enabled tool groups deliberately exclude admin tools;
- no public HTTPRoute;
- NetworkPolicy restricts callers to the agent-observers namespace;
- the Deployment has no Kubernetes service-account token.

## Activation

This Deployment is staged at zero replicas.

1. In Grafana, create a dedicated service account such as `sre-mcp` with
   Viewer permissions only.
2. Generate one service-account token and store it in Doppler
   `cluster/prd:GRAFANA_MCP_SERVICE_ACCOUNT_TOKEN`.
3. Apply homelab-infra so `GRAFANA_MCP_AUTH_TOKEN` exists.
4. Add `externalsecret.yaml` to this kustomization.
5. Set replicas to 1 in Git.
6. Verify unauthenticated MCP calls fail and authenticated read tools work.

Never give this service account Grafana Admin or Editor solely for SRE RCA.
