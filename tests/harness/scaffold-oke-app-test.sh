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
s() { SCAFFOLD_ROOT="$tmp" bash "$repo_root/scripts/scaffold-oke-app.sh" "$@"; }
s tools/ok ok ok-ns >/dev/null
grep -q 'path: k8s/clusters/oracle-a1/ok$' "$tmp/k8s/clusters/oracle-a1/apps/ok.yaml"
grep -q '^  - ok.yaml$' "$tmp/k8s/clusters/oracle-a1/apps/kustomization.yaml"
grep -q 'applications/tools/ok$' "$tmp/k8s/clusters/oracle-a1/ok/kustomization.yaml"
if s tools/ok ok ok-ns 2>/dev/null; then echo 'FAIL: duplicate accepted'; exit 1; fi
if s tools/data data data-ns 2>/dev/null; then echo 'FAIL: data base accepted'; exit 1; fi
[[ ! -e $tmp/k8s/clusters/oracle-a1/data ]]
if s tools/quoted quoted q-ns 2>/dev/null; then echo 'FAIL: quoted PVC kind accepted'; exit 1; fi
if s tools/ok other-ns-unlisted unlisted-ns 2>/dev/null; then echo 'FAIL: unlisted namespace accepted'; exit 1; fi
if s ../x x x 2>/dev/null; then echo 'FAIL: traversal accepted'; exit 1; fi
echo "scaffold-oke-app contract test: PASS"
