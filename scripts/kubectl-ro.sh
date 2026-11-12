#!/usr/bin/env bash
# Read-only ad hoc kubectl through the canonical operator access (AGENTS.md).
#
# Usage: bash scripts/kubectl-ro.sh <get|describe|logs|top|events|api-resources|version> [args...]
#   bash scripts/kubectl-ro.sh get applications -n argocd
#   bash scripts/kubectl-ro.sh logs -n cilium ds/cilium --tail=50
#   bash scripts/kubectl-ro.sh get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=up'
#
# Access comes from scripts/lib/kube-preflight.sh (Doppler bootstrap, SHA-256,
# TLS, API auth): the verified kubeconfig lives in a 0600 temp dir for this
# process only and is removed on exit. It is never copied elsewhere.
# Prefer `just status-app`, `just diagnose-app`, `just runtime-inventory` for
# Argo evidence; use this wrapper for anything they do not cover.
#
# Refused: any verb outside the list above; Secret contents (get secret with
# -o/--output other than `-o name`, -v>=6); flags that swap credentials or weaken TLS;
# --raw except the exact form `get --raw <path>` where <path> is a read-only
# Prometheus/Loki query API reached through the API server service proxy
# (monitoring/kube-prometheus-stack-prometheus:9090, monitoring/loki-gateway:80,
# monitoring/loki:3100). Query strings must be percent-encoded (PromQL/LogQL).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

refuse() { echo "kubectl-ro: refusé : $*" >&2; exit 64; }

[ "$#" -ge 1 ] || refuse "verbe manquant (get|describe|logs|top|events|api-resources|version)"

verb=$1
case "$verb" in
  get|describe|logs|top|events|api-resources|version) ;;
  *) refuse "verbe '$verb' hors liste blanche (lecture seule : get|describe|logs|top|events|api-resources|version)" ;;
esac

# --- metrics: `get --raw <path>` limited to the monitoring query APIs (PLT-167/187)
RAW_MAX=4096
RAW_SVC='/api/v1/namespaces/monitoring/services'
RAW_LABEL='label/[A-Za-z_][A-Za-z0-9_]*/values'
RAW_PROM="kube-prometheus-stack-prometheus:9090/proxy/api/v1/(query|query_range|series|labels|$RAW_LABEL)"
RAW_LOKI="(loki-gateway:80|loki:3100)/proxy/loki/api/v1/(query|query_range|series|labels|$RAW_LABEL)"
RAW_PATH_RE="^$RAW_SVC/($RAW_PROM|$RAW_LOKI)\$"
# query: unreserved chars, & = + , : and printable %XX (literal '/', '?', '#' refused; %2F/%3F
# only reach the backend as decoded query values, never the proxied path)
RAW_QUERY_RE='^([A-Za-z0-9._~=&+,:-]|%[2-7][0-9A-Fa-f])*$'
raw_check() { # raw_check PATH -> refuse unless allowed
  local raw=$1 path query="" LC_ALL=C
  [ "${#raw}" -le "$RAW_MAX" ] || refuse "--raw : chemin trop long (> $RAW_MAX)"
  case "$raw" in *..*|*//*|*'#'*|*\\*) refuse "--raw : '..', '//', '#' ou '\\' interdits" ;; esac
  path=${raw%%\?*}
  [ "$path" = "$raw" ] || query=${raw#*\?}
  [[ "$path" =~ $RAW_PATH_RE ]] ||
    refuse "--raw '$path' : seul le proxy de lecture Prometheus/Loki est autorisé ($RAW_SVC/{kube-prometheus-stack-prometheus:9090|loki-gateway:80|loki:3100}/proxy/.../(query|query_range|series|labels|label/<nom>/values))"
  [[ "$query" =~ $RAW_QUERY_RE ]] ||
    refuse "--raw : paramètres de requête invalides (encoder PromQL/LogQL en %XX ; un seul '?', pas de '/' ni de caractère de contrôle)"
}
raw_mode=0
for arg in "${@:2}"; do
  case "$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')" in --raw|--raw=*) raw_mode=1 ;; esac
done
if [ "$raw_mode" = 1 ]; then
  if [ "$verb" = get ] && [ "$#" = 3 ] && [ "$2" = --raw ]; then
    raw_check "$3"
  elif [ "$verb" = get ] && [ "$#" = 2 ] && [ "${2#--raw=}" != "$2" ]; then
    raw_check "${2#--raw=}"
  else
    refuse "--raw : seule la forme exacte 'get --raw <chemin>' est autorisée (aucune autre option)"
  fi
fi

secret_ref=0
output_flag=0
next_is_output=0
for arg in "${@:2}"; do
  lower=$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')
  if [ "$next_is_output" = 1 ]; then
    next_is_output=0
    [ "$lower" = name ] || output_flag=1
    continue
  fi
  case "$arg" in
    # kubectl (pflag) reads --a_b as --a-b: normalize before matching
    --*) lower=${lower//_/-} ;;
    # grouped short flags (-Aoyaml = -A -o yaml, -Av8, -Rf dir) would dodge the checks below:
    # only value-taking shorthands may carry a suffix (-oname, -nmonitoring, -lapp=x, -cname, -Lcol)
    -[!-]?*)
      case "$arg" in
        -[onlcL]*) ;;
        *) refuse "option '$arg' : options courtes groupées ou collées interdites (les séparer : -A -o ...)" ;;
      esac ;;
  esac
  case "$lower" in
    --kubeconfig|--kubeconfig=*|--token|--token=*|--as|--as=*|--as-group|--as-group=*|--as-uid|--as-uid=*|\
    --server|--server=*|-s|-s*|--user|--user=*|--context|--context=*|--cluster|--cluster=*|\
    --client-key|--client-key=*|--client-certificate|--client-certificate=*|--username|--username=*|--password|--password=*)
      refuse "option '$arg' : l'accès vient uniquement de kube-preflight.sh" ;;
    --insecure-skip-tls-verify|--insecure-skip-tls-verify=*|--certificate-authority|--certificate-authority=*|--tls-server-name|--tls-server-name=*)
      refuse "option '$arg' : TLS non contournable" ;;
    --raw|--raw=*)
      [ "$raw_mode" = 1 ] || refuse "option '$arg' : accès API brut non autorisé" ;;
    -v|-v=*|-v[0-9]*|--v|--v=*|--vmodule|--vmodule=*)
      refuse "option '$arg' : la verbosité kubectl affiche les corps HTTP (Secrets compris)" ;;
    -k|-k*|--kustomize|--kustomize=*|--filename|--filename=*|-r|-R|--recursive|--recursive=*|-f?*)
      refuse "option '$arg' : lecture par fichier/kustomize non autorisée (nommer la ressource)" ;;
    -w|--watch|--watch=*|--watch-only|--watch-only=*|--follow|--follow=*)
      refuse "option '$arg' : sortie non bornée (pas de watch/follow)" ;;
    -f)
      [ "$verb" != logs ] || refuse "option '-f' : sortie non bornée (utiliser --tail=N)"
      refuse "option '-f' : lecture par fichier non autorisée (nommer la ressource)" ;;
    -oname|--output=name) ;;
    -o|--output)
      next_is_output=1 ;;
    -o*|--output=*|--template|--template=*)
      output_flag=1 ;;
  esac
  # secret / secrets / sec, alone, in a comma list, or as type/name
  if printf '%s' "$lower" | grep -Eq '(^|[,/])(secret|secrets|sec)($|[,/.])'; then
    secret_ref=1
  fi
done

# a dangling -o/--output (no value) counts as an output flag
[ "$next_is_output" = 0 ] || output_flag=1
if [ "$verb" = get ] && [ "$secret_ref" = 1 ] && [ "$output_flag" = 1 ]; then
  refuse "contenu d'un Secret (get secret avec -o/--output) ; utiliser 'get secret' sans -o ou 'describe secret' (tailles seulement)"
fi

# never inherit an ambient/pre-validated kubeconfig: always the canonical copy
unset KUBECONFIG KUBE_ACCESS_CANONICALIZED KUBE_ACCESS_BOOTSTRAP KUBE_ACCESS_SOURCE KUBE_ACCESS_TMPDIR
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
