# service-postgres-oidc@v1 (pilote)

Template Backstage (`fetch:template` + `publish:github:pull-request`) qui ouvre une PR kube-ops
pour un service avec base dans `pg-shared-homelab`, login Authentik OIDC et exposition interne.

- Rendu : moteur Nunjitsu (celui de Backstage, delimiteurs `${{ }}`), pas de moteur maison.
- Test sans Backstage : `bash tests/harness/service-postgres-oidc-template-test.sh` (rendu, JSON Schema,
  assertions, kustomize, kubeconform, garde d'isolation, idempotence, refus negatifs).
- Enregistrement : `POST /api/catalog/locations` avec l'URL du `template.yaml` sur la branche poussee ;
  execution : `POST /api/scaffolder/v2/tasks` avec `templateRef: template:default/service-postgres-oidc`.
- Ordre obligatoire : la ligne sentinelle `roles: [] # GOLDEN-PATH-ROLES` de `cluster.yaml` doit etre sur `main`
  AVANT toute execution (liste vide valide pour CNPG ; le 1er service la convertit en sentinelle ouverte).
- Limites : unicite des noms non verifiee (garde CI seulement), idempotence sur PR fermee non garantie,
  noms de variables Grafana non testes au runtime, rendu Backstage reel non rejoue (moteur de test + handlers reels).
