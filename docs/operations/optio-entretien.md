# Optio : entretien automatique des pods (PLT-518)

Le CronJob `optio-secret-sync` (`k8s/applications/platform/optio/secret-sync.yaml`, namespace
`optio`) passe toutes les 15 minutes et fait deux choses dans le même run : resynchroniser les
secrets privés d'Optio et nettoyer les pods d'agents inactifs.
Exploitation : [optio.md](optio.md) — routage privé : [optio-gateway.md](optio-gateway.md) —
prise des tickets : [optio-intake.md](optio-intake.md).

## Ce que fait l'entretien

1. **Secrets** — pour l'utilisateur Optio configuré, écrit dans le magasin chiffré d'Optio
   (portée `user`) `OPTIO_GATEWAY_URL`, `OPTIO_GATEWAY_KEY`, puis `CLAUDE_AUTH_MODE=gateway`
   (écrite en dernier), plus `LINEAR_INTAKE_KEY` si la clé Linear est présente. Une valeur déjà à
   jour n'est pas réécrite ; chaque ligne journalisée vaut `SYNC_STATUS=PASS <NOM> unchanged|written`.
2. **Nettoyage** — une tâche de dépôt (`kind=repo`) arrêtée depuis plus de 2 h sans être `completed`
   (`needs_attention`, `failed`, `cancelled`, `pr_opened`) et sans `recovery_required` passe
   `worktree_state = 'removed'` ; une ligne de pod de dépôt en erreur (`pool=repo`), sans pod ni
   agent actif, de plus de 15 min est supprimée. Optio supprime ensuite le StatefulSet inactif et
   Kubernetes ses volumes (`k8s/infrastructure/security/optio-agents/volume-retention.yaml`).

Un seul run à la fois (`concurrencyPolicy: Forbid`, `backoffLimit: 2`, `activeDeadlineSeconds:
300`) ; il compte hors quota de pods d'agents (PriorityClass `optio-maintenance`), donc des slots
d'agents saturés ne l'arrêtent pas.

## Ce qui est perdu

- **Le travail non poussé** d'une tâche nettoyée : worktree supprimé, pod d'agent arrêté, volumes
  supprimés avec lui. Les commits déjà poussés ne sont pas touchés.
- **La trace** d'une ligne de pod en erreur : la ligne est supprimée de la base, son diagnostic
  disparaît avec elle.
- **Rien** pour une tâche marquée `recovery_required` : elle n'est jamais nettoyée.

## Vérifier le dernier passage

1. Jobs du namespace : `bash scripts/kubectl-ro.sh get jobs -n optio`
2. Journaux du dernier Job (nom `optio-secret-sync-<suffixe>`) :
   `bash scripts/kubectl-ro.sh logs -n optio job/<job>` — attendu : les lignes `SYNC_STATUS=PASS`
   puis `JANITOR_STATUS=PASS released=<n> pruned=<n>`. `SYNC_STATUS=FAIL` : lire le nom de
   l'erreur, jamais de valeur de secret.
3. Horodatage du CronJob : `bash scripts/kubectl-ro.sh get cronjob -n optio optio-secret-sync`
   (`lastScheduleTime`, `lastSuccessfulTime`).
4. Alerte `OptioMaintenanceStale` : aucun run réussi depuis 1 h
   (`k8s/infrastructure/monitoring/prometheus-stack/optio-rules.yaml`).

Seul le dernier Job réussi et les deux derniers échecs sont conservés (`successfulJobsHistoryLimit:
1`, `failedJobsHistoryLimit: 2`) et un Job est supprimé 24 h après sa fin : l'absence de Job ne
prouve donc pas un échec.
