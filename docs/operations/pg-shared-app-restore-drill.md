# Drill de restauration par application depuis pg-shared (homelab)

Statut : **RTO MESURÉ le 22/11/2026 (PLT-375), RPO non mesuré.** Le drill a tourné par GitOps
(voie « Drill GitOps » ci-dessous), sur `pg-shared-homelab` : RTO du cluster 284 s. Le jeu de
données restauré est quasi vide (aucune application n'est encore migrée) : ce RTO est un
plancher, pas une garantie pour des bases de plusieurs Go. Le RPO ≤ 5 min reste non prouvé.
Le script `scripts/pg-shared-app-restore-proof.sh` (voie impérative, blocants B1 à B6) reste
non exécuté.

Contexte : un `Cluster` CloudNativePG et ses sauvegardes Barman couvrent tout le cluster.
Une seule application se restaure donc soit par PITR dans un cluster temporaire puis
dump ciblé (`--mode pitr`), soit par `pg_dump -Fc` vers une base temporaire (`--mode dump`).
Ce drill mesure les deux chemins. Étude de référence : section 4 de
`pg-shared-etude` (notes de session, non versionnées).

## Ce qui est en Git

| Chemin | Rôle |
| --- | --- |
| `scripts/pg-shared-app-restore-proof.sh` | Drill : dry-run par défaut, exécution gardée, mesure RTO/RPO, nettoyage |
| `docs/operations/pg-shared-app-restore-drill.md` | Ce runbook |

Aucun autre fichier n'est modifié. Le `.justfile` n'est pas touché : la commande n'y est
pas branchée.

## Garanties du script

- `--dry-run` par défaut. Aucun accès cluster, aucune écriture.
- `--execute` exige `--confirm I-APPROVE-PG-SHARED-APP-RESTORE-DRILL`. Sans cette chaîne exacte, refus avant tout accès.
- Relevé température informatif : maximum Tctl de la dernière heure (Prometheus via `scripts/kubectl-ro.sh`), affiché dans la sortie, sans seuil ni refus.
- Lecture seule sur la source (`kubectl-ro`). Les écritures passent par une seule fonction `drill_write`.
- `drill_write` refuse tout `delete` visant un PVC. Les PVC résiduels sont listés en lecture seule.
- Nettoyage du Cluster temporaire sur EXIT, INT et TERM. Un échec de suppression donne `CLEANUP=LEFTOVER` et un code de sortie 1.
- RPO mesuré seulement : `RPO = T_W - epoch max restauré`, où T_W vient du commit de la graine. Sans mesure, `STATUS=NOT_PROVEN`.

## Commandes exactes

### 1. Dry-run (sans risque, aucun accès cluster)

```
bash scripts/pg-shared-app-restore-proof.sh \
  --app <base_testee> --other-db <base_temoin> --source-namespace <namespace_source> \
  --mode pitr --id <suffixe_court>
```

Résultat attendu : le plan des étapes s'affiche et la dernière ligne est
`STATUS=NOT_TESTED RPO=NOT_MEASURED RTO=NOT_MEASURED`, code de sortie 0.

### 2. Refus attendus (vérifiés localement)

| Commande | Sortie attendue |
| --- | --- |
| sans `--other-db` | `REFUS: au moins un --other-db requis`, code 2 |
| `--namespace` ne finissant pas par `-drill` | `REFUS: --namespace doit se terminer par -drill`, code 2 |
| `--execute` sans `--confirm` | `REFUS: confirmation explicite absente`, code 2 |
| `--execute --confirm` correct, sans `PG_PROOF_IMAGE` | `REFUS: PG_PROOF_IMAGE requise`, code 2 |

### 3. Exécution (interdite tant que les blocants B1 à B5 ne sont pas levés)

```
PG_PROOF_IMAGE='<image>@sha256:<digest>' \
PG_PROOF_DB_SECRET='<nom_du_secret_applicatif>' \
PG_PROOF_OBJECTSTORE='<nom_objectstore_R2_lecture_seule>' \
bash scripts/pg-shared-app-restore-proof.sh \
  --app <base_testee> --other-db <base_temoin> --source-namespace <namespace_source> \
  --mode pitr --id <suffixe_court> \
  --execute --confirm I-APPROVE-PG-SHARED-APP-RESTORE-DRILL
```

Durée attendue : attente d'archivage de 360 s, puis restauration. Le RTO dépend du volume
de WAL à rejouer ; la littérature interne cite 3 à 29 min sur des clusters isolés.

Les noms des variables sont à remplir par Paul. Aucune valeur de secret n'est écrite dans
ce document ni dans le script.

## Résultats attendus et critères

| Indicateur | Source | PASS | FAIL | NOT_PROVEN |
| --- | --- | --- | --- | --- |
| Relevé température (informatif) | max Tctl 1 h (Prometheus) | affiché, hors verdict | — | affiché `indisponible`, hors verdict |
| `T_W_EPOCH` | logs du Job graine | présent | absent | — |
| RTO (`RTO_S`) | création → Ready | ≤ 1800 s | > 1800 s | non mesuré |
| RPO (`RPO_S`) | T_W − epoch max restauré | ≤ 300 s | > 300 s | non mesuré |
| `NONIMPACT` | empreintes des témoins source avant/après | `PASS` | `FAIL` (empreinte modifiée) | `NOT_TESTED` (Job non lancé) |
| `APP_ROWS` | Job verify | ≥ 1 | 0 | illisible |
| `CLEANUP` | suppression du Cluster temporaire | `OK` | `LEFTOVER` (action Paul) | — |

Verdict global : `STATUS=PASS` seulement si RPO et RTO sont mesurés dans les seuils et si le
non-impact est `PASS`. Un RPO n'est jamais déclaré ≤ 5 min sans mesure.

## Ce que Paul doit approuver avant tout passage à l'exécution

| Id | Blocant | Pourquoi |
| --- | --- | --- |
| B1 | Identité d'écriture du drill | `kubectl-rw` n'admet ni `Cluster`, ni `Job`, ni `exec`. Sans identité approuvée, `drill_write` échoue fermé (code 75). |
| B2 | Écriture de la table `restore_drill_marks` dans la base testée et les témoins | Écriture dans des bases de production : une table de marques. Suppression de la table après drill à approuver. |
| B3 | Capteur et seuil de température | Levé : le seuil de 70 °C est retiré du script (décision Paul, cluster sans contrainte de ressources). Le relevé Tctl reste informatif, sans condition d'arrêt. Plus de blocant. |
| B4 | ObjectStore R2 en lecture seule dans le namespace de drill | Le plugin barman-cloud lit l'ObjectStore du même namespace que le Cluster. Il faut une copie en lecture seule, avec un jeton `Object Read only` restreint au préfixe `homelab-backup-cnpg/<ns>`. Pas le jeton écrivain. |
| B5 | Image PostgreSQL pinée par digest et nom du Secret applicatif | Valeurs à fournir ; le script refuse une image sans `@sha256:`. |
| B6 | Résidus PVC | Une suppression de Cluster CNPG peut emporter ses PVC par owner reference. Décision D-13 de Paul : garder ou supprimer. Le script ne supprime jamais de PVC. |

Décisions hors périmètre de ce drill :

- Le mode `dump` mesure le chemin dump au moment du drill, pas le RPO du dump quotidien (24 h).
- Le RPO ≤ 5 min de `pg-shared` dépend aussi de `archive_timeout: 5min` sur le cluster source. Il est à vérifier séparément, pas par ce drill.

## D1b : restauration Barman avec un Secret de rôle neuf (secrets, lot 1)

Statut : **NOT_RUN.** Procédure seulement. **Obligatoire avant la première donnée réelle** dans `pg-shared-homelab` et avant de migrer une base existante vers un rôle au mot de passe généré. Elle ne bloque pas le merge du lot 1 (`docs/architecture/secrets-migration-spec.md`, §3.4 et lot 1). Exécution sous **MANDAT** : un opérateur la lance ; aucun agent ne la lance.

Ce qu'elle prouve (fait F5/F6 de la spec) : Barman ne sauvegarde aucun Secret ; sur un cluster reconstruit, l'ExternalSecret `pg-<ns>` est neuf (statut vide), ESO génère une valeur **neuve**, CNPG l'applique au rôle de la base restaurée, et la connexion réussit. Cette réapplication au premier passage après restauration est attendue mais non documentée par CNPG : c'est ce que D1b prouve.

Prérequis : les blocants B1 à B6 ci-dessus levés ; une application de test déjà créée avec le gabarit `app-database.example.tmpl` (rôle `<app>`, Secret `pg-<ns>`), avec des lignes synthétiques (jamais de donnée réelle).

Procédure :

1. Lancer le drill de restauration ci-dessus (`--mode pitr`) : le cluster temporaire `bootstrap.recovery` est créé dans un namespace `*-drill`.
2. Dans ce namespace, créer le rôle géré `<app>` avec un Secret **neuf** : un `Password` et un ExternalSecret `pg-<ns-du-drill>` (forme C : `CreatedOnce`, `Orphan`, classe `T1`, `cnpg.io/reload: "true"`), et la ligne `managed.roles` correspondante dans le Cluster temporaire. Aucune copie de la valeur de la source.
3. Observer, sans lire de valeur : `get cluster -n <ns-drill> <cluster> -o yaml` : condition `PasswordSecretChange` présente, rôle dans `managedRolesStatus` avec l'état `reconciled`.
4. Job de connexion dans le namespace du drill, avec les variables `PG*` de la copie : `psql -c 'select count(*) from restore_drill_marks'` réussit (lignes synthétiques restaurées).
5. Nettoyage : comme le drill (le script nettoie le Cluster temporaire) ; le Secret `Orphan` du drill est supprimé par l'opérateur (**MANDAT**).

Critère `PASS` (spec §3.4) : cluster temporaire restauré depuis R2, rôle géré avec un Secret neuf, connexion réussie, aucune valeur lue. `FAIL` : la connexion est refusée (mot de passe non réappliqué après restauration) ; dans ce cas T1 n'est plus « jetable » et le lot 1 doit être rouvert avant toute donnée réelle. Preuves : `docs/operations/secrets-migration-evidence.md`, section lot 1.

## Drill GitOps (voie retenue, PLT-375)

Les blocants B1 à B6 portent sur la voie impérative. Un agent n'a que la lecture cluster : le
drill passe donc par Argo, comme le drill Hindsight (PLT-301). Dossier
`k8s/applications/platform/pg-shared-restore-drill` (kube-ops#1820) : namespace isolé
(`pg-shared-restore-drill`, deny-all sauf DNS, R2 et opérateur CNPG), ExternalSecret en lecture
seule (`R2_CNPG_RESTORE_RO_*`, jamais le jeton écrivain), `ObjectStore` sur
`s3://homelab-backup-cnpg/homelab/pg-shared`, `Cluster` `bootstrap.recovery` (`serverName:
pg-shared-homelab`, base `app`, sans archiveur WAL, donc aucune écriture dans R2), Job
`pg-shared-restore-verify` (attend la base, inventaire, `pg_dump -Fc` de la base cible, relecture
`pg_restore --list`). Aucune écriture sur la base vivante : B1, B2, B4 sans objet. Aucun PVC
supprimé par un agent (B6) : le retrait du drill par PR laisse Argo supprimer l'application ;
les PVC résiduels éventuels sont listés en lecture seule.

Mesure du RTO, en lecture seule : `Cluster.metadata.creationTimestamp` jusqu'à la condition `Ready`
(`kubectl-ro.sh get cluster -n pg-shared-restore-drill pg-shared-restore -o json`).

## Preuves

Drill du 22/11/2026, `STATUS=PASS` sur le chemin PITR (dernier WAL archivé) puis dump ciblé.

| Indicateur | Valeur | Source |
| --- | --- | --- |
| Cluster créé (Argo) | 02:35:08 UTC | `creationTimestamp` |
| Cluster `Ready` | 02:39:52 UTC | condition `Ready` |
| **RTO (cluster)** | **284 s (4 min 44 s)**, seuil 1800 s : PASS | différence |
| Pod primaire restauré (job `full-recovery` puis démarrage) | 02:39:39 UTC | pod |
| Version restaurée | PostgreSQL 18.4 | Job verify |
| Taille des bases | `app` 8,0 Mo, `postgres` 8,0 Mo | Job verify |
| Dump de la base cible | 1 s, 1080 octets, 0 entrée : aucune table utilisateur | Job verify |
| `DRILL_STATUS` | `PASS` | logs du Job |

Limites (honnêtes) :

- La base restaurée ne contient aucune table applicative : `pg-shared-homelab` n'héberge encore
  aucune application. Le RTO mesure essentiellement le démarrage (Argo, ESO, tirage de la sauvegarde
  de base, rejeu de quelques WAL). Il croîtra avec le volume : à refaire avec chaque base migrée,
  avant retrait de l'ancien cluster (cf. `pg-shared-migration-plan.md`).
- Les 284 s incluent le temps de synchronisation Argo et de création de l'ExternalSecret.
- Le RPO n'est pas mesuré (`pg_last_xact_replay_timestamp` vide, aucune écriture témoin). Il
  dépend de `archive_timeout: 5min`, à prouver avec la table de marques du mode impératif.
- D1b (rôle géré avec Secret neuf après restauration) n'est pas exécuté ici.

Nettoyage : retrait du dossier par PR (voir PLT-375).
