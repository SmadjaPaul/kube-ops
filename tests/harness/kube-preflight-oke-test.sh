#!/usr/bin/env bash
# PLT-481 : lecture de la copie OKE du kubeconfig agent. Source 1 identity/agt (renouvelée par le
# CronJob d'OKE), source 2 infrastructure/prd (--provision). Doppler et kubectl sont simulés.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/lib/kube-preflight.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/kube-preflight-oke.XXXXXX")"
trap 'rm -rf "$tmp"; kube_access_cleanup' EXIT

jwt() { # jwt EXP_EPOCH
  local h p
  h=$(printf '{"alg":"none"}' | base64 | tr -d '=\n' | tr '+/' '-_')
  p=$(printf '{"exp":%s}' "$1" | base64 | tr -d '=\n' | tr '+/' '-_')
  printf '%s.%s.sig' "$h" "$p"
}
now=$(date -u +%s)
fresh=$(jwt $((now + 3600)))
stale=$(jwt $((now - 3600)))

# Le « kubeconfig » simulé est le jeton seul ; kubectl simulé en tire jsonpath et JSON.
kubectl() {
  local tok
  tok=$(cat "$KUBECONFIG")
  case "$*" in
    *jsonpath*) printf '%s' "$tok" ;;
    config\ view*) printf '%s' "json:$tok" ;;
    *) return 1 ;;
  esac
}
digest() { printf '%s' "json:$1" | _kube_access_sha256_stream; }

SECRET=KUBERNETES_AGENT_OPERATOR_KUBECONFIG_ORACLE_A1
doppler() {
  [[ "$1" == me ]] && return 0
  # doppler secrets get NAME --project P --config prd --plain
  local name=$3 proj=$5 var
  case "$proj:$name" in
    "identity:$SECRET") var=AA_TOKEN ;;
    "identity:${SECRET}_SHA256") var=AA_SHA ;;
    "infrastructure:$SECRET") var=INFRA_TOKEN ;;
    "infrastructure:${SECRET}_SHA256") var=INFRA_SHA ;;
    *) return 1 ;;
  esac
  [[ -n "${!var:-}" ]] || return 1
  printf '%s' "${!var}"
}

run() {
  KUBE_ACCESS_SOURCE=''
  KUBE_ACCESS_TOKEN_EXPIRES=''
  export KUBE_ACCESS_KUBECONFIG_SECRET=$SECRET
  if _materialize_canonical_operator_kubeconfig 2>"$tmp/err"; then
    echo "SOURCE=$KUBE_ACCESS_SOURCE EXP=${KUBE_ACCESS_TOKEN_EXPIRES:-}"
  else
    cat "$tmp/err"
  fi
}
expect() { # expect NAME SOUS-CHAINE SORTIE
  [[ "$3" == *"$2"* ]] || { printf 'ASSERTION_FAILED %s attendu=%s sortie=%s\n' "$1" "$2" "$3" >&2; exit 1; }
}
fresh_sha=$(digest "$fresh")
stale_sha=$(digest "$stale")

# 1. agent-access valide : première source, expiration affichée
export AA_TOKEN=$fresh AA_SHA=$fresh_sha INFRA_TOKEN=$fresh INFRA_SHA=$fresh_sha
out=$(run 2>&1 | tail -1)
expect agent-access-ok 'SOURCE=doppler_agent_access_oracle_a1_distribution' "$out"
expect agent-access-exp 'EXP=20' "$out"

# 2. agent-access absente : repli sur infrastructure
export AA_TOKEN= AA_SHA=
out=$(run 2>&1 | tail -1)
expect fallback-missing 'SOURCE=doppler_agent_operator_oracle_a1_distribution' "$out"

# 3. agent-access expirée, infrastructure valide : repli
export AA_TOKEN=$stale AA_SHA=$stale_sha
out=$(run 2>&1 | tail -1)
expect fallback-expired 'SOURCE=doppler_agent_operator_oracle_a1_distribution' "$out"

# 4. empreinte altérée dans agent-access : repli
export AA_TOKEN=$fresh AA_SHA=deadbeef
out=$(run 2>&1 | tail -1)
expect fallback-mismatch 'SOURCE=doppler_agent_operator_oracle_a1_distribution' "$out"

# 5. les deux expirées : refus lisible
export AA_TOKEN=$stale AA_SHA=$stale_sha INFRA_TOKEN=$stale INFRA_SHA=$stale_sha
out=$(run 2>&1)
expect both-expired 'REASON=agent_token_expired' "$out"

# 6. levier KUBE_ACCESS_DOPPLER_PROJECT : source unique, pas de repli
export AA_TOKEN=$fresh AA_SHA=$fresh_sha INFRA_TOKEN=$fresh INFRA_SHA=$fresh_sha
out=$(export KUBE_ACCESS_DOPPLER_PROJECT=infrastructure; run 2>&1 | tail -1)
expect override 'SOURCE=doppler_agent_operator_oracle_a1_distribution' "$out"

printf '%s\n' 'KUBE_PREFLIGHT_OKE_TEST=PASS'
