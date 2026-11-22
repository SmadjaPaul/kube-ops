# Modèle d'accès Authentik (PLT-176)

Proposition consolidée par usage réel. Source des liaisons : `k8s/infrastructure/auth/authentik/extra/blueprints/`. Contrôles : `tests/harness/authentik-friends-contract-test.sh`, `tests/harness/authentik-human-users-contract-test.sh`.

L'accès passe toujours par un groupe, jamais par une liaison par utilisateur. Ajouter une personne à une classe = l'ajouter au groupe, sans changer les liaisons.

## Classes

| Classe | Groupe | Règle |
|---|---|---|
| Admin | `authentik-admins` (superuser, existant) | Tout l'accès administratif : Authentik, applications d'admin. Paul y est rattaché par le groupe. Un futur admin = un ajout au groupe. Le groupe `admin` (ArgoCD, Factory) est un doublon à fusionner après vérification de ses membres. |
| Famille | `family` (existant) | Applications qui peuvent coûter de l'argent à Paul (IA, stockage, comptes créés au premier login), plus tout ce qu'ont les amis. Rien d'admin. Immich reste dans `Immich Users`. |
| Amis | `friends` (nouveau, vide) | Seulement les applications à coût marginal nul (coût identique pour 5 ou 150 utilisateurs) : Polyfin, RomM, BookOrbit, SearXNG, Stirling-PDF, plus l'étape Authentik de Cloudflare Access (application `cloudflare`). Un ami n'obtient jamais `family` par défaut ; aucune invitation n'ajoute `family` à un ami. |
| Comptes de service | pas de groupe d'accès | Voir plus bas. |

## Applications par coût marginal

| Application (slug) | Groupes aujourd'hui (hors `authentik-admins`) | Coût par utilisateur | Classe proposée |
|---|---|---|---|
| polyfin | family | nul (streaming ; comptes natifs, OIDC bloqué en amont) | friends + family |
| romm | family, media | nul | friends + family |
| bookorbit | family | faible (livres demandés stockés) | friends + family |
| searxng, stirling-pdf | family, friends | nul en argent (CPU fixe) | famille et amis (G2, décision de Paul, 2026-11-15) |
| ntfy | family | nul en argent (CPU fixe) | family |
| librechat | family | IA par requête | family |
| karakeep | Karakeep Users | IA (étiquetage) + archives | family (groupe dédié conservé) |
| opencode, factory | OpenCode Users ; admin | IA par requête | admin |
| immich | Immich Users | stockage photo, élevé | groupe dédié `Immich Users` |
| paperless, pinepods, matrix-mas | family ; Pinepods Users ; family | stockage | family |
| mealie, vikunja, rustical, sparkyfitness, sure | family | faible stockage ; Sure crée le compte au premier login | family (Sure : finances, à confirmer) |
| home-assistant | Home Assistant Users | nul, mais pilote la maison | groupe dédié, foyer seulement |
| invoice-ninja | lechaplais, authentik-admins | données de l'activité de Maureen | groupe dédié `lechaplais` (membre : maureen ; PLT-176) |
| argocd, kubectl, grafana, aiostreams, talos-* | admin, dev ; Kubectl/Grafana/Talos Users | admin | admin |
| cloudflare | authentik-admins, admin, authentik Admins, family, friends | nul (fournisseur d'identité de Cloudflare Access pour les services derrière les tunnels) | toutes les classes humaines ; un compte sans groupe lié est refusé (décision de Paul, 2026-11-15) |
| jellyfin, bazarr, lidarr, prowlarr, radarr, sonarr, sabnzbd, jellyseerr, audiobookshelf, openwebui, litellm, zigbee2mqtt | divers | service retiré ou non déployé | à supprimer d'Authentik |

## Comptes de service

- Type Authentik `service_account` (pas de mot de passe humain, pas de MFA interactif), chemin `goauthentik.io/service-accounts`, déclaré par blueprint.
- Droits par rôle RBAC minimal attaché au compte, jamais un groupe superuser. Modèle : `agent-e2e` (`qa-agent-e2e.yaml`).
- Jeton `intent: api` lu par `!Env` depuis Doppler via ExternalSecret ; jamais dans Git. Rotation : nouvelle valeur dans Doppler, puis resynchronisation.
- Création : Paul seulement (PR revue + merge). Un agent ne crée pas de compte de service.
- Applications OIDC : un client confidentiel par application, secret dans Doppler (`APP_<APP>_OIDC_CLIENT_SECRET`), pas de compte utilisateur.
- Aujourd'hui : `agent-e2e` (tests d'agents) ; outpost proxy (géré par Authentik) ; `e2e-user` / `e2e-user-secondary` sont des comptes `internal` de test avec mot de passe (Doppler), à classer.

## Break-glass (hors SSO)

- Authentik : `akadmin`, mot de passe d'amorçage dans Doppler (`APP_AUTHENTIK_BOOTSTRAP_PASSWORD`).
- Kubernetes : kubeconfig opérateur via Doppler (`scripts/kubectl-ro.sh`, `kubectl-rw.sh`), indépendant d'Authentik. ArgoCD local admin désactivé : passer par Kubernetes.
- Polyfin : compte local `polyfin-breakglass`. Grafana : admin local (secret).
- Cloudflare : connexion au compte Cloudflare, hors Authentik.
