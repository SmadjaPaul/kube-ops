# Spécification : migration des secrets internes vers la génération dans le cluster

> **Statut :** SPÉCIFICATION (prête à implémenter, lot par lot). Date : 2026-11-20.
> **Lecteur visé :** un agent de développement sans contexte. Chaque lot est autonome : lire §1, §2, §4, puis le lot.
> **Autorité :** homelab-infra `docs/decisions.md` > ce document. Paul a validé les décisions de `docs/architecture/secrets-simplification-study.md` (§11) : amender D-2026-11-18-01 règle 6 ; migrer les secrets existants seulement quand l'app est modifiée ; réutiliser par défaut les jetons externes existants ; Crossplane différé.
> **Complète :** l'étude (`secrets-simplification-study.md`) et homelab-infra `docs/architecture/secret-store-decision.md` §11 (option B « génération K8s + distribution limitée »).
> **Preuves :** `STATIC`. Lecture du code de kube-ops `origin/main` `d0c62ed` et homelab-infra `origin/main` `a945db2f`, du code ESO `v2.6.0` (`pkg/controllers/externalsecret/externalsecret_controller.go`) et de la documentation CloudNativePG (`docs/src/declarative_role_management.md`, `docs/src/recovery.md`). Aucune valeur de secret lue, aucun appel au cluster, aucun appel Doppler.

## 1. Règles non négociables (tous les lots)

1. **Aucune valeur de secret** dans un commit, une PR, un log, une sortie d'outil ou un rapport. Preuves acceptées : statut ESO, conditions CNPG, âge et taille d'un Secret (`kubectl-ro get secret` sans `-o`), résultat fonctionnel (connexion réussie), ou empreinte SHA-256 tronquée à 12 caractères calculée **dans le cluster** par un Job (jamais de valeur lue par l'agent).
2. **Pas de migration en masse.** Une app par PR. Les secrets existants migrent seulement quand l'app est modifiée pour une autre raison, ou dans un lot de ce document.
3. **Jamais de rotation destructrice sans preuve.** Toute migration d'un secret existant est une rotation (§2, fait F3). Elle exige une preuve `RUNTIME` du retour à la normale, consignée dans la PR, avant toute suppression côté Doppler ou OpenTofu.
4. **Ne pas toucher aux clés de type T6 (chiffrement de données) ni T7 (racines)** : pas de générateur, pas de copie, pas de renommage, pas de suppression. Cette interdiction tient jusqu'à ce que la politique de sauvegarde du §3 soit en place (décision écrite et drill `PASS`). Après, elles restent quand même dans Doppler (§3).
5. **Pas de nouveau composant.** ESO 2.6.0, Kyverno 1.18.1, Reloader, CNPG et Velero sont déjà là. Aucun nouveau contrôleur, aucun nouveau bucket.
6. **Écritures runtime** : seulement par GitOps (merge → Argo CD). L'agent observe par `scripts/kubectl-ro.sh`. `scripts/kubectl-rw.sh` ne peut ni supprimer un Secret ni un ExternalSecret (politique `agent-operator-guard`) : toute étape qui l'exige est marquée **MANDAT** et revient à Paul.
7. Chaque PR reste en **draft** jusqu'à `just check` vert et critères d'acceptation remplis. Pas de merge d'un lot N+1 avant les preuves `RUNTIME` du lot N.

## 2. Faits vérifiés dont dépend la conception

| # | Fait | Source | Conséquence |
| --- | --- | --- | --- |
| F1 | `CreatedOnce` : `shouldRefresh` renvoie vrai seulement si `status.syncedResourceVersion` ou `status.refreshTime` est vide. Un changement de spec ne déclenche rien. | ESO v2.6.0, `externalsecret_controller.go`, `shouldRefresh` | La valeur ne tourne jamais en régime normal. Ajouter une clé à un ExternalSecret `CreatedOnce` existant n'a aucun effet (drift silencieux). |
| F2 | `creationPolicy: Orphan` : `isSecretValid` renvoie vrai sans autre contrôle. Si le Secret est supprimé alors que le statut est rempli, **il n'est pas recréé**. Avec `Owner`, il est recréé avec une **nouvelle** valeur. | idem, `isSecretValid` ; homelab-infra `secret-store-decision.md` §11.4 | `Orphan` rend une perte visible (échec), au lieu d'une rotation silencieuse. Il faut une alerte (lot 0). |
| F3 | Un ExternalSecret **neuf** (statut vide) appelle le générateur et **crée ou met à jour** le Secret cible, même s'il existe déjà (branches `Orphan` et `Owner` : « if the secret exists, we should update it »). | idem, `Reconcile` | (a) Migrer un secret existant vers un générateur = **rotation**. (b) Une restauration Velero d'un Secret généré est **écrasée** dès qu'ESO réconcilie un ExternalSecret sans statut (Velero ne restaure pas le statut par défaut). (c) Renommer l'ExternalSecret source (même `target.name`) = rotation propre par GitOps. |
| F4 | Le provider ESO `kubernetes` lit par `Get` sur le nom : `get` sur des `resourceNames` suffit. La validation du store cherche `secrets`/`get` sans regarder `resourceNames`. | homelab-infra `secret-store-decision.md` §11.4.1 (code ESO v2.6.0 `providers/v1/kubernetes`) | RBAC minimal possible. **Attention :** un Role avec `resourceNames: []` donne accès à **tous** les Secrets du namespace : liste jamais vide (sentinelle, lot 0). |
| F5 | CNPG `managed.roles` + `passwordSecret` : le `resourceVersion` du Secret est suivi dans la condition `PasswordSecretChange` ; un changement réapplique le mot de passe ; avec le label `cnpg.io/reload`, immédiatement. | CNPG `declarative_role_management.md` | Rotation d'un rôle `pg-shared-homelab` sans geste. Après restauration (statut vide), la réapplication au premier passage est **attendue mais non documentée** : à prouver (lot 1). |
| F6 | `bootstrap.recovery` : les rôles restent ceux de la sauvegarde ; après promotion, le mot de passe de l'owner est remplacé par celui du Secret fourni ou généré. L'opérateur ne sauvegarde pas les Secrets. | CNPG `recovery.md` | Barman ne sauvegarde **aucun** Secret. Les bases dédiées (`<cluster>-app` généré par CNPG) sont jetables côté mot de passe. |
| F7 | Velero sauvegarde les Secrets de 29 plannings, dont `daily-auth` et `daily-databases` (ajoutés par #1643, le 20/11). Les manifestes (Secrets compris) vont dans `homelab-backup-velero/velero/` sur R2. Seules les données de volumes (Kopia) sont chiffrées par le mot de passe de dépôt ; les manifestes ne sont chiffrés que côté serveur par R2. | `k8s/infrastructure/controllers/velero/` | Une copie des Secrets existe déjà sur R2, lisible par quiconque lit ce bucket. Elle ne sert **pas** à restaurer un secret généré (F3). Pas de nouveau backup S3 à créer. |
| F8 | Le contrat statique `repo-contract-externalsecret-contract` exige `ClusterSecretStore doppler-cluster` et `refreshInterval: 1h` pour **tout** ExternalSecret. `factory-platform-postgresql-source` (générateur) est déjà dans `policy/baseline.tsv`. | `policy/static/repo-contract.yaml`, `policy/baseline.tsv` | Lot 0 doit amender ce contrat, sinon chaque nouveau générateur casse `just check` (cliquet). |
| F9 | ESO n'a pas de ServiceMonitor (`serviceMonitor.enabled: false`) et aucune alerte ExternalSecret n'existe dans `k8s/`. | `k8s/infrastructure/controllers/external-secrets/values.yaml` | Avec `Orphan`, une perte serait silencieuse côté monitoring. Lot 0 ajoute métriques et alerte. |
| F10 | `envFrom` d'Authentik : un Secret absent et non `optional` empêche le démarrage des pods Authentik (SSO de tout le homelab). | `k8s/infrastructure/auth/authentik/values.yaml`, `secret-store-decision.md` §11.5 | Les sources OIDC générées sont référencées avec `optional: true`. |

## 3. Politique de sauvegarde et de jetabilité

Question de Paul : sauvegarder ces secrets sur S3, ou les considérer jetables parce qu'ils peuvent être tournés ?

### 3.1 Par type

« Perte » = le Secret disparaît (cluster reconstruit à blanc comme OKE, etcd perdu, ou restauration Velero). « Régénération » = ESO produit une nouvelle valeur (F3).

| Type | Perte du Secret généré | Régénération | Classe |
| --- | --- | --- | --- |
| **T1** mot de passe de rôle `pg-shared-homelab` | Cluster neuf : l'ExternalSecret neuf génère une valeur ; CNPG l'applique au rôle de la base restaurée par Barman (F5, F6) ; l'app relit sa copie. Perte isolée (Secret supprimé, statut présent) : pas recréé (F2), CNPG ne peut plus appliquer, échec visible. | Pas de perte de données. Coupure de quelques minutes : CNPG applique le mot de passe immédiatement (`cnpg.io/reload`), mais la copie de l'app suit en ≤ 1 h (`refreshInterval`), puis Reloader redémarre l'app. | **JETABLE**, sous réserve de la preuve F5 après restauration (lot 1). Perte isolée : **RÉGÉNÉRABLE AVEC GESTE** (renommer l'ExternalSecret source). |
| **T2** base CNPG dédiée (`<cluster>-app` généré par CNPG) | CNPG régénère et applique après promotion (F6). | idem | **JETABLE**. Rien à migrer. |
| **T3** secret client OIDC Authentik ↔ app | Cluster neuf : nouvelle valeur. Le blueprint (`!Env`) la réécrit dans la base Authentik restaurée au redémarrage du worker. La copie de l'app suit. Les sessions OIDC tombent, aucune donnée perdue. | Coupure de connexion OIDC jusqu'à la synchronisation des deux côtés (Reloader sur Authentik et sur l'app). Rien à reposer à la main. | **JETABLE** (preuve : pilote, lot 2). Perte isolée : **RÉGÉNÉRABLE AVEC GESTE**. |
| **T4** clé de session, cookie, JWT d'une app | Les utilisateurs se reconnectent. | idem | **JETABLE**, **seulement si** la clé ne chiffre aucune donnée persistée. Au moindre doute, c'est un T6. |
| **T5** secret partagé entre pods d'un même namespace (Redis, MQTT, clé d'API interne) | Tous les consommateurs relisent la nouvelle valeur au redémarrage. | idem, si **chaque** consommateur lit le Secret au démarrage. Si un côté recopie la valeur dans sa base ou son UI : geste. | **JETABLE** si tous les consommateurs lisent le Secret ; sinon **RÉGÉNÉRABLE AVEC GESTE** (reste dans Doppler). |
| **T6** clé de chiffrement de données (`APP_AUTHENTIK_SECRET_KEY` par prudence, `APP_INVOICE_NINJA_APP_KEY`, `APP_SURE_SECRET_KEY_BASE`, `APP_POLYFIN_SECRET_KEY`, `APP_AIOSTREAMS_SECRET_KEY`, `APP_BOOKORBIT_*_ENCRYPTION_KEY`, `APP_SPARKYFITNESS_API_ENCRYPTION_KEY`, `APP_OPENCONNECTOR_ENCRYPTION_KEY`, `APP_MASTRA_FACTORY_CREDENTIAL_ENCRYPTION_KEY`) | Si elle était générée dans le cluster : **données illisibles** (la base restaurée garde les données chiffrées avec l'ancienne clé). Aujourd'hui : ESO la relit dans Doppler, aucune perte. | Destructive. Interdite. | **À SAUVEGARDER** : reste générée par OpenTofu → Doppler, jamais dans le cluster. |
| **T7** racines (mot de passe restic, mot de passe de dépôt Velero/Kopia, secrets machine Talos, jeton ESO → Doppler, amorçage Authentik) | Hors cluster par construction. | Destructive (restic, Velero, Talos) ou bootstrap. | **À SAUVEGARDER** : inchangé (Doppler + fiche papier, D-2026-11-15-10). |
| **T8** jetons d'API externes créés par OpenTofu (`cloudflare_api_token`, Grafana, NetBird, Proxmox, écrivains R2) | ESO les relit dans Doppler. Aucune perte. | `tofu apply -replace` → Doppler → ESO (≤ 1 h). | **JETABLE côté cluster** : la source de vérité est l'état OpenTofu et Doppler. Hors migration. |
| **T9** jetons émis par une app du cluster (Argo CD pour kubechecks, Home Assistant, Matrix, Invoice Ninja) | ESO les relit dans Doppler ; l'app restaurée les reconnaît encore. | Recréer le jeton dans l'app puis dans Doppler. | **RÉGÉNÉRABLE AVEC GESTE**. Hors migration (étude §3.4). |
| **T10** non-secret (URL, hôte, ID de client OIDC) | En Git. | n/a | Git, au fil de l'eau. |

### 3.2 Ce qui sauvegarde déjà

- **Velero → R2** (`homelab-backup-velero`, préfixe `velero/`, 14 jours) : tous les Secrets des namespaces couverts, dont `auth` et `databases` hors objets `cnpg.io/cluster`. Ce n'est pas un chemin de reprise pour les secrets générés (F3), et les manifestes ne sont pas chiffrés côté client (F7).
- **Barman → R2** (`homelab-backup-cnpg`) : données PostgreSQL et empreintes de mots de passe des rôles, **aucun Secret** (F6).
- **État OpenTofu** (`homelab-tfstate`, OCI, versionné) : copie de chaque valeur écrite par un `random_*` + `doppler_secret`. 8 des 10 clés T6 y sont. Exceptions : `APP_OPENCONNECTOR_ENCRYPTION_KEY` et `APP_MASTRA_FACTORY_CREDENTIAL_ENCRYPTION_KEY` ne sont gérées par aucune root (`git grep` vide dans `terraform/`) : leur seule copie hors cluster est Doppler.
- **Fiche papier** (D-2026-11-15-10) : racines restic, Velero et Talos.

### 3.3 Décision recommandée

1. **Secrets générés (T1, T3, T4, T5) : jetables, aucun backup.** On ne crée pas de backup S3 pour eux. Il serait inutile : ESO écrase toute valeur restaurée (F3). La fiabilité vient de la régénération prouvée, pas d'une copie.
2. **T6 et T7 : Doppler reste la source de vérité, sans nouveau mécanisme.** Ils ont déjà deux copies hors cluster indépendantes : Doppler et l'état OpenTofu versionné (plus la fiche papier pour T7). Un export chiffré (age ou SOPS) vers R2 par tâche planifiée ajouterait une racine (la clé age), un jeton Doppler en lecture et un écrivain R2, pour des valeurs qui ne changent jamais (`prevent_destroy`, `ignore_changes`). Rejeté.
3. **Combler le seul trou réel :** importer `APP_OPENCONNECTOR_ENCRYPTION_KEY` et `APP_MASTRA_FACTORY_CREDENTIAL_ENCRYPTION_KEY` dans une root OpenTofu (`import` + `doppler_secret` avec `prevent_destroy` et `ignore_changes = [value]`). Elles auront ainsi une deuxième copie dans l'état. C'est une PR homelab-infra (PR H2, §6). Sinon, Paul les reporte sur sa fiche.
4. **Règle pour toute nouvelle app :** une clé qui chiffre des données est T6. Elle naît dans OpenTofu (`random_bytes` → `doppler_secret`, `prevent_destroy`), jamais par un générateur ESO. Le test du lot 0 refuse un générateur dont la clé ressemble à une clé de chiffrement.
5. **Hors périmètre, à signaler :** les manifestes Velero sur R2 contiennent en clair les Secrets synchronisés depuis Doppler, T6 compris. Un durcissement possible est le SSE-C du plugin AWS (`customerKeyEncryptionFile`), mais il ajoute une racine. Ticket séparé ; non bloquant pour cette migration.
6. **Coût :** 0 €. Aucun objet R2 nouveau ; budget plateforme inchangé.

### 3.4 Drills qui le prouvent

| Drill | Lot | Prouve | Critère `PASS` |
| --- | --- | --- | --- |
| D0 `CreatedOnce` | 0 | F1, F3(c), F4, RBAC négatif | §5, lot 0 |
| D1 rotation de rôle | 1 | F5 en rotation | Job de connexion `Succeeded` avant et après rotation ; message de `PasswordSecretChange` changé |
| D1b restauration Barman + Secret neuf | 1 (avant toute donnée réelle dans `pg-shared-homelab`) | F5 après restauration (cas « cluster reconstruit ») | Cluster temporaire restauré depuis R2, rôle géré avec un Secret **neuf**, connexion réussie. Outil : `scripts/pg-shared-app-restore-proof.sh`, exécution sous **MANDAT** |
| D2 rotation OIDC | 2 | T3 jetable | Connexion OIDC réussie avant, puis après rotation (renommage de la source) |
| D6 reprise d'une clé T6 | après H2 | T6 récupérable hors cluster | Restauration en îlot d'une app à données chiffrées (modèle : `docs/operations/plt-221-sparkyfitness-r2-restore-drill.md`) avec la clé issue de Doppler ; données déchiffrées. Paul confirme que la valeur est aussi lisible dans l'état OpenTofu (`tofu state show`, jamais par un agent). |

## 4. Taxonomie cible et motifs de manifestes

### 4.1 Tableau de référence

| Type | Où naît la valeur | Nom de la source | Copie vers l'app | Reste dans Doppler |
| --- | --- | --- | --- | --- |
| T1 | `Password` + ExternalSecret dans `databases` | `pg-<ns>` (Secret, ExternalSecret, Password) ; rôle et base `<app>` | ExternalSecret `<app>-db` dans `<ns>`, store `k8s-databases` | rien |
| T2 | CNPG | `<cluster>-app` | aucune (même namespace) | rien |
| T3 | `Password` + ExternalSecret dans `auth` | `oidc-<ns>` ; clé `<CLIENT_ID_UPPER>_OIDC_CLIENT_SECRET` | ExternalSecret `<app>-oidc` dans `<ns>`, store `k8s-auth` | rien ; l'ID de client passe en littéral Git |
| T4 | `Password` + ExternalSecret dans `<ns>` | `<app>-<usage>` (ex. `searxng-session`) | aucune | rien |
| T5 | idem T4 | `<app>-<usage>` | aucune (même namespace) | rien si tous les consommateurs lisent le Secret |
| T6 | OpenTofu `random_bytes` → `doppler_secret` | `APP_<APP>_<USAGE>_KEY` | ExternalSecret `doppler-cluster` | **oui** |
| T7 | OpenTofu ou Paul | inchangé | inchangé | **oui** |
| T8 | OpenTofu (réutilisation par défaut) | inchangé | ExternalSecret `doppler-cluster` | **oui** |
| T9 | l'app | inchangé | ExternalSecret `doppler-cluster` | **oui** |
| T10 | Git | n/a | littéral dans `target.template.data` ou ConfigMap | non |

`<ns>` est le namespace consommateur exact (ex. `rustical-pilot`). Plusieurs secrets du même type pour un namespace : suffixe `--<usage>` (ex. `oidc-matrix--mas`). Toute source porte l'annotation `kube-ops.io/secret-class: T1|T3|T4|T5`.

### 4.2 Source générée (T1, T3, T4, T5)

```yaml
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata: {name: oidc-NS, namespace: auth}
spec: {length: 48, digits: 10, symbols: 0, allowRepeat: true}   # pas de symbole : sûr dans une URL ou un DSN
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: oidc-NS                 # rotation : renommer en oidc-NS-r2, même target.name (F3)
  namespace: auth
  annotations: {kube-ops.io/secret-class: T3}
spec:
  refreshPolicy: CreatedOnce
  target:
    name: oidc-NS
    creationPolicy: Orphan      # survit à la suppression de l'ExternalSecret ; perte = échec visible (F2)
    template:
      engineVersion: v2
      data:
        CLIENTID_OIDC_CLIENT_SECRET: "{{ .password }}"   # clé unique dans l'envFrom d'Authentik
  dataFrom:
    - sourceRef:
        generatorRef: {apiVersion: generators.external-secrets.io/v1alpha1, kind: Password, name: oidc-NS}
```

T1 : même forme dans `databases`, nom `pg-NS`, `template.type: kubernetes.io/basic-auth`, `template.metadata.labels: {cnpg.io/reload: "true"}`, `data: {username: APP, password: "{{ .password }}"}`. Modèle existant : `k8s/applications/platform/factory-platform/database-source-credentials.yaml`.

### 4.3 Stores `k8s-auth` et `k8s-databases` (lot 0)

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata: {name: k8s-auth}
spec:
  provider:
    kubernetes:
      remoteNamespace: auth
      server:
        url: https://kubernetes.default.svc
        caProvider: {type: ConfigMap, name: kube-root-ca.crt, key: ca.crt, namespace: external-secrets}
      auth:
        serviceAccount: {name: eso-k8s-auth-reader, namespace: external-secrets}
```

`k8s-databases` : identique, `remoteNamespace: databases`, SA `eso-k8s-databases-reader`. ServiceAccounts dans `external-secrets` avec `automountServiceAccountToken: false` (ESO utilise TokenRequest).

RBAC, **dans le namespace source** (fichier à côté des sources, pour que l'ajout d'une app touche un seul dossier) :

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: eso-k8s-auth-reader, namespace: auth}
rules:
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get]
    resourceNames:
      - eso-k8s-sentinel-none   # JAMAIS retirer : une liste vide donnerait tous les Secrets (F4)
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: eso-k8s-auth-reader, namespace: auth}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: eso-k8s-auth-reader}
subjects:
  - {kind: ServiceAccount, name: eso-k8s-auth-reader, namespace: external-secrets}
```

### 4.4 Copie dans le namespace de l'app

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: rustical-oidc, namespace: rustical-pilot}
spec:
  refreshInterval: 1h
  secretStoreRef: {kind: ClusterSecretStore, name: k8s-auth}
  target:
    name: rustical-oidc
    creationPolicy: Owner        # une copie se reconstruit depuis la source
    template:
      engineVersion: v2
      data:
        RUSTICAL_OIDC__CLIENT_ID: rustical          # T10 : littéral Git
        RUSTICAL_OIDC__CLIENT_SECRET: "{{ .client_secret }}"
  data:
    - secretKey: client_secret
      remoteRef: {key: oidc-rustical-pilot, property: RUSTICAL_OIDC_CLIENT_SECRET}
```

Le Deployment consommateur porte `secret.reloader.stakater.com/reload: <nom de la copie>`.

### 4.5 Garde-fou anti-lecture croisée (trois couches)

1. **RBAC** : le SA du store ne lit que les noms listés (§4.3). Protège `authentik-core-secrets` et les Secrets CNPG.
2. **Admission Kyverno** (nouveau fichier `k8s/infrastructure/security/policies/eso-k8s-store-guard.yaml`) : `ValidatingPolicy`, `validationActions: [Deny]`, `failurePolicy: Ignore`. `Fail` ferait de Kyverno un point de panne pour **tous** les ExternalSecret ; Git reste la seule voie d'écriture et la couche 3 bloque en CI. Règle, pour un ExternalSecret dont `spec.secretStoreRef.name` vaut `k8s-auth` ou `k8s-databases` :
   - `secretStoreRef.kind == 'ClusterSecretStore'` ;
   - pas de `dataFrom` ; aucun `data[].sourceRef` ;
   - chaque `data[].remoteRef.key` vaut `P + ns` ou commence par `P + ns + '--'`, avec `P = 'oidc-'` (k8s-auth) ou `'pg-'` (k8s-databases) et `ns = request.namespace` (repli : `object.metadata.namespace`, à vérifier avec `kyverno test`).
3. **Contrat statique** (`policy/static/repo-contract.yaml`, rejoué par `scripts/policy-check.sh`) : même règle sur `object.metadata.namespace`, nommée `repo-contract-eso-k8s-store-own-namespace`.

## 5. Lots

Ordre : **H1** (décision) en parallèle de **0** ; **1** et **2** exigent H1 mergée et le lot 0 prouvé ; **3** exige 1 et 2 prouvés. Une PR draft par lot, branche `claude/secrets-lot-N-<slug>`, titre `feat(secrets): lot N — <objet>`.

### Lot 0 — briques communes

**Fichiers**

| Chemin | Action |
| --- | --- |
| `k8s/infrastructure/controllers/external-secrets/k8s-stores.yaml` | créer : 2 `ClusterSecretStore`, 2 `ServiceAccount` (§4.3) |
| `k8s/infrastructure/controllers/external-secrets/kustomization.yaml` | ajouter `k8s-stores.yaml` |
| `k8s/infrastructure/controllers/external-secrets/values.yaml` | `serviceMonitor.enabled: true` (vérifier le label attendu par le Prometheus homelab, comme les autres ServiceMonitor) |
| `k8s/infrastructure/controllers/external-secrets/prometheusrule.yaml` | créer : alerte `ExternalSecretNotReady` (`externalsecret_status_condition{condition="Ready",status="False"} == 1` pendant 15 min ; vérifier le nom exact de la métrique sur `/metrics` d'ESO v2.6.0) |
| `k8s/infrastructure/auth/authentik/extra/eso-k8s-reader-rbac.yaml` + `extra/kustomization.yml` | créer Role et RoleBinding (`auth`), sentinelle seule |
| `k8s/infrastructure/database/pg-shared-homelab/eso-k8s-reader-rbac.yaml` + `kustomization.yaml` | créer Role et RoleBinding (`databases`), sentinelle seule |
| `k8s/infrastructure/security/policies/eso-k8s-store-guard.yaml` + `kustomization.yaml` | créer la politique d'admission (§4.5.2) |
| `policy/static/repo-contract.yaml` | amender `repo-contract-externalsecret-contract` : accepter (A) `doppler-cluster` + 1h (inchangé), (B) `k8s-auth`/`k8s-databases` + `ClusterSecretStore` + 1h, (C) source générée : pas de `secretStoreRef`, pas de `data`, tous les `dataFrom[].sourceRef.generatorRef`, `refreshPolicy: CreatedOnce`, `target.creationPolicy: Orphan`. Ajouter `repo-contract-eso-k8s-store-own-namespace` (§4.5.3) |
| `tests/policies/gen-tests.py` | cas pass/fail pour (A), (B), (C) et pour la règle de namespace (`oidc-<ns>`, `oidc-<ns>--x` pass ; `oidc-autre`, `dataFrom`, `kind: SecretStore` fail) ; régénérer `tests/policies/*` |
| `scripts/policy-check.sh` | ajouter `eso-k8s-store-guard.yaml` à `POLICIES` si la politique d'admission est testée par ce script |
| `policy/baseline.tsv` | retirer l'entrée `factory-platform-postgresql-source` devenue conforme (cliquet) ; ne rien ajouter |
| `tests/harness/eso-generated-secrets-contract-test.sh` + `scripts/check-bash-tests.list` | créer (voir ci-dessous) |
| `docs/operations/secrets-generated-runbook.md` | créer : rotation par renommage, perte (MANDAT), ajout d'une app, lecture des preuves |

**Test statique `eso-generated-secrets-contract-test.sh`** (bash, fixtures en `mktemp`, mêmes conventions que `tests/harness/pg-shared-homelab-isolation-guard-test.sh`), sur le rendu de `k8s/` :
1. Tout ExternalSecret qui référence un `generatorRef` a `refreshPolicy: CreatedOnce`.
2. Toute source dans `auth` ou `databases` a `creationPolicy: Orphan` et `kube-ops.io/secret-class`.
3. Les Roles liés à `eso-k8s-*-reader` : `verbs == [get]`, `resources == [secrets]`, `resourceNames` non vide, contenant `eso-k8s-sentinel-none`, et autres noms conformes à `^oidc-[a-z0-9-]+$` (auth) ou `^pg-[a-z0-9-]+$` (databases).
4. Chaque `remoteRef.key` lu par `k8s-auth`/`k8s-databases` figure dans les `resourceNames` du Role et a une source (ExternalSecret dont `target.name` est égal) dans le namespace source.
5. Refus d'un générateur dont une clé de template correspond à `ENCRYPT|KEY_BASE|APP_KEY|MASTER_KEY|RESTIC|REPOSITORY_PASSWORD|SECRET_KEY` (T6), sauf `kube-ops.io/secret-class: T4` **et** annotation `kube-ops.io/not-data-key: "<justification>"`. `grafana-admin-credentials` et `factory-platform-postgresql-source` passent.
6. Cas négatifs en fixtures pour chaque règle (le test doit échouer sur chacun).

**Drill D0 (RUNTIME)** — ressources dans `k8s/infrastructure/controllers/external-secrets/drills/createdonce/` (namespace `eso-drill`, label `kube-ops.io/drill: "true"`), branchées dans la PR du lot 0 puis retirées par une PR de nettoyage :
- source `oidc-eso-drill` dans `auth` (ajoutée aux `resourceNames`) ; copie `eso-drill-oidc` dans `eso-drill` ;
- un ExternalSecret `eso-drill-forbidden` qui lit `oidc-eso-drill--forbidden` : conforme à Kyverno, **absent** du Role ;
- un Job hook `PostSync` dans `eso-drill` qui monte la copie et écrit seulement `FP=<12 premiers hex du SHA-256>`.

Preuves attendues, consignées dans `docs/operations/secrets-migration-evidence.md` (une section par lot) :
1. `kubectl-ro get clustersecretstore k8s-auth k8s-databases` : `Ready=True`.
2. `kubectl-ro get externalsecret -n auth oidc-eso-drill -o yaml` : `Ready`, `refreshTime` rempli ; `-n eso-drill eso-drill-oidc` : `Ready`.
3. `eso-drill-forbidden` : `SecretSyncedError`, message 403 `forbidden` (couche RBAC prouvée).
4. Synchronisation Argo forcée sans changement (ou redémarrage d'ESO par `kubectl-rw.sh restart external-secrets deployment/external-secrets`, si le namespace est dans `scope.tsv`) : le `refreshTime` de la source ne change pas, l'empreinte du Job est **identique** (F1).
5. Commit de rotation : renommer l'ExternalSecret source `oidc-eso-drill` → `oidc-eso-drill-r2`, même `target.name`. Après `refreshInterval` (ou renommage de la copie dans un second commit) : empreinte **différente**, âge du Secret source inchangé (mis à jour, pas recréé) (F3c).
6. Alerte : `ExternalSecretNotReady` firing pour `eso-drill-forbidden` dans Prometheus (`kubectl-ro` sur l'API Prometheus, comme `just backup-audit`).
7. Couche Kyverno négative : `kyverno test` statique seulement (aucun refus runtime faisable par l'agent). Test runtime optionnel par Paul (`kubectl apply --dry-run=server`) : **MANDAT**.

**Critères d'acceptation (PR lot 0)** : `just check` vert ; aucune entrée ajoutée à `policy/baseline.tsv` ; nouveau test présent dans `scripts/check-bash-tests.list` et échouant sur ses fixtures négatives ; aucun ExternalSecret applicatif modifié ; preuves 1 à 6 consignées après merge ; PR de nettoyage du drill ouverte (namespace `eso-drill` et nom `oidc-eso-drill*` retirés du Role, sentinelle conservée).

### Lot 1 — `pg-shared-homelab`

Préconditions : H1 mergée ; lot 0 `PASS` ; `kubectl-ro get cluster -n databases pg-shared-homelab` : `Cluster in healthy state`.

**Fichiers**

| Chemin | Action |
| --- | --- |
| `k8s/infrastructure/database/pg-shared-homelab/app-database.example.tmpl` | remplacer l'étape 2 (« key created by Paul ») par la source T1 `pg-APP_NS` (§4.2) ; `passwordSecret.name: pg-APP_NS` à l'étape 1 ; Job d'isolation (étape 3b) : `secretKeyRef.name: pg-APP_NS` ; ajouter l'étape « ajouter `pg-APP_NS` aux `resourceNames` de `eso-k8s-reader-rbac.yaml` » et l'étape « copie `<app>-db` dans le namespace de l'app (store `k8s-databases`, host/port/dbname en littéraux) + annotation Reloader ». Retirer toute mention de Doppler pour le mot de passe |
| `k8s/infrastructure/database/pg-shared-homelab/cluster.yaml` | drill seulement : rôle `eso_drill` (`login: true`, sans `Database`, `passwordSecret: pg-eso-drill`) |
| `k8s/infrastructure/database/pg-shared-homelab/eso-drill-role.yaml` | drill : source `pg-eso-drill` + `resourceNames` + `CiliumNetworkPolicy` d'entrée depuis `eso-drill` |
| `k8s/infrastructure/controllers/external-secrets/drills/createdonce/` | copie `eso-drill-db` + Job `PostSync` `psql -c 'select 1'` sur la base `postgres` (variables `PG*` depuis la copie, `PGSSLMODE=require`) |
| `tests/harness/pg-shared-homelab-isolation-guard-test.sh` | adapter si le nom du Secret apparaît dans ses fixtures ; le nom du Job reste `pg-shared-homelab-<db>-isolation` |

**Preuves RUNTIME (D1)** : Job de connexion `Succeeded` ; `kubectl-ro get cluster -n databases pg-shared-homelab -o yaml` : condition `PasswordSecretChange` présente. Commit de rotation (renommer la source en `pg-eso-drill-r2`) : le message de la condition change (nouveau `resourceVersion`) ; puis renommer la copie dans un second commit ; le Job relancé passe. Nettoyage : `ensure: absent` sur `eso_drill` puis retrait (deux commits ; CNPG doit supprimer le rôle avant que le bloc disparaisse).

**D1b** (restauration Barman + Secret neuf) : obligatoire **avant la première donnée réelle** dans `pg-shared-homelab` et avant de migrer une base existante. Elle ne bloque pas le merge du lot 1. Exécution sous **MANDAT** (`docs/operations/pg-shared-app-restore-drill.md`).

**Critères d'acceptation** : `just check` vert ; le template ne contient plus « created by Paul » ni `doppler-cluster` pour le mot de passe de rôle ; un rendu d'exemple (fixture du test lot 0) passe les deux contrats ; preuves D1 consignées ; PR de nettoyage du rôle `eso_drill` ouverte.

### Lot 2 — pilote OIDC : RustiCal (`rustical-pilot`)

**Choix du pilote.** Candidats lus dans le dépôt : `rustical-pilot`, `polyfin`, `bookorbit`, `sparkyfitness` (optionnelle), `vikunja`, `mealie`, `librechat` (dormante), une nouvelle app.

- **RustiCal est retenu.** Il tourne déjà (`k8s/applications/platform/kustomization.yaml`), n'a que des **données synthétiques** (`rustical-pilot/README.md` : « No family data »), aucune base PostgreSQL (SQLite) et un seul secret interne : le client OIDC. Une rotation n'y coûte qu'une reconnexion. Son secret Authentik s'appelle déjà `RUSTICAL_OIDC_CLIENT_SECRET` : le blueprint `apps-rustical.yaml` ne change pas, ce qui isole la mécanique ESO. Son contrat `PILOT_GO` exige déjà une preuve de connexion OIDC à deux utilisateurs. Enfin, il est déjà généré par OpenTofu (`phase3_oidc_clients.rustical`), ce qui exerce aussi la sortie côté homelab-infra.
- Rejetés : `polyfin` et `bookorbit` portent des clés T6 ; `vikunja` et `mealie` ont des utilisateurs familiaux ; `sparkyfitness` et `librechat` ne sont pas actives ; une nouvelle app mélangerait deux preuves (l'app et le patron).

**Fichiers**

| Chemin | Action |
| --- | --- |
| `k8s/infrastructure/auth/authentik/extra/oidc-rustical-pilot.yaml` | créer : source T3 `oidc-rustical-pilot`, clé `RUSTICAL_OIDC_CLIENT_SECRET` |
| `k8s/infrastructure/auth/authentik/extra/rustical-oidc-externalsecret.yaml` | supprimer (ancien ExternalSecret Doppler `authentik-blueprint-rustical`) |
| `k8s/infrastructure/auth/authentik/extra/kustomization.yml` | remplacer l'entrée |
| `k8s/infrastructure/auth/authentik/extra/eso-k8s-reader-rbac.yaml` | ajouter `oidc-rustical-pilot` |
| `k8s/infrastructure/auth/authentik/values.yaml` | `envFrom` : `authentik-blueprint-rustical` → `oidc-rustical-pilot` avec `optional: true` (F10) ; même remplacement dans `secret.reloader.stakater.com/reload` |
| `k8s/optional/rustical/external-secret.yaml` | réécrire en copie §4.4 (store `k8s-auth`, ID de client littéral). Vérifier d'abord que `git grep -n "optional/rustical" -- k8s` ne renvoie que `rustical-pilot` ; sinon, faire un patch dans l'overlay `k8s/applications/platform/rustical-pilot/kustomization.yaml` |
| `k8s/optional/rustical/deployment.yaml` | annotation `secret.reloader.stakater.com/reload: rustical-oidc` sur le Deployment |

**Preuves RUNTIME (D2)** :
1. Sources et copie `Ready` (`kubectl-ro get externalsecret -n auth oidc-rustical-pilot`, `-n rustical-pilot rustical-oidc`).
2. Pods Authentik redémarrés après le merge (Reloader) et `Running` ; aucune régression du SSO : `tests/e2e/specs/authentik.spec.ts` passe.
3. Connexion OIDC réussie sur `https://calendar.smadja.dev` avec l'utilisateur QA (`qa-e2e-user`), puis une opération CalDAV synthétique (contrat `PILOT_GO`).
4. Rotation : commit qui renomme la source en `oidc-rustical-pilot-r2`, puis la copie ; Authentik et RustiCal redémarrés par Reloader ; nouvelle connexion OIDC réussie.
5. Aucune erreur de blueprint pour `Apps - RustiCal` dans les journaux du worker Authentik (`kubectl-ro logs`).

**Critères d'acceptation** : `just check` vert ; plus aucune référence à `APP_RUSTICAL_OIDC_*` dans `k8s/` ; preuves 1 à 5 consignées ; PR homelab-infra **H3** ouverte en draft (sortie des clés Doppler), à merger au plus tôt 7 jours après la preuve 4.

**Repli** : `git revert` de la PR. L'ExternalSecret Doppler revient avec l'ancienne valeur, toujours présente dans Doppler tant que H3 n'est pas mergée ; Authentik et l'app la relisent.

### Lot 3 — scaffolding et skills

**Fichiers**

| Chemin | Action |
| --- | --- |
| `scripts/scaffold-app-secrets.sh` | créer. Usage : `APP --namespace NS [--oidc CLIENT_ID] [--pg-shared] [--local-key USAGE]... [--data-key USAGE]... [--external cloudflare-dns\|r2-writer] [--write]`. Par défaut, dry-run : liste les fichiers et les insertions. `--write` écrit les motifs §4.2 à §4.4, ajoute les noms aux `resourceNames`, l'entrée `envFrom` (`optional: true`) et la liste Reloader d'Authentik, les étapes du template `pg-shared-homelab`. Refuse si un fichier cible existe (idempotence par refus). `--data-key` n'écrit **aucun** générateur : il imprime la PR homelab-infra à ouvrir (T6, `random_bytes` + `doppler_secret` + `prevent_destroy`) et l'ExternalSecret `doppler-cluster` correspondant. `--external` réutilise `CLOUDFLARE_API_TOKEN` ou l'écrivain R2 existant (décision 3 de l'étude). Aucun appel réseau, aucune valeur |
| `tests/harness/scaffold-app-secrets-test.sh` + `scripts/check-bash-tests.list` | créer : copie du dépôt dans `mktemp`, exécution `--write` pour une app fictive `--oidc --pg-shared --local-key session`, puis rendu `kustomize build` des dossiers touchés, `eso-generated-secrets-contract-test.sh` et `scripts/policy-check.sh` sur le résultat ; cas de refus (fichier existant, `--local-key` nommé comme une clé T6) |
| `.agents/skills/deploy-a-service/SKILL.md` | remplacer « secret `APP_<APP>_OIDC_CLIENT_SECRET` in Doppler » et « store `doppler-cluster` » par la taxonomie §4.1 et l'appel au script ; garder Doppler pour T6 à T9 ; retirer « Doppler values … remain Paul's » pour T1 à T5 |
| `.agents/skills/oidc-integration/SKILL.md` | « Secrets come from Doppler -> ESO » → patron T3 |
| `scripts/scaffold-oke-app.sh` | aucun changement de comportement ; ajouter dans sa sortie l'indication d'appeler `scaffold-app-secrets.sh` |

**Preuve** : `STATIC` suffit (pas de manifeste de production). Critères d'acceptation : `just check` vert ; le test du scaffolding échoue si on supprime l'ajout aux `resourceNames` (mutation vérifiée à la main et notée dans la PR) ; les deux skills ne mentionnent plus Doppler pour T1 à T5.

### Lots suivants — au fil de l'eau

Pour chaque app modifiée pour une autre raison, une PR dédiée :
1. Classer chaque clé de son ExternalSecret Doppler (§3.1). T6, T7, T8 et T9 : ne pas toucher. Doute : T6.
2. T1/T3/T4/T5 : `scaffold-app-secrets.sh`, supprimer les clés correspondantes de l'ExternalSecret Doppler. T10 : littéral en Git.
3. Prévenir que la migration est une rotation (F3) ; choisir une fenêtre si l'app a des utilisateurs.
4. Preuve `RUNTIME` fonctionnelle (connexion, requête) ; puis PR homelab-infra de sortie (`removed { lifecycle { destroy = false } }` pour les `random_*` et `doppler_secret` protégés par `prevent_destroy`), 7 jours après.
5. Ordre conseillé : apps sans utilisateur d'abord. OKE (`k8s/clusters/oracle-a1/external-secrets/`) : mêmes stores dans un lot dédié, après le lot 3 ; le cluster jetable (D-2026-11-18-01) est le terrain naturel de D1b.

## 6. Côté homelab-infra

| PR | Contenu | Quand |
| --- | --- | --- |
| **H1** décision | Nouvelle entrée `D-2026-11-20-xx — Secrets internes générés dans le cluster (amende D-2026-11-18-01 règle 6)` dans `docs/decisions.md`, au format des entrées voisines (citation de Paul, périmètre, exclusions). Texte de la règle : « Doppler pour les secrets externes (T8, T9), les racines (T7) et les clés qui chiffrent des données (T6, générées par OpenTofu). Les secrets internes (T1, T3, T4, T5) sont générés dans le cluster par ESO (`Password`, `CreatedOnce`, `Orphan`), jetables et non sauvegardés. Migration des existants seulement quand l'app est modifiée. » Ajouter `AMENDÉE PAR` sur le titre de D-2026-11-18-01. Mettre à jour `docs/architecture/secret-store-decision.md` §11.5 et §11.6 (Velero couvre désormais `auth` et `databases` ; la copie hors cluster des T1/T3 n'est plus un MANDAT : jetables par décision) | avant le merge des lots 1 et 2 |
| **H2** couverture T6 | Importer `APP_OPENCONNECTOR_ENCRYPTION_KEY` et `APP_MASTRA_FACTORY_CREDENTIAL_ENCRYPTION_KEY` dans la root `doppler` (`import` + `doppler_secret`, `prevent_destroy`, `ignore_changes = [value]`) : plan sans changement de valeur. Ajouter les adresses aux `protected_addresses` ARC | indépendante ; avant D6 |
| **H3** sortie RustiCal | `removed { lifecycle { destroy = false } }` pour `random_password.phase3_oidc_client["rustical"]`, `doppler_secret.cluster_phase3_oidc_client_id["rustical"]` et la ressource du secret client correspondante ; plan : aucune destruction. Les clés Doppler orphelines sont supprimées plus tard, en lot, sous MANDAT | 7 jours après la preuve D2.4 |

## 7. Découpage en PR et critères communs

| PR | Dépôt | Dépend de | Preuve exigée avant merge | Preuve exigée après merge |
| --- | --- | --- | --- | --- |
| H1 | homelab-infra | — | relecture Paul | — |
| 0 | kube-ops | — | `just check`, tests négatifs | D0 (1 à 6) |
| 0-cleanup | kube-ops | D0 `PASS` | `just check` | drill absent du cluster |
| 1 | kube-ops | H1, D0 | `just check` | D1 ; D1b avant toute donnée réelle |
| 2 | kube-ops | H1, D0 | `just check` | D2 (1 à 5) |
| 3 | kube-ops | D1, D2 | `just check`, test du scaffolding | — |
| H2 | homelab-infra | — | plan ARC sans changement de valeur | — |
| H3 | homelab-infra | D2.4 + 7 jours | plan ARC sans destruction | — |

Critères communs à chaque PR : draft ; description avec Objectif, Fichiers, Preuves (niveau `STATIC`/`RUNTIME`, commandes, verdicts, aucune valeur), Repli ; `just check` lancé avec `MISE_TRUSTED_CONFIG_PATHS=<racine du worktree>` (jamais `mise trust`) ; aucun fichier hors de la table du lot ; aucune clé T6/T7 touchée.

## 8. Risques propres à l'implémentation

| Risque | Mitigation |
| --- | --- |
| Role avec `resourceNames` vide (accès à tous les Secrets) | sentinelle obligatoire + test lot 0, règle 3 |
| Argo CD supprime puis recrée un ExternalSecret source (déplacement de dossier, changement d'Application) | rotation involontaire (F3) : jetable pour T1 à T5 par construction ; le test refuse un générateur T6 |
| Ajout d'une clé à une source `CreatedOnce` existante | sans effet (F1) : une clé = une nouvelle source, ou rotation par renommage |
| Copie en retard d'1 h après rotation | renommer la copie dans un second commit (récupération immédiate) |
| `envFrom` Authentik bloquant | `optional: true` pour toute source générée (F10) + alerte `ExternalSecretNotReady` |
| Velero restaure une ancienne valeur puis ESO l'écrase | attendu (F3) ; l'app et le serveur relisent tous deux la nouvelle valeur |
| Contrat statique trop permissif pour (C) | cas `fail` dans `gen-tests.py` : générateur sans `CreatedOnce`, avec `Owner`, mélangé à `data` |
