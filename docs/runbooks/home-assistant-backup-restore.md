# Sauvegarde et reprise de Home Assistant

Statut de la preuve de restauration : `NOT_TESTED` (drill livré, voir « Drill
non destructif » ; passe à `RUNTIME` après une exécution PASS consignée ici).

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
laisser Argo reconcilier, **sans** `--resource-modifier-configmap restore-pvc-isolation`
(il neutraliserait le pod HA). Geste d'incident, décision de Paul ; pas un drill.

## Drill non destructif

Statut : livré (PR PRD-76d), résultats mesurés ci-dessous après exécution.
Lancement, une seule commande agent :

```bash
bash scripts/kubectl-rw.sh run-cronjob velero cronjob/ha-restore-drill
```

Le Job `ha-restore-drill-manual-<horodatage>` (namespace `velero`) écrit une
ligne JSON finale : `backup`, `restore`, `restore_phase`, `pvr` (octets),
`verifier` (ligne JSON du vérificateur), `cleanup`, `prod_before`,
`prod_after`, `prod_unchanged`, durées `restore_seconds`, `verify_seconds`,
`total_seconds`, `status` `PASS|FAIL`. Lecture :
`bash scripts/kubectl-ro.sh logs -n velero job/<nom>`.

### Pièges établis (Velero 1.18.2, `pkg/restore/restore.go`)

- Restaurer seulement PVC et PV donne un volume **vide** : le backup est un
  File System Backup Kopia ; seul un PodVolumeRestore réécrit les données, et
  il exige le **pod** `home-assistant-0` restauré (Velero lui ajoute l'init
  container `restore-wait`).
- `persistentvolumes` doit figurer dans `includedResources` : sinon Velero ne
  crée aucun PodVolumeRestore (`ShouldInclude(PersistentVolumes)`), même avec
  le pod. Le PV n'est pas restauré : il est reprovisionné (méthode FSB).
- Les resource modifiers s'appliquent **après** les RestoreItemActions, et
  l'objet est créé même si le patch échoue ; un `test` JSON Patch en échec
  rend même l'objet **inchangé sans erreur**. `restore-wait` hérite du
  `securityContext` du conteneur HA (NET_ADMIN, NET_RAW, NET_BROADCAST).
- `ownerReferences` est retiré par Velero (pas de ramasse-miettes du pod).
- `longhorn-fast` est en `Retain` : le PVC du drill passe en `longhorn-drill`
  (`Delete`), sinon chaque drill laisserait un PV `Released`.
- Le pod de production est `hostNetwork` (10.0.20.60) : restauré tel quel, il
  démarrerait un second HA sur le réseau des appareils.

### Barrières (k8s/infrastructure/controllers/velero-ha-restore-drill)

1. Namespace `home-assistant-restore-test`, géré par Git (projet Argo
   `infrastructure`), Pod Security `enforce: baseline`, CiliumNetworkPolicy
   `default-deny` avec `ingressDeny`/`egressDeny` vers `all`. Permanent et vide
   hors drill.
2. ValidatingAdmissionPolicy `ha-restore-test-guard` (toute identité, ce
   namespace) : pas de hostNetwork/hostPID/hostIPC, aucun conteneur privilégié
   ni capability ajoutée, `allowPrivilegeEscalation: false` partout, init
   containers = `[restore-wait]` (image `docker.io/velero/velero:vX.Y.Z`),
   conteneurs = `[ha-restore-verify]` (image HA de production épinglée),
   montages en lecture seule, un seul volume `data` (PVC), ServiceAccount
   `default` sans jeton, aucun conteneur éphémère ; PVC seulement en
   `longhorn-drill`.
3. Deux règles de `restore-pvc-isolation`, limitées à `home-assistant` :
   PVC `home-assistant-home-assistant-0` en `longhorn-drill` ; pod
   `home-assistant-0` neutralisé par un JSON Patch (deux `test`, puis
   `restore-wait` seul en init container et durci, conteneur remplacé par le
   vérificateur, volumes = `data`, `hostNetwork: false`, `dnsPolicy:
   ClusterFirst`, ServiceAccount `default`, `automountServiceAccountToken:
   false`, `restartPolicy: Never`, labels et annotations remplacés). **Ne pas
   utiliser ce modifier pour une vraie reprise.**
4. ValidatingAdmissionPolicy `ha-restore-drill-restore-guard` : le compte
   `velero/ha-restore-drill` ne peut que **créer** un Restore nommé
   `ha-restore-drill-<14 chiffres>`, backup `velero-daily-home-assistant-<14
   chiffres>`, `includedNamespaces: [home-assistant]`, `includedResources:
   [pods, persistentvolumeclaims, persistentvolumes]`, `namespaceMapping`
   vers `home-assistant-restore-test`, `restorePVs: true`, modifier
   `restore-pvc-isolation`, aucun autre champ (ni hook, ni sélecteur, ni
   `existingResourcePolicy`).
5. RBAC du Job : `create/get` restores, `list` backups et podvolumerestores,
   `get` du ConfigMap modifier (velero) ; `get/list/delete` pods et PVC,
   `get` pods/log (namespace de test) ; `get` du seul pod et du seul PVC de
   production ; `get` du namespace de test, des deux policies et des PV.
6. Lancement agent : ligne de `cronjob-run.tsv`, `manualRuns` de
   `agent-operator-guard`, binding `agent-operator-cronjob-run-ha-restore-drill`,
   Role `agent-operator-cronjob-run` de `velero`
   (`k8s/infrastructure/security/agent-operator/cronjob-run-infra.yaml`).

### Déroulé du Job (`ha-restore-drill.py`)

1. Pré-contrôles : namespace de test `Active` et `baseline`, les deux
   policies présentes, modifier avec ses règles HA, namespace de test vide.
2. Photo de production : UID et volume du PVC, UID, phase et redémarrages
   du pod `home-assistant-0`.
3. Dernier backup `Completed` du schedule ; création du Restore.
4. Attente du Restore (arrêt immédiat si un pod `hostNetwork` apparaît dans le
   namespace de test), PodVolumeRestore `Completed`, puis fin du vérificateur.
5. Vérificateur (dans le pod restauré, `/config` en lecture seule) :
   `.storage/` non vide, `home-assistant_v2.db` ouvert en
   `mode=ro&immutable=1`, `PRAGMA integrity_check` = `ok`, nombre d'états et
   dernier horodatage, `backups/*.tar` (information), chaînes
   `maison_musique_` dans `scripts.yaml`, `automations.yaml` ou `.storage/`.
6. Nettoyage **toujours** : suppression du pod et du PVC restaurés, attente de
   la disparition du PV (`Delete`).
7. Production comparée : PVC (UID, volume) et pod (UID, redémarrages)
   identiques, pod `Running`, sinon `FAIL`.

Retour arrière : retirer le dossier `velero-ha-restore-drill`, les deux
dernières règles du modifier et les lignes agent-operator (une PR) ; Argo
supprime le namespace de test. Contrat : `tests/harness/ha-restore-drill-test.sh`.

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
