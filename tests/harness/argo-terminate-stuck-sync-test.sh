#!/usr/bin/env bash
# scripts/argo-terminate-stuck-sync.sh : préconditions, garde de protection des données
# (PVC/PV/CNPG/ObjectStore/VolumeSnapshot/Namespace non vide), dry-run, terminaison et
# vérification. Aucun cluster : copie du script avec un faux preflight, de faux kubectl,
# argocd et sleep pilotés par fichiers de fixture.
# Usage : bash tests/harness/argo-terminate-stuck-sync-test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/argo-terminate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
ko() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

mkdir -p "$WORK/repo/scripts/lib" "$WORK/bin" "$WORK/fx"
cp "$ROOT/scripts/argo-terminate-stuck-sync.sh" "$WORK/repo/scripts/"
cat >"$WORK/repo/scripts/lib/kube-preflight.sh" <<'EOF'
kube_access_cleanup() { :; }
require_kube_access() { [ "${FAKE_PREFLIGHT:-pass}" = pass ]; }
require_kube_access_quiet() { require_kube_access; }
EOF
FX="$WORK/fx"
# kubectl : application avant/après terminaison, annotations, listes par namespace.
cat >"$WORK/bin/kubectl" <<EOF
#!/usr/bin/env bash
a=" \$* "
echo "\$*" >>"$FX/calls"
case "\$a" in
  *" config set-context "*) exit 0 ;;
  *" get application "*"jsonpath={.status.operationState.phase}"*)
    f="$FX/app.json"; [ -f "$FX/terminated" ] && f="$FX/app-after.json"
    jq -j '.status.operationState.phase + "|" + .status.operationState.startedAt' "\$f" ;;
  *" get application "*)
    [ -f "$FX/app.json" ] || { echo 'NotFound' >&2; exit 1; }
    if [ -f "$FX/terminated" ]; then cat "$FX/app-after.json"; else cat "$FX/app.json"; fi ;;
  *" patch application "*) touch "$FX/terminated" ;;
  *"sync-options"*)
    prev=""; for w in \$*; do [ "\$prev" = get ] && ref=\$w; prev=\$w; done
    [ -f "$FX/opts" ] && grep -F "\$ref " "$FX/opts" | cut -d' ' -f2- | tr -d '\n' ; exit 0 ;;
  *" get "*" -o name "*)
    ns=""; prev=""; for w in \$*; do [ "\$prev" = -n ] && ns=\$w; prev=\$w; done
    for w in \$*; do case "\$w" in pvc|clusters.*|objectstores.*|volumesnapshots.*) res=\$w ;; esac; done
    f="$FX/list-\$ns-\$res"
    [ -f "$FX/list-error" ] && { echo 'Unable to connect to the server' >&2; exit 1; }
    [ -f "\$f" ] && cat "\$f"; exit 0 ;;
  *) echo "unexpected kubectl: \$*" >&2; exit 9 ;;
esac
EOF
printf '#!/bin/sh\necho "argocd $*" >>"%s/calls"\ntouch "%s/terminated"\n' "$FX" "$FX" >"$WORK/bin/argocd"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/sleep"
chmod +x "$WORK/bin/"*

OLD=2026-01-01T00:00:00Z
app() { # app PHASE STARTED MESSAGE RESOURCES_JSON -> fixture
  jq -n --arg p "$1" --arg s "$2" --arg m "$3" --argjson r "$4" \
    '{spec:{destination:{server:"https://kubernetes.default.svc"}},
      status:{operationState:{phase:$p,startedAt:$s,message:$m},resources:$r,
              sync:{status:"OutOfSync",revision:"abc"},health:{status:"Progressing"}}}'
}
reset() { rm -f "$FX"/*; }
run() { # run ARGS... -> RC, OUT
  OUT=$(PATH="$WORK/bin:$PATH" bash "$WORK/repo/scripts/argo-terminate-stuck-sync.sh" "$@" 2>&1); RC=$?
}
terminated() { [ -f "$FX/terminated" ]; }
expect() { # expect DESC RC MOTIF
  if [ "$RC" = "$2" ] && grep -qE -- "$3" <<<"$OUT"; then ok "$1"; else ko "$1 (rc=$RC, attendu $2) ${OUT//$'\n'/ }"; fi
}
WAIT='waiting for completion of hook batch/Job/migrate'
PVC='[{"kind":"PersistentVolumeClaim","namespace":"web","name":"data","requiresPruning":true}]'
NSR='[{"kind":"Namespace","name":"web","requiresPruning":true}]'

# 1. accès bloqué
reset; FAKE_PREFLIGHT=blocked run web; expect "preflight bloqué -> 2" 2 '.*'
# 2. Application absente
reset; run web; expect "application absente -> 3" 3 'REASON=application_not_found'
# 3. aucune opération en cours
reset; app Succeeded "$OLD" '' '[]' >"$FX/app.json"; run web
expect "rien en cours -> 0" 0 'RESULT=NOTHING_TO_TERMINATE'
terminated && ko "rien en cours : terminaison lancée" || ok "rien en cours : aucune terminaison"
# 4. opération trop récente
reset; app Running "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WAIT" '[]' >"$FX/app.json"; run web 600
expect "opération récente -> 3" 3 'REASON=operation_younger_than_min_age'
# 5. opération qui n'attend pas de hook
reset; app Running "$OLD" 'syncing resources' '[]' >"$FX/app.json"; run web
expect "pas d'attente hook/health -> 3" 3 'REASON=operation_not_waiting_on_hooks_or_health'
# 6. PVC prunable sans Prune=false : refus, aucune terminaison
reset; app Running "$OLD" "$WAIT" "$PVC" >"$FX/app.json"; run web
expect "PVC non protégée -> 4" 4 'PRUNE_REFUSED=PersistentVolumeClaim/data'
terminated && ko "PVC : terminaison lancée malgré le refus" || ok "PVC : aucune terminaison"
# 7. PVC avec Prune=false : admise, dry-run sans terminaison
reset; app Running "$OLD" "$WAIT" "$PVC" >"$FX/app.json"
echo 'PersistentVolumeClaim/data Prune=false' >"$FX/opts"; run web 600 --dry-run
expect "PVC Prune=false + dry-run -> 0" 0 'RESULT=DRY_RUN_WOULD_TERMINATE'
grep -q 'PRUNE_PROTECTED=PersistentVolumeClaim/data' <<<"$OUT" && ok "PVC Prune=false : marquée protégée" || ko "PVC Prune=false non reconnue"
terminated && ko "dry-run : terminaison lancée" || ok "dry-run : aucune terminaison"
# 8. Namespace prunable contenant une base CNPG : refus
reset; app Running "$OLD" "$WAIT" "$NSR" >"$FX/app.json"
echo 'cluster.postgresql.cnpg.io/web-db' >"$FX/list-web-clusters.postgresql.cnpg.io"; run web
expect "namespace avec Cluster CNPG -> 4" 4 'PRUNE_REFUSED=Namespace/web'
# 9. Namespace prunable vide : admis
reset; app Running "$OLD" "$WAIT" "$NSR" >"$FX/app.json"; run web 600 --dry-run
expect "namespace vide -> admis" 0 'PRUNE_ALLOWED_EMPTY_NAMESPACE=web'
# 10. inventaire impossible (erreur API) : jamais compté comme vide
reset; app Running "$OLD" "$WAIT" "$NSR" >"$FX/app.json"; touch "$FX/list-error"; run web
expect "inventaire impossible -> 4" 4 'PRUNE_REFUSED=Namespace/web'
# 11. terminaison nominale par argocd, vérifiée
reset; app Running "$OLD" "$WAIT" '[]' >"$FX/app.json"; app Succeeded 2026-11-20T00:00:00Z '' '[]' >"$FX/app-after.json"; run web
expect "terminaison -> TERMINATED" 0 'RESULT=TERMINATED'
grep -q 'argocd app terminate-op web --core' "$FX/calls" && ok "terminaison via argocd terminate-op --core" || ko "argocd non appelé"
# 12. opération toujours bloquée après terminaison : échec de vérification
reset; app Running "$OLD" "$WAIT" '[]' >"$FX/app.json"; cp "$FX/app.json" "$FX/app-after.json"; run web
expect "vérification en échec -> 5" 5 'RESULT=VERIFY_FAILED'

echo "# $PASS ok, $FAIL échec(s)"
[ "$FAIL" = 0 ]
