# Réversibilité des objets stateful

Date : 17/11/2026. Périmètre : racines Argo `k8s/applications/**`, `k8s/poc/**`, `k8s/optional/**`, `k8s/clusters/oracle-a1/**`. Niveau de preuve : STATIC (rendu Git) et lecture runtime seule. Aucune restauration n'est prouvée par ce document.

## Classes

| Classe | Sens | Exemples |
|---|---|---|
| A | Réversible par Git, aucune donnée perdue au retrait | Deployment, Service, ObjectStore, ScheduledBackup, Schedule Velero, StatefulSet (PVC volumeClaimTemplates conservés) |
| B | Réversible sous préconditions : PV `Retain`, rebind manuel possible. Autorisation et sauvegarde datée requises | PVC en `longhorn-fast` ou `longhorn-bulk` |
| C | Potentiellement irréversible. Autorisation explicite requise | PV `Delete` (oracle-a1, `oci-bv`), Cluster CNPG sans restauration prouvée, Namespace et CRD (cascade), Secret généré non rejouable |

## Sémantique Argo CD (v3.5.1, tracking par annotation)

- `Prune=false` : le retrait du fichier dans Git laisse la ressource dans le cluster ; l'Application passe OutOfSync. C'est la seule protection contre le prune automatique.
- `Delete=false` : protège contre la suppression de l'Application (finalizer `resources-finalizer.argocd.argoproj.io`). Ne protège pas contre un retrait Git.
- `reclaimPolicy` du PV : `Retain` conserve les données après suppression du PVC (PV `Released`, rebind manuel) ; `Delete` les supprime.
- `preserveResourcesOnDeletion` de l'ApplicationSet : absent aujourd'hui, proposé au bootstrap, hors de cette PR.

## Procédure B (PVC `Retain`)

1. Prouver une sauvegarde récente (Velero ou Longhorn) avant toute action.
2. Retirer le fichier de Git : avec `Prune=false`, le PVC reste. Ce retrait ne supprime rien.
3. Supprimer le PVC seulement par action explicite de l'opérateur, après la sauvegarde. Le PV passe `Released` et peut être rebindé.

## Escalade C

Aucun retrait ni suppression sans : décision écrite de Paul, restauration prouvée par un drill daté, et plan de retour.

## Restauration n'est pas rollback

- Un rollback Git restaure les manifestes, pas les données.
- Un rollback Git ne suffit pas pour : un secret régénéré (nouvelle valeur), un PV `Delete`, des données écrites après le retrait, un Cluster CNPG dont la restauration n'est pas prouvée, une cascade de Namespace ou de CRD.

## État des preuves

- Cette PR ne re-prouve aucune restauration.
- Runbooks existants, non revalidés ici : `pg-shared-oke-backup-drill.md`, `pg-shared-app-restore-drill.md`, `plt-171-paperless-full-restore-drill.md`, `plt-202-matrix-mas-restore-drill.md`, `plt-221-sparkyfitness-r2-restore-drill.md`, `plt-222-ntfy-r2-velero-restore-drill.md`.

## Limites de cette protection

- Objets hors périmètre de cette PR (`k8s/infrastructure/**`) : `pg-shared-homelab` sans `Delete=false`, Cluster `authentik-postgresql-restored` sans protection.
- CRD : aucune protection. Un retrait de la racine `cnpg-operator` supprimerait les CRD CNPG et donc les Clusters.
- PVC non protégés en conflit avec des PR ouvertes : `agentgateway-state`, `atlantis-apps-data` (`Delete=false` seul), Cluster `factory-platform-pg2`.
- PVC de `volumeClaimTemplates` : créés par le StatefulSet, non suivis par Argo, conservés par défaut (`whenDeleted: Retain`).
