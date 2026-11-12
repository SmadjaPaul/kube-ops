#!/usr/bin/env bash
# Read-only ad hoc kubectl through the canonical operator access (AGENTS.md).
#
# Usage: bash scripts/kubectl-ro.sh <get|describe|logs|top|events|api-resources|version> [args...]
#   bash scripts/kubectl-ro.sh get applications -n argocd
#   bash scripts/kubectl-ro.sh logs -n cilium ds/cilium --tail=50
#
# Access comes from scripts/lib/kube-preflight.sh (Doppler bootstrap, SHA-256,
# TLS, API auth): the verified kubeconfig lives in a 0600 temp dir for this
# process only and is removed on exit. It is never copied elsewhere.
# Prefer `just status-app`, `just diagnose-app`, `just runtime-inventory` for
# Argo evidence; use this wrapper for anything they do not cover.
#
# Refused: any verb outside the list above; Secret contents (get secret with
# -o/--output, --raw); flags that swap credentials or weaken TLS.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

refuse() { echo "kubectl-ro: refusé : $*" >&2; exit 64; }

[ "$#" -ge 1 ] || refuse "verbe manquant (get|describe|logs|top|events|api-resources|version)"

verb=$1
case "$verb" in
  get|describe|logs|top|events|api-resources|version) ;;
  *) refuse "verbe '$verb' hors liste blanche (lecture seule : get|describe|logs|top|events|api-resources|version)" ;;
esac

secret_ref=0
output_flag=0
for arg in "${@:2}"; do
  lower=$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    --kubeconfig|--kubeconfig=*|--token|--token=*|--as|--as=*|--as-group|--as-group=*|--as-uid|--as-uid=*|\
    --server|--server=*|-s|--user|--user=*|--context|--context=*|--cluster|--cluster=*|\
    --client-key|--client-key=*|--client-certificate|--client-certificate=*|--username|--username=*|--password|--password=*)
      refuse "option '$arg' : l'accès vient uniquement de kube-preflight.sh" ;;
    --insecure-skip-tls-verify|--insecure-skip-tls-verify=*|--certificate-authority|--certificate-authority=*|--tls-server-name|--tls-server-name=*)
      refuse "option '$arg' : TLS non contournable" ;;
    --raw|--raw=*)
      refuse "option '$arg' : accès API brut non autorisé" ;;
    -w|--watch|--watch=*|--watch-only|--watch-only=*|--follow|--follow=*)
      refuse "option '$arg' : sortie non bornée (pas de watch/follow)" ;;
    -f)
      [ "$verb" != logs ] || refuse "option '-f' : sortie non bornée (utiliser --tail=N)" ;;
    -o|--output|-o*|--output=*|--template|--template=*)
      output_flag=1 ;;
  esac
  # secret / secrets / sec, alone, in a comma list, or as type/name
  if printf '%s' "$lower" | grep -Eq '(^|[,/])(secret|secrets|sec)($|[,/.])'; then
    secret_ref=1
  fi
done

if [ "$verb" = get ] && [ "$secret_ref" = 1 ] && [ "$output_flag" = 1 ]; then
  refuse "contenu d'un Secret (get secret avec -o/--output) ; utiliser 'get secret' sans -o ou 'describe secret' (tailles seulement)"
fi

# shellcheck source=/dev/null
source "$HERE/lib/kube-preflight.sh"
set +e
umask 077
status_file=$(mktemp "${TMPDIR:-/tmp}/kubectl-ro.XXXXXX")
trap 'kube_access_cleanup; rm -f "$status_file"' EXIT
# in this shell, not $(...): the verified KUBECONFIG must stay exported
if ! require_kube_access >"$status_file" 2>&1; then
  grep -E '^(KUBE_ACCESS|REASON|NEXT_ACTION)=' "$status_file" >&2
  exit 2
fi
# the preflight may have replaced the EXIT trap; keep both cleanups
trap 'kube_access_cleanup; rm -f "$status_file"' EXIT

kubectl --request-timeout=30s "$@"
