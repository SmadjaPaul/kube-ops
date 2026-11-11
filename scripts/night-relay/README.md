# Relais de nuit (PLT-201)

Le superviseur `supervisor.sh` est un script shell sans LLM. De 23 h 00 à 08 h 30 (heure locale), il enchaîne des sessions orchestrateur `claude -p`, une à la fois. Chaque session reçoit le handoff de la précédente. À 09 h 00, il lance le rapport, puis s'arrête. Un lancement couvre une nuit.

| Fichier | Rôle |
|---|---|
| `supervisor.sh` | boucle de nuit, attente de quota, journal borné, rapport |
| `orchestrator.md` | prompt d'un cycle (`claude -p --model sonnet --permission-mode bypassPermissions --output-format json`) |
| `report.md` | prompt du rapport de 9 h (`claude -p --model opus`, même mode de permission) |
| `test_supervisor.sh` | test hors réseau du superviseur |

La sélection des tickets passe par le dispatcher existant (`scripts/dispatcher/dispatch.py --dry-run`). Il n'y a pas de seconde logique de file.

## Lancer

Depuis la racine du dépôt kube-ops, avec Doppler et `gh` authentifiés :

```sh
nohup caffeinate -i bash scripts/night-relay/supervisor.sh >/dev/null 2>&1 &
```

Lancé dans la journée, il attend 23 h. Lancé entre 23 h et 08 h 30, il démarre tout de suite. Un verrou (`state/supervisor.lock`) empêche deux superviseurs simultanés. Pour l'arrêter : `kill <pid>` (le pid est dans `state/supervisor.lock/pid`).

Les principales variables (voir l'en-tête du script pour la liste complète) :

- `START_HM=2300`, `STOP_HM=0830`, `REPORT_HM=0900` : la fenêtre et l'heure du rapport.
- `MAX_CYCLES=12`, `MAX_FAILS=3`, `ORCH_TIMEOUT=10800` : les bornes des cycles. Une session ne dépasse jamais 08 h 55.
- `QUOTA_FALLBACK_SLEEP=1800`, `QUOTA_MIN_SLEEP=300` : l'attente quand l'heure de réinitialisation est inconnue, et l'attente minimale.
- `LOG_MAX_BYTES=1048576`, `RUNS_KEEP=60` : les bornes du journal et des sorties JSON.
- `NIGHT_RELAY_STATE`, `NIGHT_RELAY_HANDOFF_DIR` : les répertoires d'état et de handoff (par défaut `state/` et `handoff/` ici, ignorés par Git).

## Comportement

- **Cycle** : le superviseur construit le prompt (`orchestrator.md` + un bloc « Contexte du superviseur » : cycle, handoff précédent, handoff à écrire, fin de fenêtre). Il lance la session, puis lit la première ligne `statut:` du handoff produit.
- **Limite d'usage** : si la session échoue (code non nul ou `"is_error": true`) avec un message de limite d'usage, le superviseur cherche l'heure de réinitialisation. Il reconnaît `usage limit reached|<epoch>` et `resets 3am` / `resets at 15:30`. Il attend jusqu'à cette heure plus `QUOTA_MARGIN`, puis rejoue le même cycle. Sans heure, il attend `QUOTA_FALLBACK_SLEEP` et réessaie. Si la réinitialisation tombe après 08 h 30, il passe au rapport. Le rapport réessaie jusqu'à 12 h.
- **Échec** : une session qui échoue sans handoff reçoit un handoff minimal (`statut: echec`, code de sortie, taille du stderr, jamais son contenu). La chaîne continue après `FAIL_BACKOFF`. Au bout de `MAX_FAILS` échecs consécutifs, le superviseur passe au rapport.
- **File vide** : avec `statut: file-vide`, il patiente `EMPTY_SLEEP` avant le cycle suivant. Avec `statut: arret`, il n'enchaîne plus.
- **Journal** : `state/supervisor.log`. Au-delà de `LOG_MAX_BYTES`, il devient `supervisor.log.1`, et l'ancien `.1` est écrasé. Les sorties JSON sont tronquées à `RUN_MAX_BYTES`. Le stderr de `claude` n'est jamais conservé.
- **Fin** : à 09 h, le rapport reçoit la liste des handoffs de la nuit. Une notification macOS locale signale sa fin.

## Handoff

`handoff/<date>-<N>.md`, où `<date>` est la date du début de nuit et `N` le numéro du cycle :

```
statut: continue | file-vide | arret
cycle: <date>-<N>
modele: sonnet
## Faits
## En cours
## Blocages (preuve)      commande, erreur, chemins essayés (D-13)
## Quota
## Améliorations
```

Le rapport est écrit dans `handoff/<date>-rapport.md` et publié sur le projet Linear « Socle sain ».

## DRY_RUN et tests

Avec `DRY_RUN=1`, le superviseur n'appelle ni `claude` ni le réseau. Il simule les sessions (handoff factice, JSON factice) et utilise une horloge simulée : `state/clock`, initialisée par `NIGHT_RELAY_FAKE_NOW` (epoch). Les attentes avancent l'horloge au lieu de dormir. Les variables `DRY_RUN_QUOTA_ATTEMPTS`, `DRY_RUN_QUOTA_RESET_IN`, `DRY_RUN_QUOTA_MSG`, `DRY_RUN_FAIL_ATTEMPTS` et `DRY_RUN_EMPTY_ATTEMPTS` injectent des scénarios.

```sh
DRY_RUN=1 NIGHT_RELAY_FAKE_NOW=$(date +%s) NIGHT_RELAY_STATE=$(mktemp -d) \
  NIGHT_RELAY_HANDOFF_DIR=$(mktemp -d) bash scripts/night-relay/supervisor.sh

bash scripts/night-relay/test_supervisor.sh       # KEEP=1 conserve le répertoire de travail
shellcheck scripts/night-relay/*.sh
```

Le test vérifie l'enchaînement, la transmission du handoff, l'attente de quota (heure parsée, heure inconnue, limite pendant le rapport), la borne du journal, le handoff d'échec, la file vide, le démarrage après minuit, le verrou et l'heure de déclenchement du rapport. Des binaires `claude`, `doppler`, `curl` et `gh` factices font échouer le test s'ils sont appelés.

## Limites

- La détection de limite d'usage repose sur le texte du message de `claude`. Ce format n'est pas un contrat stable. En cas de changement, l'attente de repli bornée s'applique.
- Le timeout sans `timeout(1)` repose sur un chien de garde shell (SIGTERM). Les sous-processus de `claude` qui ignorent ce signal ne sont pas tués.
- La sélection multi-tickets suppose qu'un ticket verrouillé `wip:*` sort du dry-run du dispatcher. Les verrous posés par l'orchestrateur bloquent donc aussi un dispatcher planifié sur la même voie.
