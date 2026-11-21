#!/usr/bin/env bash
# Tests de la bibliotheque baseline (k8s/components/baseline-vap) et du rendu oracle-a1.
#   run.sh static   : rendu kustomize (bootstrap, apps, baseline, secret-stores, overlays) + kubeconform.
#   run.sh runtime  : admission serveur sur un cluster (kind en CI) : VAP chargees,
#                     pods conformes acceptes, non conformes refuses (dry-run=server).
#   run.sh static aussi : quotas de baseline/quotas.yaml == expected-quotas.tsv ; acceptance.sh est teste a part (--dry).
# Aucun secret, aucun acces a un cluster reel. KUBECONFIG pointe le cluster de test.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fx="$root/tests/oke-baseline/fixtures"
mode="${1:-static}"
cluster=k8s/clusters/oracle-a1

static() {
  command -v kustomize >/dev/null && command -v kubeconform >/dev/null || { echo "FAIL: kustomize/kubeconform requis" >&2; exit 2; }
  local out
  out="$(mktemp -d)"
  for t in bootstrap apps baseline secret-stores; do
    if [[ "$t" == bootstrap ]]; then
      kustomize build --enable-helm "$root/$cluster/$t" > "$out/$t.yaml"
    else
      kustomize build "$root/$cluster/$t" > "$out/$t.yaml"
    fi
  done
  kustomize build "$root/k8s/components/baseline-vap" > "$out/vap.yaml"
  for d in cnpg-cluster hindsight external-secrets cloudflared; do
    kustomize build --enable-helm "$root/$cluster/$d" > "$out/$d.yaml"
  done
  # Schemas CRD absents : -ignore-missing-schemas ignore les kinds Cilium, CNPG et ESO (aucun schema CRD
  # fourni) ; ils ne sont PAS valides ici. Seuls les kinds natifs Kubernetes le sont.
  kubeconform -summary -strict -ignore-missing-schemas "$out"/*.yaml
  quotas "$out/baseline.yaml"
  echo "STATIC=PASS"
}

# Quotas rendus == expected-quotas.tsv (arch/CAPACITY.md, S3). yq (mikefarah) requis.
quotas() {
  command -v yq >/dev/null || { echo "FAIL: yq requis" >&2; exit 2; }
  local ns rcpu rmem lmem pods got bad=0
  while IFS=$'\t' read -r ns rcpu rmem lmem pods; do
    [[ -z "$ns" || "$ns" == \#* ]] && continue
    got="$(yq ea -r "select(.kind == \"ResourceQuota\" and .metadata.namespace == \"$ns\") | .spec.hard | [.[\"requests.cpu\"], .[\"requests.memory\"], .[\"limits.memory\"], .pods] | join(\",\")" "$1")"
    if [[ "$got" == "$rcpu,$rmem,$lmem,$pods" ]]; then echo "PASS: quota $ns $got"; else echo "FAIL: quota $ns attendu $rcpu,$rmem,$lmem,$pods lu '$got'"; bad=1; fi
  done < "$root/tests/oke-baseline/expected-quotas.tsv"
  [[ $bad -eq 0 ]]
}

runtime() {
  command -v kubectl >/dev/null || { echo "FAIL: kubectl requis" >&2; exit 2; }
  kubectl apply -f <(kustomize build "$root/k8s/components/baseline-vap") >/dev/null
  # Attendre que les policies soient effectives (cache d'admission).
  for _ in $(seq 1 30); do
    kubectl get validatingadmissionpolicybinding baseline-pod-hardening >/dev/null 2>&1 && break; sleep 1
  done
  sleep 5
  # PSA non applique ici : chaque cas teste une regle VAP precise (PSA restricted est couvert par baseline/namespaces.yaml).
  kubectl create namespace auth --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create namespace databases --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fails=0
  expect() { # expect LABEL ATTENDU(deny|allow) FICHIER [MOTIF]
    local label="$1" want="$2" file="$3" motif="${4:-}" out rc=0
    set +e
    out="$(kubectl apply --dry-run=server -f "$fx/$file" 2>&1)"; rc=$?
    set -e
    local ok=1
    if [[ "$want" == deny && "$rc" -eq 0 ]]; then ok=0; fi
    if [[ "$want" == allow && "$rc" -ne 0 ]]; then ok=0; fi
    if [[ -n "$motif" ]] && ! grep -q -- "$motif" <<<"$out"; then ok=0; fi
    if [[ "$ok" -eq 1 ]]; then echo "PASS: $label"; else fails=$((fails+1)); echo "FAIL: $label (rc=$rc)"; echo "$out" | sed 's/^/    /'; fi
  }
  expect "pod privilegie refuse (auth)" deny pod-privileged.yaml "baseline-pod-hardening"
  expect "hostPath refuse (auth)" deny pod-hostpath.yaml "hostPath"
  expect "hostNetwork refuse (auth)" deny pod-hostnetwork.yaml "hostNetwork"
  expect "automount sans annotation refuse (auth, pod)" deny pod-automount.yaml "automountServiceAccountToken"
  expect "deployment sans automount refuse (auth)" deny deployment-no-automount-fail.yaml "automountServiceAccountToken"
  expect "deployment avec annotation automount accepte (databases)" allow deployment-automount-annotated.yaml
  expect "pod conforme accepte (auth)" allow pod-ok.yaml
  expect "tag non epingle : warning seulement (auth)" allow pod-tag-warn.yaml "container images must be pinned by digest"
  expect "privilegie accepte dans kube-system (exemption)" allow pod-kube-system-privileged.yaml
  echo "RUNTIME=$([[ $fails -eq 0 ]] && echo PASS || echo FAIL) fails=$fails"
  [[ $fails -eq 0 ]]
}

case "$mode" in
  static) static ;;
  runtime) runtime ;;
  *) echo "usage: $0 static|runtime" >&2; exit 2 ;;
esac
