# Music Assistant : réconciliateur (PRD-83)

État désiré : `k8s/applications/automation/music-assistant/reconcile/desired.json` (JSON, car l'image Python n'a pas PyYAML). Script : `ma_reconcile.py` (stdlib). Secrets (D-2026-11-23-06) : le jeton de `svc-ma-reconcile` (PRD-84) est un Secret Kubernetes natif `ma-reconcile-token` (clé `token`), hors Git, créé une fois par Paul, saisie masquée :

```bash
read -rs MA_TOKEN && kubectl -n music-assistant create secret generic ma-reconcile-token --from-literal=token="$MA_TOKEN"; unset MA_TOKEN
```

`APP_MA_POLYFIN_PASSWORD` (compte `svc-music-assistant`, PRD-85) reste dans Doppler `cluster/prd` via l'ExternalSecret `ma-reconcile`, car le provider OpenTofu polyfin (ARC), hors cluster, le consomme aussi.

Aucun déclenchement automatique : les CronJobs `ma-reconcile-plan` et `ma-reconcile-apply` sont `suspend: true`.

```bash
# Dérive (aucune écriture ; sortie 0 = aucun écart, 2 = écarts, 1 = erreur ou refus)
kubectl -n music-assistant create job --from=cronjob/ma-reconcile-plan ma-reconcile-plan-$(date +%s)
# Application, suivie d'un plan qui doit être vide
kubectl -n music-assistant create job --from=cronjob/ma-reconcile-apply ma-reconcile-apply-$(date +%s)
kubectl -n music-assistant logs job/<nom>
```

Règles : jamais de suppression sans `--prune` et sans que le domaine soit listé dans `prune_domains` ; un champ secret n'est envoyé qu'à la création d'un fournisseur (MA ne le relit pas) ; aucun secret dans les sorties. Un utilisateur absent sans `password_env` bloque le plan (création manuelle, PRD-84).

Noms de commandes et de clés vérifiés dans le code de MA 2.10.8 (PRD-83) : liste `config/providers` avec `include_values` (`config/providers/get` exige `instance_id`, d'où le HTTP 500 du premier plan), clé `manual_discovery_ip_addresses` (liste) pour Sonos et Chromecast, création via `config/providers/setup` puis `config/flows/submit` (un fournisseur sans flux est créé vide puis complété par `config/providers/save`). À contrôler au premier `plan` réel ; en cas d'écart, `/api-docs/commands.json` de l'instance fait foi. Les jetons longue durée MA expirent après un an. Repli : sauvegarde Velero de `/data`.
