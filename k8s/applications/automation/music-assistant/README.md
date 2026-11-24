# Music Assistant (namespace `music-assistant`)

Music Assistant (MA 2.10.8) joue la médiathèque Polyfin sur les enceintes Sonos, pilotée par Home Assistant. Chaîne : Home Assistant (entrée `music_assistant`) → MA → Polyfin (fournisseur Jellyfin, compte `svc-music-assistant`) → Sonos Salon, Bureau, Chambre principale, Salle de sport.

## Qui possède quoi

| Élément | Où | Remarque |
|---|---|---|
| Déploiement, réseau, routes | ce dossier | `networkpolicy.yaml` : Home Assistant (hostNetwork, vu comme `host`) et la Gateway arrivent sur 8095 ; flux audio sur 8097 pour les enceintes |
| Fournisseurs, utilisateurs, lecteurs, jetons de service | `reconcile/desired.json`, `reconcile/ma_reconcile.py` | CronJobs suspendus `ma-reconcile-plan`, `ma-reconcile-apply`, `ma-sync` ; lancement manuel, voir le runbook |
| Compte Polyfin `svc-music-assistant` | homelab-infra, racine `polyfin` ; mot de passe dans Doppler `cluster/prd` (`APP_MA_POLYFIN_PASSWORD`) | non administrateur, masqué ; pas d'OIDC ni de Quick Connect côté MA |
| Jetons MA | Secrets natifs `ma-reconcile-token`, `ma-home-assistant-token` | aucun jeton dans Git ni dans Doppler ; registre sans valeur : Atlas, fiche `home-assistant-as-code` |
| Entrée HA `music_assistant` | Home Assistant, hors OpenTofu | HA garde son propre jeton MA : ne pas révoquer le jeton « Home Assistant » dans MA |
| Patch Jellyfin (`CanDownload`) | `patches/jellyfin-parsers.py` | garde `tests/harness/ma-jellyfin-patch-test.sh` |

## Runbooks

- Réconciliation, `ma-sync`, jetons, recréation de l'entrée HA : `docs/runbooks/music-assistant-reconcile.md`.
- « No playable items found », Cilium, CDN TorBox : `docs/runbooks/music-assistant-polyfin.md`.
- Jouer depuis un agent : MCP natif de HA (`/api/mcp/assist`), voir Atlas, fiche `musique-maison`.
