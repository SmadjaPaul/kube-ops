# Optio : limites de capacité (PLT-519)

Ce document fait foi pour le nombre d'agents Optio simultanés sur `homelab` (namespace `optio`, chart
`oci://ghcr.io/jonwiggins/optio` 0.26.4). Exploitation : `docs/operations/optio.md`, tickets : `docs/operations/optio-intake.md`.

## Trois plafonds

| Plafond | Valeur | Où le changer |
|---|---|---|
| Agents simultanés | `OPTIO_MAX_CONCURRENT=10` | `k8s/applications/platform/optio/kustomization.yaml` (patch du Deployment `optio-api`, conteneur `api`) |
| Reprises automatiques par tâche | `OPTIO_MAX_AUTO_RESUMES=3` | idem, même patch |
| Tâches en file, agents par pod du dépôt `kube-ops` | 10 tâches, 5 agents par pod, 2 pods | réglages du dépôt dans l'interface Optio : hors Git (travail privé) |

Le chart 0.26.4 n'expose aucune valeur pour ces deux variables (amont : 5 agents, 10 reprises) : le patch les pose.

## Quotas du namespace `optio` (`k8s/applications/platform/optio/quota.yaml`)

| Objet | Valeur | Portée |
|---|---|---|
| ResourceQuota `optio-agents` | PVC 24, stockage 240 Gi, requêtes CPU 8 et mémoire 24 Gi, limites CPU 40 et mémoire 80 Gi | namespace entier : API, Redis, agents |
| ResourceQuota `optio-agent-pods` | 12 pods | pods **sans** PriorityClass : API (1 pod) + Redis (1 pod) ⇒ **10 pods d'agents** au plus |
| LimitRange `optio-container-defaults` | requêtes 250m / 512Mi, limites 2 CPU / 4Gi par conteneur, PVC 20 Gi au plus | conteneurs et volumes sans valeur explicite |

Le CronJob de maintenance `optio-secret-sync` porte la PriorityClass `optio-maintenance`
(`k8s/infrastructure/security/optio-agents/priorityclass.yaml`) : il ne compte pas dans les 12 pods.
Chaque pod d'agent porte 2 PVC (home, workspace) de 10 Gi : 24 PVC et 240 Gi ⇒ 12 pods de dépôt au plus.

## Ce que consomme un agent

`k8s/applications/platform/optio/values.yaml` ne fixe pas de ressources pour les agents : un conteneur qui
n'en déclare pas retombe sur le LimitRange (250m / 512Mi de requête, 2 CPU / 4Gi de limite). Les réglages
du dépôt `kube-ops` (mémoire 2 à 8 Gi, CPU 0.5 à 4) sont plus larges : 10 agents à 8 Gi = 80 Gi, tout le
quota mémoire du namespace → le pod est refusé. À un agent par pod : 0.75 CPU et 2.3 Gi de requête.

## Lever une limite

1. `k8s/applications/platform/optio/quota.yaml` **avant** `OPTIO_MAX_CONCURRENT` : sinon l'API server
   refuse le pod (`Forbidden: exceeded quota`) et Optio cesse de prendre du travail en silence.
2. `OPTIO_MAX_CONCURRENT` et `OPTIO_MAX_AUTO_RESUMES` dans `k8s/applications/platform/optio/kustomization.yaml`.
3. Les réglages par dépôt (tâches en file, agents par pod) sont dans l'interface Optio : hors de la boucle Git → Argo.
4. `just check` → PR → merge → Argo réconcilie ; retour arrière : revert du commit.

Les volumes d'agents sont supprimés avec leur StatefulSet (PLT-516,
`k8s/infrastructure/security/optio-agents/volume-retention.yaml`) : sans elle le quota de PVC se remplit.

## Surveillance et preuve

`k8s/infrastructure/monitoring/prometheus-stack/optio-rules.yaml` : `OptioAgentVolumesNearlyFull` (75 % des PVC),
`OptioAgentSlotsStuck` (plus de place depuis 3 h). Preuve STATIC : valeurs lues dans Git, cluster non vérifié.
