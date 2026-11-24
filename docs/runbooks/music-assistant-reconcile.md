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

## Entrée `music_assistant` de Home Assistant : recréation (PRD-100, PRD-103)

### État

- L'entrée a été créée une fois à la main par l'API de flux de configuration de HA. HA y garde SON PROPRE jeton MA longue durée, nommé « Home Assistant », créé pendant le flux (`create_long_lived_token` dans `config_flow.py` de l'intégration, HA 2026.11.2). Ce jeton n'est pas celui que le réconciliateur émet pour `svc-home-assistant` (Secret `ma-home-assistant-token`).
- L'entrée est sortie du suivi OpenTofu : bloc `removed` avec `destroy = false` (homelab-infra#800, `terraform/home-assistant/music_assistant.tf`). OpenTofu ne la crée, ne la modifie ni ne la détruit : la recréer ne demande aucun `import` ni apply.
- Il n'y a plus de publication vers Doppler (CronJob `ma-publish-tokens`, clé `home/prd_maison`, `DOPPLER_MAISON_TOKEN` supprimés, kube-ops#2004).

### À ne pas faire

- Ne pas révoquer le jeton « Home Assistant » dans MA (`auth/token/revoke`) : HA perdrait l'intégration. `auth/tokens` liste plusieurs jetons de `svc-home-assistant` (un nommé `home-assistant` émis par le réconciliateur, un nommé « Home Assistant » créé par HA) ; seul le second sert à HA en fonctionnement.
- Une rotation ou une réémission du jeton du réconciliateur (`ma-home-assistant-token`) n'atteint pas HA : HA ne lit jamais ce Secret.
- Le jeton de HA dure environ 1 an (jeton longue durée MA). Entrée créée le 24/11/2026 : la réauthentification de HA est attendue vers 11/2027. Si seul le jeton est invalide, l'entrée existe encore : ne pas la supprimer, terminer le flux de réauthentification (voir plus bas).

### Obtenir un jeton MA de `svc-home-assistant`

Le jeton émis par `ma-reconcile-apply` n'est écrit que dans le Secret natif `music-assistant/ma-home-assistant-token` (clé `token`, PATCH par le ServiceAccount `ma-reconcile`, `ma_reconcile.py`, classe `Kube`). Aucun mode du script (`--plan`, `--apply`, `--sync`) ne l'affiche, et les sorties sont filtrées. L'identité agent-operator ne lit pas le contenu des Secrets (`kubectl-ro.sh` refuse `get secret -o`). Deux voies :

1. Geste de Paul : lire la clé `token` du Secret avec l'identité opérateur, puis la saisir masquée dans le terminal de la procédure ci-dessous (`read -rs`).
2. Un Job dans le cluster qui monte le Secret par `secretKeyRef` (même forme que `APP_MA_HA_TOKEN` dans `reconcile/cronjobs.yaml`) et appelle lui-même l'API de flux de HA. Ce Job n'existe pas : il faudrait l'écrire (PR), avec un egress du pod vers le Service `home-assistant` (ns `home-assistant`, port 8123) et un jeton HA administrateur. Tant qu'il n'existe pas, utiliser la voie 1.

Si le Secret est vide ou refusé par MA (401), `bash scripts/kubectl-rw.sh run-cronjob music-assistant cronjob/ma-reconcile-apply` réémet le jeton (absent, 401 ou à moins de 30 jours de l'expiration) et le range dans le Secret ; lancer d'abord `cronjob/ma-reconcile-plan` pour voir `+ token/svc-home-assistant create`.

### Recréer l'entrée par l'API du flux

Prérequis : un jeton HA administrateur (`ha.py` le lit dans Doppler, projet `home`, config `prd`, sans l'afficher) et le jeton MA ci-dessus. `scripts/ha.py` du plugin `homelab-ops` fournit `flow start|step|abort` ; ces commandes écrivent dans HA et exigent `--confirmed`, à ne passer qu'avec l'accord de Paul pour CHAQUE étape (jamais en lot), en nommant le handler, l'étape et les champs envoyés. Équivalent REST : `POST /api/config/config_entries/flow` (démarrage) puis `POST /api/config/config_entries/flow/<flow_id>` (étapes).

```bash
HA=/Users/paul/Developer/agent/agent-harness/plugins/homelab-ops/scripts/ha.py
# 1. Démarrer le flux (handler music_assistant). Réponse : étape manual (formulaire url).
python3 "$HA" flow start music_assistant --confirmed
# 2. Étape manual : l'URL doit être joignable par HA, pas par un navigateur
python3 "$HA" flow step <flow_id> --confirmed --data '{"url": "http://music-assistant.music-assistant.svc.cluster.local:8095"}'
# 3. Étape auth : saisie masquée du jeton MA, jamais dans un fichier
read -rs MA_TOKEN
python3 "$HA" flow step <flow_id> --confirmed --data "$(jq -nc --arg c "$MA_TOKEN" '{code:$c}')"
# 4. Étape finish_auth : corps vide ; la réponse est type create_entry
python3 "$HA" flow step <flow_id> --confirmed
unset MA_TOKEN
```

Ce que le code de l'intégration impose (HA 2026.11.2, `homeassistant/components/music_assistant/config_flow.py`) :

- `manual` : `{url}` ; le flux interroge `server_info` de MA, fixe l'identifiant unique sur le `server_id` de MA et avorte avec `already_configured` si l'entrée existe encore (il met alors son URL à jour : c'est le signe que l'entrée n'est pas supprimée). `schema_version >= AUTH_SCHEMA_VERSION` mène à l'étape `auth`.
- `auth` : si le composant `my` est chargé, ou si la requête porte l'en-tête `HA-Frontend-Base`, le flux répond `external` avec une URL de connexion MA ; on n'ouvre pas cette URL, on envoie `{"code": <jeton>}`, ce qui termine l'étape externe et passe à `finish_auth`. Sans `my` ni en-tête, le flux retombe sur l'étape de formulaire `auth_manual` : y envoyer `{"token": <jeton>}`, qui crée l'entrée directement (sans `finish_auth`, mais alors HA garde CE jeton et non un jeton « Home Assistant » dédié). Lire le `step_id` de la réponse avant d'envoyer.
- `finish_auth` : HA échange le jeton reçu contre un nouveau jeton longue durée nommé « Home Assistant » (`create_long_lived_token`) et crée l'entrée `{url, token}`. C'est ce nouveau jeton que HA garde ; un jeton MA valide quelconque de `svc-home-assistant` suffit comme `code`.
- Réauthentification (jeton invalide, entrée présente) : HA ouvre un flux `reauth` visible par `flow list` ; l'étape `reauth_confirm` (corps `{}`) mène à `auth`, puis mêmes étapes 3 et 4 ; l'entrée est mise à jour, pas recréée.

Statut des preuves de cette procédure : lue et vérifiée dans le code de l'intégration et dans `ha.py` (STATIC). Non rejouée sur l'instance ; les noms d'étapes `external`/`external_done` du gestionnaire de flux de HA ne figurent pas dans ce code et restent à confirmer au premier rejeu.

### Vérifier après recréation

```bash
python3 "$HA" registry entities --platform music_assistant     # media_player.salon, media_player.bureau, etc.
python3 "$HA" music search "<un titre Polyfin>"                # utilise HA_AGENT_TOKEN (agent-maison)
```

Aucun import OpenTofu n'est à refaire : l'entrée n'est plus suivie, et le plan `home-assistant` doit rester vide.
