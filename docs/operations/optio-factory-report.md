# Optio : rapport sans modèle de ce que chaque tâche a fait (PLT-540)

La vue « Needs you » d'Optio affiche un titre et un motif générique : Paul ne voit pas ce que les agents
font. `scripts/optio/factory-report.sh` rend ce qui manque, en Markdown, sans modèle et sans écriture : il
relit la liste des tâches de l'API Optio (`GET /api/tasks?limit=200`) et assemble un rapport
déterministe. Aucune planification n'est faite ici : le script ne crée, ne modifie et n'annule aucune
tâche.

## Usage

```bash
bash scripts/optio/factory-report.sh                     # 24 h, l'API Optio
bash scripts/optio/factory-report.sh --hours 168         # sept jours
bash scripts/optio/factory-report.sh --input tasks.json  # relecture locale, hors réseau
```

Le rapport part sur stdout : il se lit, se colle dans un compte rendu ou se redirige par l'appelant. Le
script n'écrit aucun fichier.

## Entrées

| Élément | Origine | Rôle |
|---|---|---|
| `OPTIO_API_TOKEN` | secret privé | en-tête `Authorization: Bearer` de l'API Optio |
| `OPTIO_API_URL` | variable du travail | base de l'API Optio (défaut `http://optio-api.optio.svc.cluster.local:4000`) |
| `OPTIO_WORKSPACE_ID` | variable du travail | en-tête `x-workspace-id` (facultatif) |

Options : `--hours N` (période couverte, 24 par défaut), `--input FILE` (liste de tâches JSON locale, deux
formes acceptées : un tableau de tâches ou un objet `{"tasks": [...]}`), `--api-url URL`.

Le jeton ne passe jamais en argument : il est écrit dans un fichier d'en-têtes en mode 600, lu par curl avec
`-H @fichier`. Le test vérifie qu'aucune valeur de secret n'apparaît ni dans la sortie ni dans la ligne de
commande, et que l'API n'est appelée qu'en lecture.

## Sortie

```markdown
# Rapport Optio — 24 h

Période : 2026-11-26T08:00:00Z → 2026-11-27T08:00:00Z
Source : API Optio — GET /api/tasks?limit=200 (lecture seule)

## Résumé

- Tâches : 3
- Par état : completed 1, failed 1, needs_attention 1
- Sans compte de tokens : 1

## Needs attention

- PLT-541 (#2106) — ci_failing_needs_attention

## Tâches

| Tâche | État | Ticket | PR | Motif | Résultat | Tokens | Coût | Dernière activité |
|---|---|---|---|---|---|---|---|---|
| [PLT-540] Rapport sans modèle | completed | PLT-540 | #2107 | inconnu | Le rapport rend une ligne par tâche. | 1234 (in 800 / out 434) | $0.4210 | 2026-11-27T07:40:00.000Z |
```

En tête : la période, le nombre de tâches par état, le nombre de tâches sans compte de tokens et la liste
des tâches `needs_attention` avec leur motif. Ensuite, une ligne par tâche : l'état, le ticket, la PR, le
motif (`errorMessage`), le résumé du résultat (`resultSummary`, tronqué à 120 caractères), les tokens et le
coût estimé quand ils existent.

## Règles de lecture

- **Un champ absent vaut « inconnu », jamais zéro.** C'est la règle qui distingue une tâche sans compte de
  tokens d'une tâche qui n'a rien consommé. Les compteurs de tokens et le coût sont ceux de l'API Optio :
  ils peuvent être vides (les tokens remontés par l'agent ne sont pas toujours comptés par Optio), le
  tableau de bord Grafana de la factory reste la source de vérité du volume consommé.
- **Le ticket** vient de `ticketExternalId` quand l'API le donne, sinon de l'identifiant du titre
  (`[PLT-540] …`). La PR vient de `prNumber`, sinon du numéro déduit de `prUrl`.
- **La période** est filtrée sur la dernière activité connue de la tâche (`updatedAt`, sinon `createdAt`).
  Une tâche sans horodatage lisible est conservée : son activité est inconnue, pas absente.
- **Les lignes sont triées** par dernière activité décroissante.
- **Aucun résumé n'est inventé.** Le rapport ne lit que des champs de l'API : pas de modèle, donc pas
  d'interprétation.

## Tests

`tests/harness/optio-factory-report-test.sh` (hors réseau : `--input` sur des fixtures locales, et un faux
`curl` pour le seul cas qui parle à l'API). Les cas couvrent : l'usage, une liste vide, une liste complète
(compteurs, liste `needs_attention`, ligne par tâche, échappement Markdown, résumé tronqué), les champs
absents, la forme `{"tasks": [...]}`, le filtrage par période, l'appel API (une seule requête GET, aucun
jeton dans la sortie ni dans la ligne de commande), l'erreur d'API et la compatibilité jq 1.6.

## Limites acceptées

- Le rapport ne décrit que ce que l'API Optio connaît. Une tâche sans résumé n'a pas de résumé : le
  rapport le dit, il ne le devine pas.
- Le jeton de l'API Optio peut aussi écrire : le script n'en fait rien, il n'appelle que `GET`.
- La période est bornée par la liste rendue par l'API (`limit=200`) : au-delà de 200 tâches, le rapport
  est partiel. Le script accepte alors une liste locale plus longue (`--input`).

## Retour arrière

Le script est en lecture seule : ne rien faire suffit. Revenir sur le script : revert du commit. Le guide
et le test disparaissent avec lui.

## Preuve

Preuve STATIC : script et tests relus, `shellcheck` propre, test
`bash tests/harness/optio-factory-report-test.sh` vert (jq 1.6 et jq 1.8). L'exécution réelle contre
l'API Optio du cluster est **NOT_TESTED** : elle demande le jeton privé et le réseau du cluster.
