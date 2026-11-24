# Sauvegarde et reprise de Home Assistant

Statut de la preuve de restauration : `NOT_TESTED`. Le drill ci-dessous est
**NON EXÉCUTÉ** et **exige l'accord explicite de Paul** avant tout lancement.
Ce document ne lance aucun Restore et ne modifie pas HA.

## État des sauvegardes (constat du 2026-11-24, niveau RUNTIME)

| Voie | Mécanisme | Planification | Rétention | État |
|---|---|---|---|---|
| Velero + Kopia vers R2 | `velero-daily-home-assistant` (`k8s/infrastructure/controllers/velero/schedules/daily-home-assistant.yaml`) | `30 2 * * *` UTC (avant : `0 2`, rafale de 12 schedules) | 336 h (14 j) | actif ; 5 backups sur 12 n'avaient pas démarré à 02:00 (cause non prouvée) |
| Longhorn | groupe `default`, recurring job | 03:17 | 7 copies | actif |
| Sauvegarde native HA | `/config/backups/*.tar` sur le PVC `home-assistant-home-assistant-0` | aucune | aucune | 1 copie manuelle périmée, non chiffrée |

Limites connues : aucune restauration testée ni documentée avant ce runbook ;
la cohérence d'une copie à chaud de la base SQLite (`home-assistant_v2.db`)
n'est pas prouvée (Kopia lit les fichiers pendant que HA écrit). Le décalage à
02:30 sort HA de la rafale ; vérifier au prochain cycle que le backup démarre
(`velero backup get --selector velero.io/schedule-name=velero-daily-home-assistant`).

## Voie rapide : restaurer un `.tar` natif

Pour une configuration ou une automation cassée, HA restant vivant.

1. Interface HA : Paramètres, Système, Sauvegardes, choisir l'archive, Restaurer.
2. Si l'UI est inaccessible : copier le `.tar` voulu depuis `/config/backups/`
   et le restaurer par l'écran d'onboarding ou `ha backups restore`, selon
   l'installation.
3. Contrôler après redémarrage : démarrage, `check_config`, entités `maison_*`.

Limite : la copie manuelle actuelle est périmée ; sans planification (section
« Activer la sauvegarde native »), cette voie ne protège rien d'actuel.

## Voie complète : Velero Restore du PVC

Pour la perte du PVC ou du namespace. Restaurer le dernier backup `Completed`
de `velero-daily-home-assistant` dans `home-assistant` : arrêter d'abord le
StatefulSet (réplicas 0 via Git, Argo selfHeal), supprimer le PVC cassé, puis
`velero restore create ha-restore-$(date -u +%Y%m%d) --from-backup <backup>` et
laisser Argo reconcilier. Geste d'incident, décision de Paul ; pas un drill.

## Drill non destructif (NON EXÉCUTÉ, accord de Paul requis)

Règle d'isolation : `k8s/infrastructure/controllers/velero/restore-pvc-isolation.yaml`.
Son modifier retire `volumeName` des PVC et l'annotation Argo `tracking-id`
pour les namespaces sources `invoice-ninja`, `longhorn-tier-dr-source` et
`home-assistant` (ajouté par PRD-76 ; test :
`tests/harness/invoice-restore-isolation-test.sh`). Sans cette entrée, le PVC
restauré viserait le PV de production et Argo attribuerait les objets à
l'Application de production. Vérifier que la ConfigMap appliquée contient
`home-assistant` avant tout drill.

Variables : `NS=home-assistant-restore-test`, `T0=$(date +%s)`.

1. Choisir le backup : `velero backup get --selector velero.io/schedule-name=velero-daily-home-assistant`,
   dernier `Completed` sans erreur. Noter nom et date.
2. Restaurer vers le namespace de test, sans démarrer HA de production :
   ```bash
   velero restore create ha-drill-$(date -u +%Y%m%d) \
     --from-backup <backup> \
     --namespace-mappings home-assistant:$NS \
     --resource-modifier-configmap restore-pvc-isolation \
     --include-resources persistentvolumeclaims,persistentvolumes \
     --restore-volumes=true --wait
   ```
   Aucun StatefulSet, Service, HTTPRoute ni ExternalSecret de production n'est
   restauré : on prouve les données, pas le service.
3. Pod HA de test isolé, manifeste appliqué à la main dans `$NS` (jamais via
   Git ni Argo) : image épinglée à la version de production, PVC restauré monté
   sur `/config`, **sans `hostNetwork`**, sans accès aux appareils (ni `hostPath`,
   ni `/dev`), **sans jeton ni Secret de production** (aucun `envFrom`, token de
   ServiceAccount non monté), NetworkPolicy en refus de sortie, `securityContext`
   non privilégié.
4. Contrôles :
   - démarrage : le pod devient `Ready`, `/api/` répond (onboarding ou 401) ;
   - journal : `kubectl -n $NS logs <pod>` sans `database disk image is malformed`,
     `corrupt` ni échec de migration ; `sqlite3 /config/home-assistant_v2.db 'PRAGMA integrity_check;'` renvoie `ok` ;
   - `.storage` : fichiers présents et non vides, et automations et scripts
     `maison_*` retrouvés (`grep -l maison_ /config/automations.yaml /config/scripts.yaml /config/.storage/*`),
     sans afficher de valeur de jeton ;
   - durée : `echo $(( $(date +%s) - T0 )) s` du début du Restore au pod `Ready`
     (RTO mesuré).
5. Nettoyage : `kubectl delete namespace $NS`, puis
   `velero restore delete ha-drill-<date>`. Vérifier qu'aucun PV orphelin ne
   reste et que `home-assistant` de production n'a pas bougé.
6. Consigner le résultat (durée, contrôles PASS/FAIL) ici et faire passer la
   preuve de `NOT_TESTED` à `RUNTIME`.

## Activer la sauvegarde native planifiée de HA

Geste dans l'UI HA, hors Git : Paramètres, Système, Sauvegardes, Configurer :
planification quotidienne à **01:00 UTC**, conserver **3 à 7** copies, agent
`backup.local` (archives dans `/config/backups`, donc couvertes ensuite par
Velero à 02:30 et Longhorn à 03:17).

Chiffrement : optionnel et **geste de Paul**. Le mot de passe de chiffrement est
créé et gardé par Paul **hors cluster** ; sans lui l'archive est irrécupérable.
Ne jamais le copier dans Git, un Secret, Doppler ou un log.
