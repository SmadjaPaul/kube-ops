# Contrat Application platform.smadja.dev/v1 (profil web)

Un agent declare une application par **un seul fichier** : `k8s/apps-generated/<name>/app.yaml`.
Le rendu est fait par le chart Helm in-repo `k8s/charts/platform-app` (pas de contrôleur, pas de Kustomize par app).
Le schéma source est `k8s/charts/platform-app/values.schema.json`.

## Exemple

```yaml
apiVersion: platform.smadja.dev/v1
kind: Application
metadata:
  name: demo-web            # ^[a-z][a-z0-9-]{1,18}[a-z0-9]$ ; namespace svc-demo-web, hostname demo-web.smadja.dev
  owner: group:default/platform
  description: Exemple
spec:
  profile: web             # web = stateless (seul profil rendu)
  source:
    image: ghcr.io/org/app:1.0.0@sha256:<64 hex>   # digest obligatoire
  runtime:
    replicas: 1            # 1..3 (>1 : PodDisruptionBudget)
    size: small            # small | medium : table requests/limits dans le chart
    port: 8080
    healthPath: /healthz
    env: {LOG_LEVEL: info} # optionnel, non secret
  exposure:
    mode: private          # Gateway internal (ns gateway) uniquement
    auth: none
  backup:
    policy: stateless
  observability:
    metrics: false
    path: /metrics
```

## Rejets explicites (message Helm actionnable)

| Demande | Résultat |
| --- | --- |
| `profile: web-postgres` ou bloc `database` | rejet : `capability database unavailable: pg-shared-homelab not reconciled (AppProject infrastructure lacks databases)` |
| bloc `storage` | rejet : capacité de stockage non validée |
| `exposure.mode: public` | rejet (Gateway external hors mandat) |
| `exposure.auth: authentik` | rejet : aucun mécanisme d'auth par route dans le dépôt, sans toucher au namespace `auth` |
| champ inconnu, `metadata.namespace`, image sans digest, size hors enum, replicas hors 1..3 | rejet par le schéma |

## Rendu

Ressources produites : Namespace `svc-<name>` (seule ressource cluster-scoped, PSA restricted),
ServiceAccount (token non monté), Deployment (non-root, rootfs RO, drop ALL, seccomp RuntimeDefault, probes),
Service, HTTPRoute vers Gateway `internal`, CiliumNetworkPolicy default-deny (ingress gateway/host, DNS egress),
PodDisruptionBudget si replicas > 1, ServiceMonitor si metrics. Aucun Secret.
Les labels portent `platform.smadja.dev/contract: v1` et `platform.smadja.dev/renderer: platform-app-<version chart>`.

## Champs optionnels 0.2.0 (chart platform-app 0.2.0)

Rétrocompatibles : absents, ils ne rendent aucune ressource en plus (le golden de l'app minimale ne change
qu'à la version du renderer).

- `spec.secrets` : liste de clés du store `doppler-cluster`. Rendu : un `ExternalSecret` dans `svc-<name>`
  et un Secret `<name>-env` injecté en `envFrom`. Chaque clé commence par `<NAME>_` (NAME en majuscules,
  `-` remplacé par `_`). Pas de store ni de préfixe arbitraire. Un changement de valeur dans Doppler
  demande un redémarrage du pod. Pré-requis : `ExternalSecret` et `ConfigMap` doivent être autorisés par
  l'AppProject `apps-generated` (diff MANDAT, `k8s/bootstrap`).
- `spec.config` : fichiers non secrets (8 max, 64 Ko chacun). Rendu : une `ConfigMap` `<name>-config` montée
  en lecture seule dans `/etc/platform-config`. Une clé privée PEM est refusée.
- `spec.egress.https` : FQDN exacts (pas de joker, pas d'IP, pas de `.local` / `.svc`), port 443 seulement.
  Rendu : `toFQDNs` dans la CiliumNetworkPolicy, et DNS visible uniquement pour ces noms.
- `spec.runtime.healthPath` accepte le point (ex. `/.backstage/health/v1/liveness`).

## Catalogue

`k8s/apps-generated/<name>/catalog-info.yaml` (Component Backstage) est écrit par le template à côté de `app.yaml`.
La CI vérifie qu'il correspond exactement à `app.yaml` (`tests/platform/catalog_info.py`).

## Tests

`python3 -m unittest discover -s tests/platform -p 'test_*.py'` : rendu déterministe, golden, négatifs, Miniflux rejeté,
update (diff de rendu limité), parité template/catalog-info, kubeconform si présent.
