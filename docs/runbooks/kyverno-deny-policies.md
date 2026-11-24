# Politiques d'admission en Deny et retour arrière

Tout le reste de `platform-baseline` est en `Audit` (cliquet `policy/baseline.tsv`). Les seules règles qui refusent à l'admission :

| Politique | Fichier | Cible | `failurePolicy` | Exceptions |
| --- | --- | --- | --- | --- |
| `platform-baseline-no-privileged` | `k8s/infrastructure/security/policies/platform-baseline.yaml` | Pods avec `privileged: true` (conteneurs, init, éphémères) | `Ignore` | namespaces système (`kube-system`, `kyverno`, `monitoring`, `kubearmor`, `security-system`, `gatekeeper-system`, `kube-node-lease`, `kube-public`), `csi-proxmox`, `longhorn-system` |
| `platform-baseline-no-loadbalancer` | idem | Services `type: LoadBalancer` | `Ignore` | namespaces système, `gateway/cilium-gateway-*`, `dns-exact-resolver/dns-exact-resolver`, `media/qbittorrent-mam-peer` |
| `eso-k8s-store-guard` | `.../policies/eso-k8s-store-guard.yaml` | ExternalSecrets lisant un store Kubernetes hors de leur namespace | `Ignore` | voir le fichier |
| `preview-namespace-guard` | `k8s/infrastructure/previews/admission-policy.yaml` | Namespaces `smadja.dev/preview=true` seulement | `Fail` | aucune (portée limitée par `namespaceSelector`) |
| `deny-loadbalancer-service` (ValidatingAdmissionPolicy) | `k8s/clusters/oracle-a1/guardrails/deny-loadbalancer-service.yaml` | Services LoadBalancer sur OKE | `Fail` | voir le fichier |
| `agent-operator-guard` (ValidatingAdmissionPolicy) | `k8s/infrastructure/security/agent-operator/validatingadmissionpolicy.yaml` | Écritures de l'identité agent-operator | `Fail` | n/a |

`failurePolicy: Ignore` : une panne de Kyverno n'arrête pas le cluster (l'admission passe). `Fail` n'est utilisé que là où la portée est étroite.

## Retour arrière [Audit]

1. PR d'une ligne par politique : `validationActions: [Deny]` devient `[Audit]` (pour une VAP, `validationActions: [Warn, Audit]` dans le Binding).
2. `bash scripts/policy-check.sh --tests` doit rester vert (les cas de test couvrent le rejet via `tests/policies/`).
3. Merge, puis vérifier la synchro Argo de l'Application qui porte `k8s/infrastructure/security` : `bash scripts/kubectl-ro.sh get validatingpolicies.policies.kyverno.io`.
4. Les violations apparaissent ensuite dans les rapports de politique (`policyreports`), plus au refus.

Retour arrière sans PR (urgence, bloquant la prod) : geste de Paul (écriture), pas d'un agent.

## Ajouter une exception

Éditer la `matchCondition` `not-explicit-exception` (ou la liste de namespaces) de la politique, ajouter un cas `skip` dans `tests/policies/gen-tests.py`, régénérer (`python3 -I tests/policies/gen-tests.py`), puis `just policy-check`.
