# Données irremplaçables et chiffrement côté client — PLT-285

Ce document fixe le périmètre des données irremplaçables, l'outil de
chiffrement côté client et la gestion de la clé, avant toute mise en œuvre.
Il prépare la tranche d'implémentation de PLT-264 (jalon J3 « Récupérable »).

- Niveau de preuve : `STATIC`. L'inventaire vient des manifests Git du
  14/11/2026 (base `6b80226`). Aucun accès cluster, aucune lecture de secret.
- Ce document ne modifie aucune sauvegarde. Velero/Kopia et CNPG/Barman
  restent en place (D-2026-11-11-05 : aucun mécanisme n'est retiré avant que
  son successeur soit prouvé).
- Décisions de référence (homelab-infra `docs/decisions.md`) :
  D-2026-11-11-05 (classer par irremplaçabilité), D-2026-11-13-02 (J3,
  exceptions CNPG Authentik/Immich/Matrix). Ticket source : PLT-170.

## Conclusion

- **Outil choisi : restic**, dans un dépôt dédié sur R2, en complément des
  sauvegardes existantes.
- **Clé** : Paul génère le mot de passe maître hors ligne. Une copie papier est
  rangée hors domicile. Doppler porte seulement une clé d'exécution distincte.
  Aucune clé n'est stockée chez Cloudflare.
- **Première tranche** : Immich (photos + base), Paperless (documents + base).
- **Restauration test** : hors cluster, dans un îlot isolé, avec le mot de passe
  ressaisi depuis la copie papier.

## Constat : les sauvegardes actuelles ne sont pas chiffrées côté client hors fournisseur

Fait 1. CNPG/Barman écrit vers R2 sans chiffrement côté client. Les
`ObjectStore` `*-r2-store` déclarent `wal.compression` et `data.compression`
(gzip), sans clé de chiffrement client (exemple :
`k8s/applications/media/immich/immich-server/database-r2.yaml`). R2 chiffre au
repos avec une clé que Cloudflare détient.

Fait 2. Velero/Kopia chiffre côté client, mais la clé est dans Doppler
seulement. Le mot de passe du dépôt Kopia vient de la clé Doppler
`HETZNER_S3_VELERO_REPOSITORY_PASSWORD`, via l'`ExternalSecret`
`velero-repo-credentials`
(`k8s/infrastructure/controllers/velero/externalsecret.yaml`). Le dépôt n'a
aucune copie hors ligne de cette clé versionnée en Git.

Conséquence. La perte du projet Doppler rend les sauvegardes Velero illisibles.
Une compromission du compte Cloudflare expose les sauvegardes CNPG en clair.
PLT-264 interdit ces deux cas.

Transition des copies Barman en clair. Le dépôt restic ne protège pas les
copies Barman déjà présentes sur R2. Ordre imposé :

1. Les copies Barman restent en place tant que la restauration restic d'une
   application n'est pas prouvée (D-2026-11-11-05).
2. Après cette preuve, Paul décide pour chaque base : chiffrement côté client
   de l'archive Barman, ou retrait des copies Barman en clair de R2.
3. Le retrait d'une copie est une suppression de sauvegarde : accord de Paul
   requis (AGENTS.md, Safety). Il ne retire jamais la seule copie.

## Inventaire (STATIC, depuis les racines Argo actives)

Racines lues : `k8s/bootstrap/argocd-root/applications-applicationset.yaml` et
les `kustomization.yaml` de `k8s/applications/*`. Un manifest hors de ces
racines (exemple : `k8s/applications/media/bookorbit`) n'est pas compté comme
déployé.

Classement selon D-2026-11-11-05. « Irremplaçable » qualifie la nature de la
donnée. La présence de données réelles n'est pas prouvée ici : PLT-170 consigne
qu'aucune donnée utilisateur n'est jugée critique au 12/11/2026. Le
classement s'applique dès le premier usage réel.

### Irremplaçable — première tranche chiffrée

| Application | Donnée | Objet Git | Protection actuelle |
| --- | --- | --- | --- |
| Immich | photos et vidéos originales | PVC `library` (StatefulSet `immich-server`, 100Gi, `longhorn-bulk`) | Velero `daily-immich` → BSL `r2` |
| Immich | métadonnées, albums, visages | CNPG `immich/immich-postgresql` (15Gi) | Barman `immich-r2-store` |
| Paperless | documents originaux et archives | PVC `paperless-media` (20Gi), `paperless-data` (5Gi) | Velero `daily-paperless` |
| Paperless | index, étiquettes, métadonnées | CNPG `paperless/paperless-postgresql` (10Gi) | Barman `paperless-r2-store` |

### Irremplaçable — tranches suivantes

| Application | Donnée | Objet Git | Remarque |
| --- | --- | --- | --- |
| Vikunja | tâches | CNPG `vikunja-postgresql`, PVC `vikunja-files` | PLT-170 : priorité retirée ; coût faible |
| SparkyFitness | santé et sport | CNPG `wellness/sparkyfitness-db` | racine `k8s/optional/sparkyfitness` importée par `platform` |
| Invoice Ninja | factures | PVC `invoice-ninja-storage`, dump MySQL `invoice-ninja-mysql-logical-backup` | |
| Sure | finances | CNPG `sure-postgresql`, PVC `sure-storage` | |
| Rustical | calendriers et contacts | PVC du pilote `rustical-pilot` | pilote sur données synthétiques |
| Hindsight | mémoires d'agents | CNPG `hindsight-db` | |
| Trilium, Karakeep, Mealie | notes, signets, recettes | PVC `trilium-data`, PVC Karakeep, PVC `mealie-data` | |
| RomM | sauvegardes de jeu | PVC `romm-assets` | à qualifier : contenu exact non prouvé |
| Authentik | identité | CNPG `authentik-postgresql-restored` | ressource d'identité : accord de Paul requis |
| Matrix | identité, messages, médias | CNPG `matrix-synapse-postgresql`, `matrix-mas-postgresql-clean`, PVC `matrix-synapse-media` | ressource d'identité : accord de Paul requis |

### Reconstructible — hors sauvegarde chiffrée

| Classe | Exemples | Source de reconstruction |
| --- | --- | --- |
| Médias re-téléchargeables | Polyfin, AIOStreams, Decypharr, AudioBookRequest, `media-share`, `romm-library`, `pinepods-downloads` | fournisseurs et catalogues |
| Caches et files | Redis d'Immich (`redis-data-immich-redis-master-0`) et de RomM (`romm-redis-data`) | régénéré au démarrage |
| Index et modèles | Immich ML, SearXNG | régénéré |
| Applications sans état utile | Stirling-PDF, IT-Tools, ntfy, Open Connector, agentgateway | GitOps |
| Observabilité | métriques, journaux | hors politique (commentaire dans `velero/schedules/kustomization.yaml`) |
| Factory gelée | `factory-platform`, `mastra-factory` | données synthétiques ; exception CNPG D-2026-11-13-02 |
| Configuration | manifests, secrets | Git et Doppler ; états OpenTofu protégés par homelab-infra |

## Comparatif des outils

Critères : chiffrement côté client, clé hors fournisseur, compatibilité S3/R2,
restauration sans Kubernetes, copie hors ligne, rotation de clé.

| Critère | restic | Kopia (dépôt autonome, clé hors fournisseur) | rclone crypt |
| --- | --- | --- | --- |
| Chiffrement | AES-256-CTR + Poly1305 ; mot de passe dérivé par scrypt | AES-256-GCM ou ChaCha20-Poly1305 ; mot de passe dérivé par scrypt | XSalsa20-Poly1305 par fichier ; noms chiffrés |
| Snapshots, déduplication | oui | oui | non : miroir de fichiers |
| R2 (S3) | backend `s3` natif | backend `s3` natif ; R2 déjà utilisé par Velero (PLT-222) | backend `s3` natif |
| Plusieurs clés pour un dépôt | oui (`restic key add`) : une clé papier, une clé d'exécution | non : un mot de passe par dépôt | non : un mot de passe par remote |
| Copie hors ligne | `restic copy` vers un dépôt sur disque | `kopia repository sync-to` | `rclone sync` |
| Vérification | `restic check --read-data-subset` | `kopia snapshot verify` | `rclone cryptcheck` |
| Restauration hors cluster | binaire unique | binaire unique | binaire unique |
| Risque propre | la clé d'exécution lit tout le dépôt | confusion avec le dépôt Kopia géré par Velero | une suppression ou un chiffrement malveillant se propage au miroir |

### Choix : restic

1. restic accepte plusieurs mots de passe pour un même dépôt. Le mot de passe
   papier de Paul et la clé d'exécution de Doppler sont donc distincts. Paul
   révoque la clé d'exécution sans réécrire les données.
2. Kopia offre le même chiffrement, mais un seul mot de passe par dépôt. La
   clé papier serait alors la clé d'exécution présente dans Doppler. Un second
   dépôt Kopia à côté du dépôt Velero crée aussi deux usages du même outil
   avec des règles différentes.
3. rclone crypt n'a ni snapshot ni déduplication. Une suppression ou un
   chiffrement malveillant de la source se propage à la copie. rclone crypt est
   rejeté comme sauvegarde principale.
4. restic restaure avec un seul binaire, sans Kubernetes, sans Velero et sans
   Doppler. Ce cas est celui de la reprise après sinistre.

Limite acceptée. restic n'a pas de chiffrement asymétrique. Le job de
sauvegarde peut donc relire le dépôt. Mitigation : identité R2 limitée au
bucket restic ; rétention gérée par un job distinct (`forget --prune`) ; copie
hors ligne `restic copy` qui ne se propage pas en suppression.

## Gestion de la clé

Règles :

- La clé n'est jamais seule dans Doppler.
- La clé n'est jamais chez Cloudflare : ni dans un bucket R2, ni dans Secrets
  Store, ni dans un secret de Worker.
- La clé n'est jamais dans Git, Linear, un journal de CI ou une conversation
  d'agent.
- Un agent ne lit, n'affiche et ne génère jamais le mot de passe maître.

Fait technique. restic stocke dans le dépôt (`keys/`) la clé maître chiffrée
par chaque mot de passe. Le bucket R2 contient donc la clé maître enveloppée,
jamais un mot de passe. Un mot de passe à forte entropie rend une attaque hors
ligne de ces fichiers irréaliste.

### Procédure (Paul)

1. **Générer.** Sur son poste, Paul génère le mot de passe maître :
   au moins 8 mots Diceware ou 32 caractères aléatoires. Aucune copie
   numérique n'est conservée hors du gestionnaire de mots de passe personnel
   de Paul, si Paul en utilise un.
2. **Imprimer.** Paul imprime une fiche : mot de passe maître, nom du bucket,
   identifiant du dépôt (`restic cat config`, non secret), date. Paul
   n'utilise pas une imprimante réseau partagée qui conserve les travaux.
3. **Ranger.** Paul range la fiche hors du domicile principal, dans une
   enveloppe scellée et datée.
4. **Initialiser.** Paul initialise le dépôt avec le mot de passe maître
   (`restic init`), puis ajoute la clé d'exécution (`restic key add`).
5. **Distribuer la clé d'exécution.** Paul enregistre la clé d'exécution dans
   Doppler `cluster/prd` sans l'afficher. ESO la livre au namespace du job.
6. **Confirmer.** Paul confirme sur PLT-264 que la fiche est rangée. Paul ne
   colle jamais la clé.

### Rotation et perte

- Clé d'exécution compromise : retirer le mot de passe ne suffit pas. Avec
  ce mot de passe et un accès en lecture au dépôt, un attaquant a déjà pu
  déchiffrer la clé maître. Celle-ci ne change pas. Paul crée donc un nouveau
  dépôt avec un nouveau mot de passe maître et une nouvelle clé d'exécution,
  reprend une sauvegarde complète, prouve la restauration, puis supprime
  l'ancien dépôt.
- Rotation planifiée sans compromission : `restic key add`, puis
  `restic key remove` de l'ancienne clé, mise à jour de Doppler. Les données
  ne sont pas réécrites.
- Fiche papier perdue : Paul génère un nouveau mot de passe maître, l'ajoute
  (`restic key add`), retire l'ancien, imprime une nouvelle fiche.
- Clé maître exposée : Paul crée un nouveau dépôt, reprend une sauvegarde
  complète, puis supprime l'ancien dépôt après la preuve de restauration.

## Restauration test en îlot isolé

Objectif : prouver la restauration sans le cluster, sans Doppler et sans clé
d'exécution. Ce test répond au critère `RUNTIME` de PLT-264.

1. **Îlot.** Une machine jetable hors cluster (VM ou poste), sans route vers
   les services de production. Aucun PVC de production n'est monté.
2. **Accès.** Une identité R2 en lecture seule, limitée au bucket restic.
3. **Clé.** Paul ressaisit le mot de passe maître depuis la fiche papier. La
   clé d'exécution n'est pas utilisée.
4. **Restauration.** Chaque snapshot porte un tag application et type de
   donnée : `immich-files`, `immich-postgres`, `paperless-files`,
   `paperless-postgres`. L'îlot sélectionne chaque snapshot par son tag, par
   exemple `restic restore latest --tag immich-files --target <répertoire de
   l'îlot>`. Le dump sélectionné par `--tag immich-postgres` (ou
   `paperless-postgres`) est restauré dans une instance PostgreSQL jetable de
   la même version majeure. Les deux snapshots restaurés appartiennent au même
   cycle de sauvegarde.
5. **Contrôle.** Le job de sauvegarde produit un manifeste SHA-256 inclus dans
   le snapshot. L'îlot recalcule les sommes et les compare. Pour la base, des
   requêtes en lecture seule comptent les lignes des tables principales.
   L'îlot démarre ensuite l'application sur la base et les fichiers restaurés.
   Un échantillon d'objets de la base (photos, documents) doit s'ouvrir.
6. **Mesures.** Consigner le RPO (âge du snapshot) et le RTO (durée de bout en
   bout), sans contenu sensible.
7. **Nettoyage.** Détruire l'îlot et ses données après la mesure.

Un exercice in-cluster suit le modèle `plt-202-matrix-mas-restore-drill.md`
(namespace de drill, destination AppProject dédiée). Il complète le test hors
cluster ; il ne le remplace pas.

## Tranche d'implémentation (à créer sous PLT-264)

- Bucket R2 dédié et identité d'écriture limitée : homelab-infra.
- CronJobs restic dans kube-ops : fichiers (montage en lecture seule des PVC)
  et dumps PostgreSQL. Le dump passe par
  `restic backup --stdin-from-command -- pg_dump -Fc ...` : restic ne crée
  aucun snapshot si `pg_dump` sort en erreur. Un pipe `pg_dump | restic backup
  --stdin` est interdit : il enregistre un dump tronqué comme un succès.
- Cohérence fichiers/base : un cycle exécute d'abord le dump, puis la
  sauvegarde des fichiers. Un fichier ajouté entre les deux est orphelin, sans
  effet sur la restauration. Une suppression passe par la corbeille de
  l'application (Immich, Paperless), donc un fichier référencé par le dump
  reste présent. Le drill démarre l'application sur les deux jeux restaurés
  pour le prouver.
- Tags restic par application et type de donnée (voir la restauration test).
- Rétention et `restic check` planifiés ; alerte sur échec.
- Copie hors ligne `restic copy` vers un disque que Paul branche.

## Checks

- Lancés : lecture des racines Argo et des manifests (`STATIC`).
- Non lancés : `just inventory` (le `yq` local n'est pas la version attendue
  par `scripts/inventory.mjs`) ; toute observation runtime (hors périmètre du
  ticket).
