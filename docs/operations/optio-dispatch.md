# Optio : orchestrateur sans LLM (PLT-527)

Le travail planifié décrit dans [optio-intake.md](optio-intake.md) devient un script déterministe,
`scripts/optio/dispatch.sh`. Les règles du passage — quels tickets, quelles revues, quelles corrections,
quelles reprises — ne dépendent plus d'un modèle : elles sont écrites en bash et en jq, et testées hors
réseau. Le modèle n'intervient plus que dans le travail de code, de revue et de correction que le script
crée. La consigne du travail planifié ([optio-intake.md](optio-intake.md), point 7) et ce script portent
la même règle : une PR ouverte d'une tâche de ticket donne une revue, une correction, ou rien.

## Mode essai par défaut

Sans `--apply`, le script **n'écrit rien** : ni dans Optio, ni dans Linear. Il affiche seulement les actions
prévues.

```bash
bash scripts/optio/dispatch.sh             # essai : aucune écriture
bash scripts/optio/dispatch.sh --apply     # exécution
```

## Entrées

| Élément | Origine | Rôle |
|---|---|---|
| `LINEAR_INTAKE_KEY` (`LINEAR_API_KEY` acceptée en repli) | secret privé, écrit par `optio-secret-sync` | en-tête `Authorization` de la requête Linear |
| `OPTIO_API_TOKEN` | secret privé | en-tête `Authorization: Bearer` de l'API Optio |
| `OPTIO_API_URL` | variable du travail | base de l'API Optio (défaut `http://optio-api.optio.svc.cluster.local:4000`) |
| `OPTIO_WORKSPACE_ID` | variable du travail | en-tête `x-workspace-id` |
| `OPTIO_DISPATCH_LOCK_FILE` | variable du travail | fichier de verrou local (défaut `$TMPDIR/optio-dispatch.lock`) |

Options : `--apply`, `--slots N` (places du dépôt, 10 par défaut), `--instructions FILE`,
`--select-actions FILE`, `--api-url URL`, `--repo-url URL`.

Les secrets ne passent jamais en argument : ils sont écrits dans un fichier d'en-têtes en mode 600, lu par
curl avec `-H @fichier`. Le test vérifie qu'aucune valeur de secret n'apparaît ni dans la sortie ni dans la
ligne de commande, et que les trois en-têtes sont bien présents.

## Ce que fait un passage

1. **Un passage à la fois** — verrou local `flock` (facultatif : le script continue sans, en le signalant).
   Un passage déjà en cours fait sortir le nouveau avec le code 3, sans rien créer.
2. **Une seule requête Linear** — GraphQL, filtrée côté serveur : label `wip:optio`, états `backlog` et
   `unstarted`, 50 au plus. Aucune autre requête Linear, aucune pagination au-delà.
3. **La décision** — `scripts/optio/select-actions.sh` (PLT-522), la version testable des étapes 2 à 7 de la
   consigne. Le fichier local est utilisé quand il existe ; sinon il est téléchargé depuis `main`, le travail
   de commande n'ayant pas de dépôt cloné.
4. **L'état réel des PR** — relu sur GitHub avant toute revue, correction ou reprise. L'état mis en cache
   par Optio (`prState`) n'est jamais utilisé pour décider. Une PR fermée ou mergée : aucune création, et
   les revues ou corrections encore actives pour cette PR sont annulées (`POST /api/tasks/:id/cancel`).
   Une tâche `needs_attention` est aussi annulée quand elle est sans objet : revue ou correction terminée
   (« did not open a pull request »), ou tâche de ce dépôt dont la PR est fermée ou mergée. Son état est relu
   avant l'annulation. Tout autre motif (agent bloqué, CI en échec sur une PR ouverte) reste visible.
5. **Une création à la fois** — la liste des travaux est relue avant chaque création. Si le nom
   `[IDENTIFIANT]`, `[REVUE PR-N <sha8>]` ou `[CORRIGE PR-N k]` existe déjà, le script s'abstient et
   l'écarte avec la raison.
6. **Les reprises** — une tâche de ticket échouée sans PR est reprise, deux reprises au plus (`retryCount`) ;
   au plafond, la tâche est signalée dans la sortie. Avant une reprise, l'état des travaux et celui des PR
   sont relus : une tâche qui n'est plus en échec, qui a une PR, ou qui a atteint le plafond n'est pas
   reprise.
7. **Les consignes** — recopiées mot pour mot depuis `docs/operations/optio-intake.md` : la consigne de code
   (avec `(IDENTIFIANT)` remplacé par l'identifiant du ticket), la consigne REVUE, la consigne CORRECTION et
   la phrase de fin. Le fichier est lu quand `--instructions` le donne, sinon téléchargé depuis `main` ; il
   n'est téléchargé que s'il y a au moins une création à faire.
8. **Le modèle** — `text/strong`, ou `code/frontier` si le ticket porte le label `agent:opus`.
9. **Le compte rendu** — la dernière ligne est un JSON : `{"tickets_read":n,"created":n,"reviews":n,
   "fixes":n,"retried":n,"cancelled":n,"skipped":n,"errors":n}`. Une erreur d'API donne un code de retour non
   nul et n'est jamais passée en silence : le compte rendu des actions est alors affiché avec `errors` à 1.

## Sortie

Deux lignes JSON, la dernière est le compte rendu :

```json
{"mode":"dry-run","apply":false,"tasks":[],"reviews":[],"fixes":[],"retries":[],"cancellations":[],"skipped":[]}
{"tickets_read":1,"created":0,"reviews":0,"fixes":0,"retried":0,"cancelled":0,"skipped":0,"errors":0}
```

En mode `--apply`, la première ligne décrit les actions **effectuées** ; en mode essai, les actions
**prévues** (rien n'est écrit). Lesctions écartées sont dans `skipped`, avec `id` et `reason`.

| Code | Signification |
|---|---|
| 0 | succès |
| 1 | erreur d'API (le compte rendu est affiché, `errors` vaut 1 ou plus) |
| 2 | usage ou configuration (variable d'environnement manquante, option inconnue) |
| 3 | un passage est déjà en cours (verrou) |

## Appels et budget de requêtes

| Destination | Appels | Authentification |
|---|---|---|
| Linear (`POST /graphql`) | 1 par passage | clé Linear, en-tête |
| API Optio (`GET /api/tasks?limit=200`) | 1 au début, puis 1 avant chaque création | jeton, en-tête |
| API Optio (`POST /api/tasks`, `/retry`, `/cancel`) | 1 par action | jeton, en-tête |
| GitHub (`GET /repos/.../pulls`) | 1 par passage (5 au plus si la liste est longue) | aucune, lecture publique |
| GitHub (`GET /repos/.../contents`, `raw.githubusercontent.com`) | 0 ou 1 par passage | aucune, lecture publique |

L'API GitHub non authentifiée est limitée à 60 requêtes par heure et par adresse IP : un passage consomme
2 à 3 requêtes, la planification toutes les 10 min tient dans le plafond. Le script n'authentifie pas et
n'écrit pas sur GitHub.

## Tests

`tests/harness/optio-dispatch-test.sh` (hors réseau : un faux `curl` sert des fixtures locales, dans
`tests/fixtures/optio-dispatch/`). Les cas couvrent : file vide, un ticket (une création en `--apply`, aucune
sans), label `agent:opus` (modèle `code/frontier`), ticket assigné (aucun travail), second passage sans
doublon, PR fermée ou mergée (aucune revue, aucune correction, annulation des travaux encore actifs), nouvelle
tête de PR (nouvelle revue), tâche échouée (une reprise, puis le plafond), état de la tâche changé entre deux
lectures, erreur d'API (code de retour non nul, erreur comptée dans le compte rendu), consignes recopiées,
secret jamais dans la sortie ni dans la ligne de commande, un seul passage à la fois, et la compatibilité
jq 1.6.

## Limites acceptées

- Le script lit l'API Optio avec le jeton du travail privé : ce jeton peut aussi écrire, donc annuler.
  Seules les écritures décrites ci-dessus sont faites, et aucune autre.
- Le prompt d'une tâche de ticket contient la description du ticket : c'est une donnée, pas une consigne.
  La consigne du travail créé reste celle du dépôt, et le modèle lit le ticket comme une donnée.
- Le texte du ticket est recopié sans transformation : une consigne cachée dans la description atteint le
  modèle qui écrit le code. La règle de sécurité de la consigne de l'orchestrateur s'applique à l'agent.
- Une revue nommée avec la tête de PR (`[REVUE PR-N <sha8>]`) : une nouvelle tête est relue, une PR jamais
  relue ne l'est pas.

## Retour arrière

Ne pas utiliser `--apply` : le script n'écrit rien. Désactiver le travail planifié et le secret privé
`LINEAR_INTAKE_KEY`. Revenir sur le script : revert du commit. Le script de sélection et le script
d'orchestration sont indépendants : le premier peut rester en place.

## Preuve

Preuve STATIC : script et tests relus, `shellcheck` propre, test `bash tests/harness/optio-dispatch-test.sh`
vert. Aucun appel réseau, aucun accès cluster, aucun travail Optio créé par cette preuve.
