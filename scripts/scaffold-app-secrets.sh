#!/usr/bin/env bash
# Lot 3 of docs/architecture/secrets-migration-spec.md: scaffold the secret manifests of a NEW app
# according to the taxonomy of section 4.1. Internal secrets (T1, T3, T4, T5) are generated inside
# the cluster by ESO (Password generator, CreatedOnce, Orphan); nothing is created in Doppler.
# Doppler stays for T6 (data-encryption keys), T7, T8, T9: reported, never generated.
# Dry-run by default: lists the files created and the insertions; --write applies them.
# No network call, no secret value read or printed (only names, kinds and policies).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scaffold-app-secrets.sh APP --namespace NS [--oidc CLIENT_ID] [--pg-shared]
                               [--local-key USAGE[:T4|:T5]]... [--data-key USAGE]...
                               [--external cloudflare-dns|r2-writer]... [--app-dir DIR] [--write]

Scaffold the secrets of a new application (spec docs/architecture/secrets-migration-spec.md, lot 3).
Default is a dry-run: it lists the files to create and the insertions in existing files.

  APP                 application name (lowercase, digits, '-')
  --namespace NS      consumer namespace, exact (the store only lets it read oidc-NS / pg-NS[--usage])
  --oidc CLIENT_ID    T3: source oidc-NS in auth (Authentik side: Role resourceNames, envFrom
                      optional:true, Reloader list) and copy APP-oidc in NS (store k8s-auth).
                      The client id is a literal in Git (T10); the secret is generated.
  --pg-shared         T1: source pg-NS in databases, managed role + Database + isolation Job +
                      network policy in pg-shared-homelab, copy APP-db in NS (store k8s-databases).
                      Needs the pg-shared-homelab template of lot 1 (see docs/operations/secrets-generated-runbook.md).
  --local-key USAGE   T4 (default) or T5 (USAGE:T5): generator + source APP-USAGE in NS, no store.
                      Only for a key that encrypts NOTHING persisted. Refused when the name looks
                      like a data-encryption key: use --data-key.
  --data-key USAGE    T6: writes NO generator. Prints the homelab-infra PR to open (random_bytes +
                      doppler_secret + prevent_destroy) and the doppler-cluster ExternalSecret.
  --external KIND     T8: reuse the existing Doppler token (cloudflare-dns: CLOUDFLARE_API_TOKEN,
                      r2-writer: R2_CNPG_WRITER_* + R2_S3_ENDPOINT) through a doppler-cluster ExternalSecret.
  --app-dir DIR       directory of the application under k8s/ (default: the unique k8s/applications/*/APP)
  --write             apply (otherwise dry-run). Refuses if any target file already exists.
  -h, --help          this help

The script never accepts a secret value: options carrying a value, a secret, a password or a token
are refused. Output lists names only.
EOF
}

die() { echo "ERROR: $*" >&2; exit "${2:-2}"; }
refuse() { echo "REFUSED: $*" >&2; exit 1; }

root=${SCAFFOLD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

app=""; ns=""; oidc=""; pg=0; write=0; app_dir_opt=""
local_keys=(); data_keys=(); externals=()

while (($#)); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --write) write=1 ;;
    --pg-shared) pg=1 ;;
    --namespace|--oidc|--local-key|--data-key|--external|--app-dir)
      opt=$1; (($# >= 2)) || die "$opt needs an argument"
      case $opt in
        --namespace) ns=$2 ;;
        --oidc) oidc=$2 ;;
        --local-key) local_keys+=("$2") ;;
        --data-key) data_keys+=("$2") ;;
        --external) externals+=("$2") ;;
        --app-dir) app_dir_opt=$2 ;;
      esac
      shift ;;
    --*=*) die "refused: write '--option VALUE', never '--option=VALUE' (this script accepts no secret value)" ;;
    --*secret*|--*password*|--*passwd*|--*token*|--*value*|--*credential*)
      refuse "this script never accepts a secret value ($1): secrets are generated in the cluster or stay in Doppler" ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) [[ -z $app ]] || die "unexpected argument: $1 (a single APP is expected)"; app=$1 ;;
  esac
  shift
done

[[ -n $app ]] || { usage >&2; exit 2; }
[[ -n $ns ]] || die "--namespace is required"

name_re='^[a-z]([a-z0-9-]{0,40}[a-z0-9])?$'
[[ $app =~ $name_re ]] || die "APP '$app' does not match $name_re"
[[ $ns =~ $name_re ]] || die "namespace '$ns' does not match $name_re"
# '--' is the usage separator of source names (oidc-NS--usage): a namespace containing it would let
# namespace 'a' read the sources of namespace 'a--b' (cross-namespace read).
[[ $ns != *--* ]] || refuse "namespace '$ns' contains '--': it would collide with the oidc-NS--usage / pg-NS--usage separator (cross-namespace read)"
case $ns in
  auth|databases|default|kube-system|kube-public|kube-node-lease|external-secrets|argocd|cnpg-system|kyverno|velero)
    refuse "namespace '$ns' is reserved: an application namespace never reads or owns the source namespaces" ;;
esac
if [[ -n $oidc ]]; then
  [[ $oidc =~ $name_re && ${#oidc} -le 32 && ! $oidc =~ ^[a-f0-9]{24,}$ ]] \
    || refuse "--oidc must be a short client id (lowercase name), not a secret value"
  [[ $oidc != *--* ]] || die "--oidc: '--' not allowed"
fi
for i in "${externals[@]}"; do
  [[ $i == cloudflare-dns || $i == r2-writer ]] || die "--external: unknown kind '$i' (cloudflare-dns | r2-writer)"
done
if ((pg)); then
  # Database name = PostgreSQL role and database name, and part of the isolation Job name
  # pg-shared-homelab-<db>-isolation (a Kubernetes name): no '-' or '_'.
  [[ $app =~ ^[a-z][a-z0-9]{0,30}$ ]] || die "--pg-shared: APP must be [a-z][a-z0-9]* (it becomes the role, the database and the Job name)"
  [[ $app != app ]] || refuse "'app' is reserved by pg-shared-homelab (bootstrap database)"
fi

upper() { printf '%s' "$1" | tr 'a-z-' 'A-Z_'; }
# Same expression as the T6 rule of tests/harness/eso-generated-secrets-contract-test.sh.
t6_re='ENCRYPT|KEY_BASE|APP_KEY|MASTER_KEY|RESTIC|REPOSITORY_PASSWORD|SECRET_KEY'

lk_usage=(); lk_class=(); lk_tkey=()
for spec in "${local_keys[@]}"; do
  usg=${spec%%:*}; cls=T4
  [[ $spec == *:* ]] && cls=${spec#*:}
  [[ $cls == T4 || $cls == T5 ]] || die "--local-key $spec: class must be T4 or T5"
  [[ $usg =~ ^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$ && $usg != *--* ]] || die "--local-key: usage '$usg' does not match the naming convention"
  tkey="$(upper "$usg")_SECRET"
  if [[ "$(upper "$usg")" =~ $t6_re || "$(upper "$app")_$(upper "$usg")" =~ $t6_re || $tkey =~ $t6_re ]]; then
    refuse "--local-key $usg looks like a data-encryption key (T6): a generated key is disposable and would make data unreadable. Use --data-key $usg (OpenTofu + Doppler)."
  fi
  lk_usage+=("$usg"); lk_class+=("$cls"); lk_tkey+=("$tkey")
done
for usg in "${data_keys[@]}"; do
  [[ $usg =~ ^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$ && $usg != *--* ]] || die "--data-key: usage '$usg' does not match the naming convention"
done

((${#local_keys[@]} || ${#externals[@]} || ${#data_keys[@]} || pg)) || [[ -n $oidc ]] || die "nothing to scaffold: give --oidc, --pg-shared, --local-key, --data-key or --external"

# The application directory is needed unless only --data-key (printed, nothing written) is requested.
app_dir=""
if ((${#local_keys[@]} || ${#externals[@]} || pg)) || [[ -n $oidc ]]; then
  if [[ -n $app_dir_opt ]]; then
    [[ $app_dir_opt != *..* && $app_dir_opt != /* ]] || die "--app-dir must stay under k8s/"
    app_dir=${app_dir_opt#./}; app_dir=${app_dir%/}
    [[ $app_dir == k8s/* ]] || die "--app-dir must be under k8s/"
  else
    shopt -s nullglob
    cands=("$root"/k8s/applications/*/"$app")
    shopt -u nullglob
    ((${#cands[@]} == 1)) || die "no unique application directory k8s/applications/*/$app (${#cands[@]} found): pass --app-dir"
    app_dir=${cands[0]#"$root"/}
  fi
  [[ -d $root/$app_dir ]] || die "application directory $app_dir does not exist"
fi

command -v yq >/dev/null || die "yq is required"
command -v python3 >/dev/null || die "python3 is required"

stage=$(mktemp -d "${TMPDIR:-/tmp}/scaffold-app-secrets.XXXXXX"); trap 'rm -rf "$stage"' EXIT
created=(); edited=()

emit() { # emit REL < content : stage a NEW file, refuse when the target exists
  local rel=$1
  [[ ! -e $root/$rel ]] || refuse "$rel already exists (idempotence by refusal): nothing written"
  [[ ! -e $stage/new/$rel ]] || die "internal: $rel emitted twice"
  mkdir -p "$(dirname "$stage/new/$rel")"; cat >"$stage/new/$rel"
  yq -e '.' "$stage/new/$rel" >/dev/null 2>&1 || die "internal: generated $rel is not valid YAML"
  created+=("$rel")
}

cat >"$stage/edit.py" <<'PYEOF'
import re, sys

kind, path, arg = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().split("\n")


def fail(msg):
    sys.stderr.write("REFUSED: %s (%s)\n" % (msg, path))
    sys.exit(1)


def indent(s):
    return len(s) - len(s.lstrip(" "))


if kind == "resource":  # append `- ARG` to the top-level `resources:` list
    start = next((i for i, l in enumerate(lines) if re.match(r"^resources:\s*(\[\s*\])?\s*$", l)), None)
    if start is None:
        fail("no top-level resources: list")
    if "[]" in lines[start]:
        lines[start] = "resources:"
        lines.insert(start + 1, "  - " + arg)
    else:
        last = start
        for i in range(start + 1, len(lines)):
            l = lines[i]
            if re.match(r"^\s*-\s", l):
                last = i
            elif l.strip() == "" or l.lstrip().startswith("#"):
                continue
            elif not l.startswith(" "):
                break
        if any(re.match(r"^\s*-\s*%s\s*$" % re.escape(arg), l) for l in lines[start:last + 1]):
            fail("resource %s already listed" % arg)
        ind = re.match(r"^(\s*)-", lines[last]).group(1) if last != start else "  "
        lines.insert(last + 1, "%s- %s" % (ind, arg))
elif kind == "resourcename":  # append a name after the sentinel's list in the Role
    s = next((i for i, l in enumerate(lines) if "eso-k8s-sentinel-none" in l and l.lstrip().startswith("-")), None)
    if s is None:
        fail("sentinel eso-k8s-sentinel-none not found in resourceNames")
    ind = indent(lines[s])
    last = s
    for i in range(s + 1, len(lines)):
        if lines[i].strip() and indent(lines[i]) == ind and lines[i].lstrip().startswith("- "):
            last = i
        else:
            break
    for l in lines:
        if l.strip().startswith("- ") and l.strip()[2:].split("#")[0].strip() == arg:
            fail("%s already in resourceNames" % arg)
    lines.insert(last + 1, " " * ind + "- " + arg)
elif kind == "envfrom":  # authentik values.yaml: add a secretRef with optional: true
    s = next((i for i, l in enumerate(lines) if re.match(r"^\s*envFrom:\s*$", l)), None)
    if s is None:
        fail("no envFrom: block")
    base = indent(lines[s])
    last = s
    for i in range(s + 1, len(lines)):
        if lines[i].strip() == "" or lines[i].lstrip().startswith("#") or indent(lines[i]) > base:
            if lines[i].strip() and not lines[i].lstrip().startswith("#"):
                last = i
        else:
            break
    for l in lines[s:last + 1]:
        if re.match(r"^\s*name:\s*%s\s*$" % re.escape(arg), l):
            fail("envFrom already references %s" % arg)
    pad = " " * (base + 2)
    lines[last + 1:last + 1] = [pad + "- secretRef:", pad + "    name: " + arg, pad + "    optional: true"]
elif kind == "reloader":  # authentik values.yaml: append to the secret.reloader list
    for i, l in enumerate(lines):
        m = re.match(r'^(\s*secret\.reloader\.stakater\.com/reload:\s*")([^"]*)(".*)$', l)
        if m:
            items = [x.strip() for x in m.group(2).split(",") if x.strip()]
            if arg in items:
                fail("Reloader list already holds %s" % arg)
            lines[i] = m.group(1) + ",".join(items + [arg]) + m.group(3)
            break
    else:
        fail("no secret.reloader.stakater.com/reload annotation")
elif kind == "pgrole":  # pg-shared-homelab cluster.yaml: add a managed role (ARG = app|secret)
    app, secret = arg.split("|")
    s = next((i for i, l in enumerate(lines) if re.match(r"^\s*roles:\s*(\[\s*\])?\s*(#.*)?$", l)), None)
    if s is None:
        fail("no managed.roles: block")
    base = indent(lines[s])
    pad = " " * (base + 2)
    block = [pad + "- name: " + app, pad + "  ensure: present", pad + "  login: true", pad + "  superuser: false",
             pad + "  createdb: false", pad + "  createrole: false", pad + "  passwordSecret:", pad + "    name: " + secret]
    if "[]" in lines[s]:
        lines[s] = " " * base + "roles:"
        lines[s + 1:s + 1] = block
    else:
        last = s
        for i in range(s + 1, len(lines)):
            if lines[i].strip() == "" or indent(lines[i]) > base:
                if lines[i].strip():
                    last = i
            else:
                break
        for l in lines[s:last + 1]:
            if re.match(r"^\s*-\s*name:\s*%s\s*$" % re.escape(app), l):
                fail("managed role %s already present" % app)
        lines[last + 1:last + 1] = block
else:
    fail("unknown edit " + kind)
open(path, "w", encoding="utf-8").write("\n".join(lines))
PYEOF

edit() { # edit KIND REL ARG : modify a COPY of an existing file (staged), refuse on conflict
  local kind=$1 rel=$2 arg=$3
  [[ -f $root/$rel ]] || die "$rel not found"
  if [[ ! -f $stage/mod/$rel ]]; then mkdir -p "$(dirname "$stage/mod/$rel")"; cp "$root/$rel" "$stage/mod/$rel"; fi
  python3 -I "$stage/edit.py" "$kind" "$stage/mod/$rel" "$arg" || exit 1
  edited+=("$rel: $kind $arg")
}

PW_SPEC='spec: {length: 48, digits: 10, symbols: 0, allowRepeat: true}   # no symbol: safe in a URL or a DSN'
gen_source() { # gen_source NAME NAMESPACE CLASS TEMPLATE_DATA_BLOCK [TEMPLATE_HEAD]
  cat <<YAML
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata: {name: $1, namespace: $2}
$PW_SPEC
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: $1  # rotation: rename to $1-r2, same target.name (spec F3)
  namespace: $2
  annotations:
    kube-ops.io/secret-class: $3
spec:
  refreshPolicy: CreatedOnce
  target:
    name: $1
    creationPolicy: Orphan      # survives the deletion of the ExternalSecret; a loss is a visible failure (spec F2)
    template:
      engineVersion: v2
${5:+$5
}      data:
$4
  dataFrom:
    - sourceRef:
        generatorRef: {apiVersion: generators.external-secrets.io/v1alpha1, kind: Password, name: $1}
YAML
}

copy_es() { # copy_es NAME STORE REMOTE_KEY PROPERTY TEMPLATE_DATA_BLOCK (ExternalSecret form B in NS)
  cat <<YAML
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: $1, namespace: $ns}
spec:
  refreshInterval: 1h
  secretStoreRef: {kind: ClusterSecretStore, name: $2}
  target:
    name: $1
    creationPolicy: Owner        # a copy is rebuilt from its source
    template:
      engineVersion: v2
      data:
$5
  data:
    - secretKey: $4
      remoteRef: {key: $3, property: $6}
YAML
}

reloader_names=()
doppler_notes=()
manual=()
auth_extra=k8s/infrastructure/auth/authentik/extra
auth_values=k8s/infrastructure/auth/authentik/values.yaml
pg_dir=k8s/infrastructure/database/pg-shared-homelab

# ---- T3: OIDC client ---------------------------------------------------------------------------
if [[ -n $oidc ]]; then
  ckey="$(upper "$oidc")_OIDC_CLIENT_SECRET"
  src="oidc-$ns"
  gen_source "$src" auth T3 "        $ckey: \"{{ .password }}\"   # unique key in the envFrom of Authentik" >"$stage/t3.yaml"
  emit "$auth_extra/$src.yaml" <"$stage/t3.yaml"
  edit resource "$auth_extra/kustomization.yml" "$src.yaml"
  edit resourcename "$auth_extra/eso-k8s-reader-rbac.yaml" "$src"
  edit envfrom "$auth_values" "$src"
  edit reloader "$auth_values" "$src"
  copy_es "$app-oidc" k8s-auth "$src" client_secret \
"        OIDC_CLIENT_ID: $oidc                       # T10: literal in Git (adapt the variable names to the app)
        OIDC_CLIENT_SECRET: \"{{ .client_secret }}\"" "$ckey" >"$stage/t3-copy.yaml"
  emit "$app_dir/$app-oidc-externalsecret.yaml" <"$stage/t3-copy.yaml"
  edit resource "$app_dir/kustomization.yaml" "$app-oidc-externalsecret.yaml"
  reloader_names+=("$app-oidc")
  manual+=("Authentik blueprint (extra/blueprints/apps-$app.yaml): client_secret: !Env $ckey, client_id: $oidc; list the blueprint in extra/kustomization.yml.")
fi

# ---- T1: pg-shared-homelab role ----------------------------------------------------------------
if ((pg)); then
  src="pg-$ns"
  gen_source "$src" databases T1 "        username: $app
        password: \"{{ .password }}\"" "      type: kubernetes.io/basic-auth
      metadata:
        labels:
          cnpg.io/reload: \"true\"" >"$stage/t1.yaml"
  emit "$pg_dir/$src.yaml" <"$stage/t1.yaml"
  edit resource "$pg_dir/kustomization.yaml" "$src.yaml"
  edit resourcename "$pg_dir/eso-k8s-reader-rbac.yaml" "$src"
  edit pgrole "$pg_dir/cluster.yaml" "$app|$src"
  digest=$(grep -Eo 'imageName: *[^ ]+' "$root/$pg_dir/cluster.yaml" | head -1 | sed 's/^imageName: *//' || true)
  [[ -n $digest ]] || die "imageName not found in $pg_dir/cluster.yaml"
  emit "$pg_dir/$app-database.yaml" <<YAML
# One database per application (template: $pg_dir/app-database.example.tmpl).
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata: {name: $app, namespace: databases}
spec:
  name: $app
  owner: $app
  cluster: {name: pg-shared-homelab}
---
# Isolation, REQUIRED (tests/harness/pg-shared-homelab-isolation-guard-test.sh): the Job fails, so the
# Argo CD application is not Healthy, if PUBLIC still has CONNECT. Bounded wait: Argo CD has no health
# check for CNPG kinds, so the Job may start before the role and the database exist.
apiVersion: batch/v1
kind: Job
metadata:
  name: pg-shared-homelab-$app-isolation
  namespace: databases
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
        - name: isolate
          image: $digest
          command: [sh, -ec]
          args:
            - |
              i=0
              until psql -tA -c "SELECT 1" >/dev/null 2>&1; do
                i=\$((i + 1)); [ "\$i" -lt 60 ] || { echo "database $app or role not ready" >&2; exit 1; }
                sleep 5
              done
              psql -v ON_ERROR_STOP=1 -c "REVOKE CONNECT ON DATABASE $app FROM PUBLIC"
              ok=\$(psql -v ON_ERROR_STOP=1 -tA -c "SELECT d.datacl IS NOT NULL AND NOT EXISTS (SELECT 1 FROM aclexplode(d.datacl) a WHERE a.grantee = 0 AND a.privilege_type = 'CONNECT') FROM pg_database d WHERE d.datname = '$app'")
              test "\$ok" = "t" || { echo "PUBLIC still has CONNECT on $app" >&2; exit 1; }
          env:
            - {name: PGHOST, value: pg-shared-homelab-rw.databases.svc.cluster.local}
            - {name: PGDATABASE, value: $app}
            - {name: PGSSLMODE, value: require}
            - name: PGUSER
              valueFrom: {secretKeyRef: {name: $src, key: username}}
            - name: PGPASSWORD
              valueFrom: {secretKeyRef: {name: $src, key: password}}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          resources:
            requests: {cpu: 10m, memory: 32Mi}
            limits: {cpu: 100m, memory: 64Mi}
---
# Ingress from the application namespace only (filters by source namespace, not by database).
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: pg-shared-homelab-$app, namespace: databases}
spec:
  endpointSelector: {matchLabels: {cnpg.io/cluster: pg-shared-homelab}}
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: $ns
      toPorts:
        - ports:
            - {protocol: TCP, port: "5432"}
YAML
  edit resource "$pg_dir/kustomization.yaml" "$app-database.yaml"
  copy_es "$app-db" k8s-databases "$src" password \
"        PGHOST: pg-shared-homelab-rw.databases.svc.cluster.local   # T10: literals in Git
        PGPORT: \"5432\"
        PGDATABASE: $app
        PGUSER: $app
        PGSSLMODE: require
        PGPASSWORD: \"{{ .password }}\"" password >"$stage/t1-copy.yaml"
  emit "$app_dir/$app-db-externalsecret.yaml" <"$stage/t1-copy.yaml"
  edit resource "$app_dir/kustomization.yaml" "$app-db-externalsecret.yaml"
  reloader_names+=("$app-db")
fi

# ---- T4 / T5: local keys -----------------------------------------------------------------------
for idx in "${!lk_usage[@]}"; do
  usg=${lk_usage[$idx]}; cls=${lk_class[$idx]}; tkey=${lk_tkey[$idx]}
  gen_source "$app-$usg" "$ns" "$cls" "        $tkey: \"{{ .password }}\"" >"$stage/lk.yaml"
  emit "$app_dir/$app-$usg-generated-secret.yaml" <"$stage/lk.yaml"
  edit resource "$app_dir/kustomization.yaml" "$app-$usg-generated-secret.yaml"
  reloader_names+=("$app-$usg")
  manual+=("$app-$usg ($cls): the Secret holds key $tkey. $cls is valid only if NOTHING persisted is encrypted with it; at the slightest doubt it is a T6 (--data-key).")
done

# ---- T8: reuse of existing external tokens (Doppler, no new key) --------------------------------
for kind in "${externals[@]}"; do
  if [[ $kind == cloudflare-dns ]]; then
    emit "$app_dir/$app-cloudflare-externalsecret.yaml" <<YAML
# T8: reuses the existing Doppler key CLOUDFLARE_API_TOKEN (study decision 3). No new Doppler key.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: $app-cloudflare, namespace: $ns}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: doppler-cluster, kind: ClusterSecretStore}
  target: {name: $app-cloudflare-api-token, creationPolicy: Owner}
  data:
    - secretKey: cloudflare-api-token
      remoteRef: {key: CLOUDFLARE_API_TOKEN}
YAML
    edit resource "$app_dir/kustomization.yaml" "$app-cloudflare-externalsecret.yaml"
    reloader_names+=("$app-cloudflare-api-token")
    doppler_notes+=("CLOUDFLARE_API_TOKEN (T8, existing, reused): scope and rotation stay in homelab-infra.")
  else
    emit "$app_dir/$app-r2-externalsecret.yaml" <<YAML
# T8: reuses the existing R2 writer keys (study decision 3). No new Doppler key.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: $app-r2-writer, namespace: $ns}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: doppler-cluster, kind: ClusterSecretStore}
  target: {name: $app-r2-writer, creationPolicy: Owner}
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef: {key: R2_CNPG_WRITER_ACCESS_KEY_ID}
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef: {key: R2_CNPG_WRITER_SECRET_ACCESS_KEY}
    - secretKey: AWS_ENDPOINT_URL_S3
      remoteRef: {key: R2_S3_ENDPOINT}
YAML
    edit resource "$app_dir/kustomization.yaml" "$app-r2-externalsecret.yaml"
    reloader_names+=("$app-r2-writer")
    doppler_notes+=("R2_CNPG_WRITER_* and R2_S3_ENDPOINT (T8, existing, reused): bucket and scope to review with the R2 owner.")
  fi
done

# ---- Defence in depth: every copy reads only its own namespace sources (spec 4.5) ---------------
if [[ -d $stage/new ]]; then
  while IFS= read -r f; do
    while IFS=$'\t' read -r store key; do
      [[ -n $store ]] || continue
      case $store in k8s-auth) p=oidc- ;; k8s-databases) p=pg- ;; *) continue ;; esac
      [[ $key == "$p$ns" || $key == "$p$ns--"* ]] || refuse "internal check: $f reads '$key' through $store, outside '$p$ns' (cross-namespace read)"
    done < <(yq -r 'select(.kind == "ExternalSecret") | .spec.secretStoreRef.name as $s | (.spec.data // [])[] | [$s, .remoteRef.key] | @tsv' "$f")
  done < <(find "$stage/new" -type f -name '*.yaml')
fi

# ---- Report ------------------------------------------------------------------------------------
if ((write)); then mode=WRITE; else mode=DRY-RUN; fi
echo "scaffold-app-secrets: app=$app namespace=$ns mode=$mode"
for f in ${created[@]+"${created[@]}"}; do echo "CREATE $f"; done
for e in ${edited[@]+"${edited[@]}"}; do echo "INSERT $e"; done

if ((write)); then
  if [[ -d $stage/new ]]; then (cd "$stage/new" && find . -type f -print0) | while IFS= read -r -d '' f; do
      mkdir -p "$(dirname "$root/${f#./}")"; cp "$stage/new/$f" "$root/${f#./}"; done; fi
  if [[ -d $stage/mod ]]; then (cd "$stage/mod" && find . -type f -print0) | while IFS= read -r -d '' f; do
      cp "$stage/mod/$f" "$root/${f#./}"; done; fi
fi

for usg in "${data_keys[@]}"; do
  key="APP_$(upper "$app")_$(upper "$usg")_KEY"
  cat <<EOF

T6 (data-encryption key): NO generator written. Open this PR in homelab-infra (root doppler), then add the ExternalSecret below.
  resource "random_bytes" "$(upper "$app" | tr 'A-Z' 'a-z')_${usg//-/_}" {
    length = 32
    lifecycle { prevent_destroy = true }
  }
  resource "doppler_secret" "$(printf '%s' "$app" | tr '-' '_')_${usg//-/_}" {
    project = "<doppler project>"
    config  = "<cluster config>"
    name    = "$key"
    value   = random_bytes.$(upper "$app" | tr 'A-Z' 'a-z')_${usg//-/_}.base64
    lifecycle {
      prevent_destroy = true
      ignore_changes  = [value]
    }
  }
  ExternalSecret in namespace $ns (store doppler-cluster, never generated in the cluster):
    spec: {refreshInterval: 1h, secretStoreRef: {name: doppler-cluster, kind: ClusterSecretStore}}
    data: [{secretKey: $key, remoteKey: $key}]
EOF
  doppler_notes+=("$key (T6): created by OpenTofu in Doppler, never by this script; add the key to the H2-style coverage (state copy).")
done

echo
echo "Reloader: on the consumer Deployment, secret.reloader.stakater.com/reload: \"$(IFS=,; echo "${reloader_names[*]:-<copy name>}")\""
for m in ${manual[@]+"${manual[@]}"}; do echo "TODO: $m"; done
echo "Doppler: ${doppler_notes[*]:+see below}${doppler_notes[*]:-nothing to create or copy by hand for T1, T3, T4, T5 (generated in the cluster).}"
for n in ${doppler_notes[@]+"${doppler_notes[@]}"}; do echo "  - $n"; done
echo "Next: just check; kustomize build --enable-helm on each touched root; open the PR as draft."
((write)) || echo "Dry-run: nothing written. Re-run with --write."
