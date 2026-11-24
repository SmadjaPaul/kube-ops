# Sauvegarde et reprise de Home Assistant

Statut de la preuve de restauration : `NOT_TESTED`. Le drill Velero ci-dessous
est **NON EXÉCUTÉ** : aucun chemin agent ne crée de `Restore` (voir « Drill
non destructif »). Ce document ne lance aucun Restore.

## État des sauvegardes (constat du 2026-11-24, niveau RUNTIME)

| Voie | Mécanisme | Planification | Rétention | État |
|---|---|---|---|---|
| Velero + Kopia vers R2 | `velero-daily-home-assistant` (`k8s/infrastructure/controllers/velero/schedules/daily-home-assistant.yaml`) | `30 2 * * *` UTC (avant : `0 2`, rafale de 12 schedules) | 336 h (14 j) | actif ; 5 backups sur 12 n'avaient pas démarré à 02:00 (cause non prouvée) |
| Longhorn | groupe `default`, recurring job | 03:17 | 7 copies | actif |
| Sauvegarde native HA | `/config/backups/*.tar` (agent `backup.local`) sur le PVC `home-assistant-home-assistant-0` | quotidienne 02:00 Europe/Paris (01:00 UTC l'hiver, 00:00 UTC l'été), activée le 2026-11-24 | 5 copies | base incluse, non chiffrée ; copie manuelle `PRD-76-preuve-chaine-2026-11-24` (2 088 960 octets) |

Les archives natives vivent sur le même PVC que HA (`/config` = volume `data`).
Elles ne protègent donc rien seules contre la perte du PVC ou du nœud : elles
sortent du nœud par Velero (PodVolumeBackup Kopia du volume `data` vers R2,
02:30 UTC) et par Longhorn (03:17). Leur intérêt : une archive cohérente de
la base SQLite, écrite par HA lui-même, à l'intérieur de chaque copie Velero.

Limites connues : aucune restauration testée ; la cohérence d'une copie à
chaud de la base SQLite (`home-assistant_v2.db`) n'est pas prouvée (Kopia lit
les fichiers pendant que HA écrit) : l'archive native du jour en est le
recours. `configuration.yaml` n'est pas lu sur le PVC : il est monté par-dessus
depuis la ConfigMap `ha-core-config` (Git), tout comme `secrets.yaml` depuis le
Secret `hassio-secrets`. Le décalage à
02:30 sort HA de la rafale ; vérifier au prochain cycle que le backup démarre
(`velero backup get --selector velero.io/schedule-name=velero-daily-home-assistant`).

## Voie rapide : restaurer un `.tar` natif

Pour une configuration ou une automation cassée, HA restant vivant.

1. Interface HA : Paramètres, Système, Sauvegardes, choisir l'archive, Restaurer.
2. Si l'UI est inaccessible : copier le `.tar` voulu depuis `/config/backups/`
   et le restaurer par l'écran d'onboarding ou `ha backups restore`, selon
   l'installation.
3. Contrôler après redémarrage : démarrage, `check_config`, entités `maison_*`.

L'archive la plus récente a au plus 24 h (planification quotidienne, section
« Sauvegarde native planifiée »).

## Voie complète : Velero Restore du PVC

Pour la perte du PVC ou du namespace. Restaurer le dernier backup `Completed`
de `velero-daily-home-assistant` dans `home-assistant` : arrêter d'abord le
StatefulSet (réplicas 0 via Git, Argo selfHeal), supprimer le PVC cassé, puis
`velero restore create ha-restore-$(date -u +%Y%m%d) --from-backup <backup>` et
laisser Argo reconcilier. Geste d'incident, décision de Paul ; pas un drill.

## Drill non destructif (NON EXÉCUTÉ)

État au 2026-11-24 (RUNTIME, lecture seule) :

- isolation vivante : la ConfigMap `restore-pvc-isolation` appliquée dans
  `velero` contient `home-assistant` dans ses deux règles (`volumeName: null`
  sur les PVC, `argocd.argoproj.io/tracking-id: null`) ;
- dernier backup : `velero-daily-home-assistant-20261124082947`, `Completed`,
  16 objets, 0 erreur ; un seul PodVolumeBackup, pod `home-assistant-0`, volume
  `data`, uploader `kopia`, 9 141 242 octets ;
- production de référence : PVC `home-assistant-home-assistant-0`, UID
  `1b4227d4-8b89-4e5e-9a0a-e52f95125314`, volume
  `pvc-1b4227d4-8b89-4e5e-9a0a-e52f95125314`, `longhorn-fast`, 5 Gi ;
  namespace `home-assistant` en Pod Security `privileged`.

Blocage : aucun chemin agent ne crée de `Restore` (`scripts/kubectl-rw.sh` ne
couvre que des workloads, Jobs et Pods ; `run-cronjob` seulement les couples de
`cronjob-run.tsv`). Le drill attend un CronJob suspendu dédié (ci-dessous).

### Piège : restaurer seulement PVC et PV donne un volume vide

Le backup est un File System Backup Kopia (PodVolumeBackup), pas un snapshot
CSI. Velero ne réécrit les données que par un PodVolumeRestore, qui exige que
le **pod** `home-assistant-0` soit restauré : Velero lui ajoute l'init
container `restore-wait`, et le node-agent écrit les fichiers quand ce
conteneur tourne. Avec `--include-resources persistentvolumeclaims,persistentvolumes`
(ancienne version de ce runbook), le PVC est provisionné vide et le Restore
reste `Completed` : faux positif.

Or le pod de production est `hostNetwork` (10.0.20.60), avec `NET_ADMIN`,
`NET_RAW`, `NET_BROADCAST`, et ses volumes `openid-patch`, `core-config`,
`secrets` qui ne sont pas restaurés. Restauré tel quel, il démarrerait un
second HA sur le réseau des appareils. Le pod doit donc être neutralisé
**avant** création, par une règle du modifier, et refusé par l'admission si la
règle échoue.

### Conception retenue (à livrer par PR)

1. Namespace `home-assistant-restore-test` géré par Git, Pod Security
   `enforce: baseline` (refuse `hostNetwork`, `NET_ADMIN`, `hostPath`), plus
   une CiliumNetworkPolicy en refus d'entrée et de sortie. Deuxième barrière :
   dans Velero 1.18 les resource modifiers s'appliquent après les
   RestoreItemActions, et un patch en échec n'empêche pas la création de
   l'objet ; seule l'admission rattrape un pod non patché.
2. Troisième règle dans `restore-pvc-isolation`, `groupResource: pods`,
   namespace source `home-assistant`, en JSON Patch unique (tout ou rien) :
   `test` du nom des conteneurs et volumes attendus, `test`
   `/spec/initContainers/0/name == restore-wait` (ajouté en tête par Velero),
   retrait des trois init containers d'origine et des volumes `openid-patch`,
   `core-config`, `secrets`, `hostNetwork: false`, `dnsPolicy: ClusterFirst`,
   `serviceAccountName: default`, `automountServiceAccountToken: false`,
   remplacement de `/spec/containers` par un vérificateur : image HA de
   production épinglée (python et sqlite3 déjà présents), `data` monté en
   lecture seule sur `/config`, aucune capability, script de contrôle puis
   attente.
3. Contrôles du vérificateur (sortie dans le journal du pod, sans valeur de
   jeton) : `.storage/` non vide, `configuration.yaml` présent sur le PVC
   (copie historique), dernier `backups/*.tar` et sa taille,
   `home-assistant_v2.db` ouvert en `mode=ro&immutable=1`,
   `PRAGMA integrity_check` = `ok`, chaînes `maison_musique_` trouvées dans
   `scripts.yaml` ou `.storage/`.
4. Déclencheur : CronJob suspendu `ha-restore-drill` (namespace `velero`, modèle
   `ha-agent-mcp-smoke`), ajouté à `cronjob-run.tsv`, lancé par
   `bash scripts/kubectl-rw.sh run-cronjob velero cronjob/ha-restore-drill`.
   Son ServiceAccount a seulement `create`/`get` sur `restores.velero.io` et
   `get` sur `backups.velero.io` dans `velero` ; une ValidatingAdmissionPolicy
   n'admet de ce compte qu'un `Restore` exact : backup du schedule
   `velero-daily-home-assistant`, `includedNamespaces: [home-assistant]`,
   `namespaceMapping` vers `home-assistant-restore-test`,
   `includedResources: [pods, persistentvolumeclaims]`, `restorePVs: true`,
   `resourceModifier` = `restore-pvc-isolation`, `existingResourcePolicy`
   absent. Le Job choisit le dernier backup `Completed`, crée le Restore,
   attend `Completed` et le PodVolumeRestore `Completed`, puis s'arrête.
5. Nettoyage : suppression du pod et du PVC restaurés par une PR qui retire le
   namespace de test (Argo prune) ; vérifier ensuite que le PVC de production
   garde l'UID et le volume ci-dessus et qu'aucun PV `Released` ne reste.
6. Consigner durée (création du Restore au journal du vérificateur) et
   contrôles PASS/FAIL ici ; passer la preuve de `NOT_TESTED` à `RUNTIME`.

## Sauvegarde native planifiée de HA (active depuis le 2026-11-24)

Réglée par l'API WebSocket admin (`backup/config/update`, jeton
`HA_RECONCILER_TOKEN`), lue ensuite par `backup/config/info` :

| Champ | Valeur |
|---|---|
| `schedule` | `recurrence: daily`, `time: 02:00:00` (fuseau HA `Europe/Paris`) |
| `create_backup.agent_ids` | `[backup.local]` |
| `create_backup.include_database` | `true` |
| `create_backup.password` | `null` (pas de chiffrement) |
| `retention.copies` | `5` |
| premier passage | `next_automatic_backup: 2026-11-25T02:00:00+01:00` |

Preuve de chaîne : `backup/generate` du 2026-11-24 17:38 (heure de Paris),
archive `PRD-76-preuve-chaine-2026-11-24`, id `96178712`, agent `backup.local`,
2 088 960 octets, HA 2026.11.2, base incluse, `failed_*` vides.

Contrôle quotidien : `backup/info` doit montrer des archives
`with_automatic_settings: true` successives et `last_completed_automatic_backup`
du jour ; le PodVolumeBackup Velero du lendemain doit grossir d'autant.

Chiffrement : optionnel et **geste de Paul**. Le mot de passe de chiffrement est
créé et gardé par Paul **hors cluster** ; sans lui l'archive est irrécupérable.
Ne jamais le copier dans Git, un Secret, Doppler ou un log.
