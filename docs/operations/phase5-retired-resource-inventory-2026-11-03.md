# Phase 5 — inventaire des ressources historiques hors Factory

Capture runtime en lecture seule du 3 novembre 2026. Ce document prépare des
lots de suppression séparés ; il ne supprime aucune ressource et ne constitue
pas une autorisation de suppression.

## Garde-fous

- Factory, Matrix, Matrix Authentication Service, Mastra, Sandboxes, ARC et
  les sauvegardes critiques sont hors périmètre.
- Les PV ci-dessous sont `Released` avec une politique de rétention qui peut
  conserver le volume après retrait du PVC. Le `Released` seul ne prouve pas
  qu'il est supprimable.
- Le propriétaire GitOps doit être recherché dans l'historique Git et dans les
  Applications Argo avant toute suppression.
- Une suppression physique doit être une opération séparée, avec une liste
  blanche exacte des PV/volumes et une preuve de backup/restauration.
- Un revert Git ne restaure pas des données supprimées.

## Candidats nommés hors Factory

Les ressources suivantes sont des PV `Released` observés dans le cluster. Les
objets Longhorn portent le même nom que le PV. Aucun workload actif correspondant
n'a été trouvé dans les namespaces retirés lors de cette capture.

| Service | PV / volume | Claim | Classe | Taille | Décision actuelle |
| --- | --- | --- | --- | ---: | --- |
| Paperclip | `pvc-27ad61d8-550b-4c52-a119-d58cf248192a` | `paperclip/paperclip-data` | `longhorn-fast` | 10Gi | candidat, backup à prouver |
| Paperclip | `pvc-b05f3dff-df79-416e-a837-396bb4039516` | `paperclip/paperclip-postgresql-1-wal` | `longhorn-fast` | 10Gi | candidat, backup à prouver |
| Paperclip | `pvc-c5b65bed-9490-4567-8d4a-a707efe46330` | `paperclip/paperclip-postgresql-1` | `longhorn-fast` | 10Gi | candidat, backup à prouver |
| Listmonk | `pvc-8a7998ba-7603-41f7-bbeb-18a146a89ad6` | `listmonk/listmonk-uploads` | `longhorn-fast` | 5Gi | candidat, données explicitement non conservées |
| Listmonk | `pvc-b082624c-023e-4b4f-a4f1-45c6c9545f0f` | `listmonk/listmonk-postgresql-1` | `longhorn-fast` | 10Gi | candidat, données explicitement non conservées |
| Twenty | `pvc-2c9b046a-9177-4069-8c07-672a346709dd` | `twenty/twenty-postgresql-1` | `longhorn-fast` | 10Gi | candidat, données explicitement non conservées |
| Twenty | `pvc-5052b6c5-9815-4123-afe1-8c8f81515c3f` | `twenty/twenty-storage` | `longhorn-fast` | 5Gi | candidat, données explicitement non conservées |
| Dawarich | `pvc-370f5fa1-101f-479e-ab89-7805e9e87e59` | `dawarich/dawarich-postgis` | `longhorn-fast` | 20Gi | candidat, backup à vérifier |
| Dawarich | `pvc-a57e69bd-049d-4f30-879c-5328a3346f65` | `dawarich/dawarich-storage` | `longhorn-fast` | 20Gi | candidat, backup à vérifier |
| Dawarich | `pvc-c351c524-0830-4bad-81dc-0a995d77dfb1` | `dawarich/dawarich-public` | `longhorn-fast` | 5Gi | candidat, backup à vérifier |
| Metabase | `pvc-39130a95-ff2f-4679-900c-277b6bfd5c4a` | `metabase/metabase-postgresql-1` | `longhorn-fast` | 10Gi | candidat, backup à vérifier |
| Actual Budget | `pvc-aa30cb75-988e-4fbc-9a67-18bb4bc11581` | `actual-budget/actual-data` | `longhorn-fast` | 5Gi | candidat, données à qualifier |
| BabyBuddy | `pvc-fd4e5e89-29e9-4383-9549-aa10a0ae6883` | `babybuddy/config-babybuddy-0` | `longhorn-fast` | 1Gi | candidat, données à qualifier |

Capacité nominale potentiellement libérable pour cette liste : **121Gi**.
Cette valeur est une capacité provisionnée, pas l'espace réellement utilisé ni
un gain NVMe mesuré.

## Autres résidus non critiques à qualifier séparément

| PV / volume | Claim | Taille | Motif de blocage |
| --- | --- | ---: | --- |
| `pvc-2b8aeac3-df5c-47ac-b04f-25ffcde54d7a` | `aiostreams-restore-qual/aiostreams-data` | 4Gi | restore qualification, owner/backup à prouver |
| `pvc-ec6c47e0-0a80-40f8-bf63-4df1c72c2bad` | `aiostreams-restore-qual/aiostreams-data` | 4Gi | restore qualification, owner/backup à prouver |
| `pvc-862b5d3a-3584-46c6-a8db-89359159bac9` | `media/polyfin-db-restore-20261027-1` | 5Gi | restauration Polyfin à qualifier |

Les namespaces `invoice-ninja-restore-drill-*` et
`openclaw-restore-drill-*` contiennent encore des workloads, PVC et/ou
CronJobs : ils ne sont pas des candidats immédiats.

Les ressources `matrix-restore-*`, `dr-protect-*`, `dr-matrix-*`,
`authentik-postgresql-restored-*` et toutes les ressources `mastra-*` sont
explicitement exclues de ce lot.

## Procédure du futur lot de suppression

Avant toute action, produire une allowlist contenant exactement :

1. le PV et l'objet Longhorn ciblés ;
2. le claim historique et le namespace ;
3. l'absence de workload, Argo Application et dépendance active ;
4. le résultat de `just backup-audit` ou une preuve de non-valeur approuvée ;
5. la capacité réellement utilisée et le gain attendu ;
6. le plan de suppression physique et la vérification post-action.

La suppression doit rester hors de la PR qui modifie uniquement le GitOps
desired state.
