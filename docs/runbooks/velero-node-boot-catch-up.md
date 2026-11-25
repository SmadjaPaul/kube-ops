# Velero : rattrapage après un démarrage du nœud (PLT-505)

## Cause

Le nœud homelab est unique. Après un arrêt, Velero lance au démarrage tous les Schedules en retard. Velero 1.18.2 (`pkg/podvolume/backupper.go`) traite alors les volumes ainsi :

| État au moment du backup | Effet sur le volume | Phase du backup |
|---|---|---|
| Pod applicatif pas Running | sauté, avertissement | `Completed` |
| `node-agent` pas Running | sauté, une erreur par pod | `PartiallyFailed` |

`Completed` ne prouve donc pas que les volumes sont sauvegardés.

## Correctif

L'initContainer `wait-node-boot` du Deployment `velero` ([values.yaml](../../k8s/infrastructure/controllers/velero/values.yaml)) retient le serveur jusqu'à 900 s d'uptime du nœud. Tous les Schedules sont couverts. Sur un nœud déjà démarré, il n'attend pas.

Effets attendus pendant les 15 premières minutes : pod `velero` en `Init`, app Argo `infra-controllers` en `Progressing`, ni backup ni restauration.

Restauration urgente dans cette fenêtre : réduire `NODE_SETTLE_SECONDS` par une PR, ou attendre.

Mesure du 25/11 (boot 09:17:07 UTC) : pods à volumes Ready entre le boot et +392 s, un pod à +605 s.

## Limites non couvertes

- Un pod applicatif qui n'est pas Running 900 s après le boot (panne, démarrage lent) : volume sauté, backup `Completed`.
- Un redéploiement d'app ou de `node-agent` pendant un backup planifié : même effet.
- Velero ne relance pas un backup. Le prochain passage du Schedule le remplace.

## Détection (PLT-506)

Alloy compte les avertissements `Skip pod volume … phase=Pending|Unknown` du serveur Velero par Schedule (`loki_process_custom_velero_skipped_pod_volumes_total`). L'alerte `VeleroBackupSkippedVolumes` ([prometheusrule.yaml](../../k8s/infrastructure/controllers/velero/prometheusrule.yaml)) se déclenche à la première valeur. Les pods `Succeeded` ou `Failed` (Jobs finis) sont exclus. Un Schedule sans volume (`velero-daily-databases`) n'émet rien.

L'alerte ne détecte pas :

- un pod absent au moment du backup (réplicas à 0, objet supprimé) : Velero n'émet pas d'avertissement ;
- un volume non demandé (annotation `backup.velero.io/backup-volumes` retirée, volume exclu) ;
- une ligne de log perdue (Alloy arrêté puis recréé avant lecture).

Le compteur est retiré 25 h après le dernier volume sauté, ou au redémarrage d'Alloy.

## Vérifier après un démarrage

```bash
bash scripts/kubectl-ro.sh get backups.velero.io -n velero \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,ERR:.status.errors,WARN:.status.warnings,START:.status.startTimestamp
```

```bash
bash scripts/kubectl-ro.sh get podvolumebackups.velero.io -n velero -l velero.io/backup-name=<backup>
```

PASS : le backup commence au moins 15 minutes après le boot, sans erreur, avec un `PodVolumeBackup` `Completed` pour chaque volume attendu. Comparer avec le backup d'un jour normal du même Schedule.
