# service-postgres-oidc@v1 (pilote)

Template Backstage (`fetch:template` + `publish:github:pull-request`) qui ouvre une PR kube-ops
pour un service avec base dans `pg-shared-homelab`, login Authentik OIDC et exposition interne.

- Rendu : moteur Nunjitsu (celui de Backstage, delimiteurs `${{ }}`), pas de moteur maison.
- Test sans Backstage : `bash tests/harness/service-postgres-oidc-template-test.sh` (rendu, JSON Schema,
  assertions, kustomize, kubeconform, garde d'isolation, idempotence, refus negatifs).
- Enregistrement : `POST /api/catalog/locations` avec l'URL du `template.yaml` sur la branche poussee ;
  execution : `POST /api/scaffolder/v2/tasks` avec `templateRef: template:default/service-postgres-oidc`.
- Limites (detail dans le checkpoint B) : second `managed:` dans `cluster.yaml` non gere, idempotence
  sur PR fermee non garantie, unicite des noms non verifiee ici, noms de variables Grafana non testes au runtime.
