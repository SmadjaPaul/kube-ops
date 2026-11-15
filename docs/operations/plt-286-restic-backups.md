# Sauvegardes restic chiffrées d'Immich et de Paperless — PLT-286

Mise en œuvre du choix de PLT-285 (restic, chiffrement côté client, R2).
Mot de passe : homelab-infra D-2026-11-15-10 et
`docs/operations/restic-master-password.md`.

## Conclusion

- Les manifests sont dans `k8s/applications/media/immich/restic-backup/`,
  `k8s/applications/catalog/paperless/restic-backup/` et le composant
  `k8s/components/restic-backup/` (scripts).
- Ils sont **activés** par la PR d'activation (imports `- restic-backup` dans les kustomizations Immich et Paperless).
  L'activation est une PR d'une ligne par application, mergée seulement après
  les préalables ci-dessous (clés R2 d'écriture présentes par nom).
- Contrat testé : `bash tests/harness/restic-backup-contract-test.sh`
  (inclus dans `just check`).

## Conception

| Point | Choix |
| --- | --- |
| Dépôts | bucket R2 dédié `homelab-backup-restic`, un dépôt par application : `immich/`, `paperless/` |
| Cycle quotidien | init `postgres-dump` (`restic backup --stdin-from-command -- pg_dump --format=custom`), puis conteneur `files` ; un dump en échec arrête le pod avant les fichiers |
| Tags | `immich-postgres`, `immich-files`, `paperless-postgres`, `paperless-files` ; hôte restic fixe (`<app>-restic`) |
| Manifeste | `/manifest/SHA256SUMS` (chemins relatifs à `/`, `sha256sum -c` depuis la cible de restauration) et `/manifest/INDEX.tsv`, dans le snapshot des fichiers |
| Sources | PVC montés `readOnly` (volume et montage) ; aucun accès en écriture aux données |
| Exclusions | Immich `thumbs/`, `encoded-video/` ; Paperless `data/index/`, `data/log/` (régénérés par l'application) |
| Rétention | hebdomadaire : `forget --group-by host,tags --keep-daily 7 --keep-weekly 5 --keep-monthly 12`, puis `prune --max-unused 10%` |
| Intégrité | hebdomadaire : `restic check --read-data-subset 5%` |
| Restauration à blanc | hebdomadaire, en mémoire : dump décodé par `pg_restore --file=/dev/null`, 20 fichiers tirés au hasard comparés au manifeste |
| Alerte | homelab-infra `restic_backup_failed` (Grafana Cloud) ; métriques `kube_cronjob_status_last_*{cronjob=~".*-restic-.*"}` ajoutées à l'allowlist Alloy |
| Réseau | `CiliumNetworkPolicy` : HTTPS vers `*.eu.r2.cloudflarestorage.com`, DNS, PostgreSQL de l'application |

## Écritures disque et stockage (PLT-344)

- Aucune écriture locale : cache restic, fichiers temporaires et manifeste
  sont dans des `emptyDir` `medium: Memory` bornés. Le dump passe par un flux,
  jamais par un fichier.
- Lectures : le manifeste est incrémental (taille et mtime identiques →
  empreinte reprise du snapshot précédent) ; restic ne relit que les fichiers
  modifiés. `--read-concurrency 1` et `nice -n 10` limitent la contention
  sur le disque `longhorn-bulk`.
- Volume au 15/11/2026 (taille réelle Longhorn, borne haute) : bibliothèque
  Immich 6,8 GiB, Paperless 0,7 GiB, bases 1,9 GiB avant compression. Dépôt
  initial estimé sous 10 GiB.
- Requests CPU de 10m par conteneur (J4 : somme des requests ≤ 70 %).

## Préalables à l'activation (ordre)

1. homelab-infra : apply ARC `grafana-cloud` → `RESTIC_BACKUP_PASSWORD` dans
   `cluster/prd`.
2. homelab-infra : apply ARC `cloudflare-r2` → bucket `homelab-backup-restic`.
3. Codex, navigateur de Paul : identité R2 Object Read & Write limitée au
   bucket → `cluster/prd` `R2_RESTIC_WRITER_ACCESS_KEY_ID` /
   `R2_RESTIC_WRITER_SECRET_ACCESS_KEY` ; identité Object Read only →
   `infrastructure/prd` `R2_RESTIC_READER_*` (îlot). Contrôle par nom :
   `bash scripts/doppler-safe.sh has <CLÉ> -p cluster -c prd`.
4. Paul : fiche papier rangée, confirmée sur PLT-264.

## Activation et preuves

1. PR : `- restic-backup` dans `k8s/applications/media/immich/kustomization.yaml`
   et `k8s/applications/catalog/paperless/kustomization.yaml` ; `just check`.
2. RECONCILED : `just verify-delivery homelab immich` et `paperless` ;
   ExternalSecret `restic-backup` `SecretSynced`.
3. RUNTIME : `kubectl-rw.sh` crée un Job depuis chaque CronJob
   (`create job --from=cronjob/<app>-restic-backup`), puis
   `restic snapshots --json` dans un Job, sortie réduite aux tags et dates.
4. Test négatif : Job ponctuel avec `PGHOST` invalide ; attendu : pod en
   échec, aucun nouveau snapshot `<app>-postgres` ni `<app>-files`.
5. Maintenance : Job ponctuel depuis `<app>-restic-maintenance` ; attendu
   `step=dry-restore ... PASS` dans les journaux.

Aucune commande ne lit ni n'affiche `RESTIC_PASSWORD` : les scripts ne
journalisent ni l'environnement ni les noms de fichiers.
