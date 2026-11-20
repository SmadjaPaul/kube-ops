#!/usr/bin/env bash
# Phase d'exécution de scripts/kubectl-rw.sh (après le plan) : preflight, identité effective,
# refus d'un Deployment en pause, échec de la commande, vérification runtime et codes de sortie.
# Aucun cluster, aucun Doppler : copie du wrapper avec un faux preflight et un faux kubectl
# piloté par variables FAKE_*.
# Usage : bash tests/agent-guard/kubectl-rw-exec-test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kubectl-rw-exec.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
ko() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

ns=$(grep -vE '^#|^$' "$ROOT/k8s/infrastructure/security/agent-operator/scope.tsv" | cut -f1 | head -1)
AGENT=system:serviceaccount:agent-operator:agent-operator

mkdir -p "$WORK/scripts/lib" "$WORK/bin"
cp "$ROOT/scripts/kubectl-rw.sh" "$WORK/scripts/kubectl-rw.sh"
cp "$ROOT/k8s/infrastructure/security/agent-operator/scope.tsv" "$WORK/scope.tsv"
cat >"$WORK/scripts/lib/kube-preflight.sh" <<'EOF'
_kube_access_sha256_stream() { shasum -a 256 | cut -d' ' -f1; }
kube_access_cleanup() { :; }
require_kube_access() {
  if [ "${FAKE_PREFLIGHT:-pass}" = pass ]; then echo KUBE_ACCESS=PASS; return 0; fi
  echo KUBE_ACCESS=BLOCKED; echo REASON=fake; return 1
}
EOF
# Faux kubectl : journalise chaque appel, répond selon FAKE_*.
cat >"$WORK/bin/kubectl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$WORK/calls"
args=" \$* "
case "\$args" in
  *" auth whoami "*) printf '%s' "\${FAKE_WHO:-$AGENT}" ;;
  *"jsonpath={.spec.paused}"*) printf '%s' "\${FAKE_PAUSED:-false}" ;;
  *"jsonpath={.spec.suspend}"*) printf '%s' "\${FAKE_SUSPEND:-true}" ;;
  *"jsonpath={.metadata.deletionTimestamp}"*)
    case "\${FAKE_DELETE:-notfound}" in
      notfound) echo 'Error from server (NotFound): not found' >&2; exit 1 ;;
      terminating) printf '2026-11-20T00:00:00Z' ;;
      present) printf '' ;;
      error) echo 'Unable to connect' >&2; exit 1 ;;
    esac ;;
  *" rollout status "*) exit "\${FAKE_ROLLOUT_RC:-0}" ;;
  *) exit "\${FAKE_CMD_RC:-0}" ;;
esac
EOF
chmod +x "$WORK/bin/kubectl"

rw() { # rw ARGS... ; FAKE_* passés par l'environnement -> RC, OUT (stdout+stderr)
  rm -f "$WORK/calls"
  OUT=$(PATH="$WORK/bin:$PATH" KUBECTL_RW_SCOPE="$WORK/scope.tsv" KUBECTL_RW_LOG="$WORK/rw.log" \
    bash "$WORK/scripts/kubectl-rw.sh" "$@" 2>&1)
  RC=$?
}
called() { grep -qF -- "$1" "$WORK/calls" 2>/dev/null; }
expect() { # expect DESC RC [MOTIF]
  local d=$1 want=$2 pat=${3:-}
  if [ "$RC" = "$want" ] && { [ -z "$pat" ] || grep -qE -- "$pat" <<<"$OUT"; }; then ok "$d"
  else ko "$d (rc=$RC, attendu $want) ${OUT:0:160}"; fi
}

# 1. preflight bloqué : sortie 2, aucune commande kubectl
FAKE_PREFLIGHT=blocked rw restart "$ns" deploy/web
expect "preflight bloqué -> exit 2" 2 'KUBE_ACCESS=BLOCKED'
[ ! -s "$WORK/calls" ] && ok "preflight bloqué : aucun appel kubectl" || ko "preflight bloqué : kubectl appelé"

# 2. identité effective ≠ agent-operator : refus avant toute écriture
FAKE_WHO=kubernetes-admin rw restart "$ns" deploy/web
expect "identité opérateur -> exit 2" 2 "identité effective 'kubernetes-admin'"
called "patch deployment/web" && ko "identité opérateur : écriture exécutée" || ok "identité opérateur : aucune écriture"

# 3. restart d'un Deployment en pause : refus 64, journalisé, pas de patch
FAKE_PAUSED=true rw restart "$ns" deploy/web
expect "restart d'un Deployment en pause -> 64" 64 'en pause'
called "patch deployment/web" && ko "pause : patch exécuté" || ok "pause : aucun patch"
grep -q 'REFUSED paused' "$WORK/rw.log" && ok "pause : refus journalisé" || ko "pause : refus non journalisé"

# 4. succès + rollout OK : PASS, exit 0, journal OK
rw restart "$ns" deploy/web
expect "restart nominal -> PASS" 0 'KUBECTL_RW=PASS VERIFY=PASS'
called "rollout status deployment/web" && ok "restart : rollout status vérifié" || ko "restart : pas de rollout status"
tail -1 "$WORK/rw.log" | grep -q "$AGENT" && ok "journal : identité effective tracée" || ko "journal sans identité"

# 5. commande appliquée mais rollout en échec : exit 3, VERIFY=FAIL
FAKE_ROLLOUT_RC=1 rw restart "$ns" deploy/web
expect "rollout en échec -> exit 3" 3 'VERIFY=FAIL'

# 6. commande kubectl en échec : code propagé, pas de vérification
FAKE_CMD_RC=5 rw restart "$ns" deploy/web
expect "commande en échec -> code propagé" 5 'KUBECTL_RW=FAIL rc=5'
called "rollout status" && ko "échec : vérification lancée quand même" || ok "échec : pas de vérification"

# 7. dry-run serveur : aucune vérification runtime
rw --dry-run restart "$ns" deploy/web
expect "dry-run -> DRY_RUN_PASS" 0 'KUBECTL_RW=DRY_RUN_PASS'
called "rollout status" && ko "dry-run : rollout vérifié" || ok "dry-run : pas de vérification"

# 8. kinds statefulset et daemonset : vérifiés par rollout status
rw restart "$ns" sts/db
expect "restart statefulset -> PASS" 0 'VERIFY=PASS'
called "rollout status statefulset/db" && ok "statefulset : rollout vérifié" || ko "statefulset : kind non résolu"
rw restart "$ns" ds/agent
called "rollout status daemonset/agent" && ok "daemonset : rollout vérifié" || ko "daemonset : kind non résolu"

# 9. suspend : vérification de spec.suspend
FAKE_SUSPEND=true rw suspend "$ns" cronjob/backup
expect "suspend vérifié -> PASS" 0 'spec.suspend=true'
FAKE_SUSPEND=false rw suspend "$ns" cronjob/backup
expect "suspend non appliqué -> exit 3" 3 'VERIFY=FAIL'

# 10. delete : absent / en suppression / toujours présent / contrôle impossible
FAKE_DELETE=notfound rw delete "$ns" pod/web-0
expect "delete : absent -> PASS" 0 'absent'
FAKE_DELETE=terminating rw delete "$ns" pod/web-0
expect "delete : en cours de suppression -> PASS" 0 'en cours de suppression'
FAKE_DELETE=present rw delete "$ns" pod/web-0
expect "delete : toujours présent -> exit 3" 3 'toujours présent'
FAKE_DELETE=error rw delete "$ns" pod/web-0
expect "delete : contrôle impossible -> exit 3" 3 'contrôle impossible'

echo "# $PASS ok, $FAIL échec(s)"
[ "$FAIL" = 0 ]
