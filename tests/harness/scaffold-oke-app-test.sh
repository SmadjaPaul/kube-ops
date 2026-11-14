#!/usr/bin/env bash
# Contract test of scripts/scaffold-oke-app.sh on a scratch copy of the tree layout.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/scaffold-oke-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/k8s/applications/tools/ok" "$tmp/k8s/applications/tools/data" "$tmp/k8s/clusters/oracle-a1/apps"
mkdir -p "$tmp/k8s/clusters/oracle-a1/bootstrap"
printf 'spec:\n  destinations:\n    - {server: https://kubernetes.default.svc, namespace: ok-ns}\n    - {server: https://kubernetes.default.svc, namespace: data-ns}\n    - {server: https://kubernetes.default.svc, namespace: q-ns}\n' >"$tmp/k8s/clusters/oracle-a1/bootstrap/project.yaml"
printf 'resources: []\n' >"$tmp/k8s/applications/tools/ok/kustomization.yaml"
printf 'resources:\n  - pvc.yaml\n' >"$tmp/k8s/applications/tools/data/kustomization.yaml"
printf 'apiVersion: v1\nkind: PersistentVolumeClaim\nmetadata:\n  name: d\n' >"$tmp/k8s/applications/tools/data/pvc.yaml"
printf 'resources:\n  - gatus.yaml\n' >"$tmp/k8s/clusters/oracle-a1/apps/kustomization.yaml"
mkdir -p "$tmp/k8s/applications/tools/quoted"
cp "$tmp/k8s/applications/tools/data/kustomization.yaml" "$tmp/k8s/applications/tools/quoted/"
printf 'apiVersion: v1\nkind: "PersistentVolumeClaim"\nmetadata:\n  name: q\n' >"$tmp/k8s/applications/tools/quoted/pvc.yaml"
# Fake kustomize: renders the folder and, recursively, the folders listed under `resources:`.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/kustomize" <<'SH'
#!/usr/bin/env bash
render() { local d=$1 r; cat "$d"/*.yaml 2>/dev/null; for r in $(sed -n 's/^  - \(\.\.\/.*\)$/\1/p' "$d/kustomization.yaml"); do render "$d/$r"; done; }
render "${@: -1}"
SH
chmod +x "$tmp/bin/kustomize"
mkdir -p "$tmp/k8s/applications/tools/viaref"
printf 'resources:\n  - ../data\n' >"$tmp/k8s/applications/tools/viaref/kustomization.yaml"
s() { PATH="$tmp/bin:$PATH" SCAFFOLD_ROOT="$tmp" bash "$repo_root/scripts/scaffold-oke-app.sh" "$@"; }
s tools/ok ok ok-ns >/dev/null
grep -q 'path: k8s/clusters/oracle-a1/ok$' "$tmp/k8s/clusters/oracle-a1/apps/ok.yaml"
grep -q '^  - ok.yaml$' "$tmp/k8s/clusters/oracle-a1/apps/kustomization.yaml"
grep -q 'applications/tools/ok$' "$tmp/k8s/clusters/oracle-a1/ok/kustomization.yaml"
refuse() { # expected stderr text, then scaffold args
  local want=$1; shift
  if err=$(s "$@" 2>&1 >/dev/null); then echo "FAIL: accepted: $*"; exit 1; fi
  [[ $err == *"$want"* ]] || { echo "FAIL: '$*' refused without '$want': $err"; exit 1; }
}
refuse "already exists" tools/ok ok ok-ns
refuse "BLOCKED: base holds data" tools/data data data-ns
refuse "BLOCKED: base holds data" tools/quoted quoted q-ns
refuse "BLOCKED: base holds data" tools/viaref viaref ok-ns      # data pulled in through resources
refuse "not a destination of AppProject" tools/ok other other-ns-unlisted
refuse "must stay under" ../x x x
[[ ! -e $tmp/k8s/clusters/oracle-a1/data && ! -e $tmp/k8s/clusters/oracle-a1/viaref ]]
# A commented project line is not a destination.
printf '    # - {server: https://kubernetes.default.svc, namespace: c-ns}\n' >>"$tmp/k8s/clusters/oracle-a1/bootstrap/project.yaml"
refuse "not a destination of AppProject" tools/ok c c-ns
# Fail closed without kustomize.
if err=$(env PATH="/usr/bin:/bin" SCAFFOLD_ROOT="$tmp" bash "$repo_root/scripts/scaffold-oke-app.sh" tools/ok nok ok-ns 2>&1 >/dev/null); then
  [[ -x /usr/bin/kustomize || -x /bin/kustomize ]] || { echo "FAIL: accepted without kustomize"; exit 1; }
else [[ $err == *"kustomize is required"* ]] || { echo "FAIL: wrong refusal without kustomize: $err"; exit 1; }; fi
echo "scaffold-oke-app contract test: PASS"
