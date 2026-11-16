#!/usr/bin/env bash
# Read-only ad hoc kubectl through the canonical operator access (AGENTS.md).
#
# Usage: bash scripts/kubectl-ro.sh [--cluster homelab|oracle-a1] <get|describe|logs|top|events|api-resources|version> [args...]
#   bash scripts/kubectl-ro.sh get applications -n argocd
#   bash scripts/kubectl-ro.sh --cluster oracle-a1 get nodes   # OKE (PLT-257)
#   bash scripts/kubectl-ro.sh logs -n cilium ds/cilium --tail=50
#   bash scripts/kubectl-ro.sh get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=up'
#
# Access comes from scripts/lib/kube-preflight.sh (Doppler bootstrap, SHA-256,
# TLS, API auth): the verified kubeconfig lives in a 0600 temp dir for this
# process only and is removed on exit. It is never copied elsewhere.
# Prefer `just status-app`, `just diagnose-app`, `just runtime-inventory` for
# Argo evidence; use this wrapper for anything they do not cover.
#
# --cluster oracle-a1 (PLT-257) reads OKE through NetBird (API 10.0.2.3:6443) with
# the read-only ServiceAccount argocd/agent-operator, from Doppler
# KUBERNETES_AGENT_OPERATOR_KUBECONFIG_ORACLE_A1 (+ _SHA256). Never the operator
# copy nor an OCI exec kubeconfig; the effective identity is checked before any
# command. Only valid as the first argument (after the verb it stays refused).
#
# Identity on homelab (PLT-312 M5). Default `auto`: the limited ServiceAccount
# agent-operator/agent-operator (RBAC view + cluster read, no Secret data), from
# Doppler KUBERNETES_AGENT_OPERATOR_KUBECONFIG (+ _SHA256), when that copy is
# present, intact and accepted by the API; otherwise a warning on stderr and a
# fallback to the operator copy (flow of the other agents unchanged).
# KUBECTL_RO_IDENTITY=agent refuses the fallback (exit 2); =operator keeps the
# legacy operator copy (rollback). The client-side filtering below stays as a
# second layer: the API-side RBAC of the ServiceAccount is the first.
# `auth whoami` (exact form) prints the effective identity and its source; no
# other `auth` form is admitted (can-i, reconcile...).
# The ServiceAccount token is short-lived (24 h, issued by Paul): renew with
#   AGENT_TOKEN_DURATION=24h bash scripts/agent-operator-token.sh --provision      (homelab)
#   AGENT_TOKEN_DURATION=24h bash scripts/agent-operator-oke-token.sh --provision  (oracle-a1)
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

# --- cluster selector (first argument only; PLT-257)
cluster=homelab
if [ "${1:-}" = --cluster ]; then
  [ "$#" -ge 2 ] || refuse "--cluster sans valeur (homelab|oracle-a1)"
  case "$2" in
    homelab|oracle-a1) cluster=$2 ;;
    *) refuse "cluster '$2' inconnu (homelab|oracle-a1)" ;;
  esac
  shift 2
fi

# --- identity selector (homelab only; oracle-a1 is always the read-only ServiceAccount)
identity_mode=${KUBECTL_RO_IDENTITY:-auto}
case "$identity_mode" in
  auto|agent|operator) ;;
  *) refuse "KUBECTL_RO_IDENTITY='$identity_mode' inconnu (auto|agent|operator)" ;;
esac

[ "$#" -ge 1 ] || refuse "verbe manquant (get|describe|logs|top|events|api-resources|version|auth whoami)"

verb=$1
whoami_mode=0
if [ "$verb" = auth ]; then
  [ "$#" = 2 ] && [ "$2" = whoami ] || refuse "auth : seule la forme exacte 'auth whoami' est admise"
  whoami_mode=1
fi
case "$verb" in
  get|describe|logs|top|events|api-resources|version|auth) ;;
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
    --kuberc|--kuberc=*|--profile|--profile=*|--profile-output|--profile-output=*|--cache-dir|--cache-dir=*|\
    --as-user-extra|--as-user-extra=*|--log-file|--log-file=*|--log-dir|--log-dir=*|--log-backtrace-at|--log-backtrace-at=*)
      refuse "option '$arg' : préférences/impersonation/écriture de fichiers non autorisées" ;;
    --insecure-skip-tls-verify|--insecure-skip-tls-verify=*|--insecure-skip-tls-verify-backend|--insecure-skip-tls-verify-backend=*|--certificate-authority|--certificate-authority=*|--tls-server-name|--tls-server-name=*)
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
    -o*|--output=*|--template|--template=*|--sort-by|--sort-by=*)
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

# kuberc preferences (~/.kube/kuberc) could add -o yaml or aliases behind the guard
export KUBERC=off
# shellcheck source=/dev/null
source "$HERE/lib/kube-preflight.sh"
set +e
umask 077
status_file=$(mktemp "${TMPDIR:-/tmp}/kubectl-ro.XXXXXX")
trap 'kube_access_cleanup; rm -f "$status_file"' EXIT

HOMELAB_AGENT_SECRET=KUBERNETES_AGENT_OPERATOR_KUBECONFIG
HOMELAB_AGENT_USER=system:serviceaccount:agent-operator:agent-operator
OKE_AGENT_USER=system:serviceaccount:argocd:agent-operator

effective_user() { kubectl --request-timeout=15s auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null; }

# acquire SECRET|"" : verified kubeconfig for that Doppler copy ("" = operator copy).
# Never inherit an ambient/pre-validated kubeconfig: always the canonical copy.
# In this shell, not $(...): the verified KUBECONFIG must stay exported.
acquire() {
  kube_access_cleanup
  unset KUBECONFIG KUBE_ACCESS_CANONICALIZED KUBE_ACCESS_BOOTSTRAP KUBE_ACCESS_SOURCE KUBE_ACCESS_TMPDIR KUBE_ACCESS_KUBECONFIG_SECRET
  [ -z "$1" ] || export KUBE_ACCESS_KUBECONFIG_SECRET=$1
  require_kube_access >"$status_file" 2>&1
  local rc=$?
  # the preflight may have replaced the EXIT trap; keep both cleanups
  trap 'kube_access_cleanup; rm -f "$status_file"' EXIT
  return "$rc"
}

blocked_exit() { grep -E '^(KUBE_ACCESS|REASON|NEXT_ACTION)=' "$status_file" >&2; exit 2; }

if [ "$cluster" = oracle-a1 ]; then
  acquire KUBERNETES_AGENT_OPERATOR_KUBECONFIG_ORACLE_A1 || blocked_exit
  who=$(effective_user)
  [ "$who" = "$OKE_AGENT_USER" ] ||
    refuse "identité effective '$who' : seule $OKE_AGENT_USER est admise sur oracle-a1"
elif [ "$identity_mode" = operator ]; then
  acquire "" || blocked_exit
else
  agent_ok=0
  if acquire "$HOMELAB_AGENT_SECRET"; then
    who=$(effective_user)
    if [ "$who" = "$HOMELAB_AGENT_USER" ]; then
      agent_ok=1
    else
      echo "REASON=agent_identity_mismatch (identité effective '$who')" >"$status_file"
    fi
  fi
  if [ "$agent_ok" = 0 ]; then
    if [ "$identity_mode" = agent ]; then
      grep -E '^(KUBE_ACCESS|REASON|NEXT_ACTION)=' "$status_file" >&2
      echo "kubectl-ro: identité agent-operator indisponible et KUBECTL_RO_IDENTITY=agent : pas de repli opérateur (Paul : AGENT_TOKEN_DURATION=24h bash scripts/agent-operator-token.sh --provision)" >&2
      exit 2
    fi
    echo "kubectl-ro: AVERTISSEMENT identité agent-operator indisponible ($(grep -m1 '^REASON=' "$status_file")) : repli sur la copie opérateur (KUBECTL_RO_IDENTITY=agent pour l'interdire)" >&2
    acquire "" || blocked_exit
  fi
fi

if [ "$whoami_mode" = 1 ]; then
  who=$(effective_user)
  [ -n "$who" ] || { echo "kubectl-ro: identité illisible" >&2; exit 2; }
  echo "cluster=$cluster identity=$who source=${KUBE_ACCESS_SOURCE:-?}"
  exit 0
fi

kubectl --request-timeout=30s "$@"
