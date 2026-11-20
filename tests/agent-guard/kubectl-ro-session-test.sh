#!/usr/bin/env bash
# Session de lecture de scripts/kubectl-ro.sh (KUBECTL_RO_SESSION_DIR) : une seule
# préflight par session, réutilisée tant qu'elle est valide (TTL, cluster, mode
# d'identité, empreinte du kubeconfig, droits du dossier) ; refus inchangés.
# Aucun cluster, aucun Doppler : copie du wrapper avec une fausse préflight qui
# compte les acquisitions et un faux kubectl.
# Usage : bash tests/agent-guard/kubectl-ro-session-test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kubectl-ro-session.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
ko() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

mkdir -p "$WORK/scripts/lib" "$WORK/bin"
cp "$ROOT/scripts/kubectl-ro.sh" "$WORK/scripts/kubectl-ro.sh"
# Fausse préflight : chaque acquisition est comptée et produit un kubeconfig 0600
# dans un dossier temporaire supprimé à la sortie, comme la vraie.
cat >"$WORK/scripts/lib/kube-preflight.sh" <<EOF
_kube_access_sha256_stream() { shasum -a 256 | cut -d' ' -f1; }
kube_access_cleanup() { [ -z "\${KUBE_ACCESS_TMPDIR:-}" ] || rm -rf "\$KUBE_ACCESS_TMPDIR"; KUBE_ACCESS_TMPDIR=""; }
require_kube_access() {
  echo "\${KUBE_ACCESS_KUBECONFIG_SECRET:-operator}" >>"$WORK/acquires"
  [ "\${FAKE_PREFLIGHT:-pass}" = pass ] || { echo KUBE_ACCESS=BLOCKED; echo REASON=fake; return 2; }
  KUBE_ACCESS_TMPDIR=\$(mktemp -d "${TMPDIR:-/tmp}/fake-access.XXXXXX")
  printf 'apiVersion: v1\nkind: Config\n# %s\n' "\${KUBE_ACCESS_KUBECONFIG_SECRET:-operator}" >"\$KUBE_ACCESS_TMPDIR/kubeconfig"
  chmod 600 "\$KUBE_ACCESS_TMPDIR/kubeconfig"
  export KUBECONFIG="\$KUBE_ACCESS_TMPDIR/kubeconfig" KUBE_ACCESS_SOURCE=fake_\${KUBE_ACCESS_KUBECONFIG_SECRET:-operator}
  echo KUBE_ACCESS=PASS
}
EOF
# Faux kubectl : identité selon la copie, journal des commandes avec le kubeconfig utilisé.
cat >"$WORK/bin/kubectl" <<EOF
#!/usr/bin/env bash
if [ "\$*" = "--request-timeout=15s auth whoami -o jsonpath={.status.userInfo.username}" ]; then
  if grep -q ORACLE "\$KUBECONFIG"; then printf system:serviceaccount:argocd:agent-operator
  elif grep -q AGENT "\$KUBECONFIG"; then printf system:serviceaccount:agent-operator:agent-operator
  else printf kubernetes-admin; fi
  exit 0
fi
[ -r "\$KUBECONFIG" ] || { echo "kubeconfig illisible" >&2; exit 7; }
echo "\$KUBECONFIG \$*" >>"$WORK/calls"
echo ran
EOF
chmod +x "$WORK/bin/kubectl"

acquires() { [ -f "$WORK/acquires" ] && wc -l <"$WORK/acquires" | tr -d ' ' || echo 0; }
ro() { OUT=$(PATH="$WORK/bin:$PATH" bash "$WORK/scripts/kubectl-ro.sh" "$@" 2>&1); RC=$?; }
reset() { rm -f "$WORK/acquires" "$WORK/calls"; }
newsession() { rm -rf "$WORK/s"; mkdir -m 700 "$WORK/s"; export KUBECTL_RO_SESSION_DIR="$WORK/s"; }
perm() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

# 1. sans session : une préflight par appel, rien ne reste sur disque
reset; unset KUBECTL_RO_SESSION_DIR
ro get ns; ro get pods -A
[ "$(acquires)" = 2 ] && ok "sans session : 2 appels -> 2 préflights" || ko "sans session : $(acquires) préflights"

# 2. avec session : une seule préflight pour trois lectures, même kubeconfig de session
reset; newsession
ro get ns; ro get pods -A; ro describe node n1
[ "$RC" = 0 ] && [ "$(acquires)" = 1 ] && ok "session : 3 appels -> 1 préflight" || ko "session : $(acquires) préflights rc=$RC $OUT"
[ "$(cut -d' ' -f1 "$WORK/calls" | sort -u | wc -l | tr -d ' ')" = 1 ] && grep -q "^$WORK/s/" "$WORK/calls" &&
  ok "session : les lectures utilisent la copie de session" || ko "session : kubeconfig inattendu $(cut -d' ' -f1 "$WORK/calls" | sort -u)"
f=$(ls "$WORK/s"/*.kubeconfig 2>/dev/null | head -1)
[ -n "$f" ] && [ "$(perm "$f")" = 600 ] && ok "session : kubeconfig en 0600" || ko "session : droits $(perm "${f:-/nonexistent}")"
ro auth whoami
grep -q 'identity=system:serviceaccount:agent-operator:agent-operator' <<<"$OUT" && [ "$(acquires)" = 1 ] &&
  ok "session : auth whoami donne l'identité mise en cache" || ko "session whoami : $OUT"

# 3. TTL écoulé : nouvelle préflight
reset; newsession
ro get ns; KUBECTL_RO_SESSION_TTL=0 ro get ns
[ "$(acquires)" = 2 ] && ok "TTL 0 : préflight refaite" || ko "TTL 0 : $(acquires) préflights"
sed -i.bak 's/^expires=.*/expires=1/' "$WORK/s"/*.meta; ro get ns
[ "$(acquires)" = 3 ] && ok "session expirée : préflight refaite" || ko "session expirée : $(acquires) préflights"

# 4. autre cluster ou autre mode d'identité : entrée de session distincte
reset; newsession
ro get ns; ro --cluster oracle-a1 get ns
[ "$(acquires)" = 2 ] && tail -1 "$WORK/acquires" | grep -q ORACLE_A1 && ok "oracle-a1 : pas de réutilisation de la session homelab" || ko "cluster : $(cat "$WORK/acquires")"
KUBECTL_RO_IDENTITY=operator ro get ns
[ "$(acquires)" = 3 ] && ok "mode operator : pas de réutilisation de la session agent" || ko "identité : $(acquires) préflights"
ro --cluster oracle-a1 get nodes
[ "$(acquires)" = 3 ] && ok "oracle-a1 : sa propre session est réutilisée" || ko "oracle-a1 réutilisation : $(acquires)"

# 5. kubeconfig de session altéré : jamais réutilisé
reset; newsession
ro get ns; f=$(ls "$WORK/s"/*.kubeconfig | head -1); echo '# altere' >>"$f"; ro get ns
[ "$(acquires)" = 2 ] && ok "kubeconfig altéré : préflight refaite" || ko "altéré : $(acquires) préflights"
ro get ns; f=$(ls "$WORK/s"/*.kubeconfig | head -1)
printf 'apiVersion: v1\nclusters:\n- cluster:\n    insecure-skip-tls-verify: true\n' >"$f"
sha=$(shasum -a 256 <"$f" | cut -d' ' -f1); sed -i.bak "s/^sha256=.*/sha256=$sha/" "$WORK/s"/*.meta; ro get ns
[ "$(acquires)" = 3 ] && ok "TLS désactivé dans le kubeconfig : jamais réutilisé" || ko "insecure : $(acquires) préflights"

# 6. dossier de session lisible par d'autres ou lien symbolique : ignoré
reset; newsession; chmod 755 "$WORK/s"
ro get ns; ro get ns
[ "$(acquires)" = 2 ] && [ -z "$(ls "$WORK/s")" ] && ok "dossier 0755 : session ignorée, rien n'y est écrit" || ko "0755 : $(acquires) préflights, $(ls "$WORK/s")"
grep -q 'KUBECTL_RO_SESSION_DIR ignoré' <<<"$OUT" && ok "dossier 0755 : avertissement sur stderr" || ko "0755 sans avertissement : $OUT"
reset; rm -rf "$WORK/s" "$WORK/real"; mkdir -m 700 "$WORK/real"; ln -s "$WORK/real" "$WORK/s"
ro get ns; ro get ns
[ "$(acquires)" = 2 ] && ok "lien symbolique : session ignorée" || ko "symlink : $(acquires) préflights"

# 7. les refus restent avant toute préflight, session ou non
reset; newsession
ro get secret x -o yaml
[ "$RC" = 64 ] && [ "$(acquires)" = 0 ] && ok "Secret -o yaml refusé avant préflight" || ko "refus secret : rc=$RC acquires=$(acquires)"
ro --insecure-skip-tls-verify get ns
[ "$RC" = 64 ] && ok "TLS contourné refusé" || ko "refus TLS : rc=$RC"

# 8. préflight bloquée : exit 2, aucune entrée de session créée
reset; newsession
FAKE_PREFLIGHT=blocked ro get ns
[ "$RC" = 2 ] && [ -z "$(ls "$WORK/s")" ] && ok "préflight bloquée : exit 2, session vide" || ko "bloquée : rc=$RC $(ls "$WORK/s")"

# 9. helper kro_session_begin : crée un dossier 0700 sous le parent et l'exporte
unset KUBECTL_RO_SESSION_DIR
d=$(bash -c "source '$ROOT/scripts/lib/kube-read.sh'; kro_session_begin '$WORK'; echo \"\$KUBECTL_RO_SESSION_DIR\"")
[ -d "$d" ] && [ "$(perm "$d")" = 700 ] && [ "${d#"$WORK"/}" != "$d" ] && ok "kro_session_begin : dossier 0700 sous le parent" || ko "kro_session_begin : '$d'"

# 10. les scripts qui lisent beaucoup ouvrent une session dans un dossier privé
for s in runtime-smoke runtime-inventory backup-audit cluster-reality investigate; do
  grep -q 'kro_session_begin "\$' "$ROOT/scripts/$s.sh" && ok "$s ouvre une session de lecture" || ko "$s sans kro_session_begin"
done
! grep -q 'kro_session_begin "\$artifact_dir"' "$ROOT/scripts/runtime-smoke.sh" && ok "runtime-smoke : session hors du dossier d'artefacts" || ko "runtime-smoke : session dans les artefacts"

echo "# $PASS ok, $FAIL échec(s)"
[ "$FAIL" = 0 ] && echo KUBECTL_RO_SESSION_TEST=PASS
[ "$FAIL" = 0 ]
