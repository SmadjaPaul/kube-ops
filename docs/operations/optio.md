# Exploitation d'Optio (PLT-339)

## Composants

Namespace `optio`. Chart `oci://ghcr.io/jonwiggins/optio` v0.26.4, Argo CD.
Pods : `optio-api` (API port 4000 + conteneur `web` port 3000), Redis in-cluster (sans TLS ni auth,
accès limité par CiliumNetworkPolicy), pods d'agents créés à la demande (label `managed-by=optio`,
quota 2).

## Accès

**Gateway/internal uniquement** (`optio.smadja.dev`) — aucune exposition publique (MANDAT 30). Linear est interrogé en sortie ; aucun webhook entrant.

## Connexion Authentik

Fournisseur OIDC `auth.smadja.dev/application/o/optio/`. PKCE activé, `trustEmail: true`,
scopes `openid email profile groups`, session 168 h.
Secrets : `optio-oidc` (clés `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`) depuis Doppler.

## Répartition des routes HTTP

| Préfixe | Backend | Raison |
|---|---|---|
| `/api/internal` | aucun (erreur Gateway) | Réservé aux agents via le Service cluster ; jamais exposé |
| `/ws` | `optio-api:4000` | WebSockets, cookie de session + Origin de confiance |
| `/api` + `Authorization: Bearer …` | `optio-api:4000` | PAT/CLI ; le proxy web supprimerait l'en-tête |
| `/` (tout le reste) | `optio-web:3000` | Proxy web : convertit le cookie en token, gère le défi de connexion |

## Isolation réseau des pods d'agents

CiliumNetworkPolicy default-deny ingress/egress. Les pods d'agents ne sortent que vers :
DNS, `optio-api`, `agentgateway`, récepteur OTLP Alloy et une liste FQDN sur 443.
Le NetworkPolicy du chart est **désactivé** (additivité Cilium : l'activer annulerait la liste FQDN).

## Secrets (noms uniquement, jamais de valeur)

| Secret (namespace `optio`) | Clés |
|---|---|
| `optio-db` | `DATABASE_URL` |
| `optio-app` | `OPTIO_ENCRYPTION_KEY` |
| `optio-oidc` | `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` |
| `optio-admins` | `OPTIO_DEPLOYMENT_ADMINS` |
| `optio-github-app` | `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY` |
| `optio-llm-pi` | `OPENAI_API_KEY` (clé virtuelle Agentgateway `optio-pi`, générée dans le cluster) |
| `optio-ghcr-pull` | `.dockerconfigjson` (lecture GHCR, clé Doppler `APP_FACTORY_ARC_GHCR_READ_TOKEN`) |

Mot de passe DB : secret `pg-optio` (namespace `databases`), généré dans le cluster (T1, `CreatedOnce`, `Orphan`).

## Base de données et sauvegarde

Cluster CNPG `pg-shared-homelab` (namespace `databases`), base `optio`, rôle `optio`.
Connexion TLS : `pg-shared-homelab-rw.databases.svc.cluster.local:5432`.
`CONNECT FROM PUBLIC` révoqué par un Job PostSync.

Sauvegarde : barman-cloud, ObjectStore `pg-shared-homelab-r2` (R2), daily 03:40 UTC, WAL archivé.
RPO objectif 5 min — **NON VÉRIFIÉ** (drill : `docs/operations/pg-shared-app-restore-drill.md`).

## Retour arrière

Argo CD avec `selfHeal`. Modifier `values.yaml` ou `kustomization.yaml` sur une branche `claude/`,
`just check` → PR → merge → Argo réconcilie. Vérifier : `just verify-delivery homelab optio`.
Effet de `rbac.clusterRole.create: false` sur les pages de vue d'ensemble du cluster : **NON VÉRIFIÉ**.
