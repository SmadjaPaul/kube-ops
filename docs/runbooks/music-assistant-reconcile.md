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

Règles : jamais de suppression sans `--prune` et sans que le domaine soit listé dans `prune_domains` ; un champ secret n'est envoyé qu'à la création d'un fournisseur (MA ne le relit pas) ; aucun secret dans les sorties. Un utilisateur absent sans `password_env` ni `password_generated` bloque le plan (création manuelle ; reste le cas de `svc-ma-reconcile`, l'amorce).

Noms de commandes et de clés vérifiés dans le code de MA 2.10.8 (PRD-83) : liste `config/providers` avec `include_values` (`config/providers/get` exige `instance_id`, d'où le HTTP 500 du premier plan), clé `manual_discovery_ip_addresses` (liste) pour Sonos et Chromecast, création via `config/providers/setup` puis `config/flows/submit` (un fournisseur sans flux est créé vide puis complété par `config/providers/save`). À contrôler au premier `plan` réel ; en cas d'écart, `/api-docs/commands.json` de l'instance fait foi. Les jetons longue durée MA expirent après un an. Repli : sauvegarde Velero de `/data`.

## Jeton de `svc-home-assistant` (PRD-84, sans geste manuel)

Cible : l'intégration `music_assistant` de Home Assistant (PRD-82) s'authentifie par un jeton longue durée du compte `svc-home-assistant` (rôle `service`).

Ce que fait `ma-reconcile-apply` (API vérifiée dans MA 2.10.8, `webserver/auth.py`) :

1. Crée `svc-home-assistant` (`auth/user/create`) avec un mot de passe aléatoire généré dans le job, jamais stocké ni affiché : le compte ne sert qu'avec son jeton (`password_generated` dans `desired.json`).
2. Émet le jeton avec `auth/token/create(name="home-assistant", user_id=…)`. Un admin (`users.manage`, donc `svc-ma-reconcile`) peut l'émettre pour un autre utilisateur : aucune connexion par mot de passe. Jeton longue durée : 1 an, sans renouvellement.
3. Le range par PATCH dans le Secret natif `ma-home-assistant-token` (clé `token`, ns `music-assistant`) via le ServiceAccount `ma-reconcile`.

Idempotence : le jeton courant arrive aux jobs par `secretKeyRef` facultatif (`APP_MA_HA_TOKEN`). Il est réémis seulement s'il est absent, refusé par MA (401) ou à moins de 30 jours de l'expiration ; sinon le plan est vide. Le plan (`ma-reconcile-plan`) affiche `+ token/svc-home-assistant create (raison)` sans rien écrire. Les anciens jetons réémis restent dans MA jusqu'à leur expiration (`auth/token/revoke` au besoin).

Compromis RBAC : `create` sur les Secrets n'est pas restreignable par `resourceNames`. Le Secret est donc créé à l'avance par un ExternalSecret (`Password` + `CreatedOnce` + `Orphan`, valeur aléatoire factice refusée par MA) et le Role `ma-reconcile` n'a que `patch` sur ce seul Secret : ni `create`, ni `get`, ni liste. Seul le CronJob apply monte le jeton de ServiceAccount, et seul lui a un egress vers kube-apiserver.

Sortie du cluster (non automatisée, bloqueur pour Paul) : HA est consommé par OpenTofu/ARC, hors cluster, donc le jeton doit finir dans Doppler `home/prd_maison`. Il manque un jeton Doppler en écriture sur ce projet, accessible à un job du cluster. Tant que ce n'est pas décidé, le geste est : lire le Secret avec le kubectl en lecture seule de Paul et le pousser dans Doppler, saisie masquée, sans afficher la valeur. Cible : un job dédié (CronJob du namespace `music-assistant`, jeton Doppler en écriture limité à `home/prd_maison`, Secret natif) qui lit `ma-home-assistant-token` et fait `doppler secrets set`.
