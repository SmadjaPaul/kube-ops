# Egress d'un pod qui échoue : quel flux, quel DNS ?

Question : « pour le pod X, quel flux a été refusé, quel DNS a échoué ces N dernières minutes ? ».

## 1. Une commande (lecture seule)

```bash
bash scripts/egress-why.sh media aiostreams --since 30m
bash scripts/egress-why.sh media aiostreams --since 330m --end 2026-11-21T23:00:00Z
```

Le script interroge Prometheus et Loki du cluster via `kubectl-ro.sh get --raw` (9 requêtes, pas de port-forward, pas de jeton Grafana) et imprime des agrégats : erreurs applicatives par type, minutes en rafale, timeouts FQDN de cilium-agent, attentes du verrou DNS par `dnsName`, drops Hubble par raison, rcodes DNS en erreur, réponses DNS retenues plus d'une seconde, événements Hubble perdus.

## 2. Lecture

| Signal | Interprétation |
| --- | --- |
| `name-lock waits` contient un hôte appelé par l'app, à la minute d'une rafale | La réponse DNS est sortie du proxy avant que l'IP soit dans la map toFQDNs (`Timed out waiting for datapath updates`) : premiers SYN refusés, `ETIMEDOUT`/`fetch failed` côté app. Problème Cilium, pas l'amont. |
| `dns errors` (SERVFAIL) non nul aux mêmes minutes | Résolution amont ou CoreDNS : lire les logs `container="coredns"`. |
| `POLICY_DENIED` en hausse sans timeouts FQDN | FQDN absent de la CiliumNetworkPolicy : vérifier la liste `toFQDNs` dans Git. |
| Rien de tout cela | L'amont est en cause (TLS, 5xx, lenteur) : logs applicatifs. |

Les métriques `hubble_*` n'ont pas de label de pod (nœud entier). La preuve par flux reste `bash .agents/skills/cilium-hubble/scripts/hubble-check.sh <ns>` (port-forward, identité dédiée).

## 3. Requêtes utiles (Grafana local ou Cloud pour les logs)

```logql
sum by (dnsName) (count_over_time({namespace="kube-system",container="cilium-agent"} |= "Name lock acquisition" | logfmt [30m]))
sum(count_over_time({namespace="kube-system",container="cilium-agent"} |= "Timed out waiting for datapath updates" [1m]))
```

```promql
sum by (reason) (increase(hubble_drop_total[30m]))
sum(increase(cilium_proxy_upstream_reply_seconds_bucket{scope="dataplaneTime",le="+Inf"}[30m])) - sum(increase(cilium_proxy_upstream_reply_seconds_bucket{scope="dataplaneTime",le="1.0"}[30m]))
```

Grafana Cloud reçoit les logs cilium-agent mais aucune métrique `hubble_*`/`cilium_*` : les requêtes PromQL ci-dessus ne marchent que sur le Prometheus local.

## 4. Pour une attribution par pod (proposition, non appliquée)

Valeurs Cilium à évaluer (cardinalité bornée par `labelsContext`, cluster mono-nœud) :

```yaml
hubble:
  metrics:
    enabled:
      - dns:labelsContext=source_namespace,source_workload
      - drop:sourceContext=workload-name|reserved-identity;destinationContext=dns|ip;labelsContext=source_namespace,source_workload
      - flow:labelsContext=source_namespace,source_workload
      - tcp
      - port-distribution
  export:
    static:
      enabled: true
      filePath: /var/run/cilium/hubble/events.log
      allowList:
        - verdict: [DROPPED, ERROR]
      fieldMask: [time, source.namespace, source.pod_name, destination.namespace, destination.pod_name, destination_names, IP.destination, l4, verdict, drop_reason_desc, is_reply]
    fileMaxSizeMb: 10
    fileMaxBackups: 3
```

L'export fichier exige qu'Alloy lise `/var/run/cilium/hubble/events.log` sur l'hôte (montage hostPath en lecture seule) et l'envoie dans Loki avec `source="hubble"` ; `egress-why.sh` pourrait alors agréger `destination_names` et `drop_reason_desc` pour le pod demandé.
