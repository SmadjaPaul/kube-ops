# Dispatcher Linear (PLT-197)

Ce script choisit un ticket de la file PLT sans LLM, en suivant D-10, D-12 et D-20. Il pose ensuite le verrou `wip:claude-<voie>` et lance une seule session `claude -p` bornée.

## Lancer

```sh
# Lecture seule : n'affiche que le ticket choisi et la commande claude, sans poser de verrou ni lancer d'exécution
doppler run -p infrastructure -c prd -- python3 scripts/dispatcher/dispatch.py --lane local --dry-run

# Exécution réelle d'un seul ticket
doppler run -p infrastructure -c prd -- python3 scripts/dispatcher/dispatch.py --lane local

# Même dry-run pour un agent (sortie masquée, AGENTS.md)
bash scripts/doppler-safe.sh run -- python3 scripts/dispatcher/dispatch.py --lane local --dry-run

# Dry-run hors réseau, sur un instantané de la file
python3 scripts/dispatcher/dispatch.py --lane local --dry-run --snapshot scripts/dispatcher/tests/fixtures/snapshot-2026-11-11.json
```

`LINEAR_API_KEY` doit être présent dans l'environnement. Le dépôt ne contient que ce nom, et la valeur vient de Doppler. `DISPATCH_PERMISSION_MODE` règle `claude --permission-mode` (par défaut : `auto`).

Options de sélection (pilotées autrefois par le superviseur `night-relay`, retiré par PLT-236 ; usage manuel uniquement) :

- `--skip PLT-1,PLT-2` : tickets jamais choisis (sautés pour la nuit).
- `--expect PLT-1` : exécution réelle seulement si le choix est encore ce ticket ; sinon code 3, sans verrou.
- `--comment-skip PLT-1 --why TEXTE` : poste le commentaire « sauté pour la nuit » et sort.
- Le dry-run affiche `progrès : <ID> pr=… liens=… commentaires=… dernier=…` pour le ticket choisi (PR liées et commentaires hors dispatcher). Une exécution en échec par limite d'usage affiche `limite d'usage : usage limit[, resets …]`.
- `--require-kube-access` (PLT-239) : préflight canonique (`require_kube_access`, comme `just kube-access-check`) avant toute lecture Linear. Si l'accès n'est pas `KUBE_ACCESS=PASS` : aucun verrou, aucun ticket, code 0, ligne stable `DISPATCH_SKIPPED=kube_access_blocked` (suivie de `KUBE_ACCESS_REASON=<jeton>`). Aucun autre kubeconfig, TLS toujours vérifié.
- `--incident PLT-283` : avec le préflight, au plus un commentaire `Exécutant local bloqué :` par tranche de 3 h sur ce ticket. Jamais en `--dry-run`. Si Linear échoue, le saut reste un code 0.
- Tâche planifiée native macOS : prompt exact et critère E2E dans `docs/operations/local-executor-scheduled-task.md`.
- SIGTERM pendant une exécution : le ticket est remis en Todo, commenté, et le verrou retiré.

Codes de sortie : 0 (succès ou rien à faire), 1 (session `claude` en échec), 2 (erreur Linear ou configuration), 3 (choix changé, `--expect`).

Le pilotage est assuré par la cascade du coordinateur du projet Homelab ; le dispatcher planifié et `night-relay` ne doivent pas être relancés.

Le prompt de session demande un worktree neuf depuis `origin/main` et, pour un ticket large, la première tranche livrable (une PR ciblée, preuve visée RUNTIME) plutôt qu'un refus. La session ne merge pas et ne passe pas Done : le coordinateur du projet Homelab s'en charge.

## Tests

```sh
python3 -m unittest discover -s scripts/dispatcher/tests
```

Les tests n'utilisent pas le réseau. Ils tournent sur des fixtures JSON et un faux client Linear. `test_preflight.py` couvre le préflight d'accès (blocage, commentaire unique par 3 h, dry-run).

## Règles

- **Éligibilité** : un ticket de l'équipe PLT au statut Todo, avec les labels Agent-ready, un seul `agent:haiku|sonnet|opus` et `exec:<voie>`. Il ne porte ni Needs-operator, ni Différé, ni `agent:codex`, ni `wip:*`, et n'a aucun bloqueur `blocks` non terminé.
- **À reprendre** (dry-run seulement) : les tickets In Progress de la voie, avec Agent-ready, un seul `agent:*` et sans `wip:*`, s'affichent en lignes `à reprendre :`. C'est le cas d'une PR mergée dont la preuve RECONCILED/RUNTIME manque. Le coordinateur du projet Homelab les reprend à chaque réveil (état réel, puis reprise au dernier point prouvé) ; le dispatcher ne le fait pas. L'exécution réelle n'en tient pas compte.
- **Tri** : d'abord le projet selon D-10, puis la priorité (sans priorité en dernier), puis la date de création.
- **Bornes** : la table `MODEL_TABLE` de `selection.py` fixe l'effort, les tours et le budget en USD par modèle. Le timeout de `claude` est de 2 h 45, sous le TTL de 3 h du verrou.
- **Verrou actif sur la voie** : le dispatcher ne démarre pas.
- **Verrou expiré** (plus de 3 h sans commentaire) : le dispatcher retire le label, remet le ticket en Todo et le commente.
- **Course** : après avoir posé son verrou, le dispatcher relit les verrous de la voie. Si un autre verrou est plus ancien, il retire le sien et s'arrête.
  - Limite : Linear n'offre pas de compare-and-set. Deux dispatchers qui prennent le même ticket au même instant passent tous les deux. Il faut donc un seul planificateur par voie.
- **Fin d'exécution** : le dispatcher écrit un checkpoint (issue, tours, tokens, coût) puis retire le verrou dans tous les cas, interruption comprise. En cas d'échec, il remet le ticket en Todo. Le stderr n'est jamais recopié : seule sa taille l'est.

## Ligne de mesure (PLT-198)

Le checkpoint finit par une ligne stable, lisible par `clé=valeur` :

```
mesure: in=<n> out=<n> cache_read=<n> cache_create=<n> tours=<n> sous_agents=<n> cout_usd=<x.xxxx> issue=<pr-valide|blocage|echec>
```

- `in`, `out`, `cache_read`, `cache_create` : tokens d'entrée, de sortie, de cache lu et de cache créé (`usage` du JSON `claude -p`).
- `tours` : `num_turns`. `cout_usd` : `total_cost_usd` estimé, à 4 décimales.
- `sous_agents` : nombre dérivé d'un champ `subagents` (liste ou entier) s'il existe dans le JSON ; sinon `n/a`. Le format exact de ce champ n'est pas vérifié hors ligne.
- `issue` : `echec` si la session n'a pas réussi ; `blocage` si le rapport final contient une ligne `Blocage éventuel : <texte non vide>` ; sinon `pr-valide`. Ce dernier état est la déclaration de la session : la PR n'est pas vérifiée sur GitHub.
- Une valeur inconnue (session plantée, JSON absent) s'écrit `n/a`, jamais `0`.
- Les autres lignes du checkpoint (issue, tours, tokens, coût) restent inchangées.
