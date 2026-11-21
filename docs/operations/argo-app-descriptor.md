# Descripteur `argocd-app.yaml` : une Application Argo CD par app (PLT-394)

Statut : ApplicationSet `apps` et AppProject `apps` en place (etape 4). Domaine pilote `tools` migre (etape 5) : Application `app-it-tools` remplace `apps-tools`. Les autres domaines migrent un par un (etape 6 et suivantes) ; jusque-la l'ApplicationSet `applications` genere une Application par domaine (`apps-<domaine>`).

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

## Post-merge et migration d'un domaine

`scripts/post-merge-affected.sh` nomme l'Application Argo attendue d'une app : `app-<name>` si `k8s/applications/<domaine>/<app>/argocd-app.yaml` existe, sinon `apps-<domaine>`. `post-merge-verify.sh` et `verify-revision.sh` reprennent ce nom tel quel ; `scripts/lib/argo-app.sh` et `scripts/observe.sh` resolvent aussi `app-<name>`. Le skill `deploy-a-service` n'est pas encore adapte (etapes suivantes).

Migration d'un domaine, dans **un seul commit** : descripteurs de toutes les apps, retrait du domaine du generateur de `applications`, `scripts/affected-tests.conf` (une entree par app migree a la place du domaine), `scope.tsv` (colonne racine Argo). L'ancienne Application `apps-<domaine>` disparait sans cascade (`preserveResourcesOnDeletion`, pas de finalizer) ; `app-<name>` reprend les ressources : Argo CD identifie les objets par le tracking annotation (`argocd.argoproj.io/tracking-id`, `<application>:<group>/<kind>:<ns>/<name>`) et la reecrit au premier sync de la nouvelle Application, sans suppression ni recreation (ServerSideApply et `ApplyOutOfSyncOnly` : l'ecriture suit le premier sync).

## Cas du domaine `ai` (objets Argo hors du domaine)

Le domaine `ai` rendait aussi, via `k8s/optional/personal-ai-2026/{hindsight,librechat}`, des objets du namespace `argocd` (Applications `personal-hindsight`, `personal-librechat`, AppProject `personal-ai-pilot`) que le projet `apps` refuse (`!argocd`). Ils sont desormais geres par le `root` : fichiers `k8s/bootstrap/argocd-root/personal-*.yaml` (`git mv`, kustomize refuse les fichiers hors de son arbre), listes dans `kustomization.yaml` du root. Le reste de chaque dossier optional devient une app (`k8s/applications/ai/personal-hindsight`, `personal-librechat`, kustomization vers le dossier optional, `extraPaths`).

Consequence pour le controle d'equivalence : `k8s/applications/ai/kustomization.yaml` n'est plus suivi par Argo, c'est un agregat des 5 dossiers d'apps ; le controle (domaine == union des apps) reste donc valable mais ne voit plus les 3 objets Argo. La preuve que rien n'est perdu a ete faite a la migration : rendu de l'ancien domaine (52 objets) == union des rendus des 5 apps + 3 objets du root, objet par objet sur contenu normalise. L'annotation `Prune=false` posee avant la migration protege les objets vivants pendant le changement de proprietaire.
