# Descripteur `argocd-app.yaml` : une Application Argo CD par app (PLT-394)

Statut : ApplicationSet `apps` et AppProject `apps` en place (etape 4), **aucune app migree**. Les domaines migrent un par un (etape 5 et suivantes) ; jusque-la l'ApplicationSet `applications` genere une Application par domaine (`apps-<domaine>`).

## Contrat

Un fichier `k8s/applications/<domaine>/<app>/argocd-app.yaml` declare l'app. Il n'est **jamais** liste dans une kustomization (le nom `app.yaml` est pris : 6 apps y mettent leurs manifestes). L'ApplicationSet `apps` (`k8s/bootstrap/argocd-root/apps-applicationset.yaml`, git files generator, goTemplate `missingkey=error`) cree `app-<name>` dont la source est le dossier de l'app.

| Champ | Type | Defaut | Role |
|---|---|---|---|
| `name` | DNS-1123, 59 caracteres max | obligatoire, egal au dossier | Application `app-<name>` |
| `namespace` | DNS-1123 | obligatoire, doit etre rendu par l'app | `destination.namespace` |
| `project` | AppProject du root (hors `default`) | `apps` | projet Argo CD |
| `postMerge` | `revert` ou `notify` | `revert` | politique du post-merge (`notify` : etat, platform) |
| `preview` | booleen | `false` | l'app a un environnement de preview |
| `extraPaths` | liste de chemins depuis la racine du depot | `[]` | chemins hors dossier de l'app qui declenchent un refresh (ex. `k8s/applications/media/shared`) ; annotation `manifest-generate-paths` = `.` + `/<chemin>` |

Exemple : `name: it-tools`, `namespace: it-tools`, puis optionnellement `postMerge`, `preview`, `extraPaths`.

Ajouter une app = creer son dossier et son `argocd-app.yaml` : aucun fichier partage n'est modifie. `project: apps` admet tout namespace sauf ceux d'infrastructure (destinations `!ns`, doc Argo CD « Projects »).

## Controles CI

`scripts/check-argo-app-descriptors.sh` (test : `tests/harness/argo-app-descriptors-contract-test.sh`, branche dans `check:argo-app-descriptors`, `scripts/check-bash-tests.list` et le workflow `v1-contract`) :

- schema, `name` unique et egal au dossier, `namespace` present dans le rendu, namespaces rendus admis par le projet ;
- `extraPaths` existent ;
- un domaine ne migre que **complet** (chaque sous-dossier a son descripteur) et l'union des rendus `kustomize build --enable-helm` des apps est identique au rendu du domaine, objet par objet `(kind, namespace, name)` sur contenu normalise : sinon une transformation de domaine (patch, labels, fichier de niveau domaine) serait perdue et l'ancienne Application `apps-<domaine>` elaguerait des objets ;
- le domaine migre est retire du generateur de l'ApplicationSet `applications` dans la meme PR (aucune app generee deux fois) ;
- le projet `apps` refuse chaque namespace d'infrastructure.

`scripts/post-merge-affected.sh` et le skill `deploy-a-service` ne sont pas encore adaptes (etapes suivantes).
