---
name: cilium-hubble
description: Check whether Cilium network policy drops traffic for a namespace or between two workloads ("is X blocked?", "why can't app A reach app B?").
---

# Cilium policy drops

1. Read the CiliumNetworkPolicy of the source and destination namespaces in Git. Every application namespace is default-deny ingress and egress: look for the missing egress rule on the source side and the missing ingress rule on the destination side.
2. Compare with the cluster: `bash scripts/kubectl-ro.sh get ciliumnetworkpolicies -n <ns>` and `bash scripts/kubectl-ro.sh get ciliumendpoints -n <ns>` (policy enforcement state per endpoint).
3. Measure drops in Prometheus through `bash scripts/kubectl-ro.sh get --raw` on the monitoring query API: `sum by (reason) (rate(hubble_drop_total[5m]))`. A rise of `POLICY_DENIED` that matches the failure is evidence. These metrics carry no namespace label by default: they show that drops exist, not which pair.
4. Per-flow proof: `bash scripts/kubectl-ro.sh hubble observe --namespace <ns> --verdict DROPPED --last 100` or, for several namespaces, `bash .agents/skills/cilium-hubble/scripts/hubble-check.sh <ns>...` (agent identity `agent-operator`, PRD-88; needs the local `hubble` CLI). Filters: `--[from-|to-](namespace|pod|workload|ip|port|label|service|fqdn|identity)`, `--node-name`, `--protocol`, `--type`, `--verdict`, `--traffic-direction`, `--since`, `--until`, `--last` (≤ 1000), `-o compact|dict|json|jsonpb|table`, `--not`, `--print-node-name`, `--print-policy-names`; anything else is refused (exit 64). Example, ha-mcp to Home Assistant: `bash scripts/kubectl-ro.sh hubble observe --from-namespace home-assistant --from-workload ha-mcp --to-ip 10.0.20.60 --to-port 8123 --last 50`. Exit 2 means the tunnel or the identity failed: report the flow verdict as `NOT_PROVEN` with that reason.

Preuve par workload sans port-forward (PRD-88, lecture seule, identité `agent-operator`) : les métriques `hubble_flows_processed_total` et `hubble_drop_total` portent `source_namespace` et `source_workload` (PLT-411). Les deux requêtes ci-dessous passent par `kubectl-ro.sh get --raw` (PromQL encodé en `%XX`, par exemple avec `python3 -c 'import sys,urllib.parse as u;print(u.quote(sys.argv[1],safe=""))' '<promql>'`) :

- `sum by (type,verdict) (hubble_flows_processed_total{source_namespace="<ns>",source_workload="<workload>"})` : `PolicyVerdict` FORWARDED prouve que la politique a laissé passer des flux du workload ; `DROPPED` avec `increase(...[10m])` à 0 prouve l'absence de drop récent.
- `hubble_drop_total{source_namespace="<ns>",source_workload="<workload>"}` : label `destination` (nom DNS) et `reason`.

Limite : ces séries n'ont ni IP ni port de destination (hors `destination` des drops). Elles ne prouvent donc ni « workload A vers IP:port B FORWARDED » ni l'IP source après SNAT : pour un flux précis, utiliser `kubectl-ro.sh hubble observe` (étape 4), qui montre l'IP et le port de destination, le verdict et, avec `--print-node-name`, le nœud (l'IP source vue par la destination après SNAT reste celle du nœud). À défaut, recouper avec les logs du client (ex. `ha-mcp` : « WebSocket connected and authenticated » vers 10.0.20.60:8123 = flux établi, niveau RUNTIME) ; sinon `NOT_PROVEN`.

A zero drop rate does not prove that a namespace's traffic flows: it needs evidence that covers the investigated pair, such as a successful request from the source workload to the destination in application logs. Without it, report `NOT_PROVEN`.

## Egress d'un pod qui échoue (ETIMEDOUT, fetch failed)

Commencer par le résumé pré-agrégé, une seule commande, une trentaine de lignes : `bash scripts/egress-why.sh <namespace> <container> [--since 30m] [--end RFC3339]`. Lecture et interprétation : `docs/runbooks/egress-why.md`.
