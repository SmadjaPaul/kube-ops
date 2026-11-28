#!/usr/bin/env bash
# PLT-542 : contrat hors reseau de la politique de l'image Pi (MutatingAdmissionPolicy).
#   * seul un pod de depot de terraform-provider-aiostreams change d'image et recoit le secret de
#     tirage ; les pods des autres depots et les pods de travaux ne changent pas ;
#   * l'image est epinglee par un digest reel (le digest nul de preparation est refuse).
# La CLI Kyverno 1.20 simule les MutatingAdmissionPolicy en v1alpha1 seulement : le test convertit
# la version d'API. La compilation CEL par l'API server (v1) n'est prouvee qu'a la reconciliation.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
policy="$ROOT/k8s/infrastructure/security/optio-agents/pi-image.yaml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

grep -qxF '  - pi-image.yaml' "$ROOT/k8s/infrastructure/security/optio-agents/kustomization.yaml" ||
  fail "pi-image.yaml hors kustomization"
sed 's#admissionregistration.k8s.io/v1$#admissionregistration.k8s.io/v1alpha1#' "$policy" >"$tmp/policy.yaml"
cat >"$tmp/values.yaml" <<'YAML'
apiVersion: cli.kyverno.io/v1alpha1
kind: Values
namespaceSelector:
  - name: optio
    labels: {kubernetes.io/metadata.name: optio}
YAML

apply() { # type repository container
  cat >"$tmp/pod.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: optio
  labels:
    managed-by: optio
    optio.type: $1
    optio.repo-url: https___github.com_smadjapaul_$2
spec:
  containers:
    - name: $3
      image: ghcr.io/jonwiggins/optio-agent-node:0.26.4
YAML
  kyverno apply "$tmp/policy.yaml" --resource "$tmp/pod.yaml" -f "$tmp/values.yaml" 2>&1 || true
}

out="$(apply repo-pod terraform-provider-aiostreams main)"
grep -q 'image: ghcr.io/smadjapaul/factory-optio-pi@sha256:' <<<"$out" || fail "image Pi non posee : $out"
grep -q -- '- name: optio-ghcr-pull' <<<"$out" || fail "secret de tirage non pose : $out"

for other in kube-ops homelab-infra agent-harness website ha-config terraform-provider-polyfin Atlas; do
  out="$(apply repo-pod "$(tr '[:upper:]' '[:lower:]' <<<"$other")" main)"
  grep -q 'pass: 0, fail: 0, warn: 0, error: 0' <<<"$out" || fail "$other ne doit pas changer : $out"
done
out="$(apply workflow-pod terraform-provider-aiostreams main)"
grep -q 'pass: 0, fail: 0, warn: 0, error: 0' <<<"$out" || fail "un pod de travail ne doit pas changer : $out"
out="$(apply repo-pod terraform-provider-aiostreams sidecar)"
if grep -q 'factory-optio-pi' <<<"$out"; then fail "conteneur inattendu modifie : $out"; fi
# JSONPatch test failures are a successful no-op in the API server; the matching pod must also
# be rejected by the bound ValidatingAdmissionPolicy, rather than admitted with its upstream image.
grep -qF 'kind: ValidatingAdmissionPolicy' "$policy" || fail "garde de validation du conteneur principal absente"
grep -qF 'name: optio-agent-pi-main-container-guard' "$policy" || fail "garde de validation du conteneur principal absente"
grep -qF "object.spec.containers[0].name == 'main'" "$policy" || fail "la validation n'impose pas le conteneur main"
grep -qF 'validationActions: [Deny]' "$policy" || fail "la validation ne refuse pas les conteneurs inattendus"
selector_count="$(grep -cF 'optio.repo-url: https___github.com_smadjapaul_terraform-provider-aiostreams' "$policy")"
[[ "$selector_count" -ge 2 ]] || fail "la validation ne cible pas le même dépôt canari"

grep -qE 'factory-optio-pi@sha256:[a-f0-9]{64}"' "$policy" || fail "image non epinglee par digest"
if grep -qE 'factory-optio-pi@sha256:0{64}' "$policy"; then
  fail "digest nul : remplacer par le digest publie avant tout merge"
fi

echo "OPTIO_PI_IMAGE=PASS"
