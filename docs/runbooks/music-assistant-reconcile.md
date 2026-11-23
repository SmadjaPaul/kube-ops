# Music Assistant : réconciliateur (PRD-83)

État désiré : `k8s/applications/automation/music-assistant/reconcile/desired.json` (JSON, car l'image Python n'a pas PyYAML). Script : `ma_reconcile.py` (stdlib). Secrets : `APP_MA_RECONCILE_TOKEN` (jeton de `svc-ma-reconcile`, PRD-84) et `APP_MA_POLYFIN_PASSWORD` (compte `svc-music-assistant`, PRD-85), Doppler `cluster/prd` via l'ExternalSecret `ma-reconcile`.

Aucun déclenchement automatique : les CronJobs `ma-reconcile-plan` et `ma-reconcile-apply` sont `suspend: true`.

```bash
# Dérive (aucune écriture ; sortie 0 = aucun écart, 2 = écarts, 1 = erreur ou refus)
kubectl -n music-assistant create job --from=cronjob/ma-reconcile-plan ma-reconcile-plan-$(date +%s)
# Application, suivie d'un plan qui doit être vide
kubectl -n music-assistant create job --from=cronjob/ma-reconcile-apply ma-reconcile-apply-$(date +%s)
kubectl -n music-assistant logs job/<nom>
```

Règles : jamais de suppression sans `--prune` et sans que le domaine soit listé dans `prune_domains` ; un champ secret n'est envoyé qu'à la création d'un fournisseur (MA ne le relit pas) ; aucun secret dans les sorties. Un utilisateur absent sans `password_env` bloque le plan (création manuelle, PRD-84).

Avant le premier `apply` : confirmer sur `https://music.smadja.dev/api-docs/openapi.json` les noms de commandes et de clés (`ips` Sonos et Chromecast, `url`/`username`/`password` Jellyfin, flux `config/providers/setup` puis `config/flows/submit`), puis lancer un `plan`. Les jetons longue durée MA expirent après un an. Repli : sauvegarde Velero de `/data`.
