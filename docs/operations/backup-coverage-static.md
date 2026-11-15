# Couverture statique des sauvegardes PVC (PLT-222)

Généré par `just backup-coverage-static` (`scripts/backup-coverage-static.py`). Ne pas éditer à la main.
Niveau de preuve : `STATIC`. Le rendu Git ne prouve ni un volume attaché, ni une sauvegarde `Completed` sur R2.

Règles : Velero couvre un PVC si un pod qui le monte est sélectionné par un Schedule actif (namespace, labels, `defaultVolumesToFsBackup`). Longhorn couvre un PVC Longhorn rattaché à un RecurringJob `backup` (labels source, sélecteur de StorageClass ou groupe `default`) et monté par un pod actif (`allowRecurringJobWhileVolumeDetached: false`). CNPG couvre un PVC de cluster si le WAL et une ScheduledBackup visent un ObjectStore R2.

- PVC déclarés : 71
- PVC couverts vers R2 : 61
- PVC irremplaçables non couverts : 0

| Namespace | PVC | StorageClass | Taille | Source | Couverture R2 | Écarts | Classe |
|---|---|---|---:|---|---|---|---|
| agentgateway | agentgateway-state | longhorn-fast | 1Gi | platform | Velero(velero-daily-agentgateway) + Longhorn(persistent-offsite-backup) | - | USEFUL — SQLite gateway state, rebuildable from Git with effort |
| atlantis-apps | atlantis-apps-data | longhorn-fast | 5Gi | atlantis-apps | **aucune** | Velero: no pod mounts it; Longhorn(persistent-offsite-backup-default-group) but no pod: detached | RETIRED — Atlantis pilot retired, retention-only path |
| atlantis-system | atlantis-pilot-data | longhorn-fast | 5Gi | atlantis-plan-only | **aucune** | Velero: no pod mounts it; Longhorn(persistent-offsite-backup) but no pod: detached | RETIRED — Atlantis pilot retired, retention-only path |
| auth | authentik-postgresql-restored-1 | longhorn-fast | 40Gi | auth | CNPG(R2) | - | IRREPLACEABLE — Authentik identity database |
| auth | authentik-postgresql-restored-1-wal | longhorn-fast | 30Gi | auth | CNPG(R2) | - | IRREPLACEABLE — Authentik identity database WAL |
| factory-platform | factory-cubestore-data | longhorn-bulk | 2Gi | platform | Velero(velero-daily-factory-platform) + Longhorn(persistent-offsite-backup-default-group) | - | REBUILDABLE — Cube Store pre-aggregations |
| factory-platform | factory-platform-pg2-1 | longhorn-bulk | 20Gi | platform | **aucune** | CNPG WAL=Hetzner base=Hetzner | USEFUL — Factory data platform database (active) |
| factory-platform | factory-platform-pg2-1-wal | longhorn-bulk | 5Gi | platform | **aucune** | CNPG WAL=Hetzner base=Hetzner | USEFUL — Factory data platform database WAL (active) |
| factory-platform | factory-platform-postgresql-1 | longhorn-bulk | 20Gi | platform | **aucune** | CNPG WAL=Hetzner base=none | RETIRED — Fenced forensic copy, replaced by factory-platform-pg2 (PLT-252) |
| factory-platform | factory-platform-postgresql-1-wal | longhorn-bulk | 5Gi | platform | **aucune** | CNPG WAL=Hetzner base=none | RETIRED — Fenced forensic copy, replaced by factory-platform-pg2 (PLT-252) |
| gpt-researcher | gpt-researcher-logs | longhorn-fast | 5Gi | ai | Longhorn(persistent-offsite-backup-default-group) | Velero: PVC label velero.io/exclude-from-backup | REBUILDABLE — Logs |
| gpt-researcher | gpt-researcher-my-docs | longhorn-fast | 10Gi | ai | Velero(velero-daily-gpt-researcher) + Longhorn(persistent-offsite-backup-default-group) | - | USEFUL — User research documents |
| gpt-researcher | gpt-researcher-outputs | longhorn-fast | 10Gi | ai | Velero(velero-daily-gpt-researcher) + Longhorn(persistent-offsite-backup-default-group) | - | USEFUL — Generated reports |
| hindsight-personal | hindsight-db-1 | longhorn-bulk | 10Gi | ai | CNPG(R2) | - | IRREPLACEABLE — Agent memory database |
| hindsight-personal | hindsight-db-1-wal | longhorn-bulk | 5Gi | ai | CNPG(R2) | - | IRREPLACEABLE — Agent memory database WAL |
| hindsight-restore-20261110 | hindsight-db-restore-1 | longhorn-bulk | 10Gi | ai | **aucune** | CNPG WAL=- base=none | DRILL — Restore proof copy |
| hindsight-restore-20261110 | hindsight-db-restore-1-wal | longhorn-bulk | 5Gi | ai | **aucune** | CNPG WAL=- base=none | DRILL — Restore proof copy |
| home-assistant | home-assistant-home-assistant-0 | longhorn-fast | 5Gi | automation | Velero(velero-daily-home-assistant) + Longhorn(persistent-offsite-backup-default-group) | - | USEFUL — Home Assistant configuration and history |
| immich | immich-postgresql-1 | longhorn-fast | 15Gi | media | CNPG(R2) | - | IRREPLACEABLE — Photo library metadata, albums, faces |
| immich | immich-postgresql-1-wal | longhorn-fast | 20Gi | media | CNPG(R2) | - | IRREPLACEABLE — Photo library metadata WAL |
| immich | library-immich-server-0 | longhorn-bulk | 100Gi | media | Velero(velero-daily-immich) + Longhorn(persistent-offsite-backup-default-group) | - | IRREPLACEABLE — Original photos and videos |
| immich | redis-data-immich-redis-master-0 | longhorn-fast | 1Gi | media | Longhorn(immich-redis-offsite) | Velero: pod not selected by any Schedule | REBUILDABLE — Job queue cache |
| invoice-ninja | data-invoice-ninja-mysql-0 | longhorn-bulk | 10Gi | invoice-ninja | Velero(velero-daily-invoice-ninja) + Longhorn(persistent-offsite-backup-default-group) | - | IRREPLACEABLE — Invoices database |
| invoice-ninja | invoice-ninja-public | longhorn-bulk | 1Gi | invoice-ninja | Velero(velero-daily-invoice-ninja) + Longhorn(persistent-offsite-backup) | - | USEFUL — Public assets and logos |
| invoice-ninja | invoice-ninja-redis | longhorn-bulk | 1Gi | invoice-ninja | Velero(velero-daily-invoice-ninja) + Longhorn(persistent-offsite-backup-default-group) | - | REBUILDABLE — Cache and queues |
| invoice-ninja | invoice-ninja-storage | longhorn-bulk | 5Gi | invoice-ninja | Velero(velero-daily-invoice-ninja) + Longhorn(persistent-offsite-backup) | - | IRREPLACEABLE — Invoice PDFs and documents |
| karakeep | data-web-0 | longhorn-fast | 5Gi | ai | Velero(velero-daily-karakeep) + Longhorn(persistent-offsite-backup-default-group) | - | IRREPLACEABLE — Bookmarks and archived pages |
| karakeep | meilisearch-data-meilisearch-0 | longhorn-fast | 5Gi | ai | Longhorn(persistent-offsite-backup-default-group) | Velero: pod not selected by any Schedule | REBUILDABLE — Search index |
| librechat | librechat-librechat-images | longhorn-bulk | 10Gi | Application/personal-librechat | Velero(velero-daily-librechat) + Longhorn(persistent-offsite-backup-default-group) | - | USEFUL — User uploaded files |
| librechat | librechat-mongodb | longhorn-bulk | 10Gi | Application/personal-librechat | Velero(velero-daily-librechat) + Longhorn(persistent-offsite-backup-default-group) | - | USEFUL — Conversations and agent settings |
| mastra-factory | mastra-factory-postgresql-1 | longhorn-bulk | 20Gi | platform | CNPG(R2) | - | USEFUL — Factory runs and agent memory |
| mastra-factory | mastra-factory-postgresql-1-wal | longhorn-bulk | 5Gi | platform | CNPG(R2) | - | USEFUL — Factory runs and agent memory WAL |
| matrix | matrix-mas-postgresql-clean-1 | longhorn-bulk | 10Gi | platform | CNPG(R2) | - | IRREPLACEABLE — Matrix identity (MAS) database |
| matrix | matrix-mas-postgresql-clean-1-wal | longhorn-bulk | 5Gi | platform | CNPG(R2) | - | IRREPLACEABLE — Matrix identity (MAS) database WAL |
| matrix | matrix-synapse-media | longhorn-bulk | 50Gi | platform | Velero(velero-daily-matrix) + Longhorn(persistent-offsite-backup) | - | IRREPLACEABLE — Matrix uploaded media |
| matrix | matrix-synapse-postgresql-1 | longhorn-bulk | 20Gi | platform | CNPG(R2) | - | IRREPLACEABLE — Matrix messages and rooms |
| matrix | matrix-synapse-postgresql-1-wal | longhorn-bulk | 5Gi | platform | CNPG(R2) | - | IRREPLACEABLE — Matrix messages and rooms WAL |
| mealie | mealie-data | longhorn-fast | 5Gi | catalog | Velero(velero-daily-mealie) + Longhorn(persistent-offsite-backup-default-group) | - | IRREPLACEABLE — Family recipes |
| media | aiostreams-data | longhorn-fast | 4Gi | media | Velero(velero-daily-aiostreams) + Longhorn(persistent-offsite-backup-default-group) | - | USEFUL — AIOStreams user configurations (SQLite) |
| media | bookorbit-data | longhorn-fast | 10Gi | media | Velero(velero-daily-bookorbit) + Longhorn(persistent-offsite-backup-default-group) | - | USEFUL — BookOrbit app data (library index, settings) |
| media | bookorbit-postgresql-1 | longhorn-fast | 10Gi | media | CNPG(R2) | - | USEFUL — BookOrbit database (users, reading progress) |
| media | media-share | longhorn-bulk | 2Ti | media | Longhorn(persistent-offsite-backup-default-group) | Velero: PVC label velero.io/exclude-from-backup | REBUILDABLE — Re-downloadable media (2Ti) |
| media | polyfin-data | longhorn-fast | 20Gi | media | Longhorn(persistent-offsite-backup-default-group) | Velero: pod not selected by any Schedule | USEFUL — Polyfin users, watch state, settings |
| media | polyfin-db-1 | longhorn-fast | 5Gi | media | **aucune** | CNPG WAL=Hetzner base=Hetzner | USEFUL — Polyfin database (R2 cutover PLT-227) |
| monitoring | storage-loki-0 | longhorn-bulk | 20Gi | monitoring | Longhorn(persistent-offsite-backup-default-group) | Velero: pod not selected by any Schedule | REBUILDABLE — Logs |
| mqtt | data-mosquitto-0 | longhorn-fast | 1Gi | automation | Velero(velero-daily-mqtt) + Longhorn(persistent-offsite-backup-default-group) | - | REBUILDABLE — MQTT retained messages |
| ntfy | ntfy-data | longhorn-fast | 1Gi | catalog | Velero(velero-daily-ntfy) + Longhorn(persistent-offsite-backup-default-group) | - | REBUILDABLE — Notification cache and users |
| open-connector | open-connector-data | longhorn-bulk | 2Gi | platform | Velero(velero-daily-open-connector) + Longhorn(persistent-offsite-backup-default-group) | - | USEFUL — Connector state |
| opencode | opencode-data-pvc | longhorn-fast | 5Gi | ai | Velero(velero-daily-opencode) + Longhorn(persistent-offsite-backup-default-group) | - | USEFUL — Agent sessions |
| opencode | opencode-workspace-pvc | longhorn-fast | 10Gi | ai | Velero(velero-daily-opencode) + Longhorn(persistent-offsite-backup-default-group) | - | REBUILDABLE — Git working copies |
| paperless | paperless-data | longhorn-fast | 5Gi | catalog | Velero(velero-daily-paperless) + Longhorn(persistent-offsite-backup-default-group) | - | IRREPLACEABLE — Document index and classifier |
| paperless | paperless-media | longhorn-fast | 20Gi | catalog | Velero(velero-daily-paperless) + Longhorn(persistent-offsite-backup-default-group) | - | IRREPLACEABLE — Original scanned documents |
| paperless | paperless-postgresql-1 | longhorn-fast | 10Gi | catalog | CNPG(R2) | - | IRREPLACEABLE — Document metadata database |
| pinepods | pinepods-backups | longhorn-fast | 3Gi | web | Longhorn(persistent-offsite-backup-default-group) | Velero: PVC label velero.io/exclude-from-backup | REBUILDABLE — Application export copies, DB on CNPG |
| pinepods | pinepods-db-1 | longhorn-fast | 60Gi | web | CNPG(R2) | - | USEFUL — Podcast subscriptions and progress |
| pinepods | pinepods-downloads | longhorn-fast | 30Gi | web | Longhorn(persistent-offsite-backup-default-group) | Velero: PVC label velero.io/exclude-from-backup | REBUILDABLE — Re-downloadable episodes |
| romm | romm-assets | longhorn-fast | 20Gi | games | Velero(velero-daily-romm) + Longhorn(persistent-offsite-backup-default-group) | - | USEFUL — Saves, states and screenshots |
| romm | romm-library | longhorn-bulk | 100Gi | games | Velero(velero-daily-romm) + Longhorn(persistent-offsite-backup-default-group) | - | USEFUL — ROM library, hard to rebuild |
| romm | romm-postgresql-1 | longhorn-fast | 10Gi | games | CNPG(R2) | - | USEFUL — RomM metadata database |
| romm | romm-postgresql-1-wal | longhorn-fast | 5Gi | games | CNPG(R2) | - | USEFUL — RomM metadata database WAL |
| romm | romm-redis-data | longhorn-fast | 2Gi | games | Velero(velero-daily-romm) + Longhorn(persistent-offsite-backup-default-group) | - | REBUILDABLE — Cache |
| romm | romm-resources | longhorn-bulk | 20Gi | games | Velero(velero-daily-romm) + Longhorn(persistent-offsite-backup-default-group) | - | REBUILDABLE — Scraped metadata and covers |
| rustical-pilot | rustical-data | longhorn-fast | 1Gi | platform | **aucune** | Velero: no pod mounts it; Longhorn(persistent-offsite-backup-default-group) but no pod: detached | RETIRED — Previous pilot PVC, replaced by rustical-data-bulk, no pod |
| rustical-pilot | rustical-data-bulk | longhorn-bulk | 1Gi | platform | Velero(velero-daily-rustical-pilot) + Longhorn(persistent-offsite-backup-default-group) | - | IRREPLACEABLE — Calendars and contacts (pilot, synthetic data today) |
| stirling-pdf | stirling-config | longhorn-fast | 2Gi | catalog | Velero(velero-daily-stirling-pdf) + Longhorn(persistent-offsite-backup-default-group) | - | REBUILDABLE — Tool configuration |
| sure | sure-postgresql-1 | longhorn-fast | 10Gi | catalog | CNPG(R2) | - | IRREPLACEABLE — Personal finance database |
| sure | sure-storage | longhorn-fast | 5Gi | catalog | Velero(velero-daily-sure) + Longhorn(persistent-offsite-backup) | - | IRREPLACEABLE — Finance attachments |
| trilium | trilium-data | longhorn-fast | 5Gi | web | Velero(velero-daily-trilium) + Longhorn(persistent-offsite-backup-default-group) | - | IRREPLACEABLE — Personal notes |
| vikunja | vikunja-files | longhorn-fast | 2Gi | catalog | Velero(velero-daily-vikunja) + Longhorn(persistent-offsite-backup-default-group) | - | IRREPLACEABLE — Task attachments |
| vikunja | vikunja-postgresql-1 | longhorn-fast | 5Gi | catalog | CNPG(R2) | - | IRREPLACEABLE — Tasks database |
| wellness | sparkyfitness-db-1 | longhorn-bulk | 5Gi | platform | CNPG(R2) | - | IRREPLACEABLE — Sport and health data |

## Sources non rendues

- ApplicationSet/hermes-personal-tenants: generated apps not rendered
- Application/personal-sparkyfitness (namespace wellness): git-source chart not rendered; PVC inventory unknown; Velero Schedules on the namespace: velero-daily-sparkyfitness
