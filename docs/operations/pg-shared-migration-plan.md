# Plan d'ordre de migration vers pg-shared-homelab (PLT-375)

Statut : **PLAN seulement. Aucune migration lancée.** Respecte PLT-169 (pas de migration de
masse) et la règle de `docs/operations/cnpg-cluster-inventory.md` : une base à la fois, restauration
prouvée avant de retirer l'ancien cluster. Chaque étape est sa propre PR, sous mandat si elle
supprime des données.

## Prérequis communs (portes)

| Porte | Condition | État au 22/11/2026 |
| --- | --- | --- |
| P1 | Dump logique quotidien par base vers R2 en service (kube-ops#1794, CronJob Synced, un objet listé dans `homelab-backup-pgdump`) | en attente des racines ARC cloudflare-r2 et grafana-cloud |
| P2 | Drill de restauration de `pg-shared-homelab` | fait, RTO 284 s sur jeu vide (`pg-shared-app-restore-drill.md`) |
| P3 | D1b : rôle géré avec Secret neuf après restauration | non exécuté (MANDAT opérateur) |
| P4 | Dimensionnement : `pg-shared-homelab` fait 20 Gi de données, 5 Gi de WAL, 1 instance, limite 2 Gi de mémoire ; somme des bases à migrer vérifiée avant chaque étape | à relever par base |
| P5 | Version : source en PostgreSQL 18.3 (`system`), cible 18.4 (`standard`) : montée mineure, dump et restauration sans conversion | OK |

## Procédure type par base

1. Gabarit `app-database.example.tmpl` : rôle géré, Secret `pg-<ns>` généré, `Database`.
2. Gel de l'application (réplicas 0), `pg_dump -Fc` du cluster source, `pg_restore` dans la base cible, comptage de lignes par table avant/après.
3. Bascule de la chaîne de connexion, démarrage, test fonctionnel.
4. Sauvegarde (dump quotidien + Barman) de la nouvelle base, drill de restauration de cette base (mesure du RTO réel).
5. Ancien cluster conservé 7 jours, retrait ensuite par PR (suppression de PVC : MANDAT).
Retour arrière avant l'étape 5 : rebasculer la chaîne de connexion vers l'ancien cluster (intact, gelé en lecture).

## Ordre proposé

| Rang | Application | Cluster source | Taille source | Pourquoi dans cet ordre |
| --- | --- | --- | --- | --- |
| 1 | Vikunja | `vikunja-postgresql` (vikunja) | PVC 5 Gi | Le plus petit, tâches personnelles, arrêt toléré : valide la procédure et mesure un RTO sur données réelles |
| 2 | Sure | `sure-postgresql` (sure) | PVC 10 Gi | Données financières : à migrer une fois la procédure rodée, avec un contrôle des lignes par table strict ; vérifier les extensions utilisées avant (Rails) |
| 3 | Paperless | `paperless-postgresql` (paperless) | PVC 10 Gi | Index des documents lié à un volume de fichiers (`paperless-data`, `paperless-media`) : base et fichiers doivent rester cohérents ; en dernier car la restauration complète est déjà prouvée (PLT-171, RTO 10 min 29 s) et ce cluster est le mieux protégé aujourd'hui |

Critères de passage d'un rang au suivant : base migrée, drill de cette base avec RTO mesuré dans
les 30 min, aucune alerte dump ou Barman sur 3 jours.

## Risques à vérifier avant le rang 1

- Capacité : `pg-shared-homelab` en 1 instance partage CPU, mémoire (2 Gi) et IOPS entre toutes
  les bases ; ajouter Vikunja + Sure + Paperless demande de relever les limites. Cluster sans
  contrainte de ressources depuis le 20/11 : relever la limite avant, pas après un incident.
- Extensions : lister `pg_extension` de chaque source ; `shared_preload_libraries` du cluster
  cible est vide.
- `REVOKE CONNECT ... FROM PUBLIC` : chaque rôle applicatif doit avoir `CONNECT` sur sa base.
- Un incident sur le cluster partagé touche toutes les applications migrées : c'est le coût du
  partage, accepté par la décision option C du 16/11.

## Miniflux (PLT-152)

Nouvelle base, pas une migration : elle suit le même gabarit. Elle attend P1 et un client OIDC
Authentik (kube-ops#1594 et #1593 fermées, à rouvrir proprement).
