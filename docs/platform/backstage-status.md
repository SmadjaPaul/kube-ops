# Statut des applications dans le MCP Backstage (options et mandat)

Objectif : un agent interroge via MCP l'état des applications `svc-*` (Deployments, Pods, événements) et,
si possible, l'état Argo CD (`gen-<name>`), avec le minimum de mandat cluster.

## Constats

- Le plugin `kubernetes-backend` expose l'action `createGetKubernetesResourcesForEntityAction` dans
  `@backstage/plugin-kubernetes-backend@0.21.12` (version publiée le 2026-10-20, la plus proche de la release
  Backstage 1.56.5 ; vérifié par `npm pack` et lecture du dist). Son nom MCP attendu est
  `kubernetes.get-kubernetes-resources-for-entity`.
  Non vérifié en direct : le plugin n'est pas installé dans le backend (dépendance et config à ajouter).
- Le plugin Argo CD de Roadie (`@roadiehq/backstage-plugin-argo-cd-backend@4.9.0`) n'enregistre aucune action MCP
  (aucune occurrence dans le dist). L'état Argo ne sera donc pas exposé en MCP sans module dédié.
- `argocd-cm` contient déjà un compte `accounts.argocd-mcp` (token non lu, non recopié ici).

## Options comparées

| Option | Lecture | Mandat cluster | Verdict |
|---|---|---|---|
| A. ClusterRole de lecture liée au SA `backstage` par ClusterRoleBinding | toutes les namespaces | ClusterRoleBinding large | Rejeté : dépasse `svc-*`. |
| B. ClusterRole `platform-svc-status-reader` + RoleBinding générée par Kyverno dans chaque `svc-*` | `svc-*` uniquement | ClusterRole, GeneratingPolicy, bind Kyverno (MANDAT) | Retenu. Aucun secret, aucune configmap, aucun log, aucun exec. |
| C. Argo CD : plugin Roadie + compte `argocd-mcp` en lecture | Applications Argo | compte existant, token à fournir | Pas de surface MCP native. À reprendre seulement avec un module d'action dédié. |

## Option retenue (B) : mandat one-time (PR draft, protégée)

Fichiers de la PR `[MANDAT Paul]` :

1. `k8s/bootstrap/argocd-root/apps-generated-project.yaml` : whitelist de `ExternalSecret` (external-secrets.io)
   et `ConfigMap`, nécessaire au contrat 0.2.0 (secrets, config).
2. `k8s/infrastructure/security/policies/apps-generated-status-rbac.yaml` : ClusterRole de lecture
   (deployments, replicasets, pods, services, HPA), ClusterRole + ClusterRoleBinding pour que Kyverno puisse
   `bind` ce rôle, GeneratingPolicy qui crée la RoleBinding `platform-svc-status-reader` dans chaque namespace
   golden path vers le SA `svc-backstage/backstage`.

Points à vérifier au dry-run serveur avant merge (non faits : kubectl-ro est en lecture seule) :
- la syntaxe CEL `generator.Apply(...)` de la GeneratingPolicy (CRD v1 servie sur le cluster) ;
- le SA `kyverno-background-controller` (présent dans le namespace `kyverno`).

## Pré-requis chart (non fait ici)

Le SA `backstage` du chart a `automountServiceAccountToken: false`. Le plugin Kubernetes a besoin du token
monté : il faut un opt-in explicite du contrat (proposition : `spec.runtime.serviceAccountToken: true`, défaut
`false`, chart 0.3.0). Ce champ ne donne rien à une autre application : la seule RoleBinding qui existe pointe
vers `svc-backstage/backstage`.

## Configuration Backstage (à appliquer quand le plugin est ajouté)

```yaml
kubernetes:
  serviceLocatorMethod:
    type: multiTenant
  clusterLocatorMethods:
    - type: config
      clusters:
        - name: homelab
          url: https://kubernetes.default.svc
          authProvider: serviceAccount
          skipTLSVerify: false
          skipMetricsLookup: true
  objectTypes:
    - deployments
    - replicasets
    - pods
    - services
    - horizontalpodautoscalers
```

Les entités `Component` doivent porter `backstage.io/kubernetes-id` et `backstage.io/kubernetes-namespace: svc-<name>`
(à ajouter au générateur `catalog_info.py`, dans le même chantier).
La permission du plugin doit être ajoutée à l'`accessRestrictions` de l'agent (`plugin: kubernetes`).
