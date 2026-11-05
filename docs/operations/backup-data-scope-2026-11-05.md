# PLT-56 — matrice de données et contrat de sauvegarde (audit I/O 2026-11-05)

> Capture de référence : 5 novembre 2026, à partir d’une collecte live locale non versionnée et de l’audit I/O [plt-io-audit-2026-11-05.md](https://github.com/SmadjaPaul/homelab-infra/pull/235) récupéré du worktree précédent (`c667dc6`). Cette matrice décrit la décision de périmètre; elle ne supprime aucune source ni sauvegarde.

## Décision

La cible est de protéger les données importantes une seule fois par un mécanisme vérifiable : CNPG/Barman pour PostgreSQL, Velero/Kopia pour les fichiers applicatifs persistants non couverts autrement. Longhorn reste uniquement une protection explicite transitoire pour les volumes déjà qualifiés; le groupe global `default` est retiré. Les caches, logs, métriques, index, téléchargements, partage média reproductible et données GitOps sont exclus explicitement ou marqués `rebuildable`.

## État du périmètre

- 95 PVC observés : 85 Bound, 10 Pending; 82 Longhorn, 13 Proxmox CSI.
- L’audit corrigé corrèle désormais les schedules Velero avec `includedNamespaces` et `labelSelector`/`orLabelSelectors`, en considérant les labels des PVC et des pods qui les montent. Le ratio PLT-56 de référence est **31/50 PVC hors CNPG vérifiés**; les claims CNPG sont évalués séparément par la ligne Barman (12/12 clusters configurés) et ne doivent pas être comptés comme une seconde copie Velero. En lecture live avant réconciliation, 19 PVC de ce périmètre restent non vérifiés; 22 PVC de résidu de restauration restent hors gate de couverture. Les écarts sont maintenus sous protection existante jusqu’à qualification.
- CNPG : 12 clusters de production configurés avec WAL/Barman/ScheduledBackup; la preuve de restauration applicative reste `UNPROVEN` dans l’audit, sans changement de contrat Factory/Mastra.

### Coût logique demandé par décision

| Décision | PVC | Capacité demandée | Interprétation |
|---|---:|---:|---|
| CNPG_BARMAN | 19 | 300.0 GiB | capacité logique des claims, pas occupation S3 |
| VELERO_KOPIA | 34 | 392.0 GiB | capacité logique des claims, pas occupation S3 |
| LONGHORN_TRANSITIONAL | 7 | 68.0 GiB | capacité logique des claims, pas occupation S3 |
| EXCLUDE_REBUILDABLE | 9 | 2151 GiB | capacité logique des claims, pas occupation S3 |
| REVIEW_HOLD | 26 | 221.0 GiB | capacité logique des claims, pas occupation S3 |

## Matrice exhaustive des PVC observés

`Current evidence` est un constat live avant réconciliation des PR; `Target` est la politique PLT-56. `Longhorn default` désigne la couverture globale historique qui est retirée, pas une copie à supprimer.

| Namespace / PVC | Propriétaire / utilité | Phase | Classe | Taille | Pod(s) montant | Current evidence | Target |
|---|---|---|---|---:|---|---|---|
| agentgateway / agentgateway-state | Donnée applicative historique explicitement Longhorn | Bound | longhorn-fast | 1Gi | agentgateway-646ddbfdd8-rxhsg | velero/kopia + Longhorn explicite / PVB terminé; schedule=yes ; explicit=yes | LONGHORN_TRANSITIONAL — Conserver; migration vers Velero/Kopia seulement après preuve |
| atlantis-system / atlantis-pilot-data | Donnée applicative historique explicitement Longhorn | Bound | longhorn-fast | 5Gi | atlantis-pilot-0 | velero/kopia + Longhorn explicite / PVB terminé; schedule=yes ; explicit=yes | LONGHORN_TRANSITIONAL — Conserver; migration vers Velero/Kopia seulement après preuve |
| auth / authentik-postgresql-restored-1 | PostgreSQL/CNPG auth | Bound | longhorn-fast | 40Gi | authentik-postgresql-restored-1 | cnpg/barman + Longhorn default; schedule=no | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| auth / authentik-postgresql-restored-1-wal | PostgreSQL/CNPG auth | Bound | longhorn-fast | 30Gi | authentik-postgresql-restored-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| dr-matrix-media-20261020 / restored-media | DR/restore residue | Bound | longhorn-bulk | 50Gi | media-readonly-check | longhorn-s3-supplemental + Longhorn default; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| dr-protect-20261020-immich / restored-redis-data | DR/restore residue | Bound | longhorn-fast | 1Gi | redis-restore-aof-check-v3, redis-restore-aof-check-v4 | longhorn-s3-supplemental + Longhorn default; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| dr-protect-20261020-mastra-active / restored-workspace | DR/restore residue | Bound | longhorn-fast | 2Gi | workspace-restore-reader, workspace-restore-reader-v2 | longhorn-s3-supplemental + Longhorn default; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| dr-protect-20261020-mastra-suspended / restored-workspace | DR/restore residue | Bound | longhorn-fast | 2Gi | workspace-restore-reader, workspace-restore-reader-v2 | longhorn-s3-supplemental + Longhorn default; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| executor / data-executor-0 | Executor état de travail reconstruisible | Bound | longhorn-bulk | 10Gi | — | longhorn-s3-supplemental + Longhorn default; schedule=yes | EXCLUDE_REBUILDABLE — Code/config rejouable; vérifier séparément les sessions avant exclusion |
| factory-platform-recovery / factory-platform-restore-20261104-1 | DR/restore residue | Bound | longhorn-bulk | 20Gi | factory-platform-restore-20261104-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| factory-platform-recovery / factory-platform-restore-20261104-1-wal | DR/restore residue | Bound | longhorn-bulk | 5Gi | factory-platform-restore-20261104-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| factory-platform / factory-cubestore-data | Donnée persistante factory-platform | Bound | longhorn-bulk | 2Gi | factory-cubestore-76b965d6b-xzqdk | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| factory-platform / factory-platform-postgresql-1 | PostgreSQL/CNPG factory-platform | Bound | longhorn-bulk | 20Gi | factory-platform-postgresql-1 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| factory-platform / factory-platform-postgresql-1-wal | PostgreSQL/CNPG factory-platform | Bound | longhorn-bulk | 5Gi | factory-platform-postgresql-1 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| gpt-researcher / gpt-researcher-logs | Loki logs | Bound | longhorn-fast | 5Gi | gpt-researcher-7b669c94d6-cx2q9 | longhorn-s3-supplemental + Longhorn default; schedule=yes | EXCLUDE_REBUILDABLE — Reconstruction/retention; pas de donnée métier |
| gpt-researcher / gpt-researcher-my-docs | Donnée persistante gpt-researcher | Bound | longhorn-fast | 10Gi | gpt-researcher-7b669c94d6-cx2q9 | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| gpt-researcher / gpt-researcher-outputs | Donnée persistante gpt-researcher | Bound | longhorn-fast | 10Gi | gpt-researcher-7b669c94d6-cx2q9 | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| home-assistant / home-assistant-home-assistant-0 | Donnée persistante home-assistant | Bound | longhorn-fast | 5Gi | home-assistant-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| immich / immich-postgresql-1 | PostgreSQL/CNPG immich | Bound | longhorn-fast | 15Gi | immich-postgresql-1 | longhorn-s3-supplemental + Longhorn default; schedule=yes | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| immich / immich-postgresql-1-wal | PostgreSQL/CNPG immich | Bound | longhorn-fast | 20Gi | immich-postgresql-1 | longhorn-s3-supplemental + Longhorn default; schedule=yes | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| immich / library-immich-server-0 | Donnée persistante immich | Bound | longhorn-bulk | 100Gi | immich-server-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| immich / redis-data-immich-redis-master-0 | Immich Redis cache | Bound | longhorn-fast | 1Gi | immich-redis-master-0 | longhorn-s3-supplemental + Longhorn explicite; schedule=yes ; explicit=yes | LONGHORN_TRANSITIONAL — Conserver la protection explicite jusqu’à preuve de remplacement |
| invoice-ninja-restore-drill-20261009-v2 / data-invoice-ninja-mysql-0 | DR/restore residue | Bound | proxmox-csi | 10Gi | invoice-ninja-mysql-0 | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| invoice-ninja-restore-drill-20261009-v2 / invoice-ninja-public | DR/restore residue | Bound | proxmox-csi | 1Gi | invoice-ninja-c5dcb77c-dz2b9 | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| invoice-ninja-restore-drill-20261009-v2 / invoice-ninja-redis | DR/restore residue | Bound | proxmox-csi | 1Gi | invoice-ninja-redis-7d46f4c45-8g2f6 | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| invoice-ninja-restore-drill-20261009-v2 / invoice-ninja-storage | DR/restore residue | Bound | proxmox-csi | 5Gi | invoice-ninja-c5dcb77c-dz2b9, invoice-ninja-mysql-logical-backup-29897535-bx4tv | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| invoice-ninja-restore-drill-20261009 / data-invoice-ninja-mysql-0 | DR/restore residue | Pending | proxmox-csi | 10Gi | invoice-ninja-mysql-0 | longhorn-s3-supplemental + Longhorn default; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| invoice-ninja-restore-drill-20261009 / invoice-ninja-public | DR/restore residue | Pending | proxmox-csi | 1Gi | invoice-ninja-c5dcb77c-b8842 | longhorn-s3-supplemental + Longhorn default; schedule=no ; explicit=yes | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| invoice-ninja-restore-drill-20261009 / invoice-ninja-redis | DR/restore residue | Pending | proxmox-csi | 1Gi | invoice-ninja-redis-7d46f4c45-287cp | longhorn-s3-supplemental + Longhorn default; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| invoice-ninja-restore-drill-20261009 / invoice-ninja-storage | DR/restore residue | Pending | proxmox-csi | 5Gi | invoice-ninja-c5dcb77c-b8842, invoice-ninja-mysql-logical-backup-29857215-chn4z | longhorn-s3-supplemental + Longhorn default; schedule=no ; explicit=yes | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| invoice-ninja / data-invoice-ninja-mysql-0 | Donnée persistante invoice-ninja | Bound | longhorn-bulk | 10Gi | invoice-ninja-mysql-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| invoice-ninja / invoice-ninja-public | Donnée applicative historique explicitement Longhorn | Bound | longhorn-bulk | 1Gi | invoice-ninja-c5dcb77c-bzcqw | longhorn-s3-supplemental + Longhorn default; schedule=yes ; explicit=yes | LONGHORN_TRANSITIONAL — Conserver; migration vers Velero/Kopia seulement après preuve |
| invoice-ninja / invoice-ninja-redis | Donnée persistante invoice-ninja | Bound | longhorn-bulk | 1Gi | invoice-ninja-redis-7d46f4c45-wfsc2 | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| invoice-ninja / invoice-ninja-storage | Donnée applicative historique explicitement Longhorn | Bound | longhorn-bulk | 5Gi | invoice-ninja-c5dcb77c-bzcqw, invoice-ninja-mysql-logical-backup-29897535-wfnnt | velero/kopia + Longhorn default / PVB terminé; schedule=yes ; explicit=yes | LONGHORN_TRANSITIONAL — Conserver; migration vers Velero/Kopia seulement après preuve |
| karakeep / data-web-0 | Donnée persistante karakeep | Bound | longhorn-fast | 5Gi | web-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| karakeep / meilisearch-data-meilisearch-0 | Média/cache/index/téléchargements | Bound | longhorn-fast | 5Gi | meilisearch-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | EXCLUDE_REBUILDABLE — Donnée reproductible ou volumineuse; source non supprimée |
| mastra-factory / mastra-factory-postgresql-1 | PostgreSQL/CNPG mastra-factory | Bound | longhorn-bulk | 20Gi | mastra-factory-postgresql-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| mastra-factory / mastra-factory-postgresql-1-wal | PostgreSQL/CNPG mastra-factory | Bound | longhorn-bulk | 5Gi | mastra-factory-postgresql-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| matrix-mas-recovery / matrix-mas-restore-20261104-1 | DR/restore residue | Bound | longhorn-bulk | 10Gi | matrix-mas-restore-20261104-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| matrix-mas-recovery / matrix-mas-restore-20261104-1-wal | DR/restore residue | Bound | longhorn-bulk | 5Gi | matrix-mas-restore-20261104-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| matrix / matrix-mas-postgresql-1 | PostgreSQL/CNPG matrix | Bound | longhorn-bulk | 10Gi | matrix-mas-postgresql-1 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| matrix / matrix-mas-postgresql-1-wal | PostgreSQL/CNPG matrix | Bound | longhorn-bulk | 5Gi | matrix-mas-postgresql-1 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| matrix / matrix-synapse-media | Donnée applicative historique explicitement Longhorn | Bound | longhorn-bulk | 50Gi | matrix-synapse-main-0 | velero/kopia + Longhorn explicite / PVB terminé; schedule=yes ; explicit=yes | LONGHORN_TRANSITIONAL — Conserver; migration vers Velero/Kopia seulement après preuve |
| matrix / matrix-synapse-postgresql-1 | PostgreSQL/CNPG matrix | Bound | longhorn-bulk | 20Gi | matrix-synapse-postgresql-1 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| matrix / matrix-synapse-postgresql-1-wal | PostgreSQL/CNPG matrix | Bound | longhorn-bulk | 5Gi | matrix-synapse-postgresql-1 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| mealie / mealie-data | Donnée persistante mealie | Bound | longhorn-fast | 5Gi | mealie-656694c96c-qdtrg | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / aiostreams-data | Donnée persistante media | Bound | longhorn-fast | 4Gi | aiostreams-6cf77ff8f-9q7zq | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / audiobookrequest-config | Donnée persistante media | Bound | longhorn-fast | 5Gi | audiobookrequest-6c8686847d-zwl74 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / cache-jellyfin-0 | Média/cache/index/téléchargements | Bound | longhorn-fast | 10Gi | jellyfin-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | EXCLUDE_REBUILDABLE — Donnée reproductible ou volumineuse; source non supprimée |
| media / config-bazarr-0 | Donnée persistante media | Bound | longhorn-fast | 1Gi | bazarr-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / config-jellyfin-0 | Donnée persistante media | Bound | longhorn-fast | 10Gi | jellyfin-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / config-jellyseerr-0 | Donnée persistante media | Bound | longhorn-fast | 5Gi | jellyseerr-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / config-lidarr-0 | Donnée persistante media | Bound | longhorn-fast | 4Gi | lidarr-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / config-prowlarr-0 | Donnée persistante media | Bound | longhorn-fast | 5Gi | prowlarr-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / config-radarr-0 | Donnée persistante media | Bound | longhorn-fast | 4Gi | radarr-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / config-sonarr-0 | Donnée persistante media | Bound | longhorn-fast | 4Gi | sonarr-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / decypharr-state | Donnée persistante media | Bound | longhorn-fast | 2Gi | decypharr-5d55c74fdc-7mb9v | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / media-share | Média/cache/index/téléchargements | Bound | longhorn-bulk | 2Ti | bazarr-0, decypharr-5d55c74fdc-7mb9v | velero/kopia + Longhorn default / PVB terminé; schedule=yes | EXCLUDE_REBUILDABLE — Donnée reproductible ou volumineuse; source non supprimée |
| media / polyfin-data | Donnée persistante media | Bound | longhorn-fast | 5Gi | polyfin-97dd46d6-sf7dv | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| media / polyfin-db-1 | PostgreSQL/CNPG media | Bound | longhorn-fast | 5Gi | polyfin-db-1 | longhorn-s3-supplemental + Longhorn default; schedule=yes | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| monitoring / prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 | Prometheus métriques | Bound | longhorn-fast | 20Gi | prometheus-kube-prometheus-stack-prometheus-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | EXCLUDE_REBUILDABLE — Reconstruction/retention; pas de donnée métier |
| monitoring / storage-loki-0 | Loki logs | Bound | longhorn-bulk | 20Gi | loki-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | EXCLUDE_REBUILDABLE — Reconstruction/retention; pas de donnée métier |
| mqtt / data-mosquitto-0 | Donnée persistante mqtt | Bound | longhorn-fast | 1Gi | mosquitto-0 | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| ntfy / ntfy-data | Donnée persistante ntfy | Bound | longhorn-fast | 1Gi | ntfy-56ff6cc886-jl9hw | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| open-connector / open-connector-data | Donnée persistante open-connector | Bound | longhorn-bulk | 2Gi | open-connector-79b4fc7b8d-jnk4b | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| openclaw-restore-drill-20261005-v2 / openclaw-data | DR/restore residue | Pending | proxmox-csi | 10Gi | — | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| openclaw-restore-drill-20261005-v3 / openclaw-data | DR/restore residue | Pending | proxmox-csi | 10Gi | — | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| openclaw-restore-drill-20261005-v4 / openclaw-data | DR/restore residue | Bound | proxmox-csi | 10Gi | openclaw-0 | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| openclaw-restore-drill-20261005-v5 / openclaw-data | DR/restore residue | Bound | proxmox-csi | 10Gi | openclaw-restore-inspector-readable | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| openclaw-restore-drill-20261005 / openclaw-config-openclaw-0 | DR/restore residue | Pending | longhorn-fast | 5Gi | — | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| openclaw-restore-drill-20261005 / openclaw-data | DR/restore residue | Bound | proxmox-csi | 10Gi | openclaw-restore-inspector, openclaw-restore-inspector-data | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| openclaw-restore-drill-20261005 / openclaw-data-openclaw-0 | DR/restore residue | Pending | longhorn-fast | 5Gi | — | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| openclaw-restore-drill-20261005 / openclaw-logs-openclaw-0 | DR/restore residue | Pending | longhorn-fast | 10Gi | — | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| openclaw-restore-drill-20261005 / openclaw-workspace-openclaw-0 | DR/restore residue | Pending | longhorn-fast | 20Gi | — | none; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| opencode / opencode-data-pvc | Donnée persistante opencode | Bound | longhorn-fast | 5Gi | opencode-web-584856fb9b-rqg5t | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| opencode / opencode-workspace-pvc | Donnée persistante opencode | Bound | longhorn-fast | 10Gi | opencode-web-584856fb9b-rqg5t | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| paperless / paperless-data | Donnée persistante paperless | Bound | longhorn-fast | 5Gi | paperless-6df754844b-nrhb8 | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| paperless / paperless-media | Donnée persistante paperless | Bound | longhorn-fast | 20Gi | paperless-6df754844b-nrhb8 | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| paperless / paperless-postgresql-1 | PostgreSQL/CNPG paperless | Bound | longhorn-fast | 10Gi | paperless-postgresql-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| pinepods / pinepods-backups | Pinepods téléchargements/backups | Bound | longhorn-fast | 3Gi | pinepods-bbf5c8967-dn9hh | longhorn-s3-supplemental + Longhorn default; schedule=yes | EXCLUDE_REBUILDABLE — Reproductible; DB couverte par CNPG |
| pinepods / pinepods-db-1 | PostgreSQL/CNPG pinepods | Bound | longhorn-fast | 60Gi | pinepods-db-1 | longhorn-s3-supplemental + Longhorn default; schedule=yes | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| pinepods / pinepods-downloads | Média/cache/index/téléchargements | Bound | longhorn-fast | 30Gi | pinepods-bbf5c8967-dn9hh | longhorn-s3-supplemental + Longhorn default; schedule=yes | EXCLUDE_REBUILDABLE — Donnée reproductible ou volumineuse; source non supprimée |
| plt105-recovery-20261020 / plt105-recovery-pvc | DR/restore residue | Bound | longhorn-fast | 2Gi | plt105-recovery-reader | longhorn-s3; schedule=no | REVIEW_HOLD — Aucune suppression; preuve de restauration et Factory/Mastra protégées |
| romm / romm-assets | Donnée persistante romm | Bound | longhorn-fast | 20Gi | romm-8646b4dcd7-ms24k | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| romm / romm-library | Donnée persistante romm | Bound | longhorn-bulk | 100Gi | romm-8646b4dcd7-ms24k | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| romm / romm-postgresql-1 | PostgreSQL/CNPG romm | Bound | longhorn-fast | 10Gi | romm-postgresql-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| romm / romm-postgresql-1-wal | PostgreSQL/CNPG romm | Bound | longhorn-fast | 5Gi | romm-postgresql-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| romm / romm-redis-data | Donnée persistante romm | Bound | longhorn-fast | 2Gi | romm-8646b4dcd7-ms24k | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| romm / romm-resources | Donnée persistante romm | Bound | longhorn-bulk | 20Gi | romm-8646b4dcd7-ms24k | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| stirling-pdf / stirling-config | Donnée persistante stirling-pdf | Bound | longhorn-fast | 2Gi | stirling-pdf-5dc699c848-89jjl | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| sure / sure-postgresql-1 | PostgreSQL/CNPG sure | Bound | longhorn-fast | 10Gi | sure-postgresql-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |
| sure / sure-storage | Donnée applicative historique explicitement Longhorn | Bound | longhorn-fast | 5Gi | sure-web-bbfd65ddf-lk7pq, sure-worker-85bd8d665-4jkvr | velero/kopia + Longhorn default / PVB terminé; schedule=yes ; explicit=yes | LONGHORN_TRANSITIONAL — Conserver; migration vers Velero/Kopia seulement après preuve |
| trilium / trilium-data | Donnée persistante trilium | Bound | longhorn-fast | 5Gi | trilium-756bb9765d-7gh5g | velero/kopia + Longhorn default / PVB terminé; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| vikunja / vikunja-files | Donnée persistante vikunja | Bound | longhorn-fast | 2Gi | vikunja-8477c89fb5-qdd27 | longhorn-s3-supplemental + Longhorn default; schedule=yes | VELERO_KOPIA — Une copie distante vérifiée; sélection par PVC/pod |
| vikunja / vikunja-postgresql-1 | PostgreSQL/CNPG vikunja | Bound | longhorn-fast | 5Gi | vikunja-postgresql-1 | longhorn-s3-supplemental + Longhorn default; schedule=no | CNPG_BARMAN — WAL + ScheduledBackup/Barman; pas de copie Velero de la base |

## Historique et volumes Released

- Le manifeste historique de synthèse contient 17 PVC (`docs/operations/dr-synth-historical-review-manifest-2026-10-19.json`), avec `executable=false` et aucune suppression autorisée. Ils restent en revue; aucun PVC, PV, volume Longhorn ou objet S3 n’est supprimé par PLT-56.
- La capture live montre 13 PVC `proxmox-csi` correspondant aux restes visibles des drills Invoice Ninja/OpenClaw; 77 PV sont en phase `Released`. Ces objets sont inventoriés et conservés, sans nettoyage automatique.
- Les 22 résidus de restauration remontés par l’audit (`RESTORE_RESIDUE_COUNT=22`) restent hors couverture de production et doivent être qualifiés séparément. Les sessions/workspaces Factory/Mastra restent protégés jusqu’à preuve de restauration applicative acceptée.

## Mesures I/O, Longhorn, réseau et température

- Audit I/O du 5 novembre : le run blanket a produit 114 backups Longhorn terminés dans une heure, pour environ 4,25 GB de `newlyUploadDataSize`. Cette mesure est l’effet observable du groupe `default`, pas une estimation de l’occupation totale S3.
- Température baseline : moyenne CPU hôte d’environ 86,7 °C sur 1 h, maximum 24 h d’environ 100,25 °C; HDD à 39–40 °C et NVMe autour de 40–43 °C. La causalité avec les écritures disque reste à mesurer après réconciliation.
- Live Longhorn : 154 volumes, 148 avec le label de groupe `default`, 9 avec un label de recurring job explicite; environ 3,93 TB de capacité logique étaient éligibles au groupe global. Les CRD de backup totalisent environ 1,115 TB de tailles logiques et 26,4 GB de `newlyUploadDataSize` cumulé; ces champs ne sont pas l’occupation physique S3.
- Velero : 467 backups observés, dont 448 `Completed`; Kopia : 40 repositories `Ready`.
- La mesure d’occupation S3 réelle n’a pas pu être obtenue : `rclone size` avec les identifiants opérateur a reçu `403 AccessDenied` sur `ListObjects`. Aucune suppression ni estimation en euros n’est donc autorisée sur cette base.
- Le différentiel avant/après devra être mesuré après réconciliation, avec la même fenêtre : débit disque/IOPS, opérations Longhorn, octets réseau, taille S3 côté fournisseur et températures CPU. Le présent document fournit la baseline, pas une réduction réelle déjà appliquée.

## PR et garde-fous

- PR Longhorn : suppression du recurring job global `default`; jobs explicites conservés.
- PR Velero : schedules retirés pour monitoring/Executor, selectors resserrés, labels d’exclusion sur les PVC directs et annotations FSB/Kopia sur les Pod templates. Aucun `volumeClaimTemplate` de StatefulSet n’est modifié; les claims existants ne déduisent pas les labels d’un template.
- PR audit/contrats : corrélation sélective Velero, test de non-régression, matrice et limites de mesure.
- Nettoyage : inventaire uniquement; aucune suppression d’anciennes sauvegardes ou de volumes sans preuve de restauration et validation opérateur.

## Références

- `docs/operations/backup-audit-consolidation-2026-10-19.md`
- `docs/operations/backup-audit-recovery-policy-2026-10-20.md`
- `docs/operations/longhorn-offsite-pvc-protection.md`
- `docs/operations/dr-restore-evidence-2026-10-20.json`
- `scripts/backup-audit.sh` et `tests/harness/backup-audit-contract-test.sh`



