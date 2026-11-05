# PLT-145 — Retrait définitif de l'ancien PostgreSQL Matrix MAS (2026-11-05)

## Décision de l'opérateur et périmètre

Le 5 novembre 2026, l'opérateur a **explicitement autorisé la suppression définitive de toutes les données historiques de l'ancien PostgreSQL Matrix MAS** : ces données n'ont aucune valeur à conserver. Cette autorisation n'inclut **aucune** donnée du nouveau `matrix-mas-postgresql-clean`, de Synapse, Factory Platform, Mastra Factory, ni aucun secret / stockage partagé.

Source ancienne strictement désignée :
- `Cluster/matrix/matrix-mas-postgresql` sous l'application dédiée `matrix-legacy-forensics` ;
- `PVC/matrix/matrix-mas-postgresql-1` (PGDATA) et `PVC/matrix/matrix-mas-postgresql-1-wal` (WAL) avec leurs PV/Longhorn exacts à revalider par UID ;
- `ScheduledBackup/matrix/matrix-mas-postgresql-weekly` (déjà `suspend: true`) ;
- `Backup/matrix/matrix-mas-postgresql-gap-remediation-20261020` et `ObjectStore/matrix/matrix-mas-hetzner-store` ;
- anciens services CNPG uniquement s'ils sont générés et n'ont aucun consommateur.

Cible à **ne jamais** toucher :
- `Cluster/matrix/matrix-mas-postgresql-clean`, `matrix-mas-postgresql-clean-rw`, son Secret `matrix-mas-postgresql-clean-app`, son Barman ObjectStore et ses backup/WAL/PVC ;
- `matrix-synapse-postgresql`, ses credentials, son stockage média, ses backups, le secret `matrix-generated` ;
- toute base, PVC ou identité Factory, les secrets Doppler, le bucket Hetzner S3 partagé.

## Étape 1 — Désarmer la protection de prune sans supprimer (cette PR)

Le manifeste source dédié `k8s/optional/matrix-legacy-source/cluster.yaml` ne porte plus `Prune=false` : l'Application `matrix-legacy-forensics` conserve **`automated.prune: false`**, son Cluster reste dans le `kustomization.yaml`, et son annotation `cnpg.io/hibernation=on` reste en place. Aucun cluster/PVC ne doit être supprimé à cette étape.

Qualification avant étape 2 : trois checks GitHub PASS, `matrix-legacy-forensics` Synced, UID des ressources, nouvelle base Ready, MAS et Synapse endpoints Ready, sauvegardes clean.

## Étape 2 — Retrait GitOps du Cluster ancien (PR séparée, destructrice)

Préflight depuis le cluster **immédiatement avant la fusion** :
1. Identifier les UIDs et `ownerReferences` de `matrix-mas-postgresql`, PGDATA et WAL ; vérifier que les PVC appartiennent **uniquement** au cluster historique et correspondent aux deux anciennes identités.
2. Constater en lecture seule l'absence de tout client actif vers `matrix-mas-postgresql-rw`, les éventuelles références réseau, et l'état santé du nouveau MAS (`matrix-mas-postgresql-clean-rw`) et de Synapse ; le 43/43 smoke antérieur n'est pas une preuve de cette fenêtre.
3. Vérifier les finalizers, PVC→PV→Longhorn Volume, VolumeAttachments, policies de retention et le comportement réel CNPG à la suppression de ce Cluster : ses PVC avec `ownerReferences` peuvent être garbage-collected. Confirmée explicitement autorisée pour ces **deux seuls** PVC. Les PV `Retain` peuvent ensuite rester et nécessiter une opération de désallocation séparée.
4. Examiner la différence exacte Argo avant promotion : une seule ressource `postgresql.cnpg.io/Cluster matrix/matrix-mas-postgresql` doit être prunée par l'application `matrix-legacy-forensics`. Toute autre suppression = **NO-GO**.
5. Préparer dans la PR 2 : retirer `cluster.yaml` des ressources de `k8s/optional/matrix-legacy-source/kustomization.yaml`; configurer **uniquement** `matrix-legacy-forensics` avec `automated.prune: true, allowEmpty: true` ; ne pas retirer l'Application avant l'observation du prune et de la convergence.

Après fusion et sync : confirmer suppression du Cluster, Pod et PVC sources, détachement Longhorn, absence de nouveau crashloop, santé nouvelle base et routes ; si des PV/volumes restent en `Retain`, les attribuer précisément avant tout nettoyage complémentaire.

## Étape 3 — Nettoyage final des références (PR séparée)

Lorsque le Cluster et ses PVC sont absents et sans effet sur Matrix :
- Supprimer **seulement** l'ancienne entrée `ScheduledBackup/matrix-mas-postgresql-weekly` et `Backup/matrix-mas-postgresql-gap-remediation-20261020` dans leurs manifests multi-documents ;
- Supprimer **seulement** l'ancien `ObjectStore/matrix-mas-hetzner-store` si aucune autre référence n'est active ;
- Retirer les sélecteurs Cilium `cnpg.io/cluster: matrix-mas-postgresql` de `networkpolicy.yaml`, conserver les entrées propres à `matrix-mas-postgresql-clean` et à Synapse ;
- Nettoyer la définition `database-mas.yaml` inactive et l'application `matrix-legacy-forensics` seulement après la preuve de prune terminé et le contrôle de tous les liens Argo. Ne pas confondre retrait de la déclaration de l'Application et suppression du Cluster : l'ordre importe.
- Laisser les sauvegardes S3 historiques expirer selon leur propre rétention, ou qualifier explicitement et borner toute suppression S3 **au seul ancien préfixe** ; ne jamais agir sur le bucket ni les préfixes `matrix-mas-clean`/`matrix-synapse`.

La cause partagée des corruptions Matrix/Factory reste **UNKNOWN**. Ce nettoyage ne doit pas modifier Factory ou arrêter l'enquête de prévention. Les tests login Matrix et bot Factory restent également `NOT_EXECUTED` tant que les identités ne sont pas autorisées.

## Bilan

État initial : `Cluster/matrix/matrix-mas-postgresql` corrompu avec 117+ restarts, ancien PGDATA+WAL 15Gi provisionnés / environ 1.03Gi réellement utilisés au dernier inventaire, nouvel MAS fonctionnel. Phase 1 = GitOps seulement, **pas** de suppression. Les étapes 2–3 ne sont pas déclarées exécutées dans ce runbook.

## État final de la phase 3 — 2026-11-05

La PR #1005 a été fusionnée par GitHub avec le merge `6f3cc4902274dd6aaae8202f26c3d8b7af775a2f` après le préflight UID-scopé et les trois checks requis. Argo a ensuite réconcilié `apps-platform` sur cette révision puis `matrix-legacy-forensics` sur une source vide avec `prune: true` et `allowEmpty: true`.

Résultat observé après réconciliation :

- le Cluster `matrix/matrix-mas-postgresql`, le Pod historique et les deux PVC sont absents ;
- les PV historiques sont `Released` avec `Retain`, les deux volumes Longhorn sont `detached`, et aucune `VolumeAttachment` ne reste ;
- le nouveau `matrix-mas-postgresql-clean` et `matrix-synapse-postgresql` sont Ready ;
- les services historiques et leurs EndpointSlices ont disparu ;
- l'Application dédiée est `Synced/Healthy` avec zéro ressource gérée.

La phase 3 retire les déclarations GitOps historiques restantes : sauvegarde hebdomadaire suspendue, Backup de gap, ObjectStore `matrix-mas-hetzner-store`, sélecteurs Cilium de l'ancien cluster, source CNPG dormante et Application dédiée. Le préfixe S3 `cnpg/matrix-mas` n'est pas supprimé dans cette PR : sa suppression exige une vérification bornée des objets et de leur identité, sans toucher au bucket partagé ni aux préfixes clean/Synapse. Les PV `Retain` et volumes Longhorn détachés restent également conservés jusqu'à une opération de stockage explicitement qualifiée.
