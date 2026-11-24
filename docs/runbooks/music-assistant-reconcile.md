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

Noms de commandes et de clés vérifiés dans le code de MA 2.10.8 (PRD-83) : liste `config/providers` avec `include_values` (`config/providers/get` exige `instance_id`, d'où le HTTP 500 du premier plan), clé `manual_discovery_ip_addresses` (liste) pour Sonos et Chromecast, création via `config/providers/setup` puis `config/flows/submit` (un fournisseur sans flux est créé vide puis complété par `config/providers/save`). Limite connue : le fournisseur `jellyfin` ne déclare aucune entrée de configuration (`get_config_entries()` vide), donc `config/providers` ne renvoie pas `url` ni `username` stockés ; le plan les marque « non lisibles » et ne les compare pas (le mot de passe n'est jamais lu). Changer `url` ou `username` dans `desired.json` n'est donc pas détecté : supprimer l'instance (`prune`) ou la modifier à la main. À contrôler au premier `plan` réel ; en cas d'écart, `/api-docs/commands.json` de l'instance fait foi. Les jetons longue durée MA expirent après un an. Repli : sauvegarde Velero de `/data`.

## Synchronisation de la bibliothèque (PRD-82)

`music/sync` exige le scope `library.manage` : seul le jeton admin de `svc-ma-reconcile` (Secret natif `ma-reconcile-token`, qui ne quitte pas le cluster) le porte. Le CronJob suspendu `ma-sync` lance `ma_reconcile.py --sync` : `music/tracks/count`, `music/sync` (tous les fournisseurs dont la synchro est activée), attente des tâches (`tasks/get`, au plus 8 min ; l'identifiant lu dans chaque `BackgroundTask` est `id`, `task_id` en repli ; une réponse non vide sans identifiant fait sortir en erreur au lieu d'afficher « 0 tâche »), puis `music/tracks/count` à nouveau. Sortie 1 si une tâche échoue ou dépasse le délai. Lancement par l'identité agent-operator :

```bash
bash scripts/kubectl-rw.sh run-cronjob music-assistant cronjob/ma-sync
bash scripts/kubectl-ro.sh logs -n music-assistant job/<nom>
```

Commandes vérifiées dans MA 2.10.8 (`controllers/music/controller.py`, `controllers/tasks`) : `music/sync(media_types?, providers?)`, `tasks/get(task_id)`, `music/tracks/count(favorite_only?)`. Une bibliothèque qui reste vide après la synchro s'explique d'abord côté fournisseur (pistes `available=false`), pas par ce job.

## Jeton de `svc-home-assistant` (PRD-84, sans geste manuel)

Cible : l'intégration `music_assistant` de Home Assistant (PRD-82) s'authentifie par un jeton longue durée du compte `svc-home-assistant` (rôle `service`).

Ce que fait `ma-reconcile-apply` (API vérifiée dans MA 2.10.8, `webserver/auth.py`) :

1. Crée `svc-home-assistant` (`auth/user/create`) avec un mot de passe aléatoire généré dans le job, jamais stocké ni affiché : le compte ne sert qu'avec son jeton (`password_generated` dans `desired.json`).
2. Émet le jeton avec `auth/token/create(name="home-assistant", user_id=…)`. Un admin (`users.manage`, donc `svc-ma-reconcile`) peut l'émettre pour un autre utilisateur : aucune connexion par mot de passe. Jeton longue durée : 1 an, sans renouvellement.
3. Le range par PATCH dans le Secret natif `ma-home-assistant-token` (clé `token`, ns `music-assistant`) via le ServiceAccount `ma-reconcile`.

Idempotence : le jeton courant arrive aux jobs par `secretKeyRef` facultatif (`APP_MA_HA_TOKEN`). Il est réémis seulement s'il est absent, refusé par MA (401) ou à moins de 30 jours de l'expiration ; sinon le plan est vide. Le plan (`ma-reconcile-plan`) affiche `+ token/svc-home-assistant create (raison)` sans rien écrire. Les anciens jetons réémis restent dans MA jusqu'à leur expiration (`auth/token/revoke` au besoin).

Compromis RBAC : `create` sur les Secrets n'est pas restreignable par `resourceNames`. Le Secret est donc créé à l'avance par un ExternalSecret (`Password` + `CreatedOnce` + `Orphan`, valeur aléatoire factice refusée par MA) et le Role `ma-reconcile` n'a que `patch` sur ce seul Secret : ni `create`, ni `get`, ni liste. Seul le CronJob apply monte le jeton de ServiceAccount, et seul lui a un egress vers kube-apiserver.

## Jeton de Home Assistant (PRD-103)

Il n'y a plus de publication vers Doppler. L'intégration `music_assistant` de Home Assistant a été créée une fois à la main par l'API de config flow (HA garde son propre jeton MA longue durée) puis adoptée par OpenTofu, qui l'a ensuite oubliée du state (bloc `removed`, `destroy = false`, homelab-infra PRD-103) sans toucher à HA. Le CronJob `ma-publish-tokens`, l'ExternalSecret `maison-doppler-write` et la clé Doppler `home/prd_maison` ne servent plus à rien.

`ma-reconcile-apply` continue d'émettre le jeton de `svc-home-assistant` et de le ranger dans le Secret natif `ma-home-assistant-token` (voir ci-dessus). En cas de perte de l'entrée HA, la recréer à la main par l'API de config flow avec ce jeton, sans passer par Doppler.
