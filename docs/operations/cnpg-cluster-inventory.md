# Inventaire des clusters CNPG et règle de création (PLT-267)

Règle (D-2026-11-13-02, jalon J4 Atlas ; texte dans `homelab-infra/docs/decisions.md`) : toute nouvelle base PostgreSQL va dans un cluster CNPG partagé (`pg-shared`). Quatre exceptions écrites au maximum : Authentik, Immich, Matrix, Factory (gelée). Une 5e exception exige une décision de Paul.

La garde `tests/harness/cnpg-cluster-allowlist-test.sh` (lancée par `just check`) refuse tout `Cluster` `postgresql.cnpg.io` absent de la table ci-dessous. Ajouter une ligne ici n'est donc pas un contournement : une ligne `à consolider` ou `partagé` créée après le 13/11/2026 est refusée en revue. Seule une ligne d'exception existante peut couvrir un cluster supplémentaire de la même application.

La consolidation se fait au fil de l'eau, une base à la fois, avec restauration prouvée (PLT-221) avant de retirer l'ancien cluster. Aucune migration de masse (PLT-169).

| Cluster | Application | Statut | Cible de consolidation |
| --- | --- | --- | --- |
| `pg-shared` | cluster partagé | partagé | cible |
| `authentik-postgresql-restored` | Authentik | exception (identité, D-02) | aucune |
| `immich-postgresql` | Immich | exception (données photo irremplaçables, restauration dédiée) | aucune |
| `matrix-synapse-postgresql` | Matrix | exception (identité, D-02) | aucune |
| `matrix-mas-postgresql-clean` | Matrix | exception (identité, D-02) | aucune |
| `factory-platform-postgresql` | Factory | exception (gelée) | aucune |
| `factory-platform-pg2` | Factory | exception (gelée) | aucune |
| `mastra-factory-postgresql` | Factory | exception (gelée) | aucune |
| `paperless-postgresql` | Paperless | à consolider | `pg-shared` |
| `sure-postgresql` | Sure | à consolider | `pg-shared` |
| `vikunja-postgresql` | Vikunja | à consolider | `pg-shared` |
| `romm-postgresql` | RomM | à consolider | `pg-shared` |
| `bookorbit-postgresql` | BookOrbit | à consolider | `pg-shared` |
| `polyfin-db` | Polyfin | à consolider | `pg-shared` |
| `pinepods-db` | PinePods | à consolider | `pg-shared` |
| `lasuite-docs-db` | La Suite | à consolider | `pg-shared` |
| `lasuite-yhub-db` | La Suite | à consolider | `pg-shared` |
| `lasuite-drive-db` | La Suite | à consolider | `pg-shared` |
| `hindsight-db` | Hindsight | à consolider | `pg-shared` |
| `hindsight-db-restore` | Hindsight (restauration) | à consolider | retrait après restauration |
| `sparkyfitness-db` | SparkyFitness | à consolider | `pg-shared` |
