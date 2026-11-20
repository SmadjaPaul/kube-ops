# Drill D1 : rotation d'un mot de passe de rôle `pg-shared-homelab` (procédure, NON LANCÉ)

Statut : **NOT_RUN.** Procédure écrite par le lot 1 de `docs/architecture/secrets-migration-spec.md`. Aucun manifeste de ce document n'est dans un `kustomization.yaml` : rien n'est appliqué tant qu'un opérateur n'ouvre pas la PR de drill décrite plus bas. Aucune valeur de secret n'apparaît ici, ni dans la PR, ni dans les preuves.

Ce que D1 prouve (fait F5 de la spec) : un rôle géré par CNPG (`managed.roles` + `passwordSecret`) dont le Secret est **généré par ESO** (Password, `CreatedOnce`, `Orphan`) se connecte avant la rotation ; après la rotation par renommage de la source (F3c), CNPG réapplique le mot de passe (condition `PasswordSecretChange`) et la connexion réussit encore avec la copie relue par le store `k8s-databases`.

D1b (restauration Barman + Secret neuf) est une procédure distincte : section « D1b » de `docs/operations/pg-shared-app-restore-drill.md`. D1 ne remplace pas D1b.

## Préconditions (vérifier, ne pas supposer)

1. `bash scripts/kubectl-ro.sh get cluster -n databases pg-shared-homelab` : `Cluster in healthy state`.
2. `bash scripts/kubectl-ro.sh get clustersecretstore k8s-auth k8s-databases` : `Ready=True` (lot 0).
3. Le lot 0 est mergé. Le drill D0 (`docs/operations/secrets-drill-d0-createdonce.md`) peut avoir déjà créé le dossier `k8s/infrastructure/controllers/external-secrets/drills/createdonce/` et le namespace `eso-drill` : vérifier `main`. Si D0 est présent, réutiliser son namespace et sa destination Argo (section « Coordination avec D1 » de D0) ; sinon ce drill crée le dossier.
4. Sauf si D0 est encore présent (alors la destination existe déjà), le namespace `eso-drill` n'est pas dans les destinations de `k8s/bootstrap/argocd-root/infrastructure-project.yaml` : la PR de drill l'ajoute (et la retire au nettoyage), ou l'opérateur choisit un autre moyen approuvé. Le namespace `databases` y est déjà.
5. La PR de drill est une PR **séparée**, en draft, jamais fusionnée avec le lot 1. Les noms `eso_drill`, `pg-eso-drill*`, `eso-drill*` sont réservés au drill.

## Fichiers de la PR de drill (à créer par l'opérateur)

| Chemin | Contenu |
| --- | --- |
| `k8s/infrastructure/database/pg-shared-homelab/cluster.yaml` | ajouter le rôle `eso_drill` à `spec.managed.roles` (bloc 1) |
| `k8s/infrastructure/database/pg-shared-homelab/eso-drill-role.yaml` + `kustomization.yaml` | source `pg-eso-drill` et `CiliumNetworkPolicy` d'entrée (bloc 2) |
| `k8s/infrastructure/database/pg-shared-homelab/eso-k8s-reader-rbac.yaml` | ajouter `pg-eso-drill` aux `resourceNames` (sentinelle conservée) |
| `k8s/infrastructure/controllers/external-secrets/drills/createdonce/` + `kustomization.yaml` du contrôleur | namespace, copie, `CiliumNetworkPolicy` de sortie et Job `PostSync` (bloc 3) |
| `k8s/bootstrap/argocd-root/infrastructure-project.yaml` | destination `eso-drill` (précondition 4) |

Le Secret et le rôle s'appellent `pg-eso-drill` / `eso_drill` : le nom du Secret est `pg-` + le namespace de la copie (`eso-drill`), comme l'exigent l'admission `eso-k8s-store-guard` et le contrat statique. Le rôle n'a **aucune base** (`Database` absent) : il ne se connecte qu'à `postgres`, où `PUBLIC` garde `CONNECT`.

### Bloc 1 : rôle (cluster.yaml)

```yaml
managed:
  roles:
    - name: eso_drill
      ensure: present
      login: true
      superuser: false
      createdb: false
      createrole: false
      passwordSecret:
        name: pg-eso-drill
```

### Bloc 2 : source et réseau (`eso-drill-role.yaml`, namespace `databases`)

```yaml
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata: {name: pg-eso-drill, namespace: databases}
spec: {length: 48, digits: 10, symbols: 0, allowRepeat: true}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: pg-eso-drill
  namespace: databases
  labels: {kube-ops.io/drill: "true"}
  annotations: {kube-ops.io/secret-class: T1}
spec:
  refreshPolicy: CreatedOnce
  target:
    name: pg-eso-drill
    creationPolicy: Orphan
    template:
      engineVersion: v2
      type: kubernetes.io/basic-auth
      metadata:
        labels:
          cnpg.io/reload: "true"
      data:
        username: eso_drill
        password: "{{ .password }}"
  dataFrom:
    - sourceRef:
        generatorRef: {apiVersion: generators.external-secrets.io/v1alpha1, kind: Password, name: pg-eso-drill}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: pg-shared-homelab-eso-drill, namespace: databases}
spec:
  endpointSelector: {matchLabels: {cnpg.io/cluster: pg-shared-homelab}}
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: eso-drill
      toPorts:
        - ports:
            - {protocol: TCP, port: "5432"}
```

### Bloc 3 : consommateur (`drills/createdonce/`, namespace `eso-drill`)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: eso-drill
  labels: {kube-ops.io/drill: "true"}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: eso-drill-db, namespace: eso-drill, labels: {kube-ops.io/drill: "true"}}
spec:
  refreshInterval: 1h
  secretStoreRef: {kind: ClusterSecretStore, name: k8s-databases}
  target:
    name: eso-drill-db
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        PGHOST: pg-shared-homelab-rw.databases.svc.cluster.local
        PGPORT: "5432"
        PGDATABASE: postgres
        PGUSER: eso_drill
        PGSSLMODE: require
        PGPASSWORD: "{{ .password }}"
  data:
    - secretKey: password
      remoteRef: {key: pg-eso-drill, property: password}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: eso-drill, namespace: eso-drill}
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels: {k8s:io.kubernetes.pod.namespace: databases, cnpg.io/cluster: pg-shared-homelab}
      toPorts:
        - ports:
            - {protocol: TCP, port: "5432"}
    - toEndpoints:
        - matchLabels: {k8s:io.kubernetes.pod.namespace: kube-system, k8s:k8s-app: kube-dns}
      toPorts:
        - ports:
            - {protocol: UDP, port: "53"}
            - {protocol: TCP, port: "53"}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: eso-drill-db-connect
  namespace: eso-drill
  labels: {kube-ops.io/drill: "true"}
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 26, runAsGroup: 26, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: connect
          image: ghcr.io/cloudnative-pg/postgresql:18.4-standard-trixie@sha256:<même digest que cluster.yaml>
          command: [sh, -ec]
          args:
            - |
              i=0
              until psql -v ON_ERROR_STOP=1 -tA -c 'select 1' >/dev/null 2>&1; do
                i=$((i + 1)); [ "$i" -lt 30 ] || { echo "CONNECT=FAIL" >&2; exit 1; }
                sleep 10
              done
              echo "CONNECT=OK"
          envFrom:
            - secretRef: {name: eso-drill-db}
          resources:
            requests: {cpu: 10m, memory: 32Mi}
            limits: {cpu: 200m, memory: 128Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
```

Avant d'ouvrir la PR : `just check` (la règle « namespace avec workload sans CiliumNetworkPolicy » et les règles Kyverno de base valent aussi pour `eso-drill`), `kustomize build --enable-helm` sur la racine concernée.

## Déroulement (lecture seule : `bash scripts/kubectl-ro.sh`, `KUBECTL_RO_IDENTITY=agent` si utile)

Toutes les écritures passent par GitOps (merge de la PR de drill, puis commits de rotation). Aucun `kubectl` d'écriture, aucune lecture de valeur.

| Étape | Action | Preuve attendue (sans valeur) |
| --- | --- | --- |
| 1 | Merge de la PR de drill, Argo synchronise | `get externalsecret -n databases pg-eso-drill` : `Ready`, `refreshTime` rempli ; `-n eso-drill eso-drill-db` : `Ready` |
| 2 | Relever l'état avant | `get cluster -n databases pg-shared-homelab -o yaml` : condition `PasswordSecretChange` **présente**, noter son `message` (contient un `resourceVersion`, jamais une valeur) ; `get secret -n databases pg-eso-drill` sans `-o` : âge et taille |
| 3 | Connexion avant | `get job -n eso-drill eso-drill-db-connect` : `Succeeded` ; `logs` : `CONNECT=OK` |
| 4 | Commit de rotation 1 : renommer la source `pg-eso-drill` en `pg-eso-drill-r2` (ExternalSecret **et** Password), **même `target.name: pg-eso-drill`**. Retirer l'ancien nom du fichier | la source `pg-eso-drill-r2` : `Ready`, `refreshTime` neuf ; le Secret `pg-eso-drill` garde son âge (mis à jour, pas recréé, F3c) |
| 5 | Réapplication par CNPG | le `message` de `PasswordSecretChange` a **changé** (nouveau `resourceVersion`) ; le Cluster reste `Cluster in healthy state` |
| 6 | Propagation à la copie. Préféré : attendre `refreshInterval` (1 h). Alternative (commit 2) : renommer la copie `eso-drill-db` en `eso-drill-db-r2`, même `target.name`. Risque connu : avec `creationPolicy: Owner`, la copie existante appartient à l'ancien ExternalSecret ; consigner si ESO refuse (« owned by another ExternalSecret ») ou recrée le Secret après le prune | `get secret -n eso-drill eso-drill-db` : mis à jour ; l'ExternalSecret de la copie est `Ready` |
| 7 | Connexion après : un nouveau commit (ou une synchronisation Argo) relance le Job `PostSync` | `Succeeded`, `CONNECT=OK` |
| 8 | Si le Job échoue après 5 : consigner l'heure, la condition CNPG et l'état de la copie ; ne rien corriger à la main | verdict `FAIL` avec ces éléments |

Critère `PASS` (spec §3.4) : Job `Succeeded` avant **et** après la rotation, et `message` de `PasswordSecretChange` différent entre les étapes 2 et 5. Sinon `FAIL` ou `NOT_PROVEN` (étape non observée).

## Nettoyage (deux commits, dans cet ordre)

1. `ensure: absent` sur le rôle `eso_drill` dans `cluster.yaml` ; retirer le Job, la copie et le namespace `eso-drill` ; retirer la destination Argo. Attendre que CNPG supprime le rôle : `get cluster -n databases pg-shared-homelab -o yaml` ne liste plus `eso_drill` dans `status.managedRolesStatus`.
2. Retirer le bloc `eso_drill` de `cluster.yaml`, `eso-drill-role.yaml`, la ligne `pg-eso-drill` de `resourceNames` (sentinelle conservée) et le dossier `drills/createdonce/`. Les noms `eso_drill` et `pg-eso-drill*` ne doivent plus apparaître dans `k8s/` (`git grep`).

Le Secret `pg-eso-drill` est `Orphan` : il survit à la suppression de son ExternalSecret. Sa suppression est hors de `scripts/kubectl-rw.sh` (politique `agent-operator-guard`) : **MANDAT** de l'opérateur (`kubectl delete secret -n databases pg-eso-drill`), à consigner.

## Preuves

Vide. À remplir dans `docs/operations/secrets-migration-evidence.md` (section lot 1) après exécution réelle : états observés, verdict `PASS`, `FAIL` ou `NOT_PROVEN`, sans aucune valeur.
