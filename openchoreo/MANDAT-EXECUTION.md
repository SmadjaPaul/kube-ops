# MANDAT D'EXÉCUTION — factory allégée, Miniflux comme preuve (NON LANCÉ)

À lancer seulement après la validation de `DECISION.md` par Paul. Agent : Opus pour la phase 1, Sonnet ensuite. Checkpoint obligatoire après chaque phase (commentaire Linear STE80 + `mission-result.v1`).

## Objectif

Un agent installe Miniflux avec PostgreSQL partagé, SSO `family`, URL privée et sauvegarde R2, en **un fichier `app.yaml` et une PR**, sans geste de Paul, puis prouve le fonctionnement, un refus et une restauration.

## Lecture au démarrage

`homelab-infra/docs/decisions-active.md` → ce mandat → `openchoreo/DECISION.md` → `kube-ops/AGENTS.md` → `k8s/charts/platform-app/` → Linear PLT-152, PLT-375.

## Périmètre

1. Phase 0 : PR homelab-infra consignant la décision (journal + résumé, `scripts/check-decisions.py`).
2. Phase 1 : chart `platform-app` 0.3.0 + `values.schema.json` + garde `service-contract` : blocs `database` (Database + rôle dans `pg-shared-homelab`), `sso` (blueprint Authentik + secret client via générateur ESO), `backup` (sauvegarde CNPG R2 + script de restauration isolée), `exposure` (`private`/`public`, Gateway Cilium, TLS). Conserver le label PSA `restricted` et le default-deny ingress/egress déjà rendus par le chart ; les étendre aux flux base, Authentik et R2 exacts. Commandes `just app-new <nom>`, `just app-status <nom>`, `just app-retire <nom>`.
3. Tests de refus obligatoires : `replicas` hors borne, `hostNetwork`/privilégié, ExternalSecret hors préfixe de l'app, lecture d'un Secret d'un autre namespace par `agent-operator`, rôle SQL d'une app sur la base d'une autre, utilisateur hors groupe `family` sur Miniflux.
4. Phase 2 : dépend de PLT-375 (`pg-shared-homelab`) ; ne pas le dupliquer.
5. Phase 3 : Miniflux 2.3.5 par digest, via le contrat seul.
6. Phase 4 : retrait Backstage (liste nominative de `DECISION.md`), une PR, après preuve de la phase 3.

## Exclusions

OpenChoreo, ThunderID, OpenBao, Flux, kgateway ; tout nouveau contrôleur ou portail ; Authentik hors blueprints d'apps générées ; OKE (PLT-384) ; toute app classée « à conserver » ; toute suppression de donnée.

## Critères de fin

- `just app-status miniflux` → `PASS`, niveau `RUNTIME`.
- 6 refus prouvés (sorties de CI et d'admission citées).
- Restauration isolée de la base Miniflux depuis R2, RTO mesuré ≤ 30 min.
- Paul se connecte une fois à Miniflux via SSO (seul geste humain, niveau `USER`).
- Backstage retiré, GitHub App révoquée, inventaire avant/après.
- Contexte agent : le skill `deploy-a-service` réécrit tient en ≤ 1 écran et ne cite que `app.yaml` et les trois commandes.

## Arrêt

Phase 1 > 7 jours d'agent ou chart > 2× sa taille ; geste humain imprévu ; garde contournée ; secret visible ; perte de donnée possible. Dans ces cas : arrêt, commentaire Linear, retour au coordinateur.

## Interdits

Ceux de `decisions-active.md` (pas de `--admin`, pas de TLS désactivé, pas de valeur de secret lue ou affichée, pas d'apply local, pas de `device_bash`).
