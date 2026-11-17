# Backstage hébergé (svc-backstage, provisoire)

Backstage 1.56.5 tourne dans le homelab sous la forme d'une application du golden path
(`k8s/apps-generated/backstage/app.yaml`, namespace `svc-backstage`). Statut : provisoire, accès LAN seulement.

## Image

- Source : `images/backstage/` (monorepo Backstage, sans `node_modules`, sans secret).
- Build : workflow `image-build` (Dockerfile multi-étapes : install, build app et backend, puis
  dépendances de production seules). Base `node:24-trixie-slim` pinnée par digest.
- Publication : `ghcr.io/smadjapaul/backstage` sur `main`, avec digest. L'`app.yaml` pointe sur le digest.
- Exécution : utilisateur non root, rootfs en lecture seule, seul `/tmp` (emptyDir) est écrit.

## Configuration

- `app-config.yaml` : base, sans secret. Les secrets sont des variables d'environnement.
- `app-config.production.yaml` : `auth.environment: production`.
- Variables requises (ExternalSecret, voir `docs/platform/backstage-github-app.md`) :
  `BACKSTAGE_GH_APP_ID`, `BACKSTAGE_GH_APP_CLIENT_ID`, `BACKSTAGE_GH_APP_CLIENT_SECRET`,
  `BACKSTAGE_GH_APP_KEY_PEM`, `BACKSTAGE_AGENT_A_TOKEN`, `BACKSTAGE_AGENT_B_TOKEN`.
- Démarrage : échec explicite si une variable manque (substitution `${VAR}` de Backstage).

## Accès et identité

- Pas de fournisseur humain (ni guest, ni OIDC). `auth.providers: {}`.
- Seuls les tokens agents (`externalAccess` static, sujets `agent:claude-idp` et `agent:readonly-catalog`)
  donnent accès. Restrictions par plugin uniquement.
- Exposition : Gateway `internal`, jamais `public`. L'OIDC humain est traité à part (agent AUTHENTIK).

## Données (stateless assumé)

- Base SQLite dans `/tmp/backstage-data`. Au redémarrage du pod, la base repart de zéro.
- Le catalogue se reconstruit depuis Git (location `url`). Les tâches Scaffolder en cours sont perdues.
  `scaffolder.taskRecovery` est activé : une tâche interrompue est marquée en échec, pas laissée en `processing`.
- Pas de PostgreSQL : `pg-shared-homelab` n'est pas présent dans le cluster et `infra-database` est OutOfSync.

## Catalogue

- `Template` `platform-application` épinglé par SHA (`b97982bd`, dernier commit du template).
- `Component` découverts sur `k8s/apps-generated/*/catalog-info.yaml` (branche `main`, lecture seule).
- `catalog.readonly: true` : pas d'écriture par l'API. `register-entity`, `unregister-entity` et
  `refresh-catalog-entity` sont retirés du registre MCP.

## Réseau

- Sorties nécessaires : `github.com`, `api.github.com`, `raw.githubusercontent.com` (HTTPS).
  Nécessite le champ `egress` du chart platform-app (contrat 0.2.0, en préparation).
- Sondes : `/.backstage/health/v1/liveness` et `/.backstage/health/v1/readiness` sur le port 7007.
  Le chart doit accepter le point dans `healthPath` (contrat 0.2.0, en préparation).

## Limites connues

- Les tokens agents contournent la politique de permissions (décisions par `accessRestrictions` uniquement).
  Un agent peut exécuter n'importe quel template de son plugin.
- Aucune restriction native par template pour un token de service.
- Pas de build d'image testé localement (daemon Docker arrêté pendant la mise en place) : la validation
  est la CI `image-build` de la PR.
- Pas de plugin Kubernetes ni Argo CD dans cette version : le statut des applications n'est pas encore visible
  (voir la note d'options de statut, à venir).
