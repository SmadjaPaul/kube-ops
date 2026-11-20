# Previews par PR (PLT-390 lot 2)

Un namespace jetable `pr-<n>-<app>` par PR, sur le cluster de prod, déployé depuis le SHA de tête de la PR. Rien n'est public.

## Utiliser

1. La PR ajoute ou modifie `k8s/applications/<catégorie>/<app>/`.
2. Poser deux labels sur la PR : `preview` et `preview:<app>` (`<app>` = nom du dossier, `^[a-z0-9][a-z0-9-]{0,37}$`). Une app par PR.
3. L'ApplicationSet `previews` (poll de 120 s) crée l'Application `preview-pr<n>-<app>`, projet `previews`.
4. `just app-test <app> pr-<n>-<app> --phase runtime` (lot 1).
5. Fermer la PR ou retirer le label : l'Application est supprimée avec ses ressources (finalizer). Le CronJob `preview-sweeper` supprime ensuite les namespaces orphelins de plus de 24 h.

## Ce qui est réécrit dans la preview (patches Argo, manifestes inchangés)

| Objet | Effet |
|---|---|
| `Namespace` | retiré (le namespace vient de l'Application, PSA `restricted`) |
| `HTTPRoute` | hostname `<app>-<n>-preview.smadja.dev`, parent `Gateway/internal` |
| `ScaledObject`, `InterceptorRoute` | retirés (ils réclameraient le hostname de prod) |
| `ExternalSecret` | store forcé à `doppler-preview` (jamais `doppler-cluster`) |
| `Deployment`, `StatefulSet`, `Job`, `CronJob` | `priorityClassName: preview-low` |

Garde-fous (source `k8s/previews/guardrails`, lue sur `main`) : ResourceQuota (0,75 Gio demandés, 1,5 Gio limite, 8 pods, 2 Gio de disque), LimitRange, CiliumNetworkPolicy default-deny puis DNS, Authentik, Gateway, même namespace. Politique Kyverno `preview-namespace-guard` (Deny, limitée aux namespaces `smadja.dev/preview=true`) et AppProject `previews` (destinations `pr-*`, aucun objet cluster, ReferenceGrant et routes non HTTP refusés).

## Limites connues

- Une app derrière KEDA (HTTPRoute vers `keda-add-ons-http-interceptor-proxy`) n'est pas joignable par le hostname de preview ; le test runtime passe par le Service du namespace.
- Les apps avec base de données partagée (`pg-shared`) ne sont pas supportées : la preview n'a pas de CNPG éphémère dans cette version.
- Les secrets de preview viennent de la config Doppler `preview` (store `doppler-preview`) ; sans elle, une app qui a un ExternalSecret reste Degraded.

## Exposition par Cloudflare Access (gestes de Paul)

1. Merger homelab-infra (MANDAT 26) et appliquer `enable_previews_access` par ARC.
2. Prouver : requête sans identité sur `https://x-1-preview.smadja.dev` = 302 Access ou 403.
3. PR kube-ops : dans `k8s/bootstrap/argocd-root/previews-applicationset.yaml`, parent `internal` devient `external`.
