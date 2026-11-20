# Drill D0 : `CreatedOnce`, rotation par renommage, RBAC hors liste (manifestes TEMPORAIRES)

Statut : manifestes livrés par la PR `claude/secrets-d0-drill` (DRAFT). Verdict : **NOT_PROVEN** tant que les preuves de `docs/operations/secrets-migration-evidence.md` (section lot 0) ne sont pas relevées. Spec : `docs/architecture/secrets-migration-spec.md` (section « Drill D0 », lot 0). Aucune valeur de secret n'apparaît dans Git, la PR, les journaux ou les preuves : seulement des statuts, conditions, dates et une empreinte de 12 caractères calculée dans le cluster.

## Ce que D0 prouve

| Fait | Preuve |
| --- | --- |
| F1 : une source `CreatedOnce` ne se régénère pas (resync Argo, redémarrage d'ESO) | `refreshTime` et empreinte `FP=` identiques avant et après une synchronisation forcée sans changement |
| F3c : renommer l'ExternalSecret source en gardant `target.name` change la valeur, le Secret est mis à jour sur place | empreinte différente après la rotation, `target`/âge du Secret inchangés (étape 2) |
| F4 : le RBAC refuse un nom hors `resourceNames` | `eso-drill-forbidden` : `SecretSyncedError`, 403 `forbidden` (acquis le 20/11/2026, objet retiré ensuite) |
| F9 : l'échec est visible | alerte `ExternalSecretNotReady` firing pour `eso-drill-forbidden` (acquis le 20/11/2026) |

## Ce que le merge crée (Argo, aucun apply manuel)

Tout est TEMPORAIRE, marqué `kube-ops.io/drill: "true"` et branché dans la racine existante `k8s/infrastructure/controllers` (Application `infra-controllers`, `automated`, `prune`, `selfHeal`).

| Objet | Fichier | Rôle |
| --- | --- | --- |
| Namespace `eso-drill` (Pod Security `restricted`) | `k8s/infrastructure/controllers/external-secrets/drills/createdonce/namespace.yaml` | baseline d'un namespace applicatif, non augmentée |
| CiliumNetworkPolicy `eso-drill-default-deny` | `.../network-policy.yaml` | default-deny entrée et sortie (`k8s/CLAUDE.md`) ; aucun accès ouvert, le Job lit seulement un Secret monté |
| Password + ExternalSecret `oidc-eso-drill` (namespace `auth`) | `.../source-auth.yaml` | source générée, forme (C), `CreatedOnce`, `Orphan`, classe `T3` |
| ExternalSecret `eso-drill-oidc` (namespace `eso-drill`) | `.../consumers.yaml` | copie par le store `k8s-auth`, `refreshInterval: 1h` |
| Job `eso-drill-fingerprint` (hook `PostSync`, `BeforeHookCreation`) | `.../fingerprint-job.yaml` | monte la copie, écrit seulement `FP=<12 premiers hex du SHA-256>` |
| `oidc-eso-drill` ajouté aux `resourceNames` (sentinelle conservée) | `k8s/infrastructure/auth/authentik/extra/eso-k8s-reader-rbac.yaml` | autorise le store à lire la source du drill, rien d'autre |
| Destination `eso-drill` | `k8s/bootstrap/argocd-root/infrastructure-project.yaml` | projet Argo `infrastructure` |

Les ExternalSecret du drill portent `argocd.argoproj.io/ignore-healthcheck: "true"` (attente transitoire du Role posé par `infra-auth`). La preuve est leur statut lu avec `kubectl-ro`, pas la santé Argo.

**Correctif du 20/11/2026 (PR `claude/secrets-d0-step2-stability`)** : l'ExternalSecret `eso-drill-forbidden` (preuves 3 et 6 acquises) a été retiré, ainsi que l'exemption `drill-expect-forbidden` du test. Son échec permanent (`could not get secret data from provider`) rendait la dernière opération Argo de `infra-controllers` `Failed` (l'annotation `ignore-healthcheck` n'agit que sur la santé, pas sur le résultat de la synchro), donc les hooks `PostSync` ne tournaient jamais et toute synchro future était en échec. Le Job d'empreinte n'a besoin d'aucun RBAC : le Secret est monté en volume (lu par le kubelet), le pod n'a pas de jeton de ServiceAccount.

Effets attendus au merge : l'alerte `ExternalSecretNotReady` pour `eso-drill-forbidden` se résout ; aucun autre Secret, aucune des 10 clés de chiffrement, aucun ExternalSecret applicatif n'est touché.

Les noms `eso-drill`, `eso-drill-*` et `oidc-eso-drill*` sont réservés au drill. Le drill D1 (`docs/operations/secrets-drill-d1-pg-shared-role.md`) réutilise le namespace `eso-drill` et le dossier `drills/createdonce/` : voir « Coordination avec D1 ».

## Déroulement

Lecture seule : `bash scripts/kubectl-ro.sh` (`KUBECTL_RO_IDENTITY=agent`). Toutes les écritures passent par Git. Les commandes exactes et les critères `PASS`/`FAIL` sont dans `docs/operations/secrets-migration-evidence.md` (section lot 0).

### Étape 1 : état stable (cette PR)

Preuves 0 à 3 et 6 : acquises le 20/11/2026 (voir le tableau d'évidence). Preuve 4 : après le merge de la PR de correctif, la synchro réussit et le hook produit FP#1 ; puis une seconde PR (modification sans effet destructeur de la spec de la source `oidc-eso-drill`, ex. annotation de documentation, pour forcer une réconciliation ESO) ; la synchro suivante produit FP#2 ; PASS si FP#2 = FP#1 et `refreshTime` de la source inchangé.

### Étape 2 : rotation par renommage (PAS dans cette PR, deux commits)

À faire seulement quand l'étape 1 est consignée `PASS`, dans une PR séparée, en deux commits :

1. Commit 1 : dans `source-auth.yaml`, renommer l'ExternalSecret **et** le Password `oidc-eso-drill` en `oidc-eso-drill-r2`, **même `target.name: oidc-eso-drill`** (le Secret, donc le nom de la `resourceNames`, ne change pas). Résultat attendu : la source `oidc-eso-drill-r2` est `Ready` avec un `refreshTime` neuf, le Secret `oidc-eso-drill` est mis à jour sur place (même `uid`/âge ; l'agent ne lit pas les Secrets : l'indice lisible est `status.syncedResourceVersion` de l'ExternalSecret et, sous MANDAT, l'âge du Secret).
2. Commit 2 (pour ne pas attendre `refreshInterval`) : renommer la copie `eso-drill-oidc` en `eso-drill-oidc-r2` (même `target.name: eso-drill-oidc`). Risque connu : avec `creationPolicy: Owner`, la copie existante appartient à l'ancien ExternalSecret ; consigner si ESO refuse (« owned by another ExternalSecret ») ou recrée le Secret après le prune.

Résultat : le Job `PostSync` relancé affiche une empreinte **différente** (preuve 5). Pas de rotation avant d'avoir relevé l'empreinte « avant » de l'étape 1.

## Coordination avec D1

D1 ajoute ses propres fichiers dans `drills/createdonce/` et suppose le namespace `eso-drill` absent du projet Argo. Si D0 est encore présent : D1 réutilise le namespace et la destination existants (ne pas les redéclarer) et son nettoyage ne retire le namespace qu'après celui de D0. Si D0 est nettoyé d'abord, D1 recrée namespace et destination comme décrit dans sa procédure.

## Nettoyage (PR de nettoyage, écrite, NON ouverte)

Condition : D0 consigné `PASS` (ou `FAIL` expliqué) dans la section lot 0 de `docs/operations/secrets-migration-evidence.md`. Branche `claude/secrets-d0-cleanup`, titre `chore(secrets): lot 0 — nettoyage du drill D0`. Un seul commit suffit (aucun rôle externe à supprimer avant) :

1. Supprimer le dossier `k8s/infrastructure/controllers/external-secrets/drills/createdonce/` (si D1 y a ajouté des fichiers qui servent encore, ne retirer que ceux de D0 : `namespace.yaml` reste tant que D1 est actif).
2. Retirer `- external-secrets/drills/createdonce` de `k8s/infrastructure/controllers/kustomization.yaml`.
3. Retirer `oidc-eso-drill` de `resourceNames` dans `k8s/infrastructure/auth/authentik/extra/eso-k8s-reader-rbac.yaml` (la sentinelle `eso-k8s-sentinel-none` reste : une liste vide donnerait accès à tous les Secrets).
4. Retirer la destination `eso-drill` de `k8s/bootstrap/argocd-root/infrastructure-project.yaml` (sauf si D1 est actif).
5. (L'exemption `kube-ops.io/drill-expect-forbidden` du test a déjà été retirée par la PR de correctif.)
6. `git grep -nE 'eso-drill|oidc-eso-drill' -- k8s` ne doit plus rien renvoyer (hors exemption du test).
7. `just check`, `kustomize build --enable-helm k8s/infrastructure/controllers`, `kustomize build --enable-helm k8s/infrastructure/auth`.

Effet au merge : Argo élague (`prune`) le namespace `eso-drill` et ses objets ; les ExternalSecret `oidc-eso-drill` et le Password sont élagués dans `auth`. Le Secret `oidc-eso-drill` (source, `Orphan`) **survit** à la suppression de son ExternalSecret : sa suppression est hors de `scripts/kubectl-rw.sh` (politique `agent-operator-guard`), donc **MANDAT** de l'opérateur : `kubectl delete secret -n auth oidc-eso-drill` (et `oidc-eso-drill-r2` n'existe pas comme Secret : le `target.name` est resté `oidc-eso-drill`). À consigner. Vérifier ensuite avec `kubectl-ro get ns eso-drill` (`NotFound`) et `get externalsecret -A | grep eso-drill` (vide).
