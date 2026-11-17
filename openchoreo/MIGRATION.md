# MIGRATION — option E (factory maison allégée)

Plan de redéploiement depuis un état propre, pour l'option recommandée dans `DECISION.md`. Rien ne démarre avant la décision de Paul.

## Principe

Pas de migration de plateforme : Argo CD, Authentik, CNPG, Doppler/ESO, Cilium et Grafana Cloud restent. On termine le contrat, on retire Backstage, puis on fait entrer les applications dans le contrat **quand on les touche**. Aucune donnée n'est détruite par ce plan.

## Classement des applications (Git + `cluster-reality.md` du 11/11 + D-2026-11-16-07)

| Classe | Applications | Traitement |
|---|---|---|
| Sans état, recréables | it-tools, searxng, stirling-pdf, ntfy, open-connector, `idp-e2e` | candidates au contrat dès la phase 3 |
| État jetable (reconstructible) | pinepods, romm, gpt-researcher, opencode, mqtt, executor, drills | contrat possible ; restauration non requise |
| Données à conserver | **Vikunja** (seules vraies données selon D-2026-11-16-07, perte « pas grave ») ; marquées « irremplaçable (à confirmer) » : immich, invoice-ninja, paperless, rustical, mealie, trilium, sure, karakeep, wellness, home-assistant, hindsight | **aucune bascule** sans décision explicite de Paul et restauration prouvée ; elles restent hors contrat tant qu'elles marchent |
| Services critiques | Authentik, Matrix | protégés ; Authentik suit PLT-384, hors de ce plan |
| Infrastructure externe | Cloudflare, Doppler, R2, OCI, Proxmox, Talos, ARC | non concernée |

Écart à trancher par Paul : le prompt du 17/11 dit « aucune donnée sensible » ; `cluster-reality.md` classe plusieurs apps « irremplaçable (à confirmer) ». Par défaut, ce plan ne détruit rien.

## Ordre

| Phase | Contenu | Critère de sortie | Preuve | Retour arrière |
|---|---|---|---|---|
| 0 | Consigner la décision ; geler Backstage/OpenChoreo | entrée `decisions.md` mergée | PR | revert |
| 1 | Blocs `database` + `sso` + `backup` + `exposure` dans le chart, le schéma et la garde ; 6 tests de refus | `just check` PASS ; 3 refus CI + 3 refus admission | CI, RUNTIME sur `idp-e2e` | revert du chart |
| 2 | `pg-shared-homelab` (PLT-375) branché sur `database` ; isolation SQL prouvée | rôle d'une app refusé sur une autre base | RUNTIME | revert ; base vide |
| 3 | **Miniflux de bout en bout** par un agent sans geste humain : `just app-new` → PR → merge → Argo → OIDC `family` → refus hors groupe → sauvegarde R2 → restauration isolée | `app-status` PASS + 2 tests utilisateur + RTO ≤ 30 min | RUNTIME + USER (Paul se connecte une fois) | `just app-retire miniflux` |
| 4 | Retrait Backstage : image, overlay #1618, GitHub App, templates, catalogue, `pg-shared` OKE si sans consommateur, cluster k3d du pilote | aucun consommateur ; GitHub App révoquée | inventaire avant/après | les fichiers restent dans l'historique Git |
| 5 | Entrée opportuniste des apps sans état et jetables dans le contrat, une PR par app | `app-status` PASS par app | RUNTIME | revert par app |

Durée estimée : phases 0–4 ≈ 8 à 14 jours d'agent ; phase 5 au fil de l'eau.

## Points de bascule DNS / OIDC

- Aucun nouveau point de bascule. Une app qui entre dans le contrat garde son nom DNS et son client OIDC ; le blueprint change de chemin, pas d'identifiant (même `client_id`, secret régénéré seulement si l'ancien n'est pas récupérable par ESO).
- La bascule `auth.smadja.dev` vers OKE reste celle de PLT-384, avec son mandat.

## Conditions de suppression des anciens composants

Un composant n'est retiré que si : son successeur a une preuve RUNTIME ; aucun consommateur n'est trouvé (`kubectl-ro`, Argo, GitHub) ; la suppression passe par une PR GitOps. Pour une donnée : sauvegarde vérifiée avant, et décision de Paul pour une donnée classée « à conserver ».

## Conditions d'arrêt

- Phase 1 dépasse 7 jours d'agent, ou le chart dépasse ~2× sa taille actuelle : arrêt et réévaluation (on reconstruirait une plateforme).
- Phase 3 exige un geste humain autre que la connexion de test de Paul : arrêt, correction du bloc fautif.
- Une app « à conserver » perdrait des données : arrêt immédiat.
- Une garde contournée, un secret affiché ou un `--admin` : arrêt et signalement.
