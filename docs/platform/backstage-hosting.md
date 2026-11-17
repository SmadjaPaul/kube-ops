# Backstage hébergé (OKE oracle-a1, namespace `backstage`)

Backstage 1.56.5 tourne sur le cluster OKE `oracle-a1` (noeud arm64), namespace `backstage`.
L'overlay GitOps est `k8s/clusters/oracle-a1/backstage/`. Accès : aucun Service LoadBalancer ; le chemin
d'accès est décidé séparément (Cloudflare Access ou NetBird, voir la PR MANDAT oracle-a1).

## Image

- Source : `images/backstage/` (monorepo Backstage, sans `node_modules`, sans secret).
- Plateforme : `linux/arm64` seulement (le workflow `image-build` sélectionne la plateforme par image ;
  `backstage` est la seule image en arm64, les autres restent `linux/amd64`).
- Build : workflow `image-build` (Dockerfile multi-étapes : install, build app et backend, puis
  dépendances de production seules). Base `node:24-trixie-slim` pinnée par digest d'index multi-architecture.
- Validation PR : build arm64 sans publication (QEMU), `Validate image build (PR, no publish)`.
- Publication : `ghcr.io/smadjapaul/backstage` sur `main` uniquement. Le digest est écrit dans le résumé du job
  (`Record published digest`). L'overlay OKE épingle ce digest ; tant qu'il n'est pas épinglé, l'Application
  `backstage` n'est pas dans la racine Argo (`apps/kustomization.yaml`).
- Exécution : utilisateur non root (uid 1000), rootfs en lecture seule, seul `/tmp` (emptyDir) est écrit.

## Configuration

- `app-config.yaml` : base, sans secret, base de dev `localhost`. Les secrets sont des variables d'environnement.
- `app-config.production.yaml` : `auth.environment: production`.
- ConfigMap `backstage-config` (overlay OKE) : URL publique et CORS, chargée en dernier.
- Variables requises (ExternalSecret `backstage-runtime`, Doppler `cluster/prd`) :
  `BACKSTAGE_GH_APP_ID`, `BACKSTAGE_GH_APP_CLIENT_ID`, `BACKSTAGE_GH_APP_CLIENT_SECRET`,
  `BACKSTAGE_GH_APP_KEY_PEM`, `BACKSTAGE_AGENT_A_TOKEN`, `BACKSTAGE_AGENT_B_TOKEN`,
  `ORACLE_A1_BACKSTAGE_POSTGRES_PASSWORD`.
- Démarrage : échec explicite si une variable manque (substitution `${VAR}` de Backstage).

## Base de données (PostgreSQL)

- `backend.database.client: pg`. Hôte `pg-shared-rw.databases.svc`, base `backstage`, rôle `backstage`
  (`Database` et `managed.roles` dans `k8s/clusters/oracle-a1/cnpg-cluster/`).
- Mot de passe : une seule valeur Doppler, `ORACLE_A1_BACKSTAGE_POSTGRES_PASSWORD`, lue par deux
  ExternalSecret (rôle dans `databases`, connexion dans `backstage`). Aucune valeur en Git.
- TLS : CNPG sert TLS avec un certificat interne ; `rejectUnauthorized: false` faute de CA montée (résiduel).
- Durabilité : NON DURABLE. La restauration hors Oracle de `pg-shared` est `NOT_TESTED`
  (`docs/operations/pg-shared-oke-backup-drill.md`). Le catalogue se reconstruit depuis Git ;
  seul l'historique des tâches Scaffolder serait perdu. Voir la PR MANDAT pour la décision.

## Accès et identité

- Pas de fournisseur humain (ni guest, ni OIDC). `auth.providers: {}`.
- Seuls les tokens agents (`externalAccess` static, sujets `agent:claude-idp` et `agent:readonly-catalog`)
  donnent accès. Restrictions par plugin uniquement.
- `/api/mcp-actions/v1` ne doit jamais être joignable sans contrôle d'accès périphérique ET token Backstage.

## Catalogue

- `Template` `platform-application` épinglé par SHA (`b97982bd`, dernier commit du template sur `main`).
- `Component` découverts sur `k8s/apps-generated/*/catalog-info.yaml` (branche `main`, lecture seule).
- `catalog.readonly: true` : pas d'écriture par l'API. `register-entity`, `unregister-entity` et
  `refresh-catalog-entity` sont retirés du registre MCP.
- `scaffolder.taskRecovery` activé : une tâche interrompue est marquée en échec, pas laissée en `processing`.

## Réseau

- Flannel : aucune NetworkPolicy n'est appliquée sur oracle-a1. Aucune isolation réseau ne doit être supposée.
- Sorties nécessaires : `github.com`, `api.github.com`, `raw.githubusercontent.com` (HTTPS) et
  `pg-shared-rw.databases.svc` (5432).
- Sondes : `/.backstage/health/v1/liveness` et `/.backstage/health/v1/readiness` sur le port 7007.

## Limites connues

- Les tokens agents contournent la politique de permissions (décisions par `accessRestrictions` uniquement).
  Un agent peut exécuter n'importe quel template de son plugin : aucune restriction native par template.
- Pas de plugin Kubernetes ni Argo CD dans cette version : le statut des applications n'est pas visible
  depuis Backstage.
