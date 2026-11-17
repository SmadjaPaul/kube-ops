#!/usr/bin/env bash
# Tests de la bibliotheque baseline (k8s/components/baseline-vap) et du rendu oracle-a1.
#   run.sh static   : rendu kustomize (bootstrap, apps, baseline, secret-stores, overlays) + kubeconform.
#   run.sh runtime  : admission serveur sur un cluster (kind en CI) : VAP chargees,
#                     pods conformes acceptes, non conformes refuses (dry-run=server).
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
  # Schemas CRD absents : -ignore-missing-schemas (Cilium, CNPG, ESO, VAP v1 couverts par kubeconform 0.8).
  kubeconform -summary -strict -ignore-missing-schemas "$out"/*.yaml
  echo "STATIC=PASS"
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
  kubectl create namespace backstage --dry-run=client -o yaml | kubectl apply -f - >/dev/null
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
  expect "pod privilegie refuse (backstage)" deny pod-privileged.yaml "baseline-pod-hardening"
  expect "hostPath refuse (backstage)" deny pod-hostpath.yaml "hostPath"
  expect "hostNetwork refuse (backstage)" deny pod-hostnetwork.yaml "hostNetwork"
  expect "automount sans annotation refuse (backstage, pod)" deny pod-automount.yaml "automountServiceAccountToken"
  expect "deployment sans automount refuse (backstage)" deny deployment-no-automount-fail.yaml "automountServiceAccountToken"
  expect "deployment avec annotation automount accepte (databases)" allow deployment-automount-annotated.yaml
  expect "pod conforme accepte (backstage)" allow pod-ok.yaml
  expect "tag non epingle : warning seulement (backstage)" allow pod-tag-warn.yaml
  expect "privilegie accepte dans kube-system (exemption)" allow pod-kube-system-privileged.yaml
  echo "RUNTIME=$([[ $fails -eq 0 ]] && echo PASS || echo FAIL) fails=$fails"
  [[ $fails -eq 0 ]]
}

case "$mode" in
  static) static ;;
  runtime) runtime ;;
  *) echo "usage: $0 static|runtime" >&2; exit 2 ;;
esac
