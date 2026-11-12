# Relais de nuit (PLT-201)

Le superviseur `supervisor.sh` est un script shell sans LLM. De 23 h 00 à 08 h 30 (heure locale), il enchaîne des sessions orchestrateur `claude -p`, une à la fois. Chaque session reçoit le handoff de la précédente. À 09 h 00, il lance le rapport, puis s'arrête. Un lancement couvre une nuit.

| Fichier | Rôle |
|---|---|
| `supervisor.sh` | boucle de nuit, attente de quota, journal borné, rapport |
| `orchestrator.md` | prompt d'un cycle (`claude -p --model sonnet --permission-mode bypassPermissions --output-format json`) |
| `report.md` | prompt du rapport de 9 h (`claude -p --model opus`, même mode de permission) |
| `kube-status.sh` | préflight Kubernetes d'un cycle : une ligne non sensible (`disponible (...)` / `indisponible (catégorie : raison)`) |
| `test_supervisor.sh` | test hors réseau du superviseur |

La sélection des tickets passe par le dispatcher existant (`scripts/dispatcher/dispatch.py --dry-run`). Il n'y a pas de seconde logique de file.

## Lancer

Depuis la racine du dépôt kube-ops, avec Doppler et `gh` authentifiés :

```sh
nohup caffeinate -i bash scripts/night-relay/supervisor.sh >/dev/null 2>&1 &
```

Lancé dans la journée, il attend 23 h. Lancé entre 23 h et 08 h 30, il démarre tout de suite. Un verrou (`state/supervisor.lock`) empêche deux superviseurs simultanés ; un verrou dont le pid est mort est repris. Pour l'arrêter : `kill <pid>` (le pid est dans `state/supervisor.lock/pid`). Le superviseur tue alors la session `claude` en cours et ses sous-processus (SIGTERM, puis SIGKILL après `KILL_GRACE`), son chien de garde, supprime son stderr et libère le verrou.

Les principales variables (voir l'en-tête du script pour la liste complète) :

- `START_HM=2300`, `STOP_HM=0830`, `REPORT_HM=0900` : la fenêtre et l'heure du rapport.
- `MAX_CYCLES=12`, `MAX_FAILS=3`, `ORCH_TIMEOUT=10800` : les bornes des cycles. Une session ne dépasse jamais 08 h 55.
- `QUOTA_FALLBACK_SLEEP=1800`, `QUOTA_MIN_SLEEP=300` : l'attente quand l'heure de réinitialisation est inconnue, et l'attente minimale.
- `QUOTA_MAX_RETRIES=4` : au-delà de ce nombre de limites d'usage consécutives, la tentative compte comme un échec (une limite mal détectée ne contourne pas `MAX_FAILS`).
- `LOG_MAX_BYTES=1048576`, `RUNS_KEEP=60` : les bornes du journal et des sorties JSON.
- `NIGHT_RELAY_STATE`, `NIGHT_RELAY_HANDOFF_DIR` : les répertoires d'état et de handoff (par défaut `state/` et `handoff/` ici, ignorés par Git).

## Comportement

- **Cycle** : le superviseur lance d'abord `kube-status.sh` (chaque tentative bornée par `KUBE_CHECK_TIMEOUT=120` ; `KUBE_CHECK_ATTEMPTS=2` tentatives espacées de `KUBE_CHECK_RETRY_DELAY=60` avant de déclarer l'accès indisponible ; la ligne du prompt garde la catégorie et le nombre de tentatives). Il construit ensuite le prompt (`orchestrator.md` + un bloc « Contexte du superviseur » : cycle, handoff précédent, handoff à écrire, fin de fenêtre, ligne `Kubernetes : ...`). Il lance la session, puis lit la première ligne `statut:` du handoff produit.
- **Accès Kubernetes** : `kube-status.sh` réutilise `scripts/lib/kube-preflight.sh` (Doppler, empreinte SHA-256, TLS, authentification API). Il ne garde que la raison énumérée : `auth_doppler_absente`, `api_inaccessible`, `credential_rejete`, `credential_canonique_invalide`, `outil_manquant`, `preflight_timeout`. Indisponible, le cycle démarre quand même le ticket choisi par le dispatcher : parties Git/CI/PR/Linear, et les preuves runtime vont dans `## Preuves à compléter`. `file-vide` n'est permis que si le dispatcher ne choisit aucun ticket. Dans la session, les preuves Argo et Cube passent par `just status-app`, `just diagnose-app` et `just runtime-inventory`. Le reste passe par `bash scripts/kubectl-ro.sh <get|describe|logs|top|events> ...` (lecture seule, kubeconfig temporaire du préflight, jamais copié). Un `kubectl` appelé directement tombe sur `localhost:8080` : c'était l'erreur du premier handoff (2026-11-11-2).
- **Métriques** : `bash scripts/kubectl-ro.sh get --raw <chemin>` sur le proxy Prometheus/Loki (`/api/v1/namespaces/monitoring/services/{kube-prometheus-stack-prometheus:9090|loki-gateway:80}/proxy/...`, API `query|query_range|series|labels|label/<nom>/values`, paramètres encodés %XX) ; tout autre `--raw` est refusé.
- **Secrets** : Doppler passe uniquement par `scripts/doppler-safe.sh`. Le hook `.claude/hooks/secret-output-guard.py` (déclaré dans `.claude/settings.json`) refuse les commandes qui impriment des valeurs. Test : `bash tests/agent-guard/secret-output-guard-test.sh`.
- **Preuves à compléter** : un ticket mergé sans preuve RECONCILED/RUNTIME reste In Progress. Il figure dans la section `## Preuves à compléter` du handoff, et le cycle suivant la reprend en premier. Le dry-run du dispatcher liste aussi ces tickets (`à reprendre :`, In Progress sans verrou).
- **Limite d'usage** : si la session échoue (code non nul ou `"is_error": true`) avec un message de limite d'usage, le superviseur cherche l'heure de réinitialisation. Il reconnaît `usage limit reached|<epoch>` et `resets 3am` / `resets at 15:30`. Il attend jusqu'à cette heure plus `QUOTA_MARGIN`, puis rejoue le même cycle. Sans heure, il attend `QUOTA_FALLBACK_SLEEP` et réessaie. Si la réinitialisation tombe après 08 h 30, il passe au rapport. Après `QUOTA_MAX_RETRIES` limites consécutives, la tentative compte comme un échec. Le rapport réessaie jusqu'à 12 h, dans la même borne.
- **Échec** : une session qui échoue sans handoff reçoit un handoff minimal (`statut: echec`, code de sortie, taille du stderr, jamais son contenu). La chaîne continue après `FAIL_BACKOFF`. Au bout de `MAX_FAILS` échecs consécutifs, le superviseur passe au rapport.
- **File vide et cycle inactif** : un cycle est inactif s'il rend `statut: file-vide` ou si la session dure moins de `MIN_ACTIVE_SECONDS=120` (quel que soit le statut déclaré : en dessous, aucune PR ni mise à jour de ticket n'est plausible). Après un cycle inactif, il patiente `EMPTY_SLEEP` ; à partir de `IDLE_LONG_AFTER=3` cycles inactifs consécutifs, `IDLE_LONG_SLEEP=900` (jamais moins que `EMPTY_SLEEP`). Un cycle actif remet le compteur à zéro. Origine : nuit du 2026-11-11, cycles 6 à 12 enchaînés en ~30 s avec `statut: continue`. Avec `statut: arret`, il n'enchaîne plus.
- **Journal** : `state/supervisor.log`. Au-delà de `LOG_MAX_BYTES`, il devient `supervisor.log.1`, et l'ancien `.1` est écrasé. Les sorties JSON (cycles et rapport) sont tronquées à `RUN_MAX_BYTES`, et seules les `RUNS_KEEP` plus récentes sont gardées. Le stderr de `claude` n'est jamais conservé.
- **Fin** : à 09 h, le rapport reçoit la liste des handoffs de la nuit. Une notification macOS locale signale sa fin.

## Handoff

`handoff/<date>-<N>.md`, où `<date>` est la date du début de nuit et `N` le numéro du cycle :

```
statut: continue | file-vide | arret
cycle: <date>-<N>
modele: sonnet
## Faits
## En cours
## Preuves à compléter    PR mergée, app Argo, niveau atteint, niveau manquant, raison
## Blocages (preuve)      commande, erreur, chemins essayés (D-13)
## Quota
## Améliorations
```

Le rapport est écrit dans `handoff/<date>-rapport.md` et publié sur le projet Linear « Socle sain ».

## DRY_RUN et tests

Avec `DRY_RUN=1`, le superviseur n'appelle ni `claude` ni le réseau. Il simule les sessions (handoff factice, JSON factice) et utilise une horloge simulée : `state/clock`, initialisée par `NIGHT_RELAY_FAKE_NOW` (epoch). Les attentes avancent l'horloge au lieu de dormir. Les variables `DRY_RUN_QUOTA_ATTEMPTS`, `DRY_RUN_QUOTA_RESET_IN`, `DRY_RUN_QUOTA_MSG`, `DRY_RUN_FAIL_ATTEMPTS`, `DRY_RUN_EMPTY_ATTEMPTS` et `DRY_RUN_CYCLE_SECONDS` injectent des scénarios. En DRY_RUN, `NIGHT_RELAY_KUBE_STATUS` pointé sur un faux préflight local le fait exécuter (sinon `DRY_RUN_KUBE` est utilisé tel quel).

```sh
DRY_RUN=1 NIGHT_RELAY_FAKE_NOW=$(date +%s) NIGHT_RELAY_STATE=$(mktemp -d) \
  NIGHT_RELAY_HANDOFF_DIR=$(mktemp -d) bash scripts/night-relay/supervisor.sh

bash scripts/night-relay/test_supervisor.sh       # KEEP=1 conserve le répertoire de travail
shellcheck scripts/night-relay/*.sh
```

Le test vérifie la ligne Kubernetes du prompt (disponible, indisponible, préflight lent borné), l'enchaînement, la transmission du handoff, l'attente de quota (heure parsée, heure inconnue, limite pendant le rapport), la borne du journal, le handoff d'échec, la file vide, le garde-fou de cycle inactif (pause, puis pause longue après 3 cycles), les nouvelles tentatives du préflight, le démarrage après minuit, le verrou (y compris pid mort ou vide), la borne des limites consécutives, l'heure de déclenchement du rapport et, en mode réel avec un faux `claude`, l'arrêt par signal sans processus fils ni chien de garde survivant. Des binaires `claude`, `doppler`, `curl` et `gh` factices font échouer le test s'ils sont appelés.

## Limites

- Le superviseur ne relit pas `supervisor.sh` en cours de nuit : une modification du préflight prend effet au lancement suivant. Les prompts (`orchestrator.md`, `report.md`) sont relus à chaque cycle.
- La détection de limite d'usage repose sur le texte du message de `claude`. Ce format n'est pas un contrat stable. En cas de changement, l'attente de repli bornée s'applique.
- Le timeout sans `timeout(1)` repose sur un chien de garde shell : SIGTERM sur l'arbre de processus de la session, puis SIGKILL après `KILL_GRACE`. Un sous-processus détaché de cet arbre (double fork) n'est pas suivi.
- La sélection multi-tickets suppose qu'un ticket verrouillé `wip:*` sort du dry-run du dispatcher. Les verrous posés par l'orchestrateur bloquent donc aussi un dispatcher planifié sur la même voie.
