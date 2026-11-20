# Sauvegarde `pg-shared` d'OKE vers R2 et restauration hors Oracle (PLT-190, mission M8)

Statut : **préparé, `NOT_TESTED`.** Aucune preuve live : l'accès en lecture à OKE n'existe pas encore (PLT-257) et rien n'est appliqué. Ce document ne prouve rien tant que la section « Preuves » est vide.

Contrainte (plan OKE, D-2026-11-11-17) : aucune application avec données n'est activée sur OKE sans restauration prouvée hors Oracle. La cible hors Oracle est **Cloudflare R2** (le texte de PLT-190 qui cite Hetzner est périmé ; aucun nouveau store Hetzner, voir `k8s/CLAUDE.md`).

## Ce qui est en Git

| Chemin | Rôle |
| --- | --- |
| `k8s/clusters/oracle-a1/cnpg-cluster/objectstore.yaml` | `ObjectStore pg-shared-oke-r2` : `s3://homelab-backup-cnpg/oracle-a1`, `serverName pg-shared` donc préfixe `oracle-a1/pg-shared/`, rétention 14 j, identité écrivain |
| `cnpg-cluster/external-secrets.yaml` | `pg-shared-cnpg-r2-writer` : `R2_CNPG_WRITER_*` et `R2_S3_ENDPOINT` (noms seulement, valeurs dans Doppler `cluster/prd`) |
| `cnpg-cluster/cluster.yaml` | plugin `barman-cloud.cloudnative-pg.io` en `isWALArchiver`, image PostgreSQL 17.7 épinglée par digest d'index multi-arch (même version sur le nœud arm64 d'OKE et sur le homelab amd64) |
| `cnpg-cluster/scheduledbackup.yaml` | `pg-shared-daily`, 03:50 UTC, `immediate: true` |
| `k8s/optional/pg-shared-oke-drill/` | Drill : base `backup_drill`, jobs `seed-a`, `seed-b`, `fingerprint` et `oke-backup` (OKE) ; `offsite-restore/` (homelab : restauration + empreinte) |

Le préfixe `oracle-a1/` est séparé des archives du homelab : barman-cloud refuse une archive non vide et OKE n'écrit jamais dans un préfixe du homelab. La restauration hors Oracle lit ce préfixe avec l'identité **lecture seule** `R2_CNPG_RESTORE_RO_*` (jeton `r2-cnpg-restore-ro`, Object Read only, limité à `homelab-backup-cnpg`, posé dans `cluster/prd` le 15/11/2026). Aucune clé n'est lue ni affichée par ce plan.

## Plan des volumes OKE (quota 200 Go)

Boot 50 Go + 3 volumes `oci-bv` de 50 Gi (minimum OCI ; l'unité GB ou GiB reste à vérifier au plan).

| Volume | Contenu | Namespace | Sauvegarde hors Oracle |
| --- | --- | --- | --- |
| V1 | `hindsight-db` | `hindsight` | R2 `oracle-a1/hindsight-db/` (drill PLT-303) |
| V2 | `pg-shared` (Polyfin ; Authentik et AIOStreams seulement après décision) | `databases` | R2 `oracle-a1/pg-shared/` (ce ticket) |
| V3 | réserve : Authentik dédié (réplica R2), ou SQLite AIOStreams (namespace `media`) | à choisir | AIOStreams : CronJob `.backup` vers R2 ou base dans `pg-shared` (M9) |

Le drill n'ajoute aucun volume : la restauration tourne sur le homelab ; côté OKE il ajoute seulement une base `backup_drill` dans `pg-shared`. Un PVC reste lié à son namespace : si Authentik prend V3, AIOStreams doit passer en PostgreSQL dans `pg-shared`. Authentik dans `pg-shared` exigerait l'accord de Paul (exception de D-2026-11-13-02) ; ce plan ne le suppose pas.

## Prérequis (tous vérifiés par noms seulement, jamais par valeur)

1. Accès en lecture à OKE : PLT-257 (`kubectl-ro.sh --cluster oracle-a1`). Sans lui, s'arrêter : le bastion OCI exige la clé API de Paul et n'est pas un accès d'agent.
2. OKE : `cert-manager` et `cnpg-barman-plugin` Synced/Healthy (relevé PLT-328 du 15/11/2026), `ClusterSecretStore/doppler-cluster` Ready.
3. Doppler `cluster/prd`, noms présents : `R2_CNPG_WRITER_ACCESS_KEY_ID`, `R2_CNPG_WRITER_SECRET_ACCESS_KEY`, `R2_S3_ENDPOINT`, `R2_CNPG_RESTORE_RO_ACCESS_KEY_ID`, `R2_CNPG_RESTORE_RO_SECRET_ACCESS_KEY` (relevé PLT-303, 15/11/2026). **`ORACLE_A1_POSTGRES_PASSWORD` : absent au dernier relevé** (README `oracle-a1`) ; sans lui `pg-shared-polyfin` ne se crée pas et le rôle `polyfin` n'a pas de mot de passe. À créer par qui a accès au projet `cluster` (le jeton worker n'y a pas accès).
4. Température du nœud homelab relevée à titre informatif avant la restauration, sans seuil bloquant (relevé 62 °C à 20:09 UTC le 15/11/2026, non refait ici) ; la restauration est légère (base de quelques Mo).
5. Argo du homelab : le namespace `pg-shared-oke-drill` doit être admis par l'application qui importe `offsite-restore/` (même chemin que `hindsight-oke-drill`, `k8s/applications/ai/kustomization.yaml`). Non vérifié : à contrôler à l'import (`NOT_PROVEN`).

## Procédure (une PR par import, une PR par retrait)

1. **Activation OKE (PR 1)** : ajouter `cnpg-cluster.yaml` à `k8s/clusters/oracle-a1/apps/kustomization.yaml` (jamais `media.yaml`), et `../../../optional/pg-shared-oke-drill/oke-database` à `cnpg-cluster/kustomization.yaml`. Attendre `Cluster pg-shared` Ready, `ContinuousArchiving=True`, `ScheduledBackup` immédiat `Completed` (relevé : `kubectl-ro.sh get cluster,backup -n databases`).
2. **Seed A (avant le premier base backup)** : Importer `oke-seed-a`, lire `logs job/pg-shared-drill-seed-a` : `seed_a_rows=10000`. Le backup immédiat de `pg-shared-daily` précède ce seed : il ne sert pas de base au drill.
3. **Backup base** : importer `oke-backup` (`Backup pg-shared-drill-base`) et attendre `Completed`, postérieur au seed A. Relever sous `oracle-a1/pg-shared/base/` au moins un objet.
4. **Seed B (après ce backup)** : importer `oke-seed-b` : `seed_b_rows=500`. Ces lignes n'existent que dans le flux WAL : la restauration prouve donc le rejeu des WAL, pas seulement le base backup. Noter `seed_b_done_at`.
5. **Attendre l'archivage du WAL** : au moins `archive_timeout` plus une minute (5 min par défaut CNPG, à confirmer au relevé, `NOT_PROVEN` ici). Relever `status.lastArchivedWAL` / condition `ContinuousArchiving=True` et au moins un objet sous `oracle-a1/pg-shared/wals/` postérieur à `seed_b_done_at`.
6. **Empreinte OKE** : importer `oke-fingerprint`, lire `logs job/pg-shared-drill-fingerprint`, la conserver.
7. **Restauration hors Oracle (PR 2)** : importer `k8s/optional/pg-shared-oke-drill/offsite-restore` côté homelab. Relever la création du `Cluster pg-shared-offsite` jusqu'à Ready (RTO), puis lire l'empreinte du Job.
8. **Comparer** : chaque ligne de l'empreinte restaurée égale à celle d'OKE (`rows_a`, `rows_b`, `max_id`, `marker_md5`, `last_written_at`, `database=`, `roles_md5`, `server_version`).
9. **Retraits** : retirer l'import `offsite-restore` (puis supprimer le namespace de drill et son PVC : résidu de drill) ; retirer les imports `oke-seed-*`, `oke-backup` et `oke-fingerprint`, puis `oke-database` (`databaseReclaimPolicy: delete` supprime `backup_drill`). Les archives R2 ne sont pas supprimées à la main : la rétention de 14 jours s'en charge.
10. Contrôle final : `ContinuousArchiving=True` sur `pg-shared` OKE et sur les clusters du homelab, aucune écriture homelab vers `oracle-a1/`.

## RPO et RTO : comment les mesurer

- **RTO restauration hors Oracle** = `metadata.creationTimestamp` du `Cluster pg-shared-offsite` jusqu'à la condition `Ready` (`kubectl-ro.sh get cluster -n pg-shared-oke-drill pg-shared-offsite -o json`, minutes). À reporter pour une base de quelques Mo : la durée croît avec le volume de WAL à rejouer, elle n'est pas extrapolable telle quelle à Authentik (1,2 Go de données, 4,5 Go de WAL).
- **RPO** = écart entre le dernier commit (`seed_b_done_at`) et le dernier WAL archivé couvrant ce commit. Borne théorique : `archive_timeout`. Mesure : les lignes B présentes dans la restauration prouvent que le WAL de `seed_b` était archivé avant la restauration ; l'âge de l'objet WAL le plus récent sous `oracle-a1/pg-shared/wals/` donne le décalage réel. Perte maximale en cas de panne brutale d'OKE : jusqu'à la dernière archive (jamais prouvée par une panne réelle).
- **Reconstruction depuis Git** : hors périmètre de ce ticket (M11).

## Critères de réussite (tous requis)

1. Empreinte OKE et empreinte restaurée identiques ligne à ligne (la restauration a lieu sur le homelab, hors Oracle).
2. `LastBackupSucceeded=True` et `ContinuousArchiving=True` sur `pg-shared` OKE ; objets sous `oracle-a1/pg-shared/base/` et `.../wals/`.
3. RTO et RPO mesurés et commentés dans PLT-190.
4. Aucun secret lu, affiché ou journalisé ; aucune écriture homelab vers R2 `oracle-a1/` ; aucun préfixe du homelab modifié.

## Retour arrière

Retirer `cnpg-cluster.yaml` de la racine OKE (l'Application n'a pas de finalizer de cascade : les ressources restent ; le `Cluster` porte `Prune=false`, l'`ObjectStore` `Prune=false,Delete=false`). La suppression du cluster, de son PVC ou des archives R2 est une opération séparée et explicite : jamais la seule copie de données irremplaçables.

## Preuves

| Niveau | Élément | Statut |
| --- | --- | --- |
| STATIC | `kustomize build` des chemins modifiés et du drill | voir la PR |
| RUNTIME | sauvegarde OKE, restauration hors Oracle, empreintes, RPO/RTO | `NOT_TESTED` (accès OKE absent, PLT-257) |
