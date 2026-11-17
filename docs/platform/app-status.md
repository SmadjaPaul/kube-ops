# Statut d'une application : contrat `app-status.v1`

Une commande, une sortie JSON, aucun service : `scripts/app-status.sh` dit si l'application générée `<app>` est à la
révision demandée, saine et répond. Lecture seule, via `scripts/kubectl-ro.sh` (verbe `get`).

```bash
bash scripts/app-status.sh <app> [--cluster homelab|oracle-a1] [--commit <sha>|main-head]
```

Par défaut le commit demandé est la tête de `main` (`git ls-remote`). Le schéma est
`docs/contracts/app-status-v1.schema.json`, un exemple est `docs/contracts/app-status-v1.example.json`.

## Codes de sortie et statut

| Code | `status` | Sens |
| --- | --- | --- |
| 0 | `PASS` | révision synchronisée, Argo `Synced`/`Healthy`, Deployments prêts, smoke HTTP réussi |
| 1 | `FAIL` | échec établi (opération Argo en échec, workload non prêt, smoke KO, app absente du dépôt) |
| 3 | `PENDING` | en cours : révision pas encore synchronisée, Argo `Progressing`, Application pas encore générée |
| 4 | `UNKNOWN` | non prouvable : cluster illisible, smoke non exécutable (par exemple accès refusé) |
| 2 | (aucune sortie JSON) | usage ou dépendance manquante |

Tout statut autre que `PASS` porte une `reason` d'une ligne. `evidenceLevel` vaut `RUNTIME` seulement si l'état a été
observé sur le cluster, `STATIC` sinon (cluster illisible). Un `PASS` exige `RUNTIME` et un smoke `pass` (le schéma le vérifie).

## Champs

- `requested.commit` : SHA Git demandé. `synced.revision` : révision que l'Application Argo a réellement
  synchronisée (toutes les sources doivent y être : chart et values). Différence : `PENDING`.
- `argo` : `sync`, `health`, `operationPhase` de l'Application `gen-<app>`. C'est le nom donné par l'ApplicationSet
  `apps-generated` (préfixe `gen-`).
- `workloads` : Deployments prêts/souhaités et pods prêts du namespace `svc-<app>`.
- `smoke` : `GET <healthPath>` (lu dans `k8s/apps-generated/<app>/app.yaml`) sur le Service `<app>:80`, par le
  proxy de services de l'API Kubernetes (`get --raw /api/v1/namespaces/svc-<app>/services/<app>:80/proxy<healthPath>`).
  Rien n'est exposé, le corps de la réponse est jeté. Valeurs de `result` : `pass`, `fail`, `unavailable`, `not_run`.
- `checks[]` : `db`, `backup`, `restore` ; `not_applicable` pour le profil stateless. Aucune vérification stateful n'est
  faite dans cette version.
- Aucun secret : seuls des champs de statut sont lus, `get secret` n'est jamais appelé.

## Prérequis d'accès du smoke

`kubectl-ro.sh` admet `get --raw` vers le proxy d'une application seulement pour un namespace `svc-*`, un Service nommé, un chemin
simple sans paramètres. L'identité `agent-operator` doit en plus avoir `get` sur `services/proxy` dans ces namespaces :
tant que ce droit n'existe pas (changement RBAC : mandat de Paul), le smoke vaut `unavailable` et le statut est `UNKNOWN`,
jamais `PASS`. Constaté le 2026-11-17 sur `idp-e2e` : identité `agent-operator` = `UNKNOWN` (403 sur `services/proxy`), identité opérateur (`KUBECTL_RO_IDENTITY=operator`, lecture seule) = `PASS` `RUNTIME`. Le droit à accorder, par namespace `svc-<app>` (Role + RoleBinding vers `agent-operator/agent-operator`) :

```yaml
rules:
  - apiGroups: [""]
    resources: ["services/proxy"]
    verbs: ["get"]
```

## Backstage et agents

Le catalogue généré (`k8s/apps-generated/<app>/catalog-info.yaml`) porte l'annotation
`homelab.smadja.dev/app-status: bash scripts/app-status.sh <app> --cluster homelab`. L'outil MCP `get-catalog-entity`
la renvoie déjà : un agent lit l'entité, exécute la commande, lit le JSON. Aucun plugin Backstage. L'annotation
est écrite par le template `platform-application` (skeleton) et vérifiée par `tests/platform/catalog_info.py`
(source de règles unique : `values.schema.json` pour l'application, le générateur pour le catalogue).

## Tests

`python3 -m unittest discover -s tests/platform -p 'test_*.py'` (CI : `platform-app-contract`) : fixtures hors cluster
(PASS, révision désynchronisée, workload non prêt, smoke KO, accès smoke refusé, app absente, opération Argo en échec,
cluster illisible) validées contre le schéma, avec un faux `kubectl-ro`. Niveau de preuve : `STATIC`. La preuve `RUNTIME`
vient de l'exécution du script sur le cluster.
