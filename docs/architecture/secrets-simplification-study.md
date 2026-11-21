# Étude : simplifier la gestion des secrets (homelab et OKE)

> **Statut :** PROPOSÉ (étude, recommandation ; Paul décide). Date : 2026-11-20.
> **Autorité :** homelab-infra `docs/decisions.md` > ce document. Ce document ne change aucune décision.
> **Complète :** homelab-infra `docs/architecture/secret-store-decision.md` (PLT-312, « garder Doppler »). PLT-312 traite le **magasin**. Cette étude traite ce qui **entre** dans le magasin.
> **Preuves :** lecture du code seulement. kube-ops `origin/main` `def0ff7`, homelab-infra `origin/main` `ff063fe6`. Aucune valeur de secret lue. Aucun appel Doppler. Aucun accès au cluster. Les comptes viennent d'un parsing YAML des ExternalSecret (noms de clés `remoteRef` seulement).
> **Niveau de preuve :** `STATIC`. Aucun mécanisme proposé n'est testé sur un cluster.

## 1. Conclusion

1. **Le problème est réel et mesuré.** Les ExternalSecret actifs référencent **161 clés Doppler distinctes**. **67 (42 %) sont des secrets purement internes au cluster** : mots de passe de base, clés de session, secrets OIDC entre Authentik et une app du cluster. **47 (29 %) ne sont pas des secrets** : URL, ports, e-mails, identifiants de client OIDC, ID d'App GitHub. Seules **37 clés (23 %)** sont des jetons de ressources externes. **4 clés (2 %)** sont des racines de chiffrement.
2. **Recommandation :** générer les secrets internes **dans le cluster**, avec les générateurs ESO déjà installés (ESO 2.6.0 : `Password`, `ClusterGenerator`, `refreshPolicy: CreatedOnce`). Les répliquer entre namespaces avec le **provider ESO `kubernetes`**. Une règle Kyverno borne cette réplication. Doppler ne garde que les jetons externes, les racines et les clés qui chiffrent des données.
3. **Pas de Crossplane maintenant.** Les providers Cloudflare et GitHub sont jeunes : aucune release publiée sur leurs dépôts `crossplane-contrib` à la date de l'étude. Il n'existe pas de provider Authentik, Doppler, NetBird ou Proxmox mûr. Pour les ressources externes, le chemin OpenTofu → Doppler par ARC fonctionne déjà sans geste manuel. Il manque seulement un **scaffolding** qui ouvre la PR OpenTofu en même temps que la PR kube-ops.
4. **Gain sur une app type** (base, client OIDC, route, jeton Cloudflare) : de **2 dépôts, 3 PR, 2 apply ARC, 1 geste manuel Doppler et 4 clés Doppler** à **1 PR kube-ops, 0 geste manuel et 0 clé Doppler**. Si un jeton externe nouveau est vraiment nécessaire : 1 PR OpenTofu générée et 1 clé écrite par OpenTofu. Détail au §8.
5. **Décision demandée à Paul :** amender la règle « secrets dans Doppler seulement » (D-2026-11-18-01 règle 6 ; section « IaC » du journal : « Doppler reste l'autorité des secrets »). Nouvelle formulation : « Doppler pour les secrets externes et racines ; les secrets internes sont générés dans le cluster ». Les autres décisions sont au §10.

## 2. Inventaire

### 2.1 Chiffres

| Élément | Valeur | Source |
| --- | --- | --- |
| Documents `ExternalSecret` (hors CRD du chart) | 125, dont 93 actifs (hors `k8s/optional/`, `.dormant`, `.staged`, drills) | parsing YAML de `k8s/` |
| ClusterSecretStore | 1 : `doppler-cluster` (`k8s/infrastructure/controllers/external-secrets/doppler-store.yaml`), jeton `doppler-access-token` posé par `scripts/bootstrap-cluster.sh` | kube-ops |
| Clés Doppler distinctes référencées | 211 au total ; 161 dans les ExternalSecret actifs | parsing `remoteRef.key` |
| Générateurs ESO déjà utilisés | 2 `Password` avec `refreshPolicy: CreatedOnce` : `factory-platform/database-source-credentials.yaml`, `prometheus-stack/grafana-admin-secret.yaml` | kube-ops |
| ExternalSecret actifs entièrement internes ou de configuration | 43 sur 93 | classement §2.2 |
| Clusters CNPG | 23 ; 21 laissent CNPG générer le secret `<cluster>-app` (pas de `initdb.secret`) | kube-ops |
| Ressources `doppler_secret` (OpenTofu) | 142 dans 24 fichiers | homelab-infra `terraform/` |
| Ressources `random_password` / `random_bytes` | 61, dont la plupart pour des secrets internes (`terraform/doppler/generated-app-secrets.tf`, `aiostreams-secrets.tf`) | homelab-infra |
| Jetons d'API créés par OpenTofu | `cloudflare_api_token` ×5 (DNS, opérationnel, Workers AI, R2, partner-commerce), `grafana_cloud_access_policy_token`, `grafana_service_account_token` ×2, `netbird_setup_key` ×2, `proxmox_virtual_environment_user_token` | homelab-infra |
| Câblage Authentik par client OIDC | 1 blueprint + 1 ExternalSecret dans `auth` + 1 ligne `envFrom` + 1 entrée `reloader` dans `values.yaml` + 1 ExternalSecret dans le namespace de l'app + 1 clé Doppler générée par OpenTofu | `k8s/infrastructure/auth/authentik/` |
| Geste manuel documenté | « the key is created by Paul, never in Git » pour chaque base de `pg-shared-homelab` | `k8s/infrastructure/database/pg-shared-homelab/app-database.example.tmpl` |

### 2.2 Classement des 161 clés actives

| Classe | Définition | Clés actives (toutes) | Part |
| --- | --- | --- | --- |
| **(a)** interne | Les deux extrémités sont dans le cluster : base, Redis, MQTT, session, JWT, client OIDC ↔ Authentik, clé partagée entre pods | 59 (80) | 37 % |
| **(a\*)** interne, chiffre des données | Interne, mais sa perte rend des données illisibles : clés de chiffrement applicatives | 8 (12) | 5 % |
| **(a2)** interne, émis par une app | Jeton d'API d'une app du cluster, créé par son API ou son UI : Argo CD, Home Assistant, Matrix, Invoice Ninja | 6 (6) | 4 % |
| **(n)** non secret | URL, hôte, port, e-mail, nom d'utilisateur, ID de client OIDC, ID d'App GitHub | 47 (63) | 29 % |
| **(b)** externe, créable par programme | Cloudflare, R2, Grafana Cloud, NetBird, Proxmox, Migadu, GHCR | 22 (29) | 14 % |
| **(b')** externe, non créable par API | Clés privées d'App GitHub, clés de fournisseurs LLM, OAuth Linear, S3 Hetzner, clé UniFi | 15 (17) | 9 % |
| **(c)** racine | Mot de passe maître restic, mot de passe du dépôt Velero, amorçage Authentik | 4 (4) | 2 % |

S'ajoutent les racines hors ExternalSecret (§6) : jeton ESO → Doppler, jetons Doppler d'IaC dans les environnements GitHub, identités initiales des providers OpenTofu, accès au backend d'état.

Le classement est fait par nom de clé, avec des exceptions relues à la main. Une erreur de classe sur une clé isolée ne change pas les ordres de grandeur.

### 2.3 Cinq exemples par classe

Format : clé Doppler → ExternalSecret (`fichier#nom`), chemins sous `k8s/`.

**(a) interne**
- `APP_VIKUNJA_OIDC_CLIENT_SECRET` → `applications/catalog/vikunja/externalsecret.yaml#vikunja-runtime` et `infrastructure/auth/authentik/extra/secrets.yml#authentik-blueprint-vikunja` : même valeur dans deux namespaces.
- `APP_MQTT_PASSWORD` → `applications/automation/mqtt/externalsecret.yaml#mosquitto-password`.
- `APP_SEARXNG_SECRET` → `applications/catalog/searxng/externalsecret.yaml#searxng-runtime`.
- `APP_KARAKEEP_NEXTAUTH_SECRET` → `applications/ai/karakeep/karakeep-secrets-external.yaml#karakeep-secrets`.
- `APP_SPARKYFITNESS_DB_APP_PASSWORD` → `optional/sparkyfitness/external-secret.yaml#sparkyfitness-appdb`. Généré par `random_password` dans homelab-infra, puis copié dans Doppler.

**(a\*) interne, chiffre des données**
- `APP_AUTHENTIK_SECRET_KEY` → `infrastructure/auth/authentik/extra/secrets.yml#authentik-core-secrets`.
- `APP_SPARKYFITNESS_API_ENCRYPTION_KEY` → `optional/sparkyfitness/external-secret.yaml#sparkyfitness-runtime`.
- `APP_POLYFIN_SECRET_KEY`, `APP_SURE_SECRET_KEY_BASE`, `APP_OPENCONNECTOR_ENCRYPTION_KEY`.

**(a2) interne, émis par une app**
- `APP_HA_MCP_TOKEN` → `applications/automation/hassio/ha-mcp-externalsecret.yaml#ha-mcp-secrets`.
- `APP_MATRIX_FACTORY_BOT_ACCESS_TOKEN`, `APP_INVOICE_NINJA_API_TOKEN`, `ARGOCD_MCP_API_TOKEN`.

**(n) non secret**
- `GRAFANA_CLOUD_PROMETHEUS_URL` → `infrastructure/monitoring/alloy/grafana-cloud-externalsecret.yaml#alloy-grafana-cloud`.
- `MIGADU_SMTP_HOST` → `infrastructure/auth/authentik/extra/smtp-externalsecret.yaml#authentik-smtp-credentials`.
- `R2_S3_ENDPOINT` → `applications/catalog/paperless/database-r2.yaml#paperless-cnpg-r2-credentials`.
- `APP_RUSTICAL_OIDC_CLIENT_ID`, `APP_GITHUB_ARC_INSTALLATION_ID`.

**(b) externe, créable par programme**
- `CLOUDFLARE_API_TOKEN` → `infrastructure/controllers/cert-manager/cert-manager-secrets-external.yaml#cert-manager-secrets`. Créé par `cloudflare_api_token.dns_runtime`.
- `R2_CNPG_WRITER_SECRET_ACCESS_KEY` → `applications/catalog/paperless/database-r2.yaml#paperless-cnpg-r2-credentials`. Créé dans `terraform/grafana-cloud/r2-identities.tf`.
- `GRAFANA_CLOUD_HOMELAB_WRITE_TOKEN` → `infrastructure/monitoring/alloy/grafana-cloud-externalsecret.yaml#alloy-grafana-cloud`.
- `NETBIRD_SETUP_KEY_OKE` → `clusters/oracle-a1/netbird-router/external-secret.yaml#netbird-router-setup-key`.
- `PROXMOX_CSI_TOKEN_SECRET` → `infrastructure/storage/proxmox-csi/externalsecret.yaml#proxmox-csi-plugin`.

**(b') externe, non créable par API**
- `APP_GITHUB_ARC_PRIVATE_KEY` → `optional/github-actions-arc/github-app-secret.yaml#arc-github-app`.
- `APP_MINIMAX_TOKEN_PLAN_API_KEY` → `applications/platform/agentgateway/secrets.yaml#agentgateway-runtime`.
- `HETZNER_S3_SECRET_ACCESS_KEY` → `applications/platform/factory-platform/database-s3-credentials.yaml#cnpg-hetzner-credentials`.
- `EXTERNALDNS_UNIFI_API_KEY` → `infrastructure/network/externaldns-private/externalsecret.yaml#external-dns-unifi-webhook`.
- `APP_MASTRA_FACTORY_LINEAR_CLIENT_SECRET`.

**(c) racine**
- `RESTIC_BACKUP_PASSWORD` → `applications/catalog/paperless/restic-backup/externalsecret.yaml#restic-backup` (D-2026-11-15-10).
- `HETZNER_S3_VELERO_REPOSITORY_PASSWORD` → `infrastructure/controllers/velero/externalsecret.yaml#velero-repo-credentials`.
- `APP_AUTHENTIK_BOOTSTRAP_TOKEN`, `APP_AUTHENTIK_BOOTSTRAP_PASSWORD` → `authentik-core-secrets`.
- Hors ExternalSecret : `doppler-access-token` (namespace `external-secrets`), valeur de `ESO_CLUSTER` posée par `scripts/bootstrap-cluster.sh`.

### 2.4 Pourquoi c'est « chiant » aujourd'hui

- Un secret interne fait **deux allers-retours entre dépôts**. Il est généré par `random_password` dans homelab-infra, écrit dans Doppler par `doppler_secret`, puis relu par ESO dans kube-ops. La PR OpenTofu passe par ARC, et la root `doppler` est protégée (un apply à la fois, D-2026-11-15-13).
- Un client OIDC touche **6 endroits** dans 2 dépôts (§2.1).
- Une base de `pg-shared-homelab` exige une **clé Doppler créée par Paul**.
- 29 % des clés Doppler ne sont pas des secrets. On ne peut ni les relire ni les revoir en PR.
- La règle « Doppler reste l'autorité des secrets » n'est déjà pas tenue au sens strict. Les 61 `random_*` gardent une copie de chaque valeur dans l'état OpenTofu.

## 3. Classe (a) : générer dans le cluster

### 3.1 Mécanismes évalués

| Mécanisme | Zéro geste | Idempotence | Rotation | Coût et complexité | Maturité | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| **Générateur ESO `Password` + `refreshPolicy: CreatedOnce`** | oui : un manifeste en Git | oui : le Secret est créé une fois, puis jamais réécrit | supprimer le Secret ; ESO le recrée | 0 composant : ESO 2.6.0 est déjà installé, CRD `password`, `clustergenerator` et `generatorstate` présentes | stable, déjà utilisé 2 fois ici | **retenu** |
| **Provider ESO `kubernetes`** (réplication entre namespaces) | oui | oui | suit la source (`refreshInterval`) | 1 SecretStore et 1 ServiceAccount par namespace source ; RBAC par `resourceNames` | supporte toutes les fonctions ESO, PushSecret compris (tableau de stabilité ESO) | **retenu** pour partager une valeur entre deux namespaces |
| **CNPG : génération native** | oui | oui | `cnpg.io/reload` et rôle géré | 0 | stable ; 21 clusters sur 23 l'utilisent déjà | **retenu** pour les bases dédiées |
| CNPG `managed.roles` + `passwordSecret` généré par ESO | oui | oui | CNPG réapplique le mot de passe du Secret au rôle | 0 | stable | **retenu** pour `pg-shared-homelab` |
| Authentik : `client_secret` omis, généré par Authentik | oui côté Authentik | oui | via l'API Authentik | lire la valeur exige un provider ESO `webhook` (stabilité : alpha) et un jeton d'API Authentik | faible pour l'export | alternative, pas en première étape |
| Authentik blueprint `!Env` / `!File` sur un Secret généré | oui | oui | supprimer le Secret, puis redémarrer le worker (Reloader) | 0 ; `!File` existe (doc officielle des tags) | stable | **retenu** (lecture du Secret généré) |
| Kyverno `generate` (clone ou `random()`) | oui | fragile : `synchronize` et `random()` régénèrent au moindre changement | non maîtrisée | 0 (Kyverno présent) | stable pour cloner, pas pour générer | non : ESO fait mieux, Kyverno sert seulement de garde-fou |
| Reflector / Replicator | oui | oui | suit la source | 1 contrôleur de plus | stable | non : doublon du provider ESO `kubernetes` |
| SOPS + age, Sealed Secrets | non : il faut chiffrer chaque valeur à la main ou par script | oui | rechiffrer | KSOPS ou contrôleur, clé racine de plus | stable | non : ajoute une racine et un geste. PLT-312 l'a déjà écarté. |

Sources officielles : générateurs ESO <https://external-secrets.io/latest/api/generator/>, guide <https://external-secrets.io/latest/guides/generator/> (« Every invocation produces a new set of values » : d'où `CreatedOnce`), provider Kubernetes <https://external-secrets.io/latest/provider/kubernetes/>, stabilité <https://external-secrets.io/latest/introduction/stability-support/>, tags des blueprints Authentik <https://docs.goauthentik.io/customize/blueprints/v1/tags/>. `refreshPolicy` est vérifiée dans la CRD vendorisée (`k8s/infrastructure/controllers/external-secrets/charts/external-secrets/templates/crds/externalsecret.yaml`).

### 3.2 Patron retenu : « généré chez le serveur, répliqué chez le client »

La valeur est générée **une seule fois**, dans le namespace du serveur qui fait autorité (Authentik dans `auth`, PostgreSQL dans `databases`). Elle est ensuite répliquée en lecture vers l'app. Le guide ESO précise qu'une valeur générée ne se partage pas entre deux ExternalSecret : il faut donc une source unique et une réplication.

```yaml
# 1. Namespace serveur (auth) : génération unique
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata: {name: oidc-APP, namespace: auth}
spec: {length: 48, symbols: 0, allowRepeat: true}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: oidc-APP, namespace: auth}
spec:
  refreshPolicy: CreatedOnce
  target:
    name: oidc-APP
    creationPolicy: Orphan        # le Secret survit à la suppression de l'ES
    template:
      data: {client_secret: "{{ .password }}"}
  dataFrom:
    - sourceRef:
        generatorRef: {apiVersion: generators.external-secrets.io/v1alpha1, kind: Password, name: oidc-APP}
---
# 2. Namespace client (APP) : lecture répliquée
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: oidc, namespace: APP}
spec:
  refreshInterval: 1h
  secretStoreRef: {kind: ClusterSecretStore, name: k8s-auth}   # provider kubernetes, remoteNamespace: auth
  target: {name: APP-oidc}
  data:
    - secretKey: client_secret
      remoteRef: {key: oidc-APP, property: client_secret}
```

**Garde-fou :** un seul `ClusterSecretStore` `k8s-auth` et un seul `k8s-databases`. Le ServiceAccount de chacun a un `Role` limité aux Secrets préfixés (`oidc-*`, `pg-*`). Une règle Kyverno `validate` (mode Enforce) impose que tout ExternalSecret qui utilise ces stores lise exactement `oidc-{{request.namespace}}` ou `pg-{{request.namespace}}`. Une app ne lit donc que son propre secret. Kyverno et ESO sont déjà là : ce garde-fou n'ajoute aucun composant.

**Côté Authentik :** le blueprint garde `client_secret: !Env <APP>_OIDC_CLIENT_SECRET` (aujourd'hui) ou passe à `!File` sur un volume. La ligne `envFrom` et l'entrée Reloader restent nécessaires par app. Elles sont dans kube-ops et le scaffolding les écrit (§7). Pour supprimer aussi cette ligne : regrouper les secrets OIDC sous un volume projeté unique (`projected.sources[]`, une entrée par app). C'est encore une ligne, mais dans une liste triée et vérifiable par un test. À arbitrer au prototype.

### 3.3 Durabilité : ce qui se passe si le Secret disparaît

| Cas | Conséquence | Couverture |
| --- | --- | --- |
| Secret OIDC perdu | ESO en génère un nouveau ; Authentik et l'app le relisent (Reloader) ; les sessions OIDC tombent | acceptable, aucune donnée perdue |
| Mot de passe de rôle PostgreSQL perdu | ESO en génère un nouveau ; CNPG `managed.roles` le réapplique au rôle | acceptable ; à prouver une fois par drill |
| Clé de session ou JWT perdue | les utilisateurs se reconnectent | acceptable |
| **Clé (a\*) perdue** (chiffrement applicatif) | **données illisibles** | **ne pas générer dans le cluster** : reste dans Doppler (§6) |
| Reconstruction complète du cluster | toutes les valeurs (a) sont régénérées. CNPG restaure les données depuis R2 ; les rôles reçoivent les nouveaux mots de passe | à prouver par le drill de reconstruction existant |
| OKE recréé (D-2026-11-18-01, cluster jetable) | régénération automatique, rien à nettoyer dans Doppler | avantage net par rapport à aujourd'hui |

**Correctif (2026-11-20, après lecture du code ESO v2.6.0) :** avec `creationPolicy: Orphan`, un Secret supprimé alors que l'ExternalSecret a déjà un statut **n'est pas recréé** (échec visible). La régénération se produit quand l'ExternalSecret est neuf (cluster reconstruit, ou ExternalSecret renommé). Dans ce cas, ESO écrase aussi un Secret restauré par Velero. Détails, politique de sauvegarde par type et drills : `secrets-migration-spec.md` §2 et §3.

Les plannings Velero `daily-auth` et `daily-databases` (`k8s/infrastructure/controllers/velero/schedules/`) incluent déjà toutes les ressources des namespaces, Secrets compris (`includedResources: '*'`). Ils donnent une copie de secours, mais ne sont **pas** le chemin de reprise prévu. Point à vérifier à part, indépendant de cette étude : les manifestes de ressources Velero, Secrets compris, sont stockés dans le bucket objet de Velero. Leur chiffrement au repos mérite un contrôle.

**Doppler ne peut pas servir de séquestre automatique.** Le tableau de stabilité ESO marque PushSecret comme non supporté pour Doppler. Les clés (a\*) restent donc générées par OpenTofu → Doppler, comme aujourd'hui.

### 3.4 Classe (a2) et classe (n)

- **(a2)**, jetons émis par une app du cluster : pas de mécanisme natif. Options : un `Job` PostSync idempotent qui appelle l'API de l'app et écrit le Secret (RBAC `resourceNames`), ou un générateur ESO `Webhook`. À traiter app par app, au fil de l'eau. 6 clés seulement : ce n'est pas une priorité.
- **(n)** : sortir de Doppler au fil des modifications. Les valeurs non secrètes vont en Git (ConfigMap ou `template.data` littéral de l'ExternalSecret). Aucune migration de masse.

## 4. Classe (b) : créer les ressources externes depuis Kubernetes ?

### 4.1 Options

| Option | Ce qu'elle fait | Pour | Contre | Coût | Verdict |
| --- | --- | --- | --- | --- | --- |
| **Statu quo + scaffolding** | OpenTofu (ARC) crée le jeton et écrit `doppler_secret` ; ESO le lit. Un script génère **les deux PR** (homelab-infra et kube-ops) d'un coup | rien de nouveau ; respecte ARC, `INV-OWN-02` et `INV-REC-01` ; zéro geste manuel déjà possible | 2 PR et 1 apply ARC par nouveau jeton ; la root `doppler` reste sérialisée | 0 € | **retenu** |
| **Réutiliser un jeton existant** | Règle déjà actée (« réutiliser un credential existant s'il est valide ») : écrivain R2 par classe de bucket, jeton DNS unique | 0 PR externe dans la plupart des cas | périmètre plus large (déjà accepté pour `R2_CNPG_WRITER`, D-2026-11-16-09) | 0 € | **retenu par défaut** dans le scaffolding |
| **Générateurs ESO spécialisés** | `Github` (jeton d'installation d'App GitHub, court) ; `Grafana` (jeton de compte de service Grafana) | remplacent des jetons longs (GHCR, Grafana MCP) par des jetons courts, sans Doppler | la clé privée de l'App GitHub reste une racine (b') | 0 € | **retenu à moyen terme** (GHCR, Grafana) |
| ARC + OpenTofu → `kubernetes_secret_v1` | La root écrit le Secret directement dans le cluster | supprime un saut Doppler | le runner ARC doit écrire des Secrets dans le cluster (nouvelle identité privilégiée) ; homelab-infra écrirait dans un objet de kube-ops (`INV-OWN-02`) ; un cluster recréé perd le Secret jusqu'au prochain apply ; plusieurs clusters = plusieurs écritures | 0 € | non : plus de couplage pour peu de gain |
| **Crossplane** (providers Cloudflare, GitHub, Grafana) | Ressources externes déclarées en CR ; secret de connexion écrit dans un Secret | modèle GitOps pur ; écrit directement dans Kubernetes | provider Cloudflare `crossplane-contrib/provider-upjet-cloudflare` : aucune release publiée ; GitHub `provider-upjet-github` : exemple en `v0.1.0`, aucune release publiée ; pas de provider Authentik, Doppler, NetBird, Proxmox ou Migadu mûr ; double source de vérité avec les roots OpenTofu ; un jeton Cloudflare capable de créer des jetons dans le cluster ; contredit « Crossplane différé » (PLT-376) | 0 € ; Crossplane, ses providers et leurs nombreuses CRD à maintenir | **non pour l'instant** ; à réévaluer si un provider Cloudflare publie des releases stables |
| tofu-controller (`flux-iac/tofu-controller`) | Exécute les roots OpenTofu dans le cluster ; peut écrire les sorties dans un Secret | réutilise le HCL | contredit « tout OpenTofu par ARC » ; ajoute la pile source-controller ; un état et des credentials de provider dans le cluster ; projet sans release affichée sur sa page GitHub | 0 € ; 2 contrôleurs et des pods runner | non |
| Opérateurs dédiés (tunnel Cloudflare, opérateurs Authentik communautaires) | 1 opérateur par fournisseur | ciblé | maturité inégale ; 1 composant et 1 jeton puissant par fournisseur | 0 € | non |
| Provider ESO `webhook` | Lecture d'une API externe par ESO | aucun composant | stabilité alpha ; jeton d'API à poser | 0 € | réservé à un cas isolé |

Sources : <https://github.com/crossplane-contrib/provider-upjet-cloudflare>, <https://github.com/crossplane-contrib/provider-upjet-github>, <https://github.com/flux-iac/tofu-controller> (pages consultées le 2026-11-20).

### 4.2 Lecture honnête

Pour la classe (b), le problème n'est **pas** Doppler. OpenTofu crée déjà le jeton et l'écrit dans Doppler sans geste humain. La friction vient de trois choses :

- deux PR dans deux dépôts ;
- un apply ARC sur une root sérialisée ;
- l'absence d'outil qui produit les deux PR ensemble.

Crossplane déplacerait cette friction vers des providers moins mûrs que les providers Terraform équivalents. Il ne supprimerait pas les racines (b') ni le jeton capable de créer des jetons.

## 5. Ce qui disparaît de Doppler, ce qui y reste

| | Aujourd'hui (clés actives) | Cible |
| --- | --- | --- |
| (a) interne | 59 | 0 pour toute nouvelle app ; existantes migrées seulement quand l'app est modifiée |
| (a\*) chiffre des données | 8 | 8 (OpenTofu → Doppler, inchangé) |
| (a2) émis par une app | 6 | 6, puis Job ou générateur au cas par cas |
| (n) non secret | 47 | 0 (Git), au fil de l'eau |
| (b) externe créable | 22 | ~18 (GHCR et Grafana passent aux générateurs ESO) |
| (b') externe non créable | 15 | 15 |
| (c) racine | 4 | 4 |
| **Total** | **161** | **~51** (−68 %) |

## 6. Classe (c) : le noyau racine

| Racine | Nombre | Où | Geste humain |
| --- | --- | --- | --- |
| Jeton ESO → Doppler (`doppler-access-token`), un par cluster | 2 | Doppler `infrastructure/prd`, posé au bootstrap | aucun : `bootstrap-cluster.sh` le lit (opérateur) ; avec Doppler Team, OIDC et 0 jeton, mais 21 USD/mois, hors budget |
| Accès OpenTofu à Doppler (environnements GitHub ARC) | 1 (D-2026-11-14-05) | secret GitHub | une fois, par Paul |
| Identités initiales des providers OpenTofu (Cloudflare, Grafana Cloud, NetBird, Proxmox, Migadu, OCI, GitHub App ARC) | ~7 | Doppler `infrastructure/prd` ou fédération (GCP WIF déjà en place) | une fois par fournisseur, par Paul (console) |
| Backend d'état OpenTofu | 1 | secret GitHub | une fois |
| Racines de chiffrement : restic, Velero, Talos machine secrets | 3 | Doppler + fiche papier (D-2026-11-15-10) | une copie hors ligne, par Paul |
| Clés (a\*) des apps | 8 | Doppler, générées par OpenTofu | aucun |
| Secrets externes non créables (b') | 15 | Doppler | à la création chez le fournisseur, par Paul |

**Minimum incompressible : ~12 racines d'amorçage**, plus les clés (a\*) et (b') propres aux apps. Aucune n'est créée ou modifiée par un déploiement standard. Perte du noyau : `INV-REC-01` s'applique déjà (machines + Git + état + identifiants de reprise minimaux). Les secrets (a) générés dans le cluster **ne rendent pas** la reprise plus difficile, car ils se régénèrent tout seuls (§3.3).

## 7. Impact sur le golden path

- **`scripts/scaffold-oke-app.sh`** : ne touche aucun secret aujourd'hui. Ajouter un `scripts/scaffold-app-secrets.sh APP [--oidc] [--pg-shared] [--external cloudflare-dns|r2-writer]`. Il écrit les manifestes du §3.2 (générateur, ExternalSecret source et réplique), le blueprint, la ligne Authentik et le rôle CNPG. Il ne crée une PR homelab-infra que si `--external` demande un jeton qui n'existe pas encore.
- **`.agents/skills/deploy-a-service/SKILL.md`** : remplacer « secret `APP_<APP>_OIDC_CLIENT_SECRET` in Doppler » par le patron du §3.2. Retirer « Doppler values … remain Paul's » pour la classe (a).
- **`pg-shared-homelab/app-database.example.tmpl`** : remplacer l'étape « clé créée par Paul » par un générateur `Password` dans `databases`. C'est **le seul geste manuel explicite** du golden path.
- **Backstage Scaffolder (PLT-376, PLT-378)** : les deux tickets sont **annulés** (Linear, 2026-11-20). Le patron ne produit que des manifestes en Git ; un futur portail (Backstage ou l'OpenChoreo du POC, D-2026-11-18-01) n'aura qu'à appeler le même script. Le « Crossplane différé » de PLT-376 reste cohérent avec cette étude.
- **Tests et politiques** : une règle Kyverno pour les stores `k8s-*` (§3.2). Un test bash : tout `Password` utilisé par un ExternalSecret doit avoir `refreshPolicy: CreatedOnce`, sinon la valeur tourne à chaque rafraîchissement.

## 8. Exemple avant / après : app type `notes`

Hypothèses : base dans `pg-shared-homelab`, client OIDC Authentik, `HTTPRoute`, un jeton Cloudflare (DNS-01 ou R2).

### Avant (procédure actuelle déduite du code)

1. PR homelab-infra : ajouter `notes` à `phase3_oidc_clients` dans `terraform/doppler/generated-app-secrets.tf` (`random_password` + 2 `doppler_secret`). Plan et apply ARC sur la root `doppler`, protégée et sérialisée.
2. **Paul crée `PG_SHARED_HOMELAB_NOTES_PASSWORD` dans Doppler** (template `pg-shared-homelab`).
3. PR homelab-infra : `cloudflare_api_token` + `doppler_secret` dans `terraform/cloudflare`. Plan et apply ARC.
4. PR kube-ops :
   - ExternalSecret `authentik-blueprint-notes` dans `auth` ;
   - `envFrom` et annotation Reloader dans `authentik/values.yaml` ;
   - blueprint `apps-notes.yaml` ;
   - ExternalSecret OIDC dans `notes` ;
   - ExternalSecret du rôle dans `databases` ;
   - `managed.roles` + `Database` + Job d'isolation ;
   - ExternalSecret du jeton Cloudflare ;
   - `HTTPRoute`, app, Application.
5. Attendre que les clés Doppler existent avant la synchronisation Argo, sinon les ExternalSecret restent `SecretSyncedError`.

**Bilan :** 2 dépôts, 3 PR, 2 apply ARC, **1 geste manuel**, 4 clés Doppler, 4 ExternalSecret Doppler, et un ordre à respecter entre dépôts.

### Après (cible)

1. `bash scripts/scaffold-app-secrets.sh notes --oidc --pg-shared --external cloudflare-dns` écrit dans kube-ops :
   - `Password` + ExternalSecret `oidc-notes` (`auth`, `CreatedOnce`) ; ExternalSecret `oidc` dans `notes` via `k8s-auth` ;
   - `Password` + ExternalSecret `pg-notes` (`databases`, `CreatedOnce`, `cnpg.io/reload`) ; ExternalSecret `db` dans `notes` via `k8s-databases` ;
   - blueprint, ligne Authentik, rôle géré, `Database`, Job d'isolation ;
   - ExternalSecret `cloudflare-dns` qui lit le jeton DNS **existant** (`CLOUDFLARE_API_TOKEN`, réutilisation par défaut).
2. `just check`, PR, merge. Argo synchronise tout dans le bon ordre, car aucune dépendance externe n'est nouvelle.

**Bilan :** 1 dépôt, 1 PR, 0 apply ARC, **0 geste manuel**, 0 clé Doppler créée. Si un jeton Cloudflare **dédié** est vraiment exigé : le script ouvre aussi la PR homelab-infra (1 apply ARC, 1 clé écrite par OpenTofu, toujours 0 geste manuel).

## 9. Trajectoire

### Étape 1 : quick wins (≤ 1 semaine, kube-ops seulement, 0 €)

1. Décision dans homelab-infra `docs/decisions.md` : amender « secrets dans Doppler seulement » (§1.5).
2. `ClusterSecretStore` `k8s-auth` et `k8s-databases` (provider `kubernetes`), ServiceAccounts et `Role` par préfixe, règle Kyverno du §3.2, test `CreatedOnce`.
3. Template `pg-shared-homelab` : générateur au lieu de la clé créée par Paul. Le geste manuel disparaît.
4. Pilote sur **une nouvelle app** (ou sur la prochaine app OIDC prévue) : patron OIDC complet. Preuve attendue : `RUNTIME` (connexion OIDC réussie), puis suppression volontaire du Secret source et vérification de la régénération et de la reconnexion.
5. `scripts/scaffold-app-secrets.sh` et mise à jour du skill `deploy-a-service`.

### Étape 2 : moyen terme (2 à 6 semaines)

6. Générateur ESO `Github` pour les jetons GHCR (`APP_FACTORY_PLATFORM_GHCR_TOKEN`, `APP_FACTORY_ARC_GHCR_READ_TOKEN`) depuis l'App GitHub existante ; générateur `Grafana` pour le jeton MCP.
7. Classe (n) : sortir les valeurs non secrètes de Doppler quand une app est modifiée.
8. Migration opportuniste de la classe (a) : quand une app est modifiée, passer à la génération dans le cluster. Côté OpenTofu, utiliser `removed { lifecycle { destroy = false } }` pour les `random_*` et `doppler_secret`, puis supprimer la clé Doppler après la preuve `RUNTIME`. Ne jamais toucher aux clés (a\*). Commencer par les apps sans utilisateur.
9. (a2) : un Job PostSync pour les jetons émis par une app, si le besoin revient (kubechecks retiré, PLT-397).

### Hors trajectoire (à réévaluer sur critère)

- Crossplane : quand un provider Cloudflare publie des releases stables **et** qu'une ressource externe est créée plus d'une fois par mois.
- Doppler Team (OIDC pour ESO) : seulement si le budget le permet (21 USD/mois, au-dessus du plafond de 20 €).

### Empreinte et coût

0 € par mois. Aucun nouveau contrôleur dans les étapes 1 et 2. Les objets ajoutés sont des CR ESO et une règle Kyverno.

## 10. Risques

| Risque | Effet | Mitigation |
| --- | --- | --- |
| `Password` sans `CreatedOnce` | rotation à chaque rafraîchissement, l'app perd sa base ou son client OIDC | test bash + règle Kyverno |
| Suppression de l'ExternalSecret source | le Secret disparaît avec son propriétaire | `creationPolicy: Orphan` + `CreatedOnce` |
| Lecture entre apps par le store `kubernetes` | une app lit le secret d'une autre | `Role` par préfixe + règle Kyverno sur la clé = namespace |
| Dépendance circulaire | aucune nouvelle : ESO précède déjà Authentik et CNPG ; le provider `kubernetes` ne dépend que de l'API server | ordre de sync-wave inchangé |
| Nœud homelab éteint la nuit (s'il l'est) | sans effet : chaque cluster génère ses propres secrets ; aucune lecture entre clusters | n/a |
| Reconstruction du cluster | nouveaux secrets (a), sessions perdues | acceptable par construction (§3.3) ; à prouver par drill |
| Perte d'une clé (a\*) | données illisibles | les (a\*) restent dans Doppler, générées par OpenTofu |
| Perte du noyau racine | reprise impossible | `INV-REC-01` et fiche papier (inchangés) |
| Migration d'un secret existant | coupure de l'app | seulement au fil des changements, avec preuve `RUNTIME`, jamais en masse |

## 11. Décisions pour Paul

1. **Amender la règle « secrets dans Doppler seulement »** en « Doppler pour les secrets externes, racines et clés de chiffrement de données ; secrets internes générés dans le cluster par ESO ». Oui / non.
2. **Migrer les secrets internes existants ?** Recommandé : non en masse ; seulement au fil des modifications.
3. **Réutiliser par défaut les jetons externes existants** (DNS Cloudflare, écrivain R2 par classe de bucket) dans le scaffolding, au lieu d'un jeton par app. Oui / non.
4. **Crossplane** : confirmer qu'il reste différé (cohérent avec PLT-376).
5. **Pilote** : quelle app sert de pilote pour le patron OIDC (une nouvelle app ou une app sans utilisateur) ?

## 12. Contrôles

- Exécuté : parsing YAML des ExternalSecret de `k8s/`, `git grep` sur homelab-infra `origin/main`, lecture de la CRD ESO vendorisée, lecture des tickets Linear PLT-376 et PLT-378, documentation officielle citée.
- Non exécuté : aucun test sur un cluster (`NOT_TESTED`). Le comportement exact de `CreatedOnce` combiné au provider `kubernetes` et à Authentik `!File` reste à prouver par le pilote de l'étape 1.
