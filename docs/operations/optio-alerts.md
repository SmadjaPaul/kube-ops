# Optio : alertes de capacité (PLT-517)

Règles : `k8s/infrastructure/monitoring/prometheus-stack/optio-rules.yaml` (PrometheusRule `optio-capacity`,
namespace `monitoring`). Les trois sont `severity: warning` : visibles dans Prometheus et Alertmanager,
sans notification (receiver `null`, voir [alert-runbooks.md](alert-runbooks.md)).

Repères du namespace `optio` (`k8s/applications/platform/optio/quota.yaml`) : 24 PVC (240 Gi) et 12 pods
sans PriorityClass — `optio-api` et Redis en occupent 2 ; le CronJob de maintenance est hors quota
(PriorityClass `optio-maintenance`). Un pod d'agent garde 2 PVC (home, workspace) de 10 Gi.

## OptioAgentVolumesNearlyFull

- **Sens** : au moins 75 % des 24 PVC du quota (18) sont pris depuis 30 min — l'alerte compte les PVC,
  pas l'espace. À 24, plus aucun pod d'agent ne démarre : ses PVC ne peuvent plus être créés.
- **Cause probable** : des pods d'agent inactifs gardent leurs StatefulSet et leurs volumes. Le janitor
  PLT-516 ne libère qu'une tâche de dépôt arrêtée depuis 2 h à l'état `needs_attention`, `failed`,
  `cancelled` ou `pr_opened` : un travail actif ou récent garde ses volumes. Sinon la rétention
  (`whenDeleted: Delete`) n'a pas été appliquée et les volumes survivent à leur StatefulSet.
- **Première vérification** : `bash scripts/kubectl-ro.sh get resourcequota optio-agents -n optio -o yaml`
  (`used`/`hard`), puis `bash scripts/kubectl-ro.sh get pvc -n optio` (nombre et âge) et
  `get statefulsets -n optio -l managed-by=optio` (les agents qui les tiennent).

## OptioAgentSlotsStuck

- **Sens** : les 12 places du quota de pods sont prises depuis 3 h. Aucun pod ne démarre plus dans le
  namespace : Optio ne prend plus de ticket, en silence.
- **Cause probable** : des pods d'agent ne sont pas libérés (le janitor du CronJob de maintenance n'a pas
  tourné, ou la tâche de dépôt est encore active). Le quota est global au namespace : `optio-api`, Redis
  et les pods de Job y comptent aussi.
- **Première vérification** : `bash scripts/kubectl-ro.sh get pods -n optio` (qui tient une place, depuis
  quand), puis `bash scripts/kubectl-ro.sh get resourcequota optio-agent-pods -n optio -o yaml`.

## OptioMaintenanceStale

- **Sens** : le CronJob `optio-secret-sync` (toutes les 15 min) n'a pas réussi depuis plus d'une heure.
  La clé privée de la passerelle et la clé d'intake Linear ne sont plus rafraîchies, et le janitor PLT-516
  ne libère plus ni pods ni volumes : c'est la cause amont des deux alertes ci-dessus.
- **Cause probable** : le Job échoue (`SYNC_STATUS=FAIL`) : variable d'entrée vide, base
  `pg-shared-homelab` injoignable, table interne absente de l'image épinglée. Ou le pod ne démarre pas
  (Secret d'entrée manquant : `optio-llm`, `optio-db`, `optio-app`), le CronJob est suspendu, ou le Job
  précédent bloque le suivant (`concurrencyPolicy: Forbid`, `activeDeadlineSeconds: 300`).
- **Première vérification** : `bash scripts/kubectl-ro.sh get cronjob optio-secret-sync -n optio -o yaml`
  (`lastScheduleTime`, `suspend`), `bash scripts/kubectl-ro.sh get jobs -n optio`, puis
  `bash scripts/kubectl-ro.sh logs -n optio job/<job>` : `SYNC_STATUS=FAIL` ou `JANITOR_STATUS=PASS`.

Limite (OptioMaintenanceStale) : un CronJob qui n'a jamais réussi n'a pas de série, l'alerte reste
muette ; vérifier alors `lastScheduleTime` et les Jobs. Jamais de valeur de secret affichée.
Contexte : [optio.md](optio.md), [intake Linear](optio-intake.md).
