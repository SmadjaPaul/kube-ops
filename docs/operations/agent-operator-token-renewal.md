# Identité agent-operator : défaut kubectl-ro et renouvellement du jeton (PLT-420, PLT-421, PLT-422)

Décision D-2026-11-22-02 (matrice `agent-access-matrix.json` de homelab-infra, écarts F1, F2, F3).

## PLT-420 (F1, F6) : fait dans ce dépôt

- `scripts/kubectl-ro.sh` : `KUBECTL_RO_IDENTITY` vaut `agent` par défaut. Copie agent absente, expirée ou refusée par l'API :
  exit 2, raison sur stderr, aucune commande lancée, aucun repli sur la copie opérateur. Le mode `auto` n'existe plus (refusé, exit 64).
  `KUBECTL_RO_IDENTITY=operator` reste le retour arrière explicite. OKE (`--cluster oracle-a1`) et le mode in-cluster sont inchangés.
- Tests : `tests/agent-guard/secret-helpers-test.sh` (défaut agent, pas de repli, `auto` refusé, `operator` explicite),
  `tests/agent-guard/agent-operator-token-renew-test.sh`.
- homelab-infra `AGENTS.md` : `just kubectl` et `just kube-access-check` sont déjà réservés à Paul (aucun changement requis).

Retour arrière : exporter `KUBECTL_RO_IDENTITY=operator` (immédiat, par session), ou revert de la PR.

## PLT-420 : renouvellement quotidien du jeton de 24 h (préparé, geste de Paul)

Le jeton est émis par `scripts/agent-operator-token.sh --provision`, qui exige l'accès opérateur canonique et le Doppler de Paul
(écriture `infrastructure/prd`) : un agent ne peut pas le lancer, et le homelab doit être joignable. Le renouvellement est donc
une tâche launchd sur le Mac de Paul, toutes les 12 h (une exécution ratée ne coupe pas l'accès).

Fichiers prêts : `scripts/agent-operator-token-renew.sh` (verrou, statuts seulement, alerte ntfy facultative via `NTFY_TOPIC_URL`),
`scripts/launchd/dev.smadja.agent-operator-token-renew.plist`.

Installation (Paul, sur le Mac, une seule fois ; non faite) :

```sh
REPO=/Users/paul/Desktop/perso/kube-ops
sed "s#__REPO__#$REPO#" "$REPO/scripts/launchd/dev.smadja.agent-operator-token-renew.plist" > ~/Library/LaunchAgents/dev.smadja.agent-operator-token-renew.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/dev.smadja.agent-operator-token-renew.plist
bash "$REPO/scripts/agent-operator-token-renew.sh"        # premier renouvellement, attendu : RENEW=PASS
bash "$REPO/scripts/kubectl-ro.sh" auth whoami            # attendu : identity=system:serviceaccount:agent-operator:agent-operator
```

Désinstallation : `launchctl bootout "gui/$(id -u)/dev.smadja.agent-operator-token-renew"` puis supprimer le plist.
Critère de clôture : `whoami` OK 24 h après le dernier renouvellement manuel, sans geste (journal `/tmp/agent-operator-token-renew.log`).
Limite : le Mac doit être allumé, connecté à Doppler, et atteindre l'API du homelab (hors de chez lui, le renouvellement échoue et l'accès agent expire après 24 h).

## PLT-421 (F2) : bloqué par un mandat

Jetons de service Doppler en lecture par config (`agents/prd`), créés par OpenTofu. Il faut l'accord de Paul pour (a) un jeton
d'administration Doppler limité au projet dans ARC, ou (b) l'admission de la racine `doppler` en apply (PLT-299). Rien n'est
modifiable dans ce dépôt avant cette décision.

## PLT-422 (F3) : geste de Paul requis

Créer la GitHub App `atlas-tech` (compte de Paul) : permissions `contents`, `pull_requests`, `actions`, `checks` en write, jamais
`administration` ; l'installer sur les dépôts choisis ; générer une clé privée par exécutant. Ensuite un agent range la clé dans
Doppler, bascule `gh` sur le jeton d'installation d'1 h et ajuste les règles de branche. Preuve attendue : une PR ouverte et mergée
par l'App, auteur des commits = le bot.
