# STRATEGY — OpenChoreo ou plateforme maison

Étude du 17/11/2026 (Opus, mandat « Décision architecturale OpenChoreo »). Instantané non normatif : une décision n'existe qu'après son entrée dans `homelab-infra/docs/decisions.md`.

## 1. Objectif et critères de réussite

Objectif de Paul : des agents déploient, modifient, supervisent, réparent et retirent des applications seuls, vite, avec un coût et une maintenance minimaux. Le portail, les golden paths et l'orchestration maison sont des moyens.

Critères, par ordre de poids :

1. **Livraison autonome** : la demande « Miniflux avec PostgreSQL, SSO familial, URL privée, sauvegardes » aboutit sans geste de Paul.
2. **Contexte agent minimal** : peu de concepts, peu d'outils, une seule voie d'écriture.
3. **Travail total** : mise en service + maintenance à 12 mois.
4. **Invariants de sécurité** du mandat (§7) conservés.
5. **Réversibilité** : retour arrière par `git revert` + redéploiement (principe de Paul, D-2026-11-16-07).

## 2. Constats qui décident

| # | Constat | Source | Niveau |
|---|---|---|---|
| F1 | OpenChoreo 1.3.3 installe en plus : kgateway, OpenBao, ThunderID, Backstage, cluster-gateway ; plan workflow = Argo Workflows + registre ; plan observabilité = OpenSearch (logs, traces) + Prometheus + Fluent Bit. | doc k3d v1.3.x | DOCUMENTED |
| F2 | Production : 3 nœuds de 4 CPU / 8 Go par cluster ; un nœud unique « seulement pour le développement ». | doc Deployment Topology | DOCUMENTED |
| F3 | Un data plane distant ouvre une WebSocket sortante vers le control plane. | idem | DOCUMENTED |
| F4 | Support : 3 lignes mineures ; v1.0 sortie en avril, fin de vie le 19/09/2026. Passage 1.1 → 1.2 : migration par étapes (CRD, `Project.spec.type`), réconciliation du control plane suspendue pendant la fenêtre. | doc Release Process, notes v1.2 | DOCUMENTED |
| F5 | GitOps OpenChoreo : dépôt d'exemple et skills officiels basés sur **Flux**. | `openchoreo/sample-gitops`, `openchoreo/skills` | SAMPLE |
| F6 | MCP OpenChoreo : ≈ 114 outils control plane (≈ 52 en écriture) + 15 outils observabilité ; filtrés par les droits de l'appelant. Les écritures API/MCP vont directement au cluster, pas dans Git. | doc `reference/mcp-servers`, `gitops/overview` | DOCUMENTED (comptes approximatifs) |
| F6b | Control plane arrêté : les data planes continuent ; seules les modifications et la réconciliation s'arrêtent. | doc Architecture | DOCUMENTED |
| F6c | ResourceType en `v1alpha1`, sans CEL ; exemples Postgres/Valkey en StatefulSet « dev local seulement » ; aucun exemple CNPG ; bugs ouverts #5475, #5476 sur ResourceReleaseBinding. Argo CD non documenté comme moteur GitOps. CRD non mises à jour par Helm : application manuelle à chaque mineur. | doc `resource-types`, `upgrades/overview`, issues GitHub | DOCUMENTED |
| F7 | ThunderID : 1.0.0 GA le 15/08/2026, 1.1.0 le 02/11, 2.0.0-m1 (cassant) le 06/11. OIDC/OAuth 2.1, client credentials, token exchange, passkeys, agents comme identité de premier rang, import YAML. SAML IdP non prouvé (fédération entrante documentée) ; aucun LDAP, proxy/forward-auth, SCIM, TOTP ni portail libre-service trouvé ; pas de guide d'upgrade ; défauts « évaluation seulement ». | `thunder-id/thunderid` (releases), thunderid.dev | DOCUMENTED / NOT_FOUND |
| F7b | Authentik 2026.8 : token exchange RFC 8693 ajouté ; « agent accounts » en édition Enterprise ; comptes de service et `client_credentials` en open source. | notes 2026.8 | DOCUMENTED |
| F8 | Authentik sert aujourd'hui 28 blueprints applicatifs : OIDC (majorité), **SAML** (Fleet), **proxy** (opencode). | `kube-ops` `k8s/infrastructure/auth/authentik/extra/blueprints` | STATIC |
| F9 | OKE `oracle-a1` : allocatable 1 830 m / 8,4 GiB, **31 IP de pods**, budget retenu 19 IP et 56 % CPU de requests avec Authentik seul. | ADR `oke-target-architecture.md` | RUNTIME (17/11) |
| F10 | Miniflux (PLT-152) est ouvert depuis le 08/11. Blocages réels : choix PostgreSQL partagé homelab, absence de gabarit app + blueprint OIDC + clé OpenTofu, absence de preuve de restauration. Aucun blocage ne vient du portail ou de l'abstraction applicative. | Linear PLT-152 | STATIC |
| F11 | La factory maison est petite : chart `platform-app` (6 templates), AppSet `apps-generated`, `app-status.sh`, 2 golden paths ; Backstage n'est pas déployé (suspendu, ~330 lignes TS). | `kube-ops` | STATIC |
| F12 | Pilote k3d v1.3.3 : 23 pods, 36 CRD, ≈ 670 MiB pour control + data, sans build ni observabilité ; images arm64 natives. Créer une app = 2 appels MCP. Rôle restreint : 130 → 59 outils, refus appliqués par l'API. **Aucune borne sur les valeurs** (replicas, image), **pas de default-deny egress**, **pas de labels PSA** sur les namespaces générés, pas de client OIDC par app, un seul `ClusterSecretStore` par data plane. | pilote Sonnet 17/11 | [P] |

**Conséquence de F10 et F11** : le travail difficile n'est pas « traduire une intention en Deployment ». C'est **base de données + client OIDC + secret + sauvegarde + exposition + preuve**. OpenChoreo ne fournit nativement aucun de ces cinq éléments pour notre pile (CNPG, Authentik, Doppler, R2, Cloudflare) : il faudrait les écrire en ResourceTypes/Traits, c'est-à-dire le même code maison, dans un autre format.

## 3. Les options

Correspondance avec la grille de Paul (prompt du 17/11) : **A** finir la factory avec Backstage = C ci-dessous avec Backstage ; **B** OpenChoreo + Git (PR + CI) = A/B ci-dessous ; **C** OpenChoreo « direct » (MCP écrit dans le cluster) = exclu §9 (pas de PR, pas de `git revert`) ; **D** table rase OpenChoreo + ThunderID + OpenBao = A ci-dessous sans Authentik, exclu §5 et F9 ; **E** alternative plus simple = **C allégée**, recommandée.

D sur OKE : 23 pods du pilote + Authentik remplacé ≈ 23–26 IP sur 31, sans marge pour Polyfin/AIOStreams, et un nœud unique « développement seulement » (F2). Le control plane ne tient pas sur l'A1.

### A — OpenChoreo natif, reconstruction

- Gain réel : abstractions validées par schéma, API d'état runtime, portail, promotion multi-environnements, plan de build.
- Coût réel : 8 à 12 composants nouveaux (F1), dont 4 doublons de l'existant (kgateway / Cilium Gateway, OpenBao / Doppler, Flux / Argo CD, OpenSearch / Grafana Cloud). ThunderID ne peut pas remplacer Authentik (F7, F8) : on garde deux IdP ou on perd Fleet et opencode.
- Topologie : le control plane ne tient pas sur OKE à côté d'Authentik (F2, F9). Il va au homelab ; OKE devient un data plane distant (F3).
- Les applications à chart riche (Immich, Matrix, Authentik, médias, Home Assistant) ne gagnent rien à devenir des `Component` : elles resteraient en Argo. A devient B dans les faits.

### B — OpenChoreo hybride minimal

- OpenChoreo seulement pour les nouvelles applications simples ; Argo CD, Authentik, Doppler/ESO, Grafana Cloud, CNPG gardés.
- On cumule deux systèmes de livraison (Flux pour OpenChoreo, Argo pour le reste), deux surfaces agent (MCP OpenChoreo + scripts kube-ops) et un rythme d'upgrade de ~2 mois avec migrations (F4).
- Les cinq primitives difficiles restent à écrire, en ResourceTypes.

### C — Factory maison, terminée au strict nécessaire (« C allégée »)

- On **abandonne** Backstage, le Scaffolder, les templates Nunjucks et le MCP Backstage. Un agent n'a pas besoin de portail : il écrit un fichier et ouvre une PR.
- On **termine** le contrat `platform.smadja.dev/v1` avec quatre blocs qui portent le vrai travail : `database`, `sso`, `backup`, `exposure`.
- On **garde** Argo CD (deux instances, D-2026-11-15-01), Authentik, Doppler/ESO, CNPG, Cilium/Gateway API, Cloudflare, Grafana Cloud.
- Surface agent : un fichier `app.yaml` + 3 commandes (`app-new`, `app-status`, `app-retire`).
- Friction à supprimer en priorité : aujourd'hui chaque app OIDC exige une PR protégée dans le namespace `auth`. Le bloc `sso` génère le blueprint dans un chemin dédié aux apps générées, validé par la garde, sans admission propriétaire.
- Kyverno (2 policies en audit, 618 violations préexistantes) : ne pas l'étendre. Les bornes des apps générées passent par PSA `restricted` (label du namespace) + `values.schema.json` + ValidatingAdmissionPolicy limitées à `svc-*`, comme sur OKE.

## 4. Matrice par composant

Légende décision : KEEP, REPLACE, REMOVE, BUILD (code à écrire).

| # | Composant | Nécessaire au résultat | Apport OpenChoreo réel | Décision (C allégée) | Coût / risque |
|---|---|---|---|---|---|
| 1 | Authentik vs ThunderID | SSO familial OIDC + SAML (Fleet) + proxy (opencode), MFA, récupération, déclaratif | ThunderID : OIDC, passkeys, identité agent ; SAML IdP non prouvé, ni proxy, ni LDAP ; GA depuis 3 mois | **KEEP Authentik** | voir §5 |
| 2 | Backstage maison vs portail OC | rien pour les agents ; Paul lit Linear/GitHub/Grafana | portail Backstage + assistant lecture seule | **REMOVE** Backstage maison ; pas de portail OC | −1 image, −1 base, −1 GitHub App |
| 3 | Argo CD vs Flux | réconciliation Git → cluster, deux clusters | Flux imposé par l'outillage OC (F5) | **KEEP Argo CD** | changer = réécrire 30 Applications pour 0 gain agent |
| 4 | `platform-app` vs ComponentType/Trait/ResourceType | un contrat borné, validé, une seule lecture | schéma + CEL, mêmes bornes à écrire | **KEEP + BUILD** 4 blocs | 4–7 j agent |
| 5 | Admission maison vs validations OC | bornes CPU/RAM/replicas, pas de privilèges host | validation API OC ; bornes applicatives non testées (pilote) | **KEEP** PSA `restricted` + `values.schema.json` + VAP/Kyverno ; **REMOVE** gardes CI redondantes sur preuve | baisse de la maintenance CI |
| 6 | Doppler/ESO vs OpenBao | secrets hors Git, sans jeton admin partagé | OpenBao par défaut ; `ClusterSecretStore` remplaçable | **KEEP** Doppler/ESO | OpenBao = un coffre de plus à sauvegarder |
| 7 | GitHub Actions/ARC vs workflow plane | images fournies par l'amont (GHCR) ; CI des dépôts | Argo Workflows + buildpacks + registre | **KEEP** ARC | aucun besoin de build applicatif |
| 8 | CNPG mutualisé vs provisioning natif | `Database` par app dans `pg-shared-homelab`, sauvegarde R2 | rien de natif pour CNPG ; ResourceType à écrire | **KEEP + BUILD** bloc `database` | le vrai chantier (PLT-375) |
| 9 | Grafana Cloud vs observability plane | état lisible par agent, alertes < 10 min | OpenSearch + Prometheus locaux, agent SRE | **KEEP** Grafana Cloud | OpenSearch = plusieurs GiB de RAM |
| 10 | Gateway API/Cilium/Cloudflare vs kgateway | exposition privée/publique, TLS valide | kgateway | **KEEP** | deux contrôleurs Gateway sinon |
| 11 | agent-operator, MCP, app-status vs API/MCP OC | identité K8s bornée, statut JSON, écriture par PR | MCP ≈ 114 outils filtrés par droits, RBAC CEL par projet/environnement (point fort réel) ; écritures hors Git | **KEEP** `agent-operator` + `app-status.v1` ; **REMOVE** MCP Backstage | plus de contexte agent ; écritures directes incompatibles avec le retour arrière par `git revert` |

Empreinte : A ajoute au minimum le pilote mesuré (~670 MiB, sans build ni observabilité, F6) et, en production documentée, des nœuds de 4 CPU / 8 Go (F2) ; OpenSearch se compte en GiB. C n'ajoute rien et retire Backstage (pod + base `pg-shared` sur OKE).

## 5. Identité : ThunderID ou Authentik

**Décision recommandée : garder Authentik, ne pas installer ThunderID.**

| Exigence | Authentik (en place) | ThunderID (OC ou autonome) |
|---|---|---|
| OIDC / OAuth2 | oui, 28 apps | oui (OAuth 2.1, PAR, PKCE) |
| SAML IdP (Fleet) | oui | **non prouvé** (fédération entrante documentée) |
| Proxy / forward-auth (opencode, apps sans OIDC) | oui (outpost) | **non trouvé** (il faudrait oauth2-proxy) |
| LDAP, SCIM | outposts disponibles (non utilisés) | non trouvés |
| Passkeys, MFA, récupération | oui, TOTP, libre-service utilisateur | passkeys, SMS OTP, magic link ; TOTP et portail libre-service non trouvés |
| Déclaratif GitOps | blueprints YAML (déjà 28 en Git) | import YAML au démarrage ; types importables non confirmés |
| Identité agent distincte | comptes de service, `client_credentials`, token exchange (2026.8) ; « agent accounts » en Enterprise | identité « agent » native, délégation, CIBA |
| Maturité | stable, utilisé ici | GA 15/08/2026, v2 cassante déjà en milestone, pas de guide d'upgrade |
| Migration | 0 | réécrire 28 intégrations, réenrôler la famille, protection « identité » de Paul |

Le seul avantage de ThunderID est l'identité agent native. Le besoin réel (Claude, Codex et futurs agents distincts, droits minimaux, révocables, tracés) se couvre sans changer d'IdP : un ServiceAccount Kubernetes borné par agent (`agent-operator` existe), un jeton Doppler par agent, une GitHub App ou un jeton par agent, et un client `client_credentials` Authentik par agent si une API applicative l'exige. Le ThunderID livré dans OpenChoreo est une configuration de démonstration (utilisateurs `admin@openchoreo.dev` créés au bootstrap) : il n'entre pas en production.

Exposition et disponibilité : Authentik part sur OKE (PLT-384), exposé par Cloudflare Tunnel sans Access (pas de circularité), indépendant de l'arrêt du homelab.

## 6. Topologie recommandée

- **OKE** (`oracle-a1`, Free Tier) : Authentik + son CNPG dédié, Polyfin, AIOStreams. Argo CD local. Aucun control plane de plateforme.
- **Homelab** : tout le reste, Argo CD local, `pg-shared-homelab`, ARC.
- **Pas de troisième surface** : aucune surface persistante gratuite supplémentaire n'est disponible et prouvée ; le N100 reste l'exécutant des agents.
- Arrêt du homelab : OKE continue (Authentik, médias). Les livraisons homelab attendent son retour. Aucune dépendance OKE → homelab pour s'authentifier.

Note d'écart : le mandat dit le homelab « pas nécessairement 24/7 » ; D-2026-11-16-07 le considère « allumé 24 h/24 ». La topologie ci-dessus tient dans les deux cas.

## 7. Parcours agent : Miniflux (critère principal)

Estimation, non mesurée. Hypothèse commune : `pg-shared-homelab` existe (PLT-375).

| Mesure | A natif | B hybride | C allégée |
|---|---|---|---|
| Concepts à connaître | Project, Component, ComponentType, Workload, Trait, ResourceType, Environment, ReleaseBinding, Flux + Authentik (IdP séparé) ≈ 10 | les mêmes + Argo pour le reste ≈ 12 | `app.yaml` (profil, image, database, sso, backup, exposure), Argo, `app-status` ≈ 4 |
| Fichiers modifiés | 3–5 (Component, Workload, binding, blueprint Authentik hors OC) | 3–5 | 1 (`app.yaml`) ; blueprint et secret générés par le bloc `sso` |
| Commandes | `occ` + `flux` + vérifs | `occ` + `flux` + `kubectl-ro` | `just app-new`, `just app-status`, `just app-retire` |
| PR / gestes humains | 1–2 PR / 0 | 1–2 PR / 0 | 1 PR / 0 |
| Outils dans le contexte | MCP ≈ 114 (+15 observabilité) | idem + scripts | 3 commandes + 1 skill |
| Découverte des contrats | API/MCP (fort) | API/MCP | `values.schema.json` + `just app-new --help` |
| Diagnostic runtime | API OC + observabilité OC (si installée) | partagé | `app-status.v1` + Grafana Cloud (existant) |
| Composants spécifiques à maintenir | ResourceTypes CNPG/OIDC/backup + intégrations | idem + factory | chart + 4 blocs + 3 scripts |

Ce qui reste à coder est le même pour A, B et C : provisioning base, client OIDC, secret, sauvegarde, preuve de restauration. Seul le format change. C le code une fois, dans le format déjà connu des agents.

## 8. Efforts (jours d'agent, bas / central / haut)

| Poste | A | B | C allégée |
|---|---|---|---|
| Installation plateforme | 3 / 5 / 8 | 2 / 4 / 6 | 0 |
| Identité et secrets | 2 / 4 / 6 (IdP externe + ESO Doppler) | 2 / 3 / 5 | 1 / 2 / 3 (clients OIDC générés) |
| GitOps / CI | 2 / 4 / 6 (Flux) | 2 / 3 / 5 | 0 / 0,5 / 1 |
| Profils applicatifs | 4 / 6 / 9 | 4 / 6 / 9 | 4 / 5 / 7 |
| Redéploiement des apps | 6 / 10 / 15 | 2 / 4 / 6 (nouvelles seulement) | 1 / 2 / 4 (nouvelles + simples, opportuniste) |
| Preuves runtime et sécurité | 3 / 4 / 6 | 3 / 4 / 6 | 2 / 3 / 4 |
| Retrait anciens composants | 1 / 2 / 3 | 1 / 1 / 2 | 0,5 / 1 / 1 (Backstage) |
| **Total mise en service** | **21 / 35 / 53** | **16 / 25 / 39** | **8,5 / 13,5 / 20** |
| Maintenance 3 / 6 / 12 mois | 3 / 6 / 12 (upgrade mineur ~tous les 2 mois, F4) | 4 / 8 / 15 (deux systèmes) | 1 / 2 / 4 |
| **Total à 12 mois (central)** | **≈ 47** | **≈ 40** | **≈ 17** |

L'estimation initiale de 18–27 jours (pilote) ne comptait ni le redéploiement des apps à chart riche, ni les upgrades, ni le second IdP.

## 9. Sécurité : invariants du mandat

| Invariant | C allégée | Mécanisme |
|---|---|---|
| Agent jamais cluster-admin | PASS (STATIC) | `agent-operator` borné, `scope.tsv` |
| Pas de lecture inter-projets de secrets | à prouver par test de refus | ESO par namespace, RBAC sans `secrets get` |
| Pas de privilèges host | STATIC ; refus à prouver | label PSA `restricted` déjà rendu par le chart sur chaque `svc-*` |
| Bornes CPU/RAM/replicas | PASS (STATIC) | `values.schema.json` + admission |
| Secrets hors Git, sans jeton admin partagé | PASS | Doppler → ESO ; jeton par agent à finir |
| Identités humaines / agents distinctes | partiel | SA, jeton Doppler, GitHub App par agent |
| Traçabilité, état reproductible | PASS | PR + Argo ; écritures directes limitées à `kubectl-rw` et réconciliées le jour même |
| Changements dangereux réversibles | PASS | `git revert` ; données : sauvegarde vérifiée avant |
| Données gardées restaurables | à prouver par app | bloc `backup` + drill |
| Isolation réseau | PASS (STATIC) | CiliumNetworkPolicy default-deny ingress **et egress** rendue par le chart (le pilote OpenChoreo n'avait pas d'egress deny) |
| Provenance des images | partiel | digest épinglé obligatoire ; signature non vérifiée |
| TLS validé | PASS | interdits absolus existants |

Écritures directes API/MCP : **la PR GitOps reste la seule voie d'écriture de l'état désiré.** C'est la condition du retour arrière par `git revert`, que Paul a choisi comme mécanisme de sécurité principal. Les écritures directes restent les opérations bornées de `kubectl-rw` (restart, scale, suspend), déjà tracées.

Tests de refus à exécuter (C) : agent qui lit un Secret d'un autre namespace → refus ; `app.yaml` avec `replicas: 50` ou `hostNetwork` → refus CI et admission ; ExternalSecret vers une clé Doppler hors préfixe de l'app → refus.

## 10. Risques et réversibilité

- **C** : risque principal = se remettre à construire une plateforme. Garde-fou : quatre blocs, trois commandes, pas de portail, pas de nouveau contrôleur. Réversible : rien n'est détruit.
- **A/B** : dépendance à un projet jeune (1.0 en avril 2026) au rythme d'upgrade rapide ; doublons de composants ; deux IdP. Réversible seulement avant le retrait d'Argo.
- **Réexamen d'OpenChoreo** si l'une de ces conditions apparaît : plus de ~40 apps ou plusieurs équipes et environnements ; ResourceTypes officiels CNPG + client OIDC d'un IdP externe ; support Argo CD natif ; control plane gratuit hébergé.
