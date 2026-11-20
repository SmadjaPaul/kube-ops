# Restauration prouvée : namespaces `auth` et `databases`

Runbook de drill (non exécuté à ce jour). Statut de la preuve tant qu'il n'a pas
tourné : `UNPROVEN`. Les schedules `velero-daily-auth` et `velero-daily-databases`
(04h30 et 05h05 UTC, TTL 14 j, location `r2`) existent en Git ; ce drill
prouve que leurs backups sont restaurables.

## Périmètre sauvegardé

| Schedule | Inclus | Exclu |
|---|---|---|
| `velero-daily-auth` | Secrets, ConfigMaps, ExternalSecrets, HTTPRoute, ReferenceGrant, PodMonitor, workloads et PVC Redis (fs-backup Kopia) | tout objet labellisé `cnpg.io/cluster` (pods, PVC data/WAL, Secrets générés par CNPG), CRs `clusters`, `backups`, `scheduledbackups`, `objectstores` |
| `velero-daily-databases` | Secrets, ConfigMaps, ExternalSecrets, CRs `Cluster`, `ScheduledBackup`, `ObjectStore`, CiliumNetworkPolicy | pods, PVC, PV, VolumeSnapshots, CRs `Backup` ; objets `cnpg.io/cluster` ; aucun fs-backup ni snapshot |

Pourquoi aucun volume PG dans Velero : les données PostgreSQL sont déjà protégées
par CNPG/Barman (WAL + base backups sur R2). Une copie Kopia d'un PGDATA vivant
n'est pas cohérente, double le coût R2 et donne une fausse assurance. Le test
statique `velero-storage-tier-test.sh` échoue si `databases` active
`defaultVolumesToFsBackup`/`snapshotVolumes` ou n'exclut plus pods/PVC/PV.
La restauration des données PG se prouve par le drill CNPG existant
(`tests/fixtures/recovery/cnpg-velero-restore.yaml`), pas par celui-ci.

## Règles de sécurité du drill

- Ne jamais restaurer dans `auth` ou `databases` : toujours dans un namespace
  jetable via `--namespace-mappings`.
- Ne jamais restaurer `clusters.postgresql.cnpg.io` ni `scheduledbackups` dans le
  drill : un Cluster restauré démarrerait un `initdb` et archiverait des WAL vers
  le préfixe R2 de production. Les exclure explicitement.
- Exclure aussi `externalsecrets.external-secrets.io` : le drill doit prouver
  que le Secret restauré est lisible par Velero, pas relancer ESO/Doppler.
- Ne jamais afficher de valeur de Secret : comparer des noms de clés et des
  empreintes (`sha256`) produites sans écho, jamais `-o yaml` ni `base64 -d`.

## Procédure

Variables : `NS_DRILL=drill-auth-db-$(date -u +%Y%m%d)`.

1. Choisir les backups : `velero backup get --selector velero.io/schedule-name=velero-daily-auth`
   (idem `-databases`), prendre le dernier en `Completed` sans erreur ni warning
   inattendu. Noter nom et date.
2. Relever la référence côté source, sans valeurs : pour chaque namespace,
   `kubectl -n <ns> get secret -o json | jq -r '.items[] | select(.metadata.labels["cnpg.io/cluster"]==null) | .metadata.name + ":" + (.data|keys|join(","))' | sort > ref-<ns>.txt`
   puis, pour les empreintes, un script local qui ne sort que `nom sha256` par
   Secret (`jq -c '.data' | sha256sum`, jamais la valeur) vers `ref-<ns>.sha`.
3. Restaurer `auth` :
   ```bash
   velero restore create drill-auth-$(date -u +%Y%m%d) \
     --from-backup <backup-auth> \
     --namespace-mappings auth:$NS_DRILL-auth \
     --exclude-resources clusters.postgresql.cnpg.io,scheduledbackups.postgresql.cnpg.io,backups.postgresql.cnpg.io,objectstores.barmancloud.cnpg.io,externalsecrets.external-secrets.io,httproutes.gateway.networking.k8s.io \
     --restore-volumes=true --wait
   ```
   Appliquer le modifier d'isolation PVC (`restore-pvc-isolation`, voir
   `k8s/infrastructure/controllers/velero/restore-pvc-isolation.yaml`) pour
   retirer `volumeName` et l'annotation de tracking Argo ; ajouter le namespace
   du drill à ses conditions si besoin. Mettre les workloads à 0 réplica (ou
   exclure `deployments,statefulsets`) : on prouve les objets, pas le service.
4. Restaurer `databases` :
   ```bash
   velero restore create drill-databases-$(date -u +%Y%m%d) \
     --from-backup <backup-databases> \
     --namespace-mappings databases:$NS_DRILL-db \
     --exclude-resources clusters.postgresql.cnpg.io,scheduledbackups.postgresql.cnpg.io,externalsecrets.external-secrets.io \
     --restore-volumes=false --wait
   ```
5. Comparer au relevé de l'étape 2 (mêmes commandes sur le namespace du drill).
6. Nettoyer : `kubectl delete ns $NS_DRILL-auth $NS_DRILL-db`, puis
   `velero restore delete` des deux restores. Vérifier qu'aucun PVC/PV résiduel
   ne reste (`kubectl get pvc,pv | grep $NS_DRILL`).

## Critères de réussite (tous requis)

1. Les deux restores finissent en `Completed` : `errors: 0`, aucun `PartiallyFailed`.
2. Secrets : mêmes noms et mêmes clés que la référence, hors Secrets `cnpg.io/cluster`
   (nombre égal, écart = échec) ; empreinte par Secret identique.
3. `databases` : les CRs `Cluster`, `ScheduledBackup`, `ObjectStore` sont
   présents dans le backup (`velero backup describe --details` ou
   `velero backup download` + liste), même s'ils ont été exclus à la restauration ;
   l'`ObjectStore` restauré référence le même bucket/prefix que Git.
4. `databases` : zéro PodVolumeBackup et zéro VolumeSnapshot pour ce backup
   (`kubectl -n velero get podvolumebackup -l velero.io/backup-name=<backup-databases>` vide).
5. `auth` : si le PVC Redis est restauré, il est `Bound` avec les données
   attendues ; aucun PVC `authentik-postgresql-restored-*` n'apparaît.
6. Aucune ressource du drill ne parle à la production : pas de Cluster CNPG
   créé, aucun nouveau WAL/objet sous les préfixes R2 de prod pendant la fenêtre
   (comparer le dernier WAL archivé avant/après).
7. Le namespace du drill et ses restores sont supprimés ; l'audit
   (`scripts/backup-audit.sh`) ne remonte pas de résidu de restauration.

## À consigner

Dans `k8s/infrastructure/controllers/velero/restore-drills/` (format du drill
`2026-09-30-pocket-tts.md`) : noms des backups, durée, résultat de chaque critère,
écarts. Ne jamais y consigner de valeur de Secret. Tant que ce fichier n'existe pas
pour `auth` et `databases`, ne pas retirer ces Secrets de Doppler.

## Hors périmètre

- Restauration des données PG : drill CNPG/Barman.
- Reprise applicative d'Authentik (login OIDC) : non prouvée par ce drill.
