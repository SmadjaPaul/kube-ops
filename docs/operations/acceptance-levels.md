# Acceptance levels

| Level | Evidence | Does not prove |
|---|---|---|
| STATIC | Kustomize render, strict Kubernetes schema, repository policy, backup contract | live reconciliation |
| RECONCILED | Argo desired revision, Synced state, controller conditions | user reachability |
| RUNTIME | ready workload/endpoints, HTTPRoute, UniFi DNS, valid TLS, dependencies | login/business action |
| USER | real browser/API journey with intended auth and durable action | disaster recovery |

User-facing apps require USER evidence. Stateful apps additionally require backup coverage and at least one isolated restore proof before data becomes critical.
