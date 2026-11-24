# Music Assistant et Polyfin : diagnostic « No playable items found » (PRD-77)

**Conclusion** : « No playable items found » vient presque toujours d'un titre `available=false` dans Music Assistant (MA 2.10.8) parce que Polyfin renvoie `CanDownload=false` pour l'audio. Le contournement est un patch monté sur `parsers.py`. Si le titre est disponible et que la lecture échoue, la cause suivante est le réseau (Cilium, hôtes du CDN TorBox). Chaîne prouvée de bout en bout : Home Assistant, Music Assistant, Polyfin, Sonos Salon et Bureau (RUNTIME : `play_media` 200, état `playing` ; USER : Paul entend).

Réconciliation, jeton et `--sync` : [music-assistant-reconcile.md](music-assistant-reconcile.md). Politiques Cilium : `.agents/skills/cilium-hubble`.

## Diagnostic pas à pas

Lecture seule d'abord. Ne jamais afficher un jeton ni `apiKey`.

1. **Statut du fournisseur Jellyfin.** `config/providers` (jeton `svc-ma-reconcile`) : le fournisseur doit être `loaded` sans `last_error`. Sinon, mot de passe de `svc-music-assistant` ou URL Polyfin : voir le runbook de réconciliation.
2. **Disponibilité du titre.** `music/item_by_uri` avec l'URI du titre (`jellyfin://track/<id>`) : lire `provider_mappings[].available`. `false` = cause (a) ci-dessous. `music/tracks/count` à 0 après une synchro confirme.
3. **Journaux MA**, avec masquage de `apiKey` (les URL de flux Jellyfin la portent) :
   ```bash
   bash scripts/kubectl-ro.sh logs -n music-assistant deploy/music-assistant --since=15m \
     | sed -E 's/(api_?[kK]ey=)[^&" ]+/\1***/g'
   ```
   Chercher `No playable items found`, une erreur ffmpeg ou un délai sur l'hôte `*.tb-cdn.st`.
4. **Pertes Cilium** par destination FQDN (PLT-411, lecture seule) : `hubble_drop_total{source_namespace="music-assistant",source_workload="music-assistant"}`, regrouper par `destination` et `reason` (requête encodée passée à `kubectl-ro.sh get --raw`, voir `.agents/skills/cilium-hubble`). Une destination `nexus-NNN.<région>.tb-cdn.st` avec `POLICY_DENIED` = règle `toFQDNs` insuffisante.
5. **Relancer une synchro** (exige `library.manage`, donc par le CronJob, jamais depuis un jeton non administrateur) :
   ```bash
   bash scripts/kubectl-rw.sh run-cronjob music-assistant cronjob/ma-sync
   bash scripts/kubectl-ro.sh logs -n music-assistant job/<nom>
   ```
   Sortie attendue : `music/tracks/count` supérieur à 0 après la synchro.

## Causes connues

| Cause | Signe | Correctif |
|---|---|---|
| Polyfin met `CanDownload=false` pour l'audio ; MA lit ce champ comme `available` | `available=false`, 0 titre, « No playable items found » | Patch ci-dessous (kube-ops#1977). Amont : moodiness/polyfin#1504 |
| Cilium : `*` ne franchit pas un point dans `toFQDNs` ; le CDN TorBox a des hôtes à deux labels | `POLICY_DENIED` vers `nexus-NNN.<région>.tb-cdn.st` | `matchPattern: "**.tb-cdn.st"` dans `networkpolicy.yaml` (kube-ops#1981, #1986) |
| Jellyfin dans HA en `auth_required` invisible au plan | plan vide, intégration hors service | Le réconciliateur renvoie les secrets d'un fournisseur en erreur (kube-ops#1971) |
| Salon et Bureau groupés côté Sonos | lecture sur une seule enceinte | `media_player.unjoin` ; état d'exécution, pas Git |

## Patch jellyfin (contournement `CanDownload`)

- Fichiers : `k8s/applications/automation/music-assistant/patches/jellyfin-parsers.py` (parsers.py complet patché) et `jellyfin-parsers.diff` (une ligne : `available = True`).
- Montage : ConfigMap générée `ma-jellyfin-parsers-patch`, montée en `subPath` lecture seule sur `/app/venv/lib/python3.14/site-packages/music_assistant/providers/jellyfin/parsers.py` ; l'annotation Reloader relance le pod à chaque changement.
- Garde : `tests/harness/ma-jellyfin-patch-test.sh` échoue si l'image n'est plus `PATCHED_FOR` (2.10.8) ou si le fichier s'écarte de `parsers.py` amont plus le diff. Un bump de MA (Renovate) casse donc la CI et force la décision.
- Retrait, quand moodiness/polyfin#1504 est corrigé ou que MA dépasse 2.10.8 : vérifier que `available` suit `CanDownload` correctement, supprimer le montage et le volume du `deployment.yaml`, le `configMapGenerator`, le dossier `patches/` et le test (retrait du test : à dire dans la PR). Contrôle : `music/tracks/count` à 0 puis supérieur à 0 après `ma-sync`, et une lecture sur enceinte.
- Si MA change de version sans correctif : régénérer le `.py` et le `.diff` sur la nouvelle version, puis mettre à jour `PATCHED_FOR` et `UPSTREAM_SHA256` du test.

## Entrée Home Assistant `music_assistant`

L'intégration ne se crée pas par OpenTofu : son flux de configuration a une étape `auth` externe. Procédure retenue (homelab-infra#791) :

1. Créer l'entrée par l'API du flux de HA avec `{"code": <jeton MA>}` (jeton `svc-home-assistant`, jamais affiché).
2. L'importer dans l'état OpenTofu (`homeassistant_integration.music_assistant`) ; la ressource porte `ignore_changes` sur `steps`.
3. HA stocke ensuite son propre jeton MA : la rotation du jeton Doppler ne change pas l'entrée existante.

Vérification : `ha.py` en lecture (entrées de configuration, `media_player.*` de MA présents) puis un `play_media` sur Salon.

## Suivi long terme

Passer à MA 2.11 stable (fuite d'`api_key` dans les journaux corrigée) ; retirer le patch dès que la cause amont est levée.
