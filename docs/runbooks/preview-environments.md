# Previews par PR (PLT-390 lot 2)

Un namespace jetable `pr-<n>-<app>` par PR, sur le cluster de prod, déployé depuis le SHA de tête de la PR. Rien n'est public : une preview n'est joignable que par `Gateway/internal` (LAN).

## Utiliser

1. La PR ajoute ou modifie `k8s/applications/<catégorie>/<app>/`. L'app doit avoir un descripteur `argocd-app.yaml` avec `preview: true` (opt-in, voir `docs/operations/argo-app-descriptor.md`) ; sans lui, les labels ne génèrent rien. Aujourd'hui : `it-tools` seulement ; une app d'un domaine non migré (`media`) n'a pas de descripteur donc pas de preview.
2. Poser deux labels sur la PR : `preview` et `preview:<app>` (`<app>` = nom du dossier, `^[a-z0-9][a-z0-9-]{0,37}$`) ; les ApplicationSets découvrent l'app par son descripteur (matrix PR × git files, `selector` `preview: "true"`). Une app par PR.
3. L'ApplicationSet `previews` (poll de 120 s) crée l'Application `preview-pr<n>-<app>` (projet `previews`) et l'ApplicationSet `previews-guardrails` l'Application `preview-guardrails-pr<n>-<app>` (projet `previews-guardrails`, source `main`).
4. `just app-test <app> pr-<n>-<app> --phase runtime` (lot 1).
5. Fermer la PR ou retirer le label : l'Application est supprimée avec ses ressources (finalizer). Le CronJob `preview-sweeper` supprime ensuite les namespaces orphelins de plus de 24 h.

## Ce qui est réécrit dans la preview (patches Argo, manifestes inchangés)

| Objet | Effet |
|---|---|
| `Namespace` | retiré (le namespace vient de l'Application, PSA `restricted`) |
| `HTTPRoute` | hostname `<app>-<n>-preview.smadja.dev`, parent `Gateway/internal` |
| `ScaledObject`, `InterceptorRoute` | retirés (ils réclameraient le hostname de prod) |
| `Deployment`, `StatefulSet`, `Job`, `CronJob` | `priorityClassName: preview-low` |

Garde-fous (PLT-395, défense en profondeur) :

- AppProject `previews` : liste blanche explicite de ressources namespacées (Deployment, StatefulSet, Job, CronJob, Service, ConfigMap, Secret, PVC, ServiceAccount, PodDisruptionBudget, HTTPRoute, ExternalSecret, Password du générateur ESO). Rien d'autre : ni `cilium.io`, ni `networking.k8s.io`, ni RBAC, ni Kyverno, ni GRPCRoute/TCPRoute/UDPRoute/TLSRoute, ni ReferenceGrant. Un seul objet cluster : `Namespace` (exigé par `CreateNamespace`, sans quoi Argo refuse la sync ; une PR ne peut pas livrer le sien, le patch le supprime). Destinations `pr-*`.
- Quota, LimitRange et CiliumNetworkPolicy (default-deny puis DNS, Authentik, Gateway, même namespace) viennent de `k8s/previews/guardrails`, lus sur `main`, par l'Application `preview-guardrails-pr<n>-<app>` du projet `previews-guardrails` (liste blanche : ResourceQuota, LimitRange, CiliumNetworkPolicy). Séparée car une liste blanche d'AppProject n'est pas par source. ResourceQuota : 0,75 Gio demandés, 1,5 Gio limite, 8 pods, 2 Gio de disque.
- Politique Kyverno `preview-namespace-guard` : `Deny`, `failurePolicy: Fail`, limitée par `namespaceSelector` aux namespaces `smadja.dev/preview=true` (label posé par l'ApplicationSet, une PR ne peut pas le changer). Une panne de Kyverno bloque les admissions des previews seulement, jamais le reste du cluster.
- ClusterSecretStores `doppler-cluster`, `k8s-auth`, `k8s-databases` : `spec.conditions` excluant les namespaces `smadja.dev/preview=true` (même si Kyverno est indisponible, ESO ne sert aucun secret de prod à une preview).
- `Gateway/external` : `allowedRoutes.namespaces.from: Selector`, namespaces `smadja.dev/preview` `NotIn` `true`. Une route de preview ne peut s'y attacher ni par le patch ni par un manifeste de la PR. `Gateway/internal` reste ouverte (parent imposé par le patch).
- Tests statiques : `tests/harness/preview-isolation-contract-test.sh` et `tests/harness/previews-appset-descriptors-test.sh` (découverte par descripteur ; dans `just check`) ; Kyverno : `tests/policies/namespace-guard` (cas `fail` : ExternalSecret avec store, Database, SecretStore, LoadBalancer).

## Limites connues

- Une app derrière KEDA (HTTPRoute vers `keda-add-ons-http-interceptor-proxy`, autre namespace) : `Gateway/internal` refuse la référence (`ResolvedRefs=False`, `RefNotPermitted`) et l'Application passerait Degraded. Le patch de l'ApplicationSet réécrit donc `rules[0].backendRefs` vers le Service `<app>-preview-service` (port 8080) du namespace de la preview : une app `preview: true` doit livrer ce Service (`it-tools` l'a). Un hostname de preview atteint l'app directement, sans le démarrage à froid KEDA (ScaledObject retiré).
- Une app dont le dossier contient un objet hors liste blanche (CiliumNetworkPolicy propre, Role, ServiceMonitor, GRPCRoute, etc.) est refusée par Argo (Application en erreur de sync) : retirer l'objet de la preview n'est pas automatique, la preview n'est pas possible pour cette app.
- Les apps avec base de données partagée (`pg-shared`) ne sont pas supportées : la preview n'a pas de CNPG éphémère dans cette version.
- Secrets (D-2026-11-20-04) : une preview ne lit jamais un secret de prod. Le seul ExternalSecret admis est la forme C du contrat (générateur `Password`, `refreshPolicy: CreatedOnce`, sans `secretStoreRef` ni `data`), dans le namespace de la preview. Une app dont l'ExternalSecret lit un store (`doppler-cluster`, `k8s-auth`, `k8s-databases` ou tout autre) est refusée par Kyverno `preview-namespace-guard` et reste Degraded : la preview n'est pas possible tant que l'app n'a pas de forme C. Un jeton externe réel (API tierce) est hors périmètre : aucun secret par défaut.
- Aucune base partagée : la ressource `Database` CNPG est refusée (AppProject et Kyverno), et le default-deny coupe l'accès à `databases`. Une preview n'obtient jamais de rôle ni de mot de passe `pg-shared-homelab`.

## Exposition par Cloudflare Access (gestes de Paul)

1. Merger homelab-infra (MANDAT 26) et appliquer `enable_previews_access` par ARC.
2. Prouver : requête sans identité sur `https://x-1-preview.smadja.dev` = 302 Access ou 403.
3. PR kube-ops : dans `k8s/bootstrap/argocd-root/previews-applicationset.yaml`, parent `internal` devient `external`.

## Authentifier le générateur de PR (geste de Paul, PLT-395)

Sans jeton le générateur GitHub est limité à 60 requêtes/h. Le jeton n'est jamais dans Git ni lu par un agent.

1. Paul crée une GitHub App (ou un fine-grained token) en lecture seule : Pull requests Read, Contents Read, Metadata Read, sur `SmadjaPaul/kube-ops` seulement.
2. Paul crée le Secret dans le namespace `argocd` (hors Git, par le chemin Doppler/ESO habituel ou à la main).
3. PR kube-ops : dans `previews-applicationset.yaml` et `previews-guardrails-applicationset.yaml`, ajouter sous `pullRequest.github` soit `tokenRef: {secretName: <secret>, key: token}`, soit `appSecretName: <secret>`. Ne pas le faire avant l'étape 2 : l'ApplicationSet serait en erreur.

## Ordre de merge (PLT-395)

Merger sans PR labellisée `preview` ouverte : l'ancienne Application embarquait les guardrails, la nouvelle les recrée sous un autre propriétaire (une preview vivante verrait ses CiliumNetworkPolicy supprimées puis recréées). Ne poser aucun label `preview` avant `infra-previews` et `argocd-root` Synced/Healthy.

## Preuve négative (après merge)

Dans une preview de test, une PR qui ajoute respectivement une CiliumNetworkPolicy, une GRPCRoute, un ExternalSecret `secretStoreRef: doppler-cluster` doit échouer : Argo `is not permitted in project 'previews'` pour les deux premiers, Kyverno `preview-no-store` pour le troisième.
