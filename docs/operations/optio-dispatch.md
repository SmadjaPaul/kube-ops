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

Options : `--apply`, `--slots N` (places d'agent, 5 par défaut), `--instructions FILE`,
`--select-actions FILE`, `--api-url URL`, `--repo-url URL`, `--pi-release FILE`.

Les secrets ne passent jamais en argument : ils sont écrits dans un fichier d'en-têtes en mode 600, lu par
curl avec `-H @fichier`. Le test vérifie qu'aucune valeur de secret n'apparaît ni dans la sortie ni dans la
ligne de commande, et que les trois en-têtes sont bien présents.

## Dépôts (PLT-542)

Un ticket est éligible avec une ligne exacte `Dépôt: <nom>` ; noms admis (liste `ALLOWED_REPOS` du sélecteur) :
kube-ops, agent-harness, website, homelab-infra, Atlas, ha-config, terraform-provider-polyfin,
terraform-provider-aiostreams. Deux dépôts différents dans un ticket l'écartent. La tâche n'est créée que si le
dépôt figure dans `GET /api/repos` (`{"repos":[{"repoUrl":…}]}`), sous le même propriétaire que `--repo-url` ;
si cette liste est illisible, aucun ticket n'est pris et l'erreur est comptée. Les zones interdites restent les
mêmes ; seule la zone `ha-config` ne s'applique pas à un ticket du dépôt ha-config.

Ordre de prise (PLT-562, comme Atlas `priorities.yaml`) : priorité Linear, puis palier, puis nombre de tickets
ouverts débloqués, puis ancienneté. Une relation bloquante entrante se lit dans `inverseRelations.issue`.

Les revues et corrections ne concernent que les PR de `--repo-url` (kube-ops). Les PR des autres dépôts ne donnent
ni revue ni correction : elles ont les reprises et les clôtures décrites plus bas. Leur tâche de code reçoit la consigne AUTRE-DEPOT
([optio-intake.md](optio-intake.md)) : l'agent merge lui-même sa PR, sauf les exceptions qu'elle liste. Cette
règle n'est portée que par la consigne : le script ne contrôle ni le diff ni le merge.

## Dépôts sans merge (PLT-573)

Le merge de `website` et d'`Atlas` reste humain. La liste `NO_MERGE_REPOS` du script protège ces deux dépôts,
même sans fichier de release. L'agent ouvre la PR et fournit les preuves requises par le dépôt.

* la tâche de ticket reçoit la consigne SANS-MERGE ([optio-intake.md](optio-intake.md)) au lieu de la consigne
  AUTRE-DEPOT ;
* une PR n'est reprise que pour corriger la CI ou un conflit (consigne REPRISE-SANS-MERGE) ; une PR verte n'est
  jamais reprise pour être mergée ;
* une PR verte et sans conflit fait l'objet d'un seul commentaire sur le ticket, « PR prête, merge attendu », avec
  le lien de la PR. Le commentaire porte la marque `optio-dispatch, PR prête, merge attendu : <dépôt>#<n>` : le
  passage suivant relit les commentaires du ticket et se tait. Le ticket n'est pas changé d'état : la fusion
  GitHub de Linear le ferme au merge, comme pour les autres dépôts.

Une consigne absente des instructions (fichier de `docs/operations/optio-intake.md` trop ancien) fait échouer le
passage : aucune tâche d'un dépôt sans merge n'est créée, l'erreur est comptée.

## Admission de nouvelles tâches Pi

Le planificateur accepte un fichier local `--pi-release`. Il part de l'export
`python3 scripts/ticket_context.py --factory-repos --json` d'Atlas et ajoute l'objet `pi`.

| Champ | Valeur |
|---|---|
| `owner`, `repos` | Export Atlas avec `name`, `entrypoint`, `factory_profile`, `factory_merge` pour chaque dépôt |
| `pi.image` | Référence OCI de l'image de pod Optio dérivée, épinglée par `@sha256:<digest>` |
| `pi.bundles` | Objet qui associe chaque profil admis à la référence OCI épinglée de son bundle |
| `pi.admit` | Noms des dépôts autorisés à démarrer de nouvelles tâches d'implémentation en Pi. Comparaison insensible à la casse |
| `pi.evidence` | Pour `--apply` avec une liste non vide, renseigner `optio: "0.26.4"`, `image` identique à `pi.image` et `task` avec l'UUID de la tâche canari qui a prouvé l'exécution |

L'essai à blanc détaille `agentType: "pi"`, profil, image et bundle des tâches admises. En mode écriture, une
release invalide, une preuve absente ou un `OPTIO_PI_CREDENTIAL_ID` absent arrêtent le passage avant tout appel
réseau. Avant toute écriture, le dispatcher relit le UUID auprès d'Optio : la tâche du même espace doit utiliser Pi,
viser un dépôt admis et être dans l'état `pr_opened` ou `completed`. Le dispatcher envoie
`agentType: "pi"`, `metadata.agentOptions.piModel` et
`metadata.agentOptions.credential: "secret:<id>"` à l'API Optio. `autoMerge` et `autoResume` restent à
`false`, et `maxRetries` vaut `0`. La session Pi ouvre une PR sans la fusionner. Pi reçoit les mêmes alias
Agentgateway `text/strong` et `code/frontier` que les tâches existantes.
L'export Atlas peut ajouter des exceptions de merge humain, y compris pour les tâches qui restent sur Claude.

**Avant d'activer une admission**

1. Publier l'image et le bundle. Donner au binaire le manifeste candidat minimal avec le dépôt canari
   dans `pi.admit` et les références des bundles. Ce manifeste distinct ne contient pas le digest de sa
   propre image. Le job planifié reste sans `--pi-release` pendant le canari manuel.
   Le binaire `pi` de l'image doit accepter la commande native
   d'Optio et produire ses événements JSONL `message_end` et `agent_settled`. L'adaptateur v0.26.4 passe
   `OPTIO_TASK_ID`, `OPTIO_REPO_URL` et `OPTIO_PROMPT`. Il exécute `pi --print --mode json` avec
   `--no-extensions` et le seul MCP intégré. Le binaire dérivé relie ce contrat au bundle et au profil
   résolu depuis le dépôt. Le dispatcher ne transmet ni l'image ni d'environnement personnalisé par tâche.
   [Commande native Optio](https://github.com/jonwiggins/optio/blob/v0.26.4/apps/api/src/utils/pi-command.ts)
   · [Adaptateur Pi](https://github.com/jonwiggins/optio/blob/v0.26.4/packages/agent-adapters/src/pi.ts)
2. Faire pointer le preset d'Optio vers l'image de la release en conservant Claude et le cycle de vie Optio.
   Le worker v0.26.4 utilise le preset du dépôt. Pour les presets, Optio résout
   `OPTIO_AGENT_IMAGE_PREFIX + preset + ":" + OPTIO_AGENT_IMAGE_TAG`. Rendre compatibles les presets admis
   et vérifier le digest réellement chargé sur les pods neufs avant de router une tâche. Utiliser le même
   export Atlas et les mêmes bundles dans le manifeste du binaire et dans la release du planificateur.
   [Worker Optio](https://github.com/jonwiggins/optio/blob/v0.26.4/apps/api/src/workers/task-worker.ts)
   · [Pool de pods](https://github.com/jonwiggins/optio/blob/v0.26.4/apps/api/src/services/repo-pool-service.ts)
3. Configurer dans Optio une clé virtuelle Agentgateway dédiée sous le nom `OPENAI_API_KEY`. Donner au
   dispatcher uniquement son identifiant Optio via `OPTIO_PI_CREDENTIAL_ID`. Le binaire contacte l'URL
   d'Agentgateway inscrite dans le plan compilé du bundle. Le choix explicite du credential évite le repli
   d'Optio vers toutes les clés de fournisseurs disponibles. Vérifier le modèle servi et l'absence de clé
   fournisseur brute ou d'identité de production dans la tâche.
   [Sélection du credential](https://github.com/jonwiggins/optio/blob/v0.26.4/apps/api/src/services/pi-provider-secrets.ts)
4. Créer manuellement une tâche Pi canari bornée sur un pod neuf. Vérifier la sélection du profil, le bundle,
   le résultat natif visible dans Optio et l'appel Agentgateway. Reporter le UUID et le digest observé dans la
   release externe où seul le dépôt canari est admis. Comparer le
   plan du dispatch sans `--apply` avec l'état réel avant la première écriture.

Les nouvelles revues, corrections CI et reprises de PR restent sur Claude. Les reprises d'une tâche Claude
consomment le même ID d'Optio. Les tâches Pi en échec restent visibles pour traitement explicite, car le bridge
ne reprend pas les sessions `--session-id`. Vider `pi.admit` ou retirer `--pi-release` remet les nouvelles
tâches sur Claude sans conversion des tâches existantes. Une image antérieure peut être rétablie une fois
les tâches Pi en cours terminées. Aucun preset ou réglage du travail planifié n'est changé par ce raccord.

## Places

Seuls les travaux qui consomment un agent comptent : `pending`, `queued`, `provisioning`, `running` et tout état
inconnu. `pr_opened`, `needs_attention`, `waiting_on_deps` et les états terminés ne prennent aucune place. Les
places libres sont servies dans cet ordre : reprises de revue et de correction, reprises de PR d'autres dépôts,
nouvelles revues, nouvelles corrections, reprises de ticket, nouveaux tickets.

## Ce que fait un passage

1. **Un passage à la fois** — verrou local `flock` (facultatif : le script continue sans, en le signalant).
   Un passage déjà en cours fait sortir le nouveau avec le code 3, sans rien créer.
2. **Une seule requête Linear** — GraphQL, filtrée côté serveur : label `wip:optio`, états `backlog` et
   `unstarted`, 50 au plus, sans pagination. Les clôtures et les blocages (ci-dessous) ajoutent une seule requête
   groupée.
3. **La décision** — `scripts/optio/select-actions.sh` (PLT-522), la version testable des étapes 2 à 7 de la
   consigne. Le fichier local est utilisé quand il existe ; sinon il est téléchargé depuis `main`, le travail
   de commande n'ayant pas de dépôt cloné.
4. **L'état réel des PR** — relu avant toute revue, correction ou reprise, par l'API Optio
   (`GET /api/pull-requests`) ; repli sur GitHub sans jeton si la liste échoue, ne contient aucune PR de kube-ops
   ou en contient 50 ou plus (Optio omet en silence un dépôt en erreur). L'état mis en cache
   par Optio (`prState`) n'est jamais utilisé pour décider. Une PR fermée ou mergée : aucune création, et
   les revues ou corrections encore actives pour cette PR sont annulées (`POST /api/tasks/:id/cancel`).
   Une tâche `needs_attention` est aussi annulée quand elle est sans objet : revue ou correction terminée
   (« did not open a pull request »), ou tâche de ce dépôt dont la PR est fermée ou mergée. Son état est relu
   avant l'annulation. Tout autre motif (agent bloqué, CI en échec sur une PR ouverte) reste visible.
   Le sélecteur ne reçoit que les PR ouvertes : une PR fermée ne prend aucune des 5 places de revue ou de
   correction (PLT-537).
5. **Une création à la fois** — la liste des travaux est relue avant chaque création. Une création refusée
   par Optio est comptée et n'arrête pas les suivantes. Si le nom
   `[IDENTIFIANT]`, `[REVUE PR-N <sha8>]` ou `[CORRIGE PR-N k]` existe déjà, le script s'abstient et
   l'écarte avec la raison.
6. **Les reprises** — une tâche de ticket échouée sans PR est reprise, quel que soit son dépôt. Une revue ou une
   correction de kube-ops est reprise seulement si `errorMessage` contient `usage limit` ou `429`, si la PR est
   ouverte (même tête pour une revue ; pour une correction, la plus récente d'une PR encore en échec ou en
   conflit). La même règle vaut pour une panne de pod (`Timed out waiting for pod`, `Pod needs recovery`,
   `Pod is recovering`). Plafond : 2 reprises ; 6 après un échec sur la limite du forfait, avec au moins 60 min
   depuis l'échec ; 6 après une panne de pod, avec au moins 30 min. Une tâche de ticket au plafond reste en échec et
   son ticket reçoit un commentaire, une seule fois. Le nombre de reprises est le plus grand de `retryCount` et du nombre d'événements `user_retry`
   (`GET /api/tasks/:id/events`) : Optio v0.26.4 n'incrémente pas `retryCount` pour une tâche de dépôt. Sans
   historique lisible, aucune reprise. L'état de la tâche et des PR est relu avant la reprise.
7. **Les consignes** — recopiées mot pour mot depuis `docs/operations/optio-intake.md` : la consigne de code
   (avec `(IDENTIFIANT)` remplacé par l'identifiant du ticket), la consigne REVUE, la consigne CORRECTION, la
   consigne AUTRE-DEPOT, la consigne REPRISE, la consigne SANS-MERGE, la consigne REPRISE-SANS-MERGE et la
   phrase de fin. La consigne dépend du dépôt : un dépôt sans merge reçoit SANS-MERGE (ou REPRISE-SANS-MERGE)
   au lieu d'AUTRE-DEPOT (ou REPRISE). Le fichier est lu quand `--instructions` le donne,
   sinon téléchargé depuis `main` par `raw.githubusercontent.com` (hors quota de l'API GitHub) ; il n'est
   téléchargé que s'il y a au moins une création à faire.
8. **Le modèle** — `text/strong`, ou `code/frontier` si le ticket porte le label `agent:opus`.
9. **Le compte rendu** — la dernière ligne est un JSON : `{"tickets_read":n,"created":n,"reviews":n,
   "fixes":n,"retried":n,"cancelled":n,"skipped":n,"errors":n,"resumed":n,"closed":n,"notices":n}`. Une erreur d'API donne un code de retour non
   nul et n'est jamais passée en silence : le compte rendu des actions est alors affiché avec `errors` à 1.

## PR d'autres dépôts restées ouvertes (PLT-560)

Une tâche de ticket d'un autre dépôt dont l'agent a fini (`pr_opened`, `needs_attention`, `failed`, `completed` ;
jamais `cancelled`), sans autre travail actif pour le ticket, garde parfois une PR ouverte : la CI a fini après
l'agent, un check a échoué ou la branche est en conflit. La PR est la sienne (`prUrl`) ou, si la tâche n'a rien
enregistré, une PR dont le titre porte `(IDENTIFIANT)` ou `[IDENTIFIANT]`, créée pendant son exécution.

* `GET /api/pull-requests/status` relit la CI. Checks en attente (ou aucun check depuis moins de 15 min) : rien.
  PR en brouillon : rien.
* Sinon le script crée `[REPRISE <dépôt>#N <sha8> k]` avec la consigne REPRISE : corriger sur la branche, ou
  merger quand tout est vert, avec les mêmes exceptions que la consigne AUTRE-DEPOT. Un dépôt sans merge
  (`website`) n'est pas repris pour être mergé : une PR verte et sans conflit n'y donne aucune reprise, elle
  donne un commentaire sur le ticket (« PR prête, merge attendu »).
* Plafond : 3 reprises par PR et une seule par tête (une reprise en échec est retentée après 60 min). Au plafond, ou
  quand une reprise a laissé la PR ouverte sur la même tête, le ticket reçoit un commentaire, une seule fois.
* Une reprise terminée sans PR est annulée : elle ne reste pas dans « Needs you ».

## Tâches mergées sans PR détectée (PLT-560)

Une tâche de ticket `needs_attention` avec « did not open a pull request » est close quand une PR du même dépôt,
attachée au ticket Linear après la création de la tâche et portant son identifiant, est mergée (état lu par l'API
Optio) et qu'aucune autre n'est ouverte. Optio 0.26.4 n'a aucune transition `needs_attention` -> `completed`
(seulement `running`, `queued`, `cancelled`) : la tâche est **annulée** (`POST /api/tasks/:id/cancel`).

Avant l'annulation, le ticket reçoit un commentaire avec l'URL et la tête mergée. Il passe à Done seulement si la PR
le corrige : lien Linear `closes` (métadonnée `linkKind`), ou, sans cette métadonnée et pour un dépôt public, ligne
`Fixes IDENTIFIANT` sans `Part of`. Sinon il reste ouvert, avec le commentaire. Si une écriture Linear échoue, la
tâche n'est pas annulée. Ce sont les seules écritures Linear du script, avec les commentaires de blocage.

## Sortie

Deux lignes JSON, la dernière est le compte rendu :

```json
{"mode":"dry-run","apply":false,"tasks":[],"reviews":[],"fixes":[],"resumes":[],"closures":[],"notices":[],"retries":[],"cancellations":[],"skipped":[]}
{"tickets_read":1,"created":0,"reviews":0,"fixes":0,"retried":0,"cancelled":0,"skipped":0,"errors":0,"resumed":0,"closed":0,"notices":0}
```

En mode `--apply`, la première ligne décrit les actions **effectuées** ; en mode essai, les actions
**prévues** (rien n'est écrit). Les actions écartées sont dans `skipped`, avec `id` et `reason`.

| Code | Signification |
|---|---|
| 0 | succès |
| 1 | erreur d'API (le compte rendu est affiché, `errors` vaut 1 ou plus) |
| 2 | usage ou configuration (variable d'environnement manquante, option inconnue) |
| 3 | un passage est déjà en cours (verrou) |

## Appels et budget de requêtes

| Destination | Appels | Authentification |
|---|---|---|
| Linear (`POST /graphql`) | 1 par passage ; 1 de plus s'il y a une clôture ou un blocage ; 1 par écriture | clé Linear, en-tête |
| API Optio (`GET /api/tasks?limit=1000`) | 1 au début, puis 1 avant chaque création, reprise ou clôture | jeton, en-tête |
| API Optio (`GET /api/repos`) | 1 par passage | jeton, en-tête |
| API Optio (`GET /api/pull-requests`) | 1 par passage, 1 de plus avant les écritures | jeton, en-tête |
| API Optio (`GET /api/pull-requests/status`) | 1 par PR à reprendre ou à clore | jeton, en-tête |
| API Optio (`GET /api/tasks/:id/events`) | 1 par tâche en échec candidate | jeton, en-tête |
| API Optio (`POST /api/tasks`, `/retry`, `/cancel`) | 1 par action | jeton, en-tête |
| `raw.githubusercontent.com` (consignes, sélecteur) | 0 à 2 par passage | aucune, hors quota API |
| API GitHub (`GET /repos/.../pulls`) | repli seulement | aucune, lecture publique |
| API GitHub (`GET /repos/.../pulls/N`) | clôture sans `linkKind` seulement | aucune, lecture publique |

L'API GitHub non authentifiée est limitée à 60 requêtes par heure et par adresse IP, partagées avec le reste du
réseau : deux passages sur 59 ont échoué en HTTP 403 le 26/11. Un passage normal n'y fait plus aucun appel. Le
script n'écrit pas sur GitHub.

## Tests

`tests/harness/optio-dispatch-test.sh` (hors réseau : un faux `curl` sert des fixtures locales, dans
`tests/fixtures/optio-dispatch/`). Les cas couvrent : file vide, un ticket (une création en `--apply`, aucune
sans), label `agent:opus` (modèle `code/frontier`), ticket assigné (aucun travail), second passage sans
doublon, PR fermée ou mergée (aucune revue, aucune correction, annulation des travaux encore actifs), nouvelle
tête de PR (nouvelle revue), tâche échouée (une reprise, puis le plafond), état de la tâche changé entre deux
lectures, erreur d'API (code de retour non nul, erreur comptée dans le compte rendu), consignes recopiées,
secret jamais dans la sortie ni dans la ligne de commande, un seul passage à la fois, la compatibilité
jq 1.6 et, pour PLT-560, les reprises de PR (plafond, tête, CI en attente), les clôtures (Done, « Part of »,
écriture Linear refusée), les pannes de pod et le repli GitHub. Pour PLT-573 : la consigne d'un dépôt sans merge
(« tu ne merges pas », jamais `gh pr merge`), l'absence de reprise sur une PR verte, le commentaire unique
« PR prête, merge attendu » (et son absence au passage suivant), la reprise sur CI en échec ou conflit, et le
refus de créer une tâche ou une reprise quand la consigne manque dans les instructions.

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
