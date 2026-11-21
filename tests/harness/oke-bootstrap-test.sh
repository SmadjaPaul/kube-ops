#!/usr/bin/env bash
# Contrat de scripts/oke-bootstrap.sh (PLT-405) avec kubectl et kustomize factices : aucun cluster,
# aucun reseau, aucun secret. Verifie l'ordre (CRD avant Application/AppProject), l'idempotence
# (server-side apply seulement), le dry-run sans appel API et les refus d'arguments.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/oke-bootstrap.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$tmp/bin"
cat >"$tmp/bin/kustomize" <<'SH'
#!/usr/bin/env bash
cat <<'YAML'
apiVersion: v1
kind: Namespace
metadata: {name: argocd}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: applications.argoproj.io}
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: bootstrap, namespace: argocd}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: root, namespace: argocd}
YAML
SH
cat >"$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
# journal des appels ; le contenu applique est range pour inspection
echo "kubectl $*" >>"$FAKE_LOG"
case "$*" in
  *"config current-context"*) echo fake-oke ;;
  *"apply --server-side -f "*) n=$(grep -c '^kubectl.*apply' "$FAKE_LOG"); cp "${@: -1}" "$FAKE_DIR/apply-$n.yaml" ;;
esac
exit 0
SH
chmod +x "$tmp/bin/kustomize" "$tmp/bin/kubectl"
export FAKE_LOG="$tmp/log" FAKE_DIR="$tmp"; : >"$FAKE_LOG"
kc="$tmp/kubeconfig"; echo "not-a-real-kubeconfig" >"$kc"
run() { PATH="$tmp/bin:$PATH" bash "$script" "$@" >"$tmp/out" 2>&1; }

# 1. dry-run : rend, n'appelle jamais l'API
run --kubeconfig "$kc" --dry-run || { cat "$tmp/out" >&2; fail "dry-run must pass"; }
[[ ! -s $FAKE_LOG ]] || { cat "$FAKE_LOG" >&2; fail "dry-run must not call kubectl"; }
grep -q 'DRY-RUN' "$tmp/out" || fail "dry-run marker missing"

# 2. apply : namespace et CRD d'abord, puis attente des CRD, puis projet et root
run --kubeconfig "$kc" || { cat "$tmp/out" >&2; fail "bootstrap must pass"; }
grep -q 'get --raw /readyz' "$FAKE_LOG" || fail "API reachability not checked"
first=$(grep -n 'apply --server-side' "$FAKE_LOG" | sed -n 1p | cut -d: -f1)
wait_crd=$(grep -n 'wait --for=condition=Established' "$FAKE_LOG" | sed -n 1p | cut -d: -f1)
second=$(grep -n 'apply --server-side' "$FAKE_LOG" | sed -n 2p | cut -d: -f1)
[[ -n $first && -n $wait_crd && -n $second && $first -lt $wait_crd && $wait_crd -lt $second ]] || { cat "$FAKE_LOG" >&2; fail "order must be apply, wait CRD, apply"; }
grep -q 'kind: Namespace' "$tmp/apply-1.yaml" || fail "first pass must hold the namespace"
if grep -qE 'kind: (Application|AppProject)' "$tmp/apply-1.yaml"; then fail "first pass must hold no Application/AppProject"; fi
grep -q 'kind: Application' "$tmp/apply-2.yaml" || fail "second pass must hold the Application"
grep -q 'kind: AppProject' "$tmp/apply-2.yaml" || fail "second pass must hold the AppProject"
if grep ' apply ' "$FAKE_LOG" | grep -qv -- '--server-side'; then fail "only server-side apply"; fi
if grep -qE 'get secret|secrets|--force|delete' "$FAKE_LOG"; then fail "no secret access, no delete"; fi

# 3. une seconde execution est identique (idempotence : memes appels)
cp "$FAKE_LOG" "$tmp/log1"; : >"$FAKE_LOG"
run --kubeconfig "$kc" || fail "second run must pass"
cmp -s <(sed "s# -f .*##" "$tmp/log1") <(sed "s# -f .*##" "$FAKE_LOG") || fail "second run must replay the same calls"

# 4. refus
if run; then fail "missing --kubeconfig must be refused"; fi
if run --kubeconfig "$tmp/absent"; then fail "missing kubeconfig file must be refused"; fi
if run --kubeconfig "$kc" --bogus; then fail "unknown flag must be refused"; fi
if grep -qF "$(cat "$kc")" "$tmp/out"; then fail "kubeconfig content must never be printed"; fi

# Le découpage early/late garde les séparateurs de documents : avec --no-doc, yq colle les
# objets et kubectl apply reçoit un objet fusionné (NetworkPolicy argocd-server + rules d'un RBAC).
if grep -nE "yq eval --no-doc 'select\(" "$script"; then fail "split must keep YAML document separators (no --no-doc)"; fi

echo "OK: oke-bootstrap contract"
