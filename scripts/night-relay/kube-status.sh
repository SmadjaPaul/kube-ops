#!/usr/bin/env bash
# One-line, non-sensitive Kubernetes access status for the night relay (PLT-201).
#
# Usage: bash scripts/night-relay/kube-status.sh
# Prints exactly one line on stdout, always exits 0:
#   disponible (cluster vX.Y.Z)
#   indisponible (<categorie> : <REASON>)
# categorie: auth_doppler_absente | api_inaccessible | credential_rejete |
#            credential_canonique_invalide | outil_manquant | inconnu
#
# Reuses scripts/lib/kube-preflight.sh (Doppler bootstrap, SHA-256, TLS, API auth).
# Nothing from the kubeconfig, Doppler or kubectl stderr is printed: only the
# preflight's enum REASON and a category derived from it. The temporary
# kubeconfig is removed on exit by the preflight's own cleanup.
#
# KUBE_STATUS_LIB overrides the preflight library (offline tests only).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB=${KUBE_STATUS_LIB:-$HERE/../lib/kube-preflight.sh}

if [ ! -r "$LIB" ]; then
  echo "indisponible (outil_manquant : kube_preflight_missing)"
  exit 0
fi

# never inherit an ambient/pre-validated kubeconfig: always the canonical copy
unset KUBECONFIG KUBE_ACCESS_CANONICALIZED KUBE_ACCESS_BOOTSTRAP KUBE_ACCESS_SOURCE KUBE_ACCESS_TMPDIR
# shellcheck source=/dev/null
source "$LIB"
set +e
umask 077
status_file=$(mktemp "${TMPDIR:-/tmp}/night-relay-kube-status.XXXXXX")
trap 'kube_access_cleanup; rm -f "$status_file"' EXIT

# Run in this shell (not $(...)) so the verified KUBECONFIG stays exported for
# the probe below. The preflight prints only KEY=enum lines.
require_kube_access >"$status_file" 2>&1
rc=$?
# the preflight may have replaced the EXIT trap with its own cleanup
trap 'kube_access_cleanup; rm -f "$status_file"' EXIT
out=$(grep -E '^[A-Z_]+=' "$status_file")

field() { # field NAME -> sanitized value of NAME=... in $out
  printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1 | tr -cd 'A-Za-z0-9_.+-'
}

if [ "$rc" -eq 0 ] && [ "$(field KUBE_ACCESS)" = PASS ]; then
  echo "disponible (cluster $(field CLUSTER_VERSION))"
  exit 0
fi

reason=$(field REASON)
reason=${reason:-unknown}
case "$reason" in
  doppler_not_authenticated|canonical_operator_distribution_unavailable)
    cat=auth_doppler_absente ;;
  kubectl_missing|jq_missing)
    cat=outil_manquant ;;
  canonical_operator_kubeconfig_missing|canonical_operator_fingerprint_missing|\
  canonical_operator_context_invalid|canonical_operator_integrity_mismatch|\
  invalid_operator_context|missing_operator_context)
    cat=credential_canonique_invalide ;;
  api_unreachable)
    # The preflight leaves the verified temporary kubeconfig in place until
    # cleanup: one more bounded probe separates "rejected credential" from
    # "API down". Only the category is kept, never the error text.
    cat=api_inaccessible
    if [ -n "${KUBECONFIG:-}" ] && [ -f "$KUBECONFIG" ]; then
      probe=$(kubectl --request-timeout=8s get --raw=/version 2>&1 >/dev/null)
      if [ -z "$probe" ]; then
        probe=$(kubectl --request-timeout=8s get namespace/default -o name 2>&1 >/dev/null)
      fi
      if grep -Eiq 'unauthorized|forbidden|certificate has expired|x509|provide credentials|token has expired' <<<"$probe"; then
        cat=credential_rejete
      fi
    fi
    ;;
  *) cat=inconnu ;;
esac
echo "indisponible ($cat : $reason)"
exit 0
