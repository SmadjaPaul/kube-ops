# DECISION — OpenChoreo : écarter maintenant, terminer une factory maison allégée sans Backstage

Recommandation unique (Opus, 17/11/2026), à valider par Paul. Elle n'est en vigueur qu'après son entrée dans `homelab-infra/docs/decisions.md`.

## Recommandation

**Écarter OpenChoreo comme plateforme principale (ni natif, ni hybride, ni direct, ni table rase).** Adopter l'option **E — factory maison allégée** :

- un seul contrat `app.yaml` (`platform.smadja.dev/v1`) complété de quatre blocs : `database`, `sso`, `backup`, `exposure` ;
- livraison par PR → CI → Argo CD (ApplicationSet `apps-generated`) → chart `platform-app` ;
- trois commandes agent : `just app-new`, `just app-status`, `just app-retire` ;
- **sans Backstage, sans Scaffolder, sans portail.**

Réexamen d'OpenChoreo seulement si une condition du §10 de `STRATEGY.md` apparaît.

## Preuves principales

1. **Le travail difficile n'est pas dans OpenChoreo.** Miniflux est bloqué depuis le 08/11 par la base partagée, le client OIDC, le secret et la preuve de restauration (PLT-152), pas par l'abstraction applicative. OpenChoreo ne fournit nativement aucun de ces éléments pour CNPG, Authentik, Doppler, R2 et Cloudflare ; ResourceType est en `v1alpha1`, sans exemple CNPG, avec des bugs ouverts. [D]
2. **Le pilote montre des trous sur nos primitives** : aucune borne de valeurs, pas de default-deny egress, pas de PSA, pas de client OIDC par app, un seul `ClusterSecretStore`. Les combler revient à réécrire nos gardes en CEL. [P]
3. **Le mode qui rend OpenChoreo agréable aux agents (MCP direct) casse le retour arrière par `git revert`**, que Paul a choisi comme sécurité principale (D-2026-11-16-07). Le mode Git est documenté avec Flux seulement ; Argo n'est ni documenté ni testé. [D/P]
4. **ThunderID ne remplace pas Authentik** : SAML IdP non prouvé (Fleet), pas de proxy (opencode), pas de TOTP ni de portail libre-service trouvés, GA depuis le 15/08/2026 avec une v2 cassante déjà en milestone. [D]
5. **OKE ne peut pas porter le control plane** : 23 pods du pilote contre 31 IP par nœud dont 19 déjà prises ; production documentée à 3 nœuds de 4 CPU / 8 Go. [P/D]
6. **Coût à 12 mois** (estimation) : E ≈ 17 jours d'agent ; OpenChoreo hybride ≈ 40 ; natif ≈ 47, avec un mineur tous les 1–2 mois et des CRD à migrer à la main. [S]
7. **Contexte agent** : E = 1 fichier, 3 commandes, ~4 concepts ; OpenChoreo = ~10 concepts et 59 à 130 outils MCP selon le rôle. [P/S]

## Compromis acceptés

- Pas de portail graphique. Paul lit Linear, GitHub et Grafana Cloud.
- Pas de promotion multi-environnements (dev/staging/prod) : inutile pour ~20 utilisateurs familiaux.
- Pas de build intégré : les images viennent de l'amont (GHCR, digest épinglé).
- Nous maintenons un chart et quatre blocs nous-mêmes (≈ 1 à 4 jours d'agent par an), au lieu de suivre les migrations d'un projet jeune.
- Pas d'identité « agent » native : on compose SA Kubernetes + jeton Doppler + identité GitHub + client Authentik par agent.

## Ce qui reste incertain

| Point | Statut | Plus petit test |
|---|---|---|
| Blueprint Authentik généré hors du namespace `auth` sans PR protégée | NOT_PROVEN | PR Miniflux avec bloc `sso` : Authentik charge le blueprint, login OIDC `family` PASS, utilisateur hors groupe refusé |
| Isolation SQL par rôle dans `pg-shared-homelab` | NOT_TESTED au homelab (PLT-375) | rôle Miniflux refusé sur la base d'une autre app |
| Refus d'admission des apps générées | partiel | `replicas: 50`, `hostNetwork: true`, ExternalSecret hors préfixe → 3 refus CI + 3 refus admission |
| Restauration d'une app à base | NOT_PROVEN | restauration isolée de la base Miniflux depuis R2, RTO mesuré ≤ 30 min |
| OpenChoreo + Argo CD | NOT_TESTED | inutile maintenant ; test de réexamen ci-dessous |

**Test de réexamen d'OpenChoreo (≤ 1,5 jour d'agent, k3d isolé), seulement si un déclencheur apparaît** : Argo CD synchronise Component + Workload + ReleaseBinding depuis Git (`autoDeploy=false`) ; un ResourceType crée une `Database` CNPG avec rôle dédié ; un ProjectType pose PSA `restricted` + default-deny ingress/egress ; kgateway coexiste avec la Gateway Cilium. Succès = 4/4 PASS, 3 refus de contenu prouvés, et code CEL à écrire inférieur au chart + gardes actuels. Sinon, la décision reste.

## Liste nominative

| Élément | Sort |
|---|---|
| Backstage maison (image, config, overlay OKE #1618, image arm64 #1613) | **ABANDONNÉ** |
| MCP Backstage (`mcp-actions-backend`) | **ABANDONNÉ** |
| Template `platform-application` (Scaffolder) | **ABANDONNÉ**, remplacé par `just app-new` |
| Template `service-postgres-oidc` | **ABANDONNÉ**, absorbé par les blocs `database` + `sso` |
| Catalogue généré (`catalog-info.yaml`, `catalog/`) | **ABANDONNÉ** |
| GitHub App Backstage | **ABANDONNÉ** (à révoquer) |
| `pg-shared` sur OKE réservé à Backstage | **ABANDONNÉ** |
| `app.yaml` / contrat `platform.smadja.dev/v1` | **ADAPTÉ** : blocs `database`, `sso`, `backup`, `exposure` |
| Chart `platform-app` (≈ 290 lignes de templates ; PSA `restricted` et default-deny ingress/egress Cilium déjà rendus) | **ADAPTÉ** : rendu des quatre blocs |
| Garde `service-contract` | **ADAPTÉ** : valide les quatre blocs et les refus |
| AppProject / ApplicationSet `apps-generated` | **CONSERVÉ** |
| `app-status.v1` / `status-app.sh` / `app-status.sh` | **CONSERVÉ** (une seule commande gardée) |
| Contrat `pg-shared` + garde d'isolation SQL | **CONSERVÉ**, branché sur le bloc `database` |
| Générateur de secrets ESO + SecretStore par domaine | **CONSERVÉ**, branché sur `sso` et `database` |
| Blueprints Authentik | **ADAPTÉ** : générés par app, sans PR protégée dans `auth` |
| Authentik | **CONSERVÉ** (migration OKE PLT-384 inchangée) |
| Doppler / ESO | **CONSERVÉ** |
| Kyverno | **ADAPTÉ** : gelé, pas de nouvelle policy ; bornes des apps par PSA + VAP |
| Argo CD (deux instances) | **CONSERVÉ** |
| Cilium + Gateway API | **CONSERVÉ** |
| Protections stateful (Prune=false, classes de réversibilité) | **CONSERVÉ** |
| CI `v1-contract`, `plan_diff` stateful | **CONSERVÉ** ; autres gardes retirées seulement sur preuve de doublon |
| OpenChoreo, ThunderID, OpenBao, kgateway, Flux | **NON ADOPTÉS** |
| Pilote OpenChoreo k3d | **ABANDONNÉ** (supprimer le cluster local) |

## Actions immédiates

1. Paul valide ou corrige cette décision ; un agent la consigne dans `decisions.md` et `decisions-active.md`.
2. Arrêter tout développement Backstage, Scaffolder, catalogue et pilote OpenChoreo.
3. Lancer le mandat d'exécution unique (`MANDAT-EXECUTION.md`), Miniflux comme preuve de bout en bout.
4. PLT-384 (OKE, Authentik) continue sans changement.

## Réponse à la question finale

**« Si je repartais de zéro avec ces machines, ces besoins et ces contraintes, est-ce que je choisirais OpenChoreo natif, OpenChoreo hybride ou notre factory Backstage maison ? »**

Aucun des trois tel quel. Je choisirais **la factory maison sans Backstage** : Argo CD + un chart unique piloté par un fichier `app.yaml` à quatre blocs + trois commandes, avec Authentik, CNPG mutualisé, Doppler/ESO et Grafana Cloud. OpenChoreo résout bien un problème d'équipes multiples et d'environnements multiples que nous n'avons pas, et ne résout pas celui que nous avons (base, SSO, secret, sauvegarde, preuve). C'est l'option qui minimise le travail total et le contexte des agents.
