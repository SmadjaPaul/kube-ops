# Drill de restauration par application depuis pg-shared (homelab)

Statut : **NOT_TESTED.** Ce runbook et `scripts/pg-shared-app-restore-proof.sh` sont
préparés. Le cluster `pg-shared` homelab n'existe pas encore : aucune restauration n'a
été lancée, aucun RPO ni RTO n'est mesuré. Tant que la section « Preuves » est vide, rien
ici ne prouve un RPO ≤ 5 min ni un RTO ≤ 30 min.

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
- Gate température : relevé Prometheus via `scripts/kubectl-ro.sh`, refus si ≥ 70 °C ou valeur absente.
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
| Gate température | relevé Prometheus | < 70 °C | ≥ 70 °C : aucune écriture | valeur absente (gate fermé) |
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
| B3 | Capteur de température | La requête par défaut (Tctl, job `proxmox-host`) donne une moyenne de 88 °C sur 7 j (`compute-baseline-2026-11-12.md`), donc le gate refuserait presque toujours. Le relevé 62 °C cité dans `pg-shared-oke-backup-drill.md` vient d'un autre capteur. Paul choisit le capteur et confirme le seuil. |
| B4 | ObjectStore R2 en lecture seule dans le namespace de drill | Le plugin barman-cloud lit l'ObjectStore du même namespace que le Cluster. Il faut une copie en lecture seule, avec un jeton `Object Read only` restreint au préfixe `homelab-backup-cnpg/<ns>`. Pas le jeton écrivain. |
| B5 | Image PostgreSQL pinée par digest et nom du Secret applicatif | Valeurs à fournir ; le script refuse une image sans `@sha256:`. |
| B6 | Résidus PVC | Une suppression de Cluster CNPG peut emporter ses PVC par owner reference. Décision D-13 de Paul : garder ou supprimer. Le script ne supprime jamais de PVC. |

Décisions hors périmètre de ce drill :

- Le mode `dump` mesure le chemin dump au moment du drill, pas le RPO du dump quotidien (24 h).
- Le RPO ≤ 5 min de `pg-shared` dépend aussi de `archive_timeout: 5min` sur le cluster source. Il est à vérifier séparément, pas par ce drill.

## Preuves

Vide. À remplir uniquement après exécution réelle, avec les lignes `STATUS=`, `RTO_S=`,
`RPO_S=`, `NONIMPACT=`, `CLEANUP=` et l'identifiant `--id` utilisé.
