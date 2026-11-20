#!/usr/bin/env bash
# PLT-390 : contrat de scripts/app-test.sh (sortie CHECK/APP_TEST, codes, cas negatifs et positif).
# Hors ligne : fixtures generees dans un depot factice (APP_TEST_ROOT), faux kubectl-ro/rw.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/app-test-harness.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
for c in kustomize yq jq; do command -v "$c" >/dev/null || { echo "APP_TEST_CONTRACT=BLOCKED missing_tool=$c"; exit 2; }; done

fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

root="$tmp/repo"
mkdir -p "$root/k8s/applications/fx" "$root/scripts/lib"
cp "$repo_root/renovate.json" "$root/renovate.json"
DIGEST="sha256:$(printf 'a%.0s' $(seq 64))"

# mk_app NAME : application conforme (positif). Les cas negatifs la derivent par sed/rm.
mk_app() {
  local d="$root/k8s/applications/fx/$1"; rm -rf "$d"; mkdir -p "$d"
  cat >"$d/kustomization.yaml" <<K
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [namespace.yaml, app.yaml, route.yaml, pvc.yaml, backup.yaml, netpol.yaml, monitor.yaml]
K
  cat >"$d/namespace.yaml" <<K
apiVersion: v1
kind: Namespace
metadata:
  name: $1
  labels: { pod-security.kubernetes.io/enforce: restricted }
K
  cat >"$d/app.yaml" <<K
apiVersion: apps/v1
kind: Deployment
metadata: { name: $1, namespace: $1 }
spec:
  replicas: 1
  selector: { matchLabels: { app: $1 } }
  template:
    metadata: { labels: { app: $1 } }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: $1
          image: ghcr.io/example/$1@$DIGEST
          env:
            - { name: OIDC_AUTH_ENABLED, value: "true" }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { cpu: 100m, memory: 64Mi } }
          readinessProbe: { httpGet: { path: /, port: 8080 } }
          livenessProbe: { httpGet: { path: /, port: 8080 } }
          volumeMounts: [{ name: data, mountPath: /data }]
      volumes: [{ name: data, persistentVolumeClaim: { claimName: $1-data } }]
---
apiVersion: v1
kind: Service
metadata: { name: $1, namespace: $1 }
spec: { selector: { app: $1 }, ports: [{ port: 80, targetPort: 8080 }] }
K
  cat >"$d/route.yaml" <<K
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: $1, namespace: $1 }
spec:
  parentRefs: [{ name: external, namespace: gateway }]
  hostnames: [$1.example.test]
  rules: [{ backendRefs: [{ name: $1, port: 80 }] }]
K
  cat >"$d/pvc.yaml" <<K
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $1-data, namespace: $1 }
spec: { accessModes: [ReadWriteOnce], storageClassName: longhorn-fast, resources: { requests: { storage: 1Gi } } }
K
  cat >"$d/backup.yaml" <<K
apiVersion: velero.io/v1
kind: Schedule
metadata: { name: daily-$1, namespace: velero }
spec:
  schedule: "0 2 * * *"
  template: { includedNamespaces: [$1], defaultVolumesToFsBackup: true, storageLocation: r2 }
K
  cat >"$d/netpol.yaml" <<K
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: $1, namespace: $1 }
spec:
  endpointSelector: {}
  ingress: [{ fromEntities: [ingress] }]
K
  cat >"$d/monitor.yaml" <<K
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: { name: $1, namespace: $1 }
spec: { selector: { matchLabels: { app: $1 } }, endpoints: [{ port: http }] }
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata: { name: $1, namespace: $1 }
spec: { groups: [{ name: $1, rules: [{ alert: Down, expr: "up == 0" }] }] }
K
}
app() { printf '%s' "$root/k8s/applications/fx/$1"; }
drop_file() { rm "$(app "$1")/$2"; sed -i.bak "s/, $2//" "$(app "$1")/kustomization.yaml"; }

# run_static NAME [args] : stdout dans $tmp/out, code dans $rc
run_static() {
  local n=$1; shift
  APP_TEST_ROOT="$root" bash "$repo_root/scripts/app-test.sh" "$n" "$n" --phase static "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
}
expect() { # expect LABEL CHECK_ID STATUS RC
  local label=$1 id=$2 st=$3 want_rc=$4
  grep -q "^CHECK $id $st " "$tmp/out" || fail "$label: attendu CHECK $id $st ; obtenu: $(grep "^CHECK $id " "$tmp/out" || echo absent) | $(head -3 "$tmp/err")"
  [[ $rc == "$want_rc" ]] || fail "$label: code $rc, attendu $want_rc"
  case "$want_rc" in
    0) grep -q '^APP_TEST=PASS$' "$tmp/out" || fail "$label: APP_TEST=PASS absent" ;;
    1) grep -q '^APP_TEST=FAIL$' "$tmp/out" || fail "$label: APP_TEST=FAIL absent" ;;
    2) grep -q '^APP_TEST=BLOCKED$' "$tmp/out" || fail "$label: APP_TEST=BLOCKED absent" ;;
  esac
}

# --- positif -------------------------------------------------------------------------------
mk_app good; run_static good
expect "positif" oidc PASS 0
for id in exposure backup renovate observability selfheal network; do
  grep -q "^CHECK $id PASS " "$tmp/out" || fail "positif: $id pas PASS ($(grep "^CHECK $id " "$tmp/out"))"
done
[[ $(grep -c '^CHECK ' "$tmp/out") == 7 ]] || fail "positif: 7 lignes CHECK attendues"

# --- negatifs ------------------------------------------------------------------------------
mk_app noauth; sed -i.bak '/OIDC_AUTH_ENABLED/d' "$(app noauth)/app.yaml"; run_static noauth
expect "route externe sans auth" oidc FAIL 1

mk_app nodigest; sed -i.bak "s#@$DIGEST#:1.2.3#" "$(app nodigest)/app.yaml"; run_static nodigest
expect "image sans digest" renovate FAIL 1

mk_app nonetpol; drop_file nonetpol netpol.yaml; run_static nonetpol
expect "namespace sans NetworkPolicy" network FAIL 1

mk_app lb
cat >>"$(app lb)/app.yaml" <<K
---
apiVersion: v1
kind: Service
metadata: { name: lb-ext, namespace: lb }
spec: { type: LoadBalancer, selector: { app: lb }, ports: [{ port: 80 }] }
K
run_static lb; expect "Service LoadBalancer" exposure FAIL 1

mk_app nobackup; drop_file nobackup backup.yaml; run_static nobackup
expect "PVC sans Schedule Velero" backup FAIL 1

mk_app noprobe; sed -i.bak '/Probe:/d' "$(app noprobe)/app.yaml"; run_static noprobe
expect "sans probes (observability)" observability FAIL 1
grep -q '^CHECK selfheal FAIL ' "$tmp/out" || fail "sans probes: selfheal devrait aussi etre FAIL"

mk_app pdb; sed -i.bak 's/replicas: 1/replicas: 2/' "$(app pdb)/app.yaml"; run_static pdb
expect "replicas 2 sans PDB" selfheal FAIL 1

mk_app norootfs; sed -i.bak 's/readOnlyRootFilesystem: true/readOnlyRootFilesystem: false/' "$(app norootfs)/app.yaml"; run_static norootfs
expect "rootfs en ecriture" network FAIL 1

mk_app nomonitor; drop_file nomonitor monitor.yaml; run_static nomonitor
expect "sans ServiceMonitor" observability FAIL 1

# --- exceptions ----------------------------------------------------------------------------
mk_app exc1; printf 'auth: none\n' >"$(app exc1)/app-test.yaml"
sed -i.bak '/OIDC_AUTH_ENABLED/d' "$(app exc1)/app.yaml"; run_static exc1
{ grep -q '^CHECK exceptions FAIL ' "$tmp/out" && [[ $rc == 1 ]]; } || fail "auth: none sans raison doit etre FAIL (rc=$rc)"
mk_app exc2; printf 'auth: none\nexceptions:\n  auth: "outil public sans donnee"\n' >"$(app exc2)/app-test.yaml"
sed -i.bak '/OIDC_AUTH_ENABLED/d' "$(app exc2)/app.yaml"; run_static exc2
expect "auth: none avec raison" oidc SKIP 0
mk_app exc3; printf 'backup: none\nexceptions:\n  backup: "   "\n' >"$(app exc3)/app-test.yaml"; run_static exc3
grep -q '^CHECK exceptions FAIL ' "$tmp/out" || fail "exception a raison vide doit etre FAIL"
mk_app exc4; printf 'backup: none\nexceptions:\n  backup: "cache jetable"\n' >"$(app exc4)/app-test.yaml"
drop_file exc4 backup.yaml; run_static exc4
expect "backup: none avec raison" backup SKIP 0
mk_app exc5; printf 'admin: true\n' >"$(app exc5)/app-test.yaml"; run_static exc5
expect "app admin sur la gateway externe" exposure FAIL 1
mk_app exc6; printf 'exceptions:\n  network: "audit seulement"\n' >"$(app exc6)/app-test.yaml"
drop_file exc6 netpol.yaml; run_static exc6
expect "exception network avec raison" network SKIP 0
mk_app exc7; printf 'bogus: 1\n' >"$(app exc7)/app-test.yaml"; run_static exc7
grep -q '^CHECK exceptions FAIL ' "$tmp/out" || fail "cle inconnue doit etre FAIL"

# --- usage et BLOCKED ----------------------------------------------------------------------
APP_TEST_ROOT="$root" bash "$repo_root/scripts/app-test.sh" absente absente --phase static >"$tmp/out" 2>&1; rc=$?
{ [[ $rc == 2 ]] && grep -q '^APP_TEST=BLOCKED$' "$tmp/out"; } || fail "app inconnue doit etre BLOCKED/2 (rc=$rc)"
APP_TEST_ROOT="$root" bash "$repo_root/scripts/app-test.sh" good >/dev/null 2>&1; [[ $? == 2 ]] || fail "usage sans namespace doit sortir 2"
APP_TEST_ROOT="$root" bash "$repo_root/scripts/app-test.sh" good 'x;y' --phase static >/dev/null 2>&1; [[ $? == 2 ]] || fail "namespace invalide doit sortir 2"

# --- runtime avec faux kubectl-ro / kubectl-rw -----------------------------------------------
cp "$repo_root/scripts/app-test.sh" "$root/scripts/app-test.sh"
cp "$repo_root/scripts/lib/kube-read.sh" "$repo_root/scripts/lib/output-mode.sh" "$root/scripts/lib/"
mkdir -p "$tmp/fake"
cat >"$tmp/fake-ro.sh" <<'FAKE_RO'
#!/usr/bin/env bash
[[ -z ${FAKE_FAIL:-} ]] || { echo "connection refused" >&2; exit 1; }
a="$*"; f=""
case "$a" in
  *"get namespace"*) f=ns ;; *"get pods"*) f=pods ;; *"get services"*) f=svc ;; *"get httproutes"*) f=routes ;;
  *"get pvc"*) f=pvc ;; *"get clusters.postgresql"*) f=cnpg ;; *"get backups.velero"*) f=vb ;;
  *"get backups.postgresql"*) f=cb ;; *"get scaledobjects"*) f=so ;; *"get --raw"*) f=up ;;
esac
if [[ -n $f && -f $FAKE_DIR/$f.json ]]; then cat "$FAKE_DIR/$f.json"; else echo 'Error from server (NotFound): not found' >&2; exit 1; fi
FAKE_RO
cat >"$tmp/fake-rw.sh" <<'FAKE_RW'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/rw.log"
cp "$FAKE_DIR/pods-after.json" "$FAKE_DIR/pods.json"
FAKE_RW
cat >"$tmp/probe.sh" <<'FAKE_PROBE_SH'
#!/usr/bin/env bash
echo "${FAKE_PROBE:-401 }"
FAKE_PROBE_SH
chmod +x "$tmp/fake-ro.sh" "$tmp/fake-rw.sh" "$tmp/probe.sh"
export APP_TEST_CHAOS_INTERVAL=0 FAKE_DIR="$tmp/fake" KUBECTL_RO_SCRIPT="$tmp/fake-ro.sh" KUBECTL_RW_SCRIPT="$tmp/fake-rw.sh" APP_TEST_PUBLIC_PROBE="$tmp/probe.sh"

now_minus_h() { jq -rn --argjson h "$1" '(now - $h * 3600) | todate'; }
rt_setup() { # [PSA enforce]
  echo "{\"metadata\":{\"name\":\"good\",\"labels\":{\"pod-security.kubernetes.io/enforce\":\"${1:-restricted}\"}}}" >"$FAKE_DIR/ns.json"
  echo '{"items":[{"metadata":{"name":"good-1"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}],"containerStatuses":[{"name":"good","restartCount":0}]}}]}' >"$FAKE_DIR/pods.json"
  sed 's/good-1/good-2/' "$FAKE_DIR/pods.json" >"$FAKE_DIR/pods-after.json"
  echo '{"items":[]}' >"$FAKE_DIR/svc.json"
  echo '{"items":[{"spec":{"parentRefs":[{"name":"external"}],"hostnames":["good.example.test"]}}]}' >"$FAKE_DIR/routes.json"
  echo '{"items":[{}]}' >"$FAKE_DIR/pvc.json"; echo '{"items":[]}' >"$FAKE_DIR/cnpg.json"
  echo "{\"items\":[{\"status\":{\"phase\":\"Completed\",\"completionTimestamp\":\"$(now_minus_h 5)\"},\"spec\":{\"includedNamespaces\":[\"good\"]}}]}" >"$FAKE_DIR/vb.json"
  echo '{"status":"success","data":{"result":[{"metric":{"job":"good"},"value":[0,"1"]}]}}' >"$FAKE_DIR/up.json"
  rm -f "$FAKE_DIR/so.json" "$FAKE_DIR/rw.log"
}
run_rt() { # run_rt NS [args]
  local ns=$1; shift
  APP_TEST_ROOT="$root" bash "$root/scripts/app-test.sh" good "$ns" --phase runtime "$@" >"$tmp/out" 2>"$tmp/err"; rc=$?
}
rt_setup; run_rt good
expect "runtime conforme" oidc PASS 0
for id in exposure backup observability selfheal network; do
  grep -q "^CHECK $id PASS " "$tmp/out" || fail "runtime conforme: $id ($(grep "^CHECK $id " "$tmp/out"))"
done
grep -q '^CHECK renovate SKIP ' "$tmp/out" || fail "runtime seul: renovate doit etre SKIP"

rt_setup; FAKE_PROBE="200 " run_rt good; expect "GET sans cookie => 200" oidc FAIL 1
rt_setup; FAKE_PROBE="302 https://auth.smadja.dev/application/o/authorize/" run_rt good; expect "302 Authentik" oidc PASS 0
rt_setup; FAKE_PROBE="302 https://evil.example/" run_rt good; expect "302 hors Authentik" oidc FAIL 1
rt_setup; echo "{\"items\":[{\"status\":{\"phase\":\"Completed\",\"completionTimestamp\":\"$(now_minus_h 40)\"},\"spec\":{\"includedNamespaces\":[\"good\"]}}]}" >"$FAKE_DIR/vb.json"
run_rt good; expect "backup de 40 h" backup FAIL 1
rt_setup; echo '{"status":"success","data":{"result":[{"metric":{"job":"good"},"value":[0,"0"]}]}}' >"$FAKE_DIR/up.json"; run_rt good
expect "cible up==0" observability FAIL 1
rt_setup; sed -i.bak 's/"True"/"False"/' "$FAKE_DIR/pods.json"; run_rt good; expect "pod non Ready" selfheal FAIL 1
rt_setup unrestricted; run_rt good; expect "PSA non restricted" network FAIL 1
rt_setup; rm "$FAKE_DIR/ns.json"; run_rt good; expect "namespace absent" selfheal FAIL 1
rt_setup; FAKE_FAIL=1 run_rt good; expect "cluster injoignable" selfheal BLOCKED 2
rt_setup; echo '{"items":[{"spec":{"type":"NodePort"},"metadata":{"name":"x"}}]}' >"$FAKE_DIR/svc.json"; run_rt good; expect "Service NodePort runtime" exposure FAIL 1

# chaos : refuse hors pr-*, delegue a kubectl-rw dans pr-*
rt_setup; run_rt good --chaos
[[ ! -f $FAKE_DIR/rw.log ]] || fail "chaos hors pr-* : aucune suppression permise"
grep -q 'refuse hors namespace pr-' "$tmp/out" || fail "chaos hors pr-*: refus non signale ($(grep '^CHECK selfheal' "$tmp/out"))"
rt_setup; run_rt pr-12-good --chaos
grep -q '^delete pr-12-good pod/good-1' "$FAKE_DIR/rw.log" 2>/dev/null || fail "chaos pr-*: kubectl-rw delete attendu ($(cat "$FAKE_DIR/rw.log" 2>/dev/null))"
grep -q 'chaos: pod good-1 supprime' "$tmp/out" || fail "chaos pr-*: remplacement Ready non constate ($(grep '^CHECK selfheal' "$tmp/out"))"

if ((fails > 0)); then echo "APP_TEST_CONTRACT=FAIL failures=$fails"; exit 1; fi
echo "APP_TEST_CONTRACT=PASS"
