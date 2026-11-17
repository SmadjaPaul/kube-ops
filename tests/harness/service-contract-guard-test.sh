#!/usr/bin/env bash
# Tests reels de la garde d'admission service-contract (tests/harness/service-contract-guard.py).
# Chaque cas construit un depot git reel : base = BASE_REF (figee, tests/fixtures/service-contract),
# head = base + variante (sortie du template canari rendu par B, mutations, PR ecrite a la main).
# La garde tourne sur merge-base..HEAD, comme en CI. Aucun cluster requis.
# Audit : l'etat de origin/main est diagnostique (non bloquant, ne fait jamais echouer ce test).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/tests/harness/service-contract-guard.py"
fix="$repo_root/tests/fixtures/service-contract"
base_ref="$(tr -d '[:space:]' < "$fix/BASE_REF")"
for t in git python3 yq perl awk sed; do
  command -v "$t" >/dev/null || { echo "FAIL: outil requis absent: $t" >&2; exit 1; }
done
git -C "$repo_root" cat-file -e "$base_ref^{commit}" 2>/dev/null \
  || { echo "FAIL: base $base_ref absente du depot (fetch-depth 0 requis en CI)" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo_root" archive --format=tar "$base_ref" -- k8s tests/harness/pg-shared-homelab-isolation-guard-test.sh \
  | tar -x -C "$repo"
git -C "$repo" init -q -b main
git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A
git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm base

fails=0
passes=0
ADM="fixture-admission-appproject-infrastructure"
BP="k8s/infrastructure/auth/authentik/extra/blueprints/apps-canari-pg-oidc.yaml"
CI="k8s/applications/catalog/canari-pg-oidc/catalog-info.yaml"
DEP="k8s/applications/catalog/canari-pg-oidc/deployment.yaml"
SVCRT="k8s/applications/catalog/canari-pg-oidc/service-route.yaml"
PG_DB="k8s/infrastructure/database/pg-shared-homelab/canari-pg-oidc-database.yaml"
PG_CL="k8s/infrastructure/database/pg-shared-homelab/cluster.yaml"
INFRA_PROJ="k8s/bootstrap/argocd-root/infrastructure-project.yaml"

begin() { git -C "$repo" checkout -q -f -B case main; git -C "$repo" clean -fdq; }

commit_case() {
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$1" --allow-empty
}

# --- variantes ---
# Sortie du template canari (rendu par golden-paths/service-postgres-oidc/tests/render.mjs).
v_canary() { cp -R "$fix/template-canary/k8s/." "$repo/k8s/"; }

# Correctif AppProject infrastructure : destinations.databases (edition d'un fichier hors contrat).
v_infra() {
  awk '{print} /^  destinations:$/ && !done {print "    - namespace: databases"; print "      server: https://kubernetes.default.svc"; done=1}' \
    "$repo/$INFRA_PROJ" > "$tmp/ip.yaml"
  mv "$tmp/ip.yaml" "$repo/$INFRA_PROJ"
}

# Template complet admissible (avec correctif infrastructure, a admettre humainement).
v_full() { v_canary; v_infra; }

# PR ecrite a la main : memes fichiers, sans annotation golden-path ni en-tete de generation.
v_handwritten() {
  v_full
  perl -0pi -e 's/\n    homelab\.smadja\.dev\/golden-path: [^\n]*//' "$repo/$CI"
  perl -0pi -e 's/# Genere par golden-path[^\n]*\n//' "$repo/$BP"
}

# Renommage du service canari (dossier, fichiers, contenu).
rename_canary() {
  local old="$1" new="$2" f
  while IFS= read -r f; do perl -pi -e "s/\Q$old\E/$new/g" "$f"; done < <(grep -rl -- "$old" "$repo/k8s" || true)
  while IFS= read -r f; do
    mv "$f" "$(dirname "$f")/$(basename "$f" | sed "s/$old/$new/")"
  done < <(find "$repo/k8s" -name "*$old*" | sort -r)
}

# --- execution ---
unset GITHUB_EVENT_NAME GITHUB_HEAD_REF
guard_run() {
  if [ -n "$1" ]; then
    env SERVICE_CONTRACT_HUMAN_ADMISSION="$1" python3 -I "$guard" --repo "$repo" --base main --head HEAD
  else
    # Les cas stricts ne doivent pas heriter du contexte CI (mode conseil) ; ils l'exigent
    # via GUARD_CI_EVENT / GUARD_CI_HEAD_REF uniquement.
    env -u SERVICE_CONTRACT_HUMAN_ADMISSION \
      ${GUARD_CI_EVENT:+GITHUB_EVENT_NAME="$GUARD_CI_EVENT"} \
      ${GUARD_CI_HEAD_REF:+GITHUB_HEAD_REF="$GUARD_CI_HEAD_REF"} \
      python3 -I "$guard" --repo "$repo" --base main --head HEAD
  fi
}

# case_run LIBELLE ATTENDU(PASS|FAIL) MOTIF(regex|-) ADMISSION("" ou valeur) VARIANTE(fonction) [args]
case_run() {
  local label="$1" expect="$2" want="$3" adm="$4"
  shift 4
  begin
  "$@"
  commit_case "$label"
  local out rc=0 ok=1
  set +e
  out="$(guard_run "$adm" 2>&1)"
  rc=$?
  set -e
  if [ "$expect" = PASS ] && [ "$rc" -ne 0 ]; then ok=0; fi
  if [ "$expect" = FAIL ] && [ "$rc" -ne 1 ]; then ok=0; fi
  if [ "$want" != "-" ] && ! printf '%s\n' "$out" | grep -Eq -- "$want"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    passes=$((passes + 1))
    echo "PASS: $label [rc=$rc, attendu $expect, motif $want]"
  else
    fails=$((fails + 1))
    echo "FAIL: $label [rc=$rc, attendu $expect, motif $want]"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# Mutations sur la base v_full (negatifs : sans admission, chacun doit echouer sur SA regle).
m_full() { v_full; }
m_name_taken() { v_full; rename_canary canari-pg-oidc gateway; rename_canary canaripgoidc gatewaypgoidc; }
m_group_forbidden() { v_full; perl -pi -e 's/authentik-admins/admin/g' "$repo/$CI" "$repo/$BP"; }
m_redirect_domain() { v_full; perl -pi -e 's/canari-pg-oidc\.smadja\.dev\/login/canari-pg-oidc.example.org\/login/' "$repo/$BP"; }
m_protected_blueprint() { echo "# modification" >> "$repo/k8s/infrastructure/auth/authentik/extra/blueprints/apps-mealie.yaml"; }
m_group_created() {
  mkdir -p "$repo/k8s/infrastructure/auth/authentik/extra/blueprints"
  cat > "$repo/k8s/infrastructure/auth/authentik/extra/blueprints/canari-pg-oidc-groups.yaml" <<'EOF'
version: 1
metadata: {name: groups}
entries:
  - model: authentik_core.group
    identifiers: {name: authentik-admins}
    attrs: {name: authentik-admins, is_superuser: true}
EOF
}
m_superuser() { v_full; perl -0pi -e 's/superuser: false/superuser: true/' "$repo/$PG_CL"; }
m_other_owner() { v_full; perl -pi -e 's/^  owner: canaripgoidc$/  owner: app/' "$repo/$PG_DB"; }
m_inroles() { v_full; perl -0pi -e 's/(        createrole: false\n)/$1        inRoles: [pg_read_all_data]\n/' "$repo/$PG_CL"; }
m_other_secret_reader() {
  v_full
  perl -0pi -e 's/^    name: canari-pg-oidc-secret-reader$/    name: ntfy-secret-reader/m; s/^    namespace: canari-pg-oidc$/    namespace: ntfy/m' "$repo/$PG_DB"
}
m_secret_no_resourcenames() {
  v_full
  perl -0pi -e 's/    resourceNames: \["pg-shared-homelab-canari-pg-oidc"\]\n//; s/    verbs: \["get"\]\n/    verbs: ["get", "list"]\n/' "$repo/$PG_DB"
}
m_other_app_externalsecret() {
  v_full
  perl -0pi -e 's/remoteRef: \{key: authentik-blueprint-canari-pg-oidc/remoteRef: {key: authentik-blueprint-ntfy/' "$repo/k8s/applications/catalog/canari-pg-oidc/secret-distribution.yaml"
}
m_external() {
  v_full
  perl -pi -e 's/exposure: internal/exposure: external/' "$repo/$CI"
  perl -pi -e 's/name: internal/name: external/' "$repo/$SVCRT"
}
m_image_no_digest() { v_full; perl -pi -e 's/(image: [^ @]+)\@sha256:[0-9a-f]+/$1/' "$repo/$DEP"; }
m_no_probe() { v_full; perl -0pi -e 's/          livenessProbe:\n(?:            .*\n){3}//' "$repo/$DEP"; }
m_limit_over_plafond() { v_full; perl -pi -e 's/memory: "512Mi"/memory: "1Gi"/' "$repo/$DEP"; }
m_pod_is_reader() { v_full; perl -pi -e 's/serviceAccountName: canari-pg-oidc$/serviceAccountName: canari-pg-oidc-secret-reader/' "$repo/$DEP"; }
m_literal_env_secret() {
  v_full
  perl -pi -e 's/^(            - \{name: GF_USERS_ALLOW_SIGN_UP, value: "false"\})$/$1\n            - {name: GF_SECURITY_ADMIN_PASSWORD, value: "literal-test"}/' "$repo/$DEP"
}
m_literal_client_secret() { v_full; perl -pi -e 's/client_secret: !Env CANARIPGOIDC_OIDC_CLIENT_SECRET/client_secret: literal-test/' "$repo/$BP"; }
m_new_cluster() {
  v_full
  cat > "$repo/k8s/infrastructure/database/pg-shared-homelab/canari-pg-oidc-cluster.yaml" <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: canari-pg-oidc-cluster
  namespace: databases
spec:
  instances: 1
EOF
}
m_modify_existing_service() { echo "# modification" >> "$repo/k8s/applications/catalog/mealie/deployment.yaml"; }
m_unrelated_file() {
  v_full
  cat > "$repo/k8s/infrastructure/monitoring/unrelated-note.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: unrelated-note
  namespace: monitoring
data:
  note: hors-perimetre
EOF
}
m_private_key() {
  v_full
  cat > "$repo/k8s/applications/catalog/canari-pg-oidc/canari-pg-oidc-debug.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: canari-pg-oidc-debug
  namespace: canari-pg-oidc
data:
  key: |
    -----BEGIN RSA PRIVATE KEY-----
    MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu
    -----END RSA PRIVATE KEY-----
EOF
}
m_appproject_missing_ns() {
  v_canary
  git -C "$repo" show "main:k8s/bootstrap/argocd-root/applications-project.yaml" > "$repo/k8s/bootstrap/argocd-root/applications-project.yaml"
  v_infra
}
m_nothing() { :; }
m_image_no_digest_handwritten() { v_handwritten; perl -pi -e 's/(image: [^ @]+)\@sha256:[0-9a-f]+/$1/' "$repo/$DEP"; }
echo "--- 1. positif et PR ecrite a la main"
case_run "positif strict : template brut, sans correctif AppProject infrastructure" \
  FAIL 'FAIL \[R9\] namespace databases absent des destinations du projet infrastructure' "" v_canary
case_run "template + correctif infrastructure, sans admission humaine" \
  FAIL 'HORS \[additif\] fichier existant modifie k8s/bootstrap/argocd-root/infrastructure-project.yaml' "" v_full
case_run "positif : template + correctif infrastructure + admission humaine documentee" \
  PASS 'ADMIS-HUMAIN \[additif\] fichier existant modifie k8s/bootstrap/argocd-root/infrastructure-project.yaml' "$ADM" v_full
case_run "PR ecrite a la main, fichiers conformes, sans annotation golden-path" \
  PASS 'SERVICE_CONTRACT_GUARD=PASS services=canari-pg-oidc' "$ADM" v_handwritten
case_run "PR ecrite a la main non conforme (image sans digest)" \
  FAIL 'FAIL \[R8\] canari-pg-oidc: image .* sans digest' "$ADM" m_image_no_digest_handwritten

echo "--- 2. negatifs : un cas par regle (sans admission humaine)"
case_run "R1 nom deja pris (namespace gateway sur main)" FAIL 'R1\] gateway' "" m_name_taken
case_run "R2 groupe non autorise (admin)" FAIL 'R2\] .*admin' "" m_group_forbidden
case_run "R3 redirect hors domaine" FAIL 'R3\] .*redirect_uri .*example\.org' "" m_redirect_domain
case_run "R4 modification d'un blueprint protege existant (apps-mealie)" FAIL 'MANDAT \[R4\] blueprint Authentik existant modifie .*apps-mealie' "" m_protected_blueprint
case_run "R4 creation du groupe authentik-admins" FAIL 'MANDAT \[R4\] creation de groupe authentik-admins' "" m_group_created
case_run "R4 modification d'un service existant (mealie)" FAIL 'MANDAT \[R4\] service existant mealie' "" m_modify_existing_service
GUARD_CI_EVENT=pull_request GUARD_CI_HEAD_REF=idp/stateful-protection case_run "CI : PR modifiant un service existant hors branche golden-path/ : conseil, pas d'echec" PASS 'CONSEIL \(revue humaine\) \[R4\] service existant mealie' "" m_modify_existing_service
GUARD_CI_EVENT=pull_request GUARD_CI_HEAD_REF=idp/ecrite-a-la-main case_run "CI : creation de service hors golden-path/ avec nom deja pris : reste strict" FAIL 'R1\] gateway' "" m_name_taken
GUARD_CI_EVENT=pull_request GUARD_CI_HEAD_REF=golden-path/canari case_run "CI : meme modification sur branche golden-path/ : refus strict" FAIL 'MANDAT \[R4\] service existant mealie' "" m_modify_existing_service
case_run "R5 role PG superuser" FAIL 'R5\] .*superuser=true' "" m_superuser
case_run "R5 role PG vers une autre base (owner app)" FAIL 'R5\] .*owner de la base canaripgoidc = app' "" m_other_owner
case_run "R5 role PG avec inRoles" FAIL 'R5\] .*inRoles' "" m_inroles
case_run "R5 nouveau Cluster CNPG" FAIL 'R5\] nouveau Cluster CNPG' "" m_new_cluster
case_run "R6 lecture du secret-reader d'une autre app (ntfy)" FAIL 'R6\] RoleBinding .*ntfy-secret-reader' "" m_other_secret_reader
case_run "R6 droits sur secrets sans resourceNames" FAIL 'R6\] .*sans resourceNames' "" m_secret_no_resourcenames
case_run "R6 ExternalSecret lit le secret d'une autre app" FAIL 'R6\] .*ExternalSecret .*authentik-blueprint-ntfy' "" m_other_app_externalsecret
case_run "R6 secret litteral en variable d'environnement" FAIL 'R6\] .*GF_SECURITY_ADMIN_PASSWORD' "" m_literal_env_secret
case_run "R6 client_secret litteral (non !Env)" FAIL 'R6\] .*client_secret litteral' "" m_literal_client_secret
case_run "R6 SA du pod = secret-reader" FAIL 'R6\] .*SA du pod' "" m_pod_is_reader
case_run "R6 cle privee PEM ajoutee" FAIL 'R6\] .*cle privee PEM' "" m_private_key
case_run "R7 exposition external (MANDAT)" FAIL 'MANDAT \[R7\]' "" m_external
case_run "R8 image sans digest" FAIL 'R8\] .*sans digest' "" m_image_no_digest
case_run "R8 probe absente" FAIL 'R8\] .*livenessProbe' "" m_no_probe
case_run "R8 limite RAM au-dela du plafond" FAIL 'R8\] .*limite RAM' "" m_limit_over_plafond
case_run "R9 namespace canari-pg-oidc absent de l'AppProject applications" FAIL 'R9\] namespace canari-pg-oidc absent' "" m_appproject_missing_ns
case_run "perimetre : fichier ajoute hors du service" FAIL 'HORS \[perimetre\]' "" m_unrelated_file

echo "--- 3. controles"
case_run "aucune modification : PASS" PASS 'SERVICE_CONTRACT_GUARD=PASS services=-' "" m_nothing

echo "--- 4. derive du rendu : fixture = rendu courant du template B"
render_check() {
  if ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' 2>/dev/null; then
    echo "SKIP: derive du rendu (node >= 22 requis)"; return 0
  fi
  local rt="$tmp/render-tools" gp="$repo_root/golden-paths/service-postgres-oidc"
  mkdir -p "$rt"
  cp "$gp/tests/render.mjs" "$rt/"
  printf '{"name":"tools","private":true,"type":"module"}\n' > "$rt/package.json"
  if ! (cd "$rt" && npm install --silent --no-audit --no-fund nunjitsu@0.7.0 ajv@8 >/dev/null 2>&1); then
    echo "SKIP: derive du rendu (npm indisponible)"; return 0
  fi
  yq -o=json '.' "$gp/template.yaml" > "$rt/template.json"
  # Base de rendu = k8s/ du depot + ligne sentinelle. PREREQUIS MANDAT (Paul) : la sentinelle sur main.
  # Tant qu'elle n'y est pas, elle est posee dans cette copie seulement (le depot n'est jamais modifie).
  local rbase="$rt/base"
  mkdir -p "$rbase" && cp -R "$repo_root/k8s" "$rbase/k8s"
  if ! grep -q 'GOLDEN-PATH-ROLES' "$repo_root/k8s/infrastructure/database/pg-shared-homelab/cluster.yaml"; then
    echo "INFO: sentinelle GOLDEN-PATH-ROLES absente de main : pose simulee dans la copie de rendu"
    perl -0pi -e 's/  storage:\n    storageClass: longhorn-fast/  managed:\n    roles: [] # GOLDEN-PATH-ROLES\n  storage:\n    storageClass: longhorn-fast/' "$rbase/k8s/infrastructure/database/pg-shared-homelab/cluster.yaml"
  fi
  if ! node "$rt/render.mjs" "$rt/template.json" "$gp/tests/canary.params.json" "$gp/skeleton" "$rbase" "$rt/work" >/dev/null 2>&1; then
    fails=$((fails + 1)); echo "FAIL: rendu du template canari"; return 0
  fi
  if diff -r "$rt/work/out/k8s" "$fix/template-canary/k8s" >/dev/null; then
    passes=$((passes + 1)); echo "PASS: fixture template-canary identique au rendu courant"
  else
    fails=$((fails + 1)); echo "FAIL: fixture template-canary diverge du rendu courant (regenerer la fixture)"
  fi
}
render_check

echo "--- 5. audit de origin/main (diagnostic non bloquant)"
audit_ref="${SERVICE_CONTRACT_AUDIT_REF:-origin/main}"
if git -C "$repo_root" cat-file -e "$audit_ref^{commit}" 2>/dev/null; then
  audit_tmp="$(mktemp -d)"
  git -C "$repo_root" archive --format=tar "$audit_ref" -- k8s | tar -x -C "$audit_tmp"
  set +e
  audit_out="$(python3 -I "$guard" --audit --repo "$repo_root" --head "$audit_ref" 2>&1)"
  audit_rc=$?
  set -e
  rm -rf "$audit_tmp"
  if [ "$audit_rc" -ne 0 ]; then
    fails=$((fails + 1)); echo "FAIL: audit rc=$audit_rc"; printf '%s\n' "$audit_out" | sed 's/^/    /'
  else
    # Defaut #1591 : databases doit figurer dans infrastructure ; sinon l'audit doit le signaler.
    if git -C "$repo_root" show "$audit_ref:$INFRA_PROJ" | grep -q '^    - namespace: databases$'; then
      echo "INFO: $audit_ref liste databases dans infrastructure : defaut #1591 corrige"
      passes=$((passes + 1))
    elif printf '%s\n' "$audit_out" | grep -Eq 'PREEXISTANT \[R9\] namespace databases absent des destinations du projet infrastructure'; then
      passes=$((passes + 1))
      echo "PASS: audit signale le defaut #1591 sur $audit_ref (databases absent de infrastructure)"
    else
      fails=$((fails + 1)); echo "FAIL: audit n'a pas signale databases/infrastructure sur $audit_ref"
    fi
    printf '%s\n' "$audit_out" | grep -E 'PREEXISTANT|AUDIT=' | sed 's/^/    /' || true
  fi
else
  echo "SKIP: audit ($audit_ref absent)"
fi

echo "---"
echo "RESULTAT: $passes PASS, $fails FAIL"
if [ "$fails" -eq 0 ]; then echo "SERVICE_CONTRACT_GUARD_TEST=PASS"; else echo "SERVICE_CONTRACT_GUARD_TEST=FAIL"; exit 1; fi
