# Contrat PostgreSQL OKE (pg-shared, oracle-a1)

Statut : **écrit et testé en CI (garde service-contract), non prouvé à l'exécution.** Le cluster
`pg-shared` d'OKE sera reconstruit depuis ce contrat. Aucune donnée réelle n'entre dans `pg-shared`
avant la restauration hors Oracle (D-2026-11-11-17, drill `docs/operations/pg-shared-oke-backup-drill.md`).

Ce contrat couvre les bases de **plateforme** sur `pg-shared` (cluster CNPG `databases/pg-shared`,
namespace `databases`, sur oracle-a1). Il ne touche pas au cluster homelab `pg-shared-homelab`, dont
les règles restent dans `k8s/infrastructure/database/pg-shared-homelab/` et la garde inchangée.

## Règles

| # | Règle | Contrôle |
| --- | --- | --- |
| C1 | Une base = un rôle propriétaire, non superuser, sans `createdb`, `createrole`, `replication`, `bypassrls`, sans `inRoles`, avec `login`. Le proprietaire doit exister exactement une fois comme role managed de `pg-shared`. | garde R5 voie OKE (`oke_role`, `oke_database`) |
| C2 | Base admise seulement si présente dans l'allowlist `OKE_DB_ALLOW` de la garde. Aujourd'hui : `backstage` (rôle `backstage`). | `oke_database` |
| C3 | Owner de la base = rôle homonyme de l'allowlist. Namespace `databases`, cluster `pg-shared` uniquement. | `oke_database` |
| C4 | `REVOKE CONNECT ON DATABASE <base> FROM PUBLIC` pour chaque base, dans la **commande exécutée** (`command`/`args`) d'un Job PostSync `pg-shared-<base>-isolation` dans `cnpg-cluster/` (le CRD `Database` n'a pas de champ de grant ; une annotation ou un commentaire ne compte pas). Y compris la base `app` créée par CNPG (`pg-shared-app-isolation`). | `oke_isolation_job` |
| C5 | Mot de passe de rôle : ExternalSecret dans `databases`, Secret `pg-shared-<rôle>`, clé Doppler `ORACLE_A1_<RÔLE>_DB_PASSWORD` mappée sur `secretKey: password`, template `password: "{{ .password }}"`, `username` = rôle. Aucune valeur dans Git. | `oke_role` |
| C6 | Extensions interdites : `extensions` vide ou absent (allowlist d'extensions vide). Hindsight n'est pas dans `pg-shared`. | `oke_database` |
| C7 | Pas de `databaseReclaimPolicy: delete` (les données partiraient avec l'objet). | `oke_database` |
| C8 | Sauvegarde couverte par le cluster : `pg-shared` a un plugin `barman-cloud` en `isWALArchiver: true` (R2, préfixe `oracle-a1/pg-shared/`) et un `ScheduledBackup` en `method: plugin` avec `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`. | `check_oke` |
| C9 | Un seul Cluster CNPG (`pg-shared`) sur oracle-a1 ; un nouveau Cluster reste refusé. | règle R5 existante |

Périmètre de la voie : objets de `k8s/clusters/oracle-a1/cnpg-cluster/` **nouveaux ou modifiés**
par la PR, jugés en entier. Les objets **retenus** (base et rôle de l'allowlist) restent revalidés
à chaque PR qui touche ce dossier, même inchangés : retirer leur Job, leur ExternalSecret ou leur
rôle fait échouer la garde. Un objet hors allowlist identique à `main` n'est pas re-jugé (grandfathered).
Une Database ou un role PG ajouté ailleurs (`k8s/clusters/oracle-a1/hindsight/`, etc.) reste refusé
par la règle R5 existante.

Admission : la voie OKE n'utilise **ni MANDAT ni `SERVICE_CONTRACT_HUMAN_ADMISSION`**. Un écart est un
FAIL bloquant, même avec admission humaine ou hors golden-path. Une base conforme passe en PASS
(la revue humaine reste la règle de merge, pas une dérogation de la garde).

## Objets sur main (grandfathered)

- `Database polyfin` et `Database backup-drill` (drill, `k8s/optional/`), rôle `polyfin` : **ne sont pas
  allowlistés**. Ils restent tant qu'ils ne changent pas. Toute modification les soumet au contrat et
  échoue jusqu'à décision de Paul (ajout à l'allowlist, ou retrait).
- Base `app` et rôle `app` : créés par CNPG (initdb), hors Git ; couverts par C4.
- Base `postgres` et templates : superuser CNPG, accès distant superuser désactivé par défaut de CNPG.
  Non revoquée ici (le Job tourne en propriétaire, pas en superuser). Restent fermées par le réseau
  (Cilium, `allow-ingress-databases` de la baseline).

## Chaîne de connexion Backstage (pour l'agent BACKSTAGE-OKE)

Pas de RBAC cross-namespace : Backstage ne lit pas le Secret `pg-shared-backstage` (namespace
`databases`). Il a son **propre ExternalSecret** dans son namespace, sur la **même clé Doppler**.
C'est le modèle à retenir pour tout service de plateforme :

| Élément | Valeur |
| --- | --- |
| Clé Doppler (projet `cluster`, config `prd`) | `ORACLE_A1_BACKSTAGE_DB_PASSWORD` (créée par Paul, jamais dans Git) |
| Rôle / base / owner | `backstage` / `backstage` / `backstage` |
| Hôte | `pg-shared-rw.databases.svc.cluster.local` |
| Port | `5432` |
| TLS | `sslmode=require` (certificat CNPG interne, non vérifié) |
| Secret côté CNPG (déjà en Git) | `pg-shared-backstage` (`databases`), clés `username`, `password` |
| Secret à créer par BACKSTAGE-OKE | `backstage-db` (namespace `backstage`), clés `username`, `password` |
| ExternalSecret à créer | `backstage-db`, namespace `backstage`, même clé Doppler |

Exemple (à placer par BACKSTAGE-OKE dans son dossier, pas dans `cnpg-cluster/`) :

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: backstage-db
  namespace: backstage
spec:
  refreshInterval: 1h
  secretStoreRef: {name: doppler-cluster, kind: ClusterSecretStore}
  target:
    name: backstage-db
    creationPolicy: Owner
    template:
      type: kubernetes.io/basic-auth
      data:
        username: backstage
        password: "{{ .password }}"
  data:
    - secretKey: password
      remoteRef: {key: ORACLE_A1_BACKSTAGE_DB_PASSWORD}
```

Réseau : la baseline autorise `backstage` vers `databases:5432` (`allow-ingress-databases`) et
`backstage` peut sortir vers `databases:5432` (`allow-egress-backstage`). Le namespace `backstage` doit
exister avec le même Secret que la baseline (PR #1620, à reprendre par BASELINE). Le `SecretStore`
par namespace de #1620 remplacera `doppler-cluster` quand il sera mergé ; l'ExternalSecret ne change
alors que sa référence de store.

## Preuves à produire (NOT_PROVEN à ce stade)

1. Après reconstruction de `pg-shared` : `Cluster` Ready, `ContinuousArchiving=True`, `ScheduledBackup`
   `Completed`, rôle `backstage` créé (`status` du Cluster, pas le Secret).
2. Base `backstage` présente, propriétaire `backstage`, `datacl` sans CONNECT pour PUBLIC
   (`kubectl-ro` sur la requête `aclexplode`, pas de lecture de Secret).
3. Négatif : connexion en rôle `app` à `backstage` refusée (`permission denied for database backstage`).
4. Jobs `pg-shared-backstage-isolation` et `pg-shared-app-isolation` en `Succeeded`.
5. Connexion Backstage avec `backstage-db` : `SELECT 1` depuis le pod Backstage.

## Limites connues

- Le cluster actuel tourne avec un seul `instance`. Le `inheritedMetadata` (annotation
  `baseline.smadja.dev/automount-token`, requise par la VAP de baseline pour CNPG) redémarre l'unique
  instance à la synchro : prévoir la fenêtre (drill seulement, pas de donnée réelle).
- Argo CD ne sait pas que CNPG est prêt (pas de health check). Les Jobs PostSync attendent donc la base et le
  rôle : boucle `until psql` bornée à 5 minutes, `PGCONNECT_TIMEOUT=5` pour chaque tentative, et
  `activeDeadlineSeconds: 600` pour le Job entier (`backoffLimit: 3`).
- `polyfin` et `backup-drill` ne sont pas conformes à ce contrat : décision de Paul à prendre avant
  toute modification de leurs objets.
