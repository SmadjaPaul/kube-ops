#!/usr/bin/env bash
# Faux kubectl-ro pour tests/platform/test_app_status.py : sert les fichiers de $APP_STATUS_FIXTURE.
# Aucun cluster, aucun reseau. Ne repond qu'aux appels get utilises par scripts/app-status.sh.
set -u
d=${APP_STATUS_FIXTURE:?}
[ "${1:-}" = --cluster ] && shift 2
[ "${1:-}" = get ] || { echo "stub: verbe refuse" >&2; exit 64; }
shift
case "$1" in
  application.argoproj.io)
    if [ -f "$d/argo.err" ]; then cat "$d/argo.err" >&2; exit 2; fi
    if [ -f "$d/argo.json" ] && [ "$2" = gen-demo-web ]; then cat "$d/argo.json"; exit 0; fi
    echo "Error from server (NotFound): applications.argoproj.io \"$2\" not found" >&2; exit 1 ;;
  deployments,pods,services) cat "$d/objs.json" ;;
  --raw)
    case "$2" in /api/v1/namespaces/svc-demo-web/services/demo-web:80/proxy/healthz) ;; *) echo "stub: chemin inattendu $2" >&2; exit 64 ;; esac
    rc=$(cat "$d/smoke.rc"); [ -f "$d/smoke.err" ] && cat "$d/smoke.err" >&2
    [ "$rc" = 0 ] && printf 'ok'; exit "$rc" ;;
  *) echo "stub: appel inattendu $*" >&2; exit 64 ;;
esac
