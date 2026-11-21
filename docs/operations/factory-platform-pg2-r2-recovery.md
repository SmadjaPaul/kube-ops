# factory-platform-pg2 : source de recovery sur R2 et drill isolé (PLT-332)

Statut : PLAN. Le manifeste de bascule est dans la PR `claude/pg2-recovery-source-r2`. Le drill ci-dessous n'est pas exécuté par cette PR : il est à lancer par un opérateur après merge.

## 1. État avant la PR

- `factory-platform-pg2` (namespace `factory-platform`) est restauré par PITR le 2026-10-29T00:35:32Z depuis l'archive Hetzner de l'ancien cluster `factory-platform-postgresql` (serverName `factory-platform-postgresql`).
- Son `externalClusters` `factory-platform-old` et son `bootstrap.recovery` pointent vers `factory-platform-hetzner-store`.
- L'archivage WAL de pg2 vers Hetzner est arrêté (MANDAT 21, D-2026-11-16-07). pg2 n'a aucune sauvegarde continue.
- La copie R2 de l'archive est faite et vérifiée : bucket `homelab-backup-cnpg`, préfixe `cnpg/factory-platform/`, 391 objets, 372 965 353 octets, MD5 identiques (preuve sur PLT-219).

## 2. Changement de la PR (minimal)

- Nouveau fichier `k8s/applications/platform/factory-platform/database-r2-recovery.yaml` :
  - ExternalSecret `factory-platform-cnpg-r2-ro` : identité lecture seule existante `R2_CNPG_RESTORE_RO_*` (token Object Read only sur `homelab-backup-cnpg`, comme `pg-shared-oke-drill`). Aucune valeur dans Git.
  - ObjectStore `factory-platform-r2-recovery-store` : `destinationPath: s3://homelab-backup-cnpg/cnpg/factory-platform`. Pas de `isWALArchiver`, pas de Backup, pas de ScheduledBackup.
- `database-pg2.yaml` : seul `externalClusters[factory-platform-old].plugin.parameters.barmanObjectName` passe de `factory-platform-hetzner-store` à `factory-platform-r2-recovery-store`. `serverName` reste `factory-platform-postgresql` (même clé d'objets dans les deux buckets). Le bloc `bootstrap.recovery` est inchangé.
- `kustomization.yaml` : une ligne ajoutée.
- Non touchés : `factory-platform-hetzner-store` et son fichier, `database.yaml` (cluster gelé, PLT-252), les PVC, le Secret Hetzner.

## 3. Drill isolé (à exécuter PAR UN OPÉRATEUR après merge, jamais par un agent)

Objectif : prouver qu'une PITR depuis la copie R2 produit un cluster sain, sans toucher à `factory-platform-pg2` ni à `factory-platform-postgresql`.

### 3.1 Ressources (namespace jetable `factory-platform-drill`)

- Namespace avec labels `backup.smadja.dev/restore-drill: "true"` et `pod-security.kubernetes.io/enforce: restricted`.
- ExternalSecret `factory-platform-cnpg-r2-ro` et ObjectStore `factory-platform-r2-recovery-store` : copies identiques de celles de `factory-platform` (même `destinationPath`, même identité lecture seule), dans le namespace drill.
- CiliumNetworkPolicy default-deny : ingress depuis le namespace et depuis le port 8000 du pod opérateur CNPG (`cnpg-system`) ; egress vers DNS (kube-dns), kube-apiserver, et `*.eu.r2.cloudflarestorage.com` / `homelab-backup-cnpg.*.eu.r2.cloudflarestorage.com` en 443. Modèle : `k8s/optional/pg-shared-oke-drill/offsite-restore/networkpolicy.yaml`.
- Cluster `factory-platform-drill`, sans archiveur WAL :

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: factory-platform-drill
  namespace: factory-platform-drill
  labels:
    backup.smadja.dev/restore-drill: "true"
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.7
  bootstrap:
    recovery:
      source: factory-platform-old
      database: factory
      owner: factory
      recoveryTarget:
        targetTime: "2026-10-29T00:35:32Z"   # cible validée PLT-168
  externalClusters:
    - name: factory-platform-old
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: factory-platform-r2-recovery-store
          serverName: factory-platform-postgresql
  storage: {size: 20Gi, storageClass: longhorn-bulk}
  walStorage: {size: 5Gi, storageClass: longhorn-bulk}
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {cpu: "1", memory: 1Gi}
  affinity: {enablePodAntiAffinity: false}
```

- Avant la création : lister la fin de l'archive en lecture seule (`base/` et `wals/` sous `cnpg/factory-platform/factory-platform-postgresql/`, via l'identité RO) et confirmer que la cible PITR est couverte par les WAL. Si l'archive ne couvre pas la cible, arrêter et consigner.
- Option : sans `recoveryTarget`, la restauration va à la fin des WAL disponibles. Ce choix change la preuve : à consigner avant le lancement.

### 3.2 Critères (PASS seulement si tous sont vrais)

1. `Cluster factory-platform-drill` condition `Ready=True`. Durée mesurée = `Ready` moins `creationTimestamp` (RTO du drill), à consigner.
2. Logs du pod `factory-platform-drill-1` sans erreur du plugin barman ni de récupération.
3. Requête de contrôle, sans lire de ligne de données ni de secret :

```sql
SELECT pg_is_in_recovery() AS in_recovery,
       count(*) AS user_tables
FROM information_schema.tables
WHERE table_schema NOT IN ('pg_catalog', 'information_schema');
```

   Attendu : `in_recovery = f`, `user_tables > 0`. Le même décompte par schéma (`raw`, `control`, `public`) est comparé à celui de `factory-platform-pg2` lu au même moment (lecture seule, comptes seulement). Un écart est à expliquer dans le résultat (les données post-PITR ne sont pas dans la copie).
4. Aucun changement sur `factory-platform-pg2` (même pod UID, `Ready`) et sur `factory-platform-postgresql` (inchangé).

Résultat attendu : `mission-result.v1` avec les statuts `PASS`, `FAIL`, `NOT_PROVEN` par critère.

### 3.3 Nettoyage

- Supprimer le namespace `factory-platform-drill` (Cluster, PVC, Secrets, ObjectStore, CNP).
- Vérifier l'absence de PVC et de PV orphelins liés au namespace.
- Ne pas supprimer d'objet dans R2 ni dans Hetzner.

### 3.4 Retour arrière du drill

Supprimer le namespace. Aucun effet sur la production : le drill ne lit que R2 et n'écrit rien.

## 4. Ordre sûr des étapes

1. Relecture de la PR, `just check` vert, puis merge (aucun mandat dans cette PR).
2. Argo synchronise `factory-platform`. Vérifier : `factory-platform-pg2` reste `Ready` (même pod UID), ObjectStore `factory-platform-r2-recovery-store` présent, ExternalSecret `Synced`. Un dry-run serveur de la modification `externalClusters` est à faire par un opérateur avant merge, car le webhook CNPG peut refuser un changement du bloc de recovery.
3. Drill isolé (section 3), par un opérateur.
4. Seulement si le drill est PASS : PR suivante pour l'archivage R2 de pg2 (ObjectStore en écriture `R2_CNPG_WRITER_*`, `isWALArchiver`, ScheduledBackup plugin, Backup initial R2, preuve `CNPG(R2)`). Hors de cette PR.
5. Ensuite seulement, et après décision : retrait de `externalClusters` `factory-platform-old` et de `bootstrap.recovery` (PLT-388). Refusable par le webhook tant que `bootstrap.recovery.source` le référence.

## 5. Retour arrière

- Production : `git revert` de la PR. `barmanObjectName` redevient `factory-platform-hetzner-store`, qui est conservé. Aucune donnée n'est supprimée. `bootstrap` n'étant pas rejoué sur un cluster existant, le retour arrière ne touche pas aux données de pg2.
- Drill : suppression du namespace (section 3.4).

## 6. Risques

- Le webhook CNPG peut refuser ou ne pas accepter la modification de `barmanObjectName`. Vérifier en dry-run serveur (opérateur) avant merge.
- Une mise à jour du Cluster pourrait déclencher un redémarrage de l'instance. Le contrôle est le pod UID avant et après.
- Le token R2 `R2_CNPG_RESTORE_RO_*` lit tout le bucket `homelab-backup-cnpg`, pas seulement le préfixe. C'est le périmètre existant de `pg-shared-oke-drill`, accepté ici. Un token limité par préfixe n'existe pas dans R2 (PLT-219).
- La cible PITR de 2026-10-29T00:35:32Z est celle validée en PLT-168. Une cible plus récente dépend des WAL disponibles, non vérifiés.
- La copie R2 est une copie de l'archive Hetzner à une date donnée, pas une sauvegarde continue. Les écritures de pg2 après la restauration ne sont dans aucune archive. Ce risque est accepté (MANDAT 17) jusqu'à l'étape 4.

## 7. Conflits avec kube-ops#1592 (PLT-369, non mergée)

- `database-pg2.yaml` : #1592 ajoute une annotation dans `metadata` (`backup.smadja.dev/velero-crash-consistent`). Cette PR modifie `spec.externalClusters`. Hunks distincts ; un conflit de contexte reste possible.
- `kustomization.yaml` : #1592 touche la liste `resources`. Cette PR insère une ligne après `database-pg2-objectstore.yaml`. Conflit possible si #1592 insère au même endroit.
- `database.yaml` : #1592 ajoute `backup.smadja.dev/forensic-fenced`. Non touché ici.
- Docs : #1592 crée `docs/operations/factory-platform-pg2-restore.md` et met à jour `backup-coverage-static.md` et `backup-coverage-classes.tsv`. Ce document a un nom différent, sans conflit attendu.
- Règle : ne pas merger ni modifier #1592. Si #1592 est mergée en premier, rebaser cette branche sur `origin/main` et résoudre les deux petits conflits attendus. Si cette PR est mergée en premier, #1592 doit être rebasée par son auteur.
