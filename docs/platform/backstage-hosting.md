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
- Publication : `ghcr.io/smadjapaul/backstage` sur `main` uniquement. Digest épinglé dans le Deployment : `sha256:4758cb57...` (index arm64, run d5d4ffd).
- Exécution : utilisateur non root (uid 1000), rootfs en lecture seule, seul `/tmp` (emptyDir) est écrit.

## Configuration

- `app-config.yaml` : base, sans secret, base SQLite éphémère, URL de dev `localhost`. Les secrets sont des variables d'environnement.
- `app-config.production.yaml` : `auth.environment: production`.
- ConfigMap `backstage-config` (overlay OKE) : URL publique et CORS, chargée en dernier.
- Variables requises (ExternalSecret `backstage-runtime`, Doppler `cluster/prd`) :
  `BACKSTAGE_GH_APP_ID`, `BACKSTAGE_GH_APP_CLIENT_ID`, `BACKSTAGE_GH_APP_CLIENT_SECRET`,
  `BACKSTAGE_GH_APP_KEY_PEM`, `BACKSTAGE_AGENT_A_TOKEN`, `BACKSTAGE_AGENT_B_TOKEN`.
- Démarrage : échec explicite si une variable manque (substitution `${VAR}` de Backstage).

## Base de données (PostgreSQL durable, contrat #1621)

- Cible : `backend.database.client: pg` sur `pg-shared-rw.databases.svc.cluster.local:5432`, base `backstage`, rôle `backstage` (Database et rôle dans `cnpg-cluster/`, contrat `docs/platform/postgres-oke-contract.md`).
- Mot de passe : une seule clé Doppler `ORACLE_A1_BACKSTAGE_DB_PASSWORD`, lue par l'ExternalSecret `backstage-db` (namespace `backstage`, SecretStore `doppler`) et par le rôle CNPG (`databases`).
- `BACKSTAGE_DB_MODE=pg` (défaut du Deployment) charge `app-config.database-pg.yaml`.
- Mode test SQLite éphémère : `BACKSTAGE_DB_MODE=sqlite` (explicite, jamais par défaut). Aucune donnée durable dans ce mode.
- Le catalogue vient de Git ; `scaffolder.taskRecovery` marque les tâches interrompues en échec.

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

- Flux autorisés par la baseline (#1620, Cilium chaining + NetworkPolicy) : `cloudflared` vers `backstage:7007` ; `backstage` vers `databases:5432` ; `backstage` vers `api.github.com` et `github.com` en 443 (CiliumNetworkPolicy) ; DNS.
- Sondes : `/.backstage/health/v1/liveness` et `/.backstage/health/v1/readiness` sur le port 7007.
- Aucune isolation réseau n'est à supposer hors de la baseline : elle est la référence.

## Limites connues

- Les tokens agents contournent la politique de permissions (décisions par `accessRestrictions` uniquement). Un agent peut exécuter n'importe quel template de son plugin : aucune restriction native par template.
- Catalogue : `raw.githubusercontent.com` (443) n'est pas dans la baseline : à ajouter avant que les `url` locations sur `github.com/.../blob/` ne se résolvent (à traiter dans #1620).
- Pas de plugin Kubernetes ni Argo CD : le statut des applications n'est pas visible depuis Backstage.
