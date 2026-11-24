#!/usr/bin/env bash
# PRD-83: reconciliateur Music Assistant : tests Python (faux MA) + contrat statique du kustomize.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/k8s/applications/automation/music-assistant"

python3 -I "$ROOT/tests/harness/ma-reconcile-test.py"
python3 -I "$ROOT/tests/harness/ma-publish-tokens-test.py"

if command -v kustomize >/dev/null 2>&1; then
  out="$(kustomize build "$APP")"
  # Aucun declenchement automatique : les trois CronJobs (plan, apply, publish-tokens) sont suspendus.
  [ "$(grep -c 'suspend: true' <<<"$out")" -eq 3 ] || {
    echo "FAIL: les CronJobs ma-reconcile et ma-publish-tokens doivent etre suspendus" >&2
    exit 1
  }
  grep -q 'name: ma-reconcile-script' <<<"$out"
  grep -q 'name: ma-reconcile-desired' <<<"$out"
  grep -q 'name: ma-reconcile-token' <<<"$out"
  # Le jeton MA n'est pas dans Doppler : Secret natif, hors Git.
  if grep -q 'key: APP_MA_RECONCILE_TOKEN' <<<"$out"; then
    echo "FAIL: jeton MA via ExternalSecret" >&2
    exit 1
  fi
  grep -q 'key: APP_MA_POLYFIN_PASSWORD' <<<"$out"
  # PRD-84 : jeton HA range par PATCH d'un seul Secret natif ; ni create, ni get, ni liste.
  role="$(awk '/^kind: Role$/{f=1} f&&/^---/{exit} f' <<<"$out" | tr -d '\n' | tr -s ' ')"
  [[ "$role" == *"resourceNames: - ma-home-assistant-token resources: - secrets verbs: - patch" ]] || {
    echo "FAIL: Role ma-reconcile doit etre patch seul sur le Secret ma-home-assistant-token" >&2
    exit 1
  }
  grep -q 'name: ma-home-assistant-token' <<<"$out"
  # Seul le job apply monte le jeton de ServiceAccount.
  [ "$(grep -c 'automountServiceAccountToken: true' <<<"$out")" -eq 1 ] || {
    echo "FAIL: un seul CronJob (apply) monte le jeton de ServiceAccount" >&2
    exit 1
  }
  # PRD-84 : ma-publish-tokens, jeton Doppler en ecriture pour ce job seul, sans API Kubernetes.
  pub="$(kustomize build "$APP" | yq -N 'select(.kind == "CronJob" and .metadata.name == "ma-publish-tokens")')"
  [ "$(grep -c 'maison-doppler-write' <<<"$out")" -ge 2 ] || {
    echo "FAIL: ExternalSecret maison-doppler-write absent" >&2
    exit 1
  }
  grep -q 'name: maison-doppler-write' <<<"$pub" || {
    echo "FAIL: le CronJob ma-publish-tokens doit lire le jeton Doppler en ecriture" >&2
    exit 1
  }
  for other in ma-reconcile-plan ma-reconcile-apply; do
    if kustomize build "$APP" | yq -N "select(.kind == \"CronJob\" and .metadata.name == \"$other\")" | grep -q 'maison-doppler-write\|APP_MAISON_DOPPLER_WRITE_TOKEN'; then
      echo "FAIL: $other ne doit pas voir le jeton Doppler en ecriture" >&2
      exit 1
    fi
  done
  grep -q 'automountServiceAccountToken: false' <<<"$pub" || {
    echo "FAIL: ma-publish-tokens ne monte pas le jeton de ServiceAccount" >&2
    exit 1
  }
  grep -Eq 'image: .*@sha256:[0-9a-f]{64}' <<<"$pub" || {
    echo "FAIL: image de ma-publish-tokens non epinglee par digest" >&2
    exit 1
  }
  cnp="$(kustomize build "$APP" | yq -N 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "ma-publish-tokens")')"
  [ "$(yq '[.spec.egress[].toFQDNs[].matchName] | join(",")' <<<"$cnp")" = "api.doppler.com" ] &&
    [ "$(yq '[.spec.egress[] | select(has("toFQDNs")) | .toPorts[].ports[].port] | join(",")' <<<"$cnp")" = "443" ] &&
    [ "$(yq '.spec.egress | length' <<<"$cnp")" = "2" ] &&
    [ "$(yq '.spec.ingress | length' <<<"$cnp")" = "0" ] || {
    echo "FAIL: egress de ma-publish-tokens = DNS + api.doppler.com:443 seulement, aucun ingress" >&2
    exit 1
  }
  # Aucun secret en clair dans les manifestes rendus.
  if grep -Eq 'kind: Secret$' <<<"$out"; then
    echo "FAIL: Secret en clair rendu" >&2
    exit 1
  fi
fi
echo "ma-reconcile-test: PASS"
