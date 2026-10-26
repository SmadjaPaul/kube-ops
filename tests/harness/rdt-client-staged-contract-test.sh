#!/usr/bin/env bash
# PLT-118: official RDT-Client stays dormant until full TorBox/Arr qualification.
set -euo pipefail
root=k8s/applications/media
pkg="$root/rdt-client"
fail() { echo "RDT_CLIENT_STAGED=FAIL: $*" >&2; exit 1; }
check() {
  local actual
  actual="$(yq -r "$1" "$2")"
  [[ "$actual" == "$3" ]] || fail "$2 $1 expected=$3 actual=$actual"
}

[[ -f "$pkg/kustomization.yaml" ]] || fail "missing staged package"
! grep -Eq '^[[:space:]]*-[[:space:]]+rdt-client([[:space:]]|$)' "$root/kustomization.yaml" ||
  fail "RDT-Client must not appear in active Media root"
[[ ! -e "$pkg/http-route.yaml" ]] || fail "no public/private HTTPRoute before auth qualification"
[[ ! -e "$pkg/networkpolicy.yaml" ]] ||
  fail "network policy must be qualified with live TorBox CDN evidence before admission"
check '.spec.replicas' "$pkg/deployment.yaml" '1'
check '.spec.template.spec.automountServiceAccountToken' "$pkg/deployment.yaml" 'false'
check '.spec.template.spec.containers[0].image' "$pkg/deployment.yaml" 'rogerfar/rdtclient:2.0.143'
check '.spec.template.spec.containers[0].env[] | select(.name == "SKIP_CHOWN") | .value' "$pkg/deployment.yaml" 'true'
check '.spec.template.spec.containers[0].env[] | select(.name == "PUID") | .value' "$pkg/deployment.yaml" '2501'
check '.spec.template.spec.containers[0].env[] | select(.name == "PGID") | .value' "$pkg/deployment.yaml" '2501'
check '.spec.template.spec.containers[0].ports[0].containerPort' "$pkg/deployment.yaml" '6500'
check '.spec.template.spec.volumes[] | select(.name == "media") | .persistentVolumeClaim.claimName' "$pkg/deployment.yaml" 'media-share'
check '.spec.template.spec.volumes[] | select(.name == "state") | .persistentVolumeClaim.claimName' "$pkg/deployment.yaml" 'rdt-client-state'
check '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .mountPath' "$pkg/deployment.yaml" '/data'
check '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "state") | .mountPath' "$pkg/deployment.yaml" '/data/db'
check '.spec.type' "$pkg/service.yaml" 'ClusterIP'
check '.spec.ports[0].port' "$pkg/service.yaml" '6500'
check '.metadata.annotations."argocd.argoproj.io/sync-options"' "$pkg/pvc.yaml" 'Prune=false'
check '.spec.storageClassName' "$pkg/pvc.yaml" 'longhorn-fast'
if grep -Eqi '(^|[[:space:]])(api[_-]?key|password|token):[[:space:]]*[^[:space:]]' "$pkg/deployment.yaml"; then
  fail "possible hardcoded credential"
fi
grep -Fq 'pin the immutable registry multiarch digest' "$pkg/README.md" ||
  fail 'missing immutable image admission gate'
grep -Fq 'media-access' "$pkg/README.md" ||
  fail 'missing Cilium bypass admission gate'
grep -Fq 'BookOrbit' "$pkg/README.md" ||
  fail 'missing BookOrbit category-less compatibility gate'
echo 'RDT_CLIENT_STAGED=PASS (STATIC_ONLY; ROOT_NOT_ADMITTED; RUNTIME=NOT_EXECUTED)'
