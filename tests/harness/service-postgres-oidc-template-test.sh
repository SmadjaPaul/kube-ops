#!/usr/bin/env bash
# Golden path service-postgres-oidc@v1 : rendu SANS Backstage, puis kustomize, kubeconform,
# assertions structurelles, garde d'isolation pg-shared-homelab, idempotence et refus negatifs.
# Moteur de rendu : nunjitsu 0.7.0 (le moteur de Backstage, delimiteurs ${{ }}), installe dans un
# dossier temporaire. Aucun cluster, aucun Doppler, aucun appel GitHub.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gp="$repo_root/golden-paths/service-postgres-oidc"
params="$gp/tests/canary.params.json"

for t in node npm yq jq python3 kustomize kubeconform; do
  command -v "$t" >/dev/null || { echo "FAIL: outil requis absent: $t" >&2; exit 1; }
done
node_major="$(node -p 'process.versions.node.split(".")[0]')"
[ "$node_major" -ge 22 ] || { echo "FAIL: node >= 22 requis (nunjitsu 0.7.0), trouve $node_major" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tools"
cp "$gp/tests/render.mjs" "$tmp/tools/render.mjs"
printf '{"name":"tools","private":true,"type":"module"}\n' > "$tmp/tools/package.json"
(cd "$tmp/tools" && npm install --silent --no-audit --no-fund nunjitsu@0.7.0 ajv@8 >/dev/null)

fails=0
step() { echo "--- $1"; }
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

yq -o=json '.' "$gp/template.yaml" > "$tmp/template.json"
name="$(jq -r .name "$params")"

# Base de rendu : k8s/ du depot. PREREQUIS MANDAT (Paul) : la ligne sentinelle `roles: [] # GOLDEN-PATH-ROLES`
# doit etre sur main dans pg-shared-homelab/cluster.yaml. Tant qu'elle n'y est pas, le test la pose dans
# SA COPIE temporaire seulement (jamais dans le depot) et le dit. Sans sentinelle sur main, une execution
# reelle du template ne ferait AUCUNE edition de cluster.yaml (fs:replace : 0 occurrence = silencieux).
base="$tmp/base"
mkdir -p "$base"
cp -R "$repo_root/k8s" "$base/k8s"
base_cluster="$base/k8s/infrastructure/database/pg-shared-homelab/cluster.yaml"
if grep -q 'GOLDEN-PATH-ROLES' "$repo_root/k8s/infrastructure/database/pg-shared-homelab/cluster.yaml"; then
  echo "INFO: ligne sentinelle presente sur le depot (prerequis pose)"
else
  echo "INFO: PREREQUIS MANDAT non fait : sentinelle absente de main. Pose simulee dans la copie de test uniquement."
  perl -0pi -e 's/  storage:\n    storageClass: longhorn-fast/  managed:\n    roles: [] # GOLDEN-PATH-ROLES\n  storage:\n    storageClass: longhorn-fast/' "$base_cluster"
fi

step "1. rendu du template (validation JSON Schema + etapes)"
if node "$tmp/tools/render.mjs" "$tmp/template.json" "$params" "$gp/skeleton" "$base" "$tmp/work" >"$tmp/render.log" 2>&1; then
  pass "rendu canari $name"
else
  grep -v 'NODE_TLS_REJECT\|trace-warnings' "$tmp/render.log" | head -30
  echo "FAIL: rendu canari (arret, les etapes suivantes dependent du rendu)"
  exit 1
fi

step "2. arbre fusionne (depot + sorties du template)"
mkdir -p "$tmp/merged"
cp -R "$base/k8s" "$tmp/merged/k8s"
cp -R "$tmp/work/out/k8s/." "$tmp/merged/k8s/"
if python3 -I "$gp/tests/assert_canary.py" "$tmp/merged" "$params"; then pass "assertions structurelles"; else bad "assertions structurelles"; fi

step "3. kustomize build (application, base, Authentik)"
if kustomize build "$tmp/merged/k8s/applications/catalog/$name" > "$tmp/app.yaml"; then pass "kustomize application"; else bad "kustomize application"; fi
if kustomize build "$tmp/merged/k8s/infrastructure/database/pg-shared-homelab" > "$tmp/pg.yaml"; then pass "kustomize pg-shared-homelab"; else bad "kustomize pg-shared-homelab"; fi
if kustomize build "$tmp/merged/k8s/infrastructure/auth/authentik/extra" > "$tmp/auth.yaml"; then pass "kustomize authentik extra"; else bad "kustomize authentik extra"; fi

step "4. kubeconform (CRD absentes ignorees, consignees dans le rapport)"
for f in app pg auth; do
  if [ -s "$tmp/$f.yaml" ] && kubeconform -strict -ignore-missing-schemas -summary "$tmp/$f.yaml"; then
    pass "kubeconform $f"
  else
    bad "kubeconform $f"
  fi
done

step "5. garde d'isolation pg-shared-homelab (arbre fusionne)"
mkdir -p "$tmp/merged/tests/harness"
cp "$repo_root/tests/harness/pg-shared-homelab-isolation-guard-test.sh" "$tmp/merged/tests/harness/"
if bash "$tmp/merged/tests/harness/pg-shared-homelab-isolation-guard-test.sh" >"$tmp/guard.log" 2>&1; then
  pass "pg-shared-homelab-isolation-guard-test"
else
  tail -20 "$tmp/guard.log"; bad "pg-shared-homelab-isolation-guard-test"
fi

step "6. idempotence : deux rendus identiques (aucune valeur aleatoire dans les fichiers)"
node "$tmp/tools/render.mjs" "$tmp/template.json" "$params" "$gp/skeleton" "$base" "$tmp/work2" >/dev/null
if diff -r "$tmp/work" "$tmp/work2" >/dev/null; then pass "rendus identiques"; else bad "rendus differents"; fi

step "7. refus negatifs (chaque variante doit etre refusee)"
neg() {
  local label="$1" filter="$2" p="$tmp/neg.json"
  jq "$filter" "$params" > "$p"
  if node "$tmp/tools/render.mjs" "$tmp/template.json" "$p" "$gp/skeleton" "$base" "$tmp/neg-work" >/dev/null 2>&1; then
    bad "accepte a tort: $label"
  else
    pass "refuse: $label"
  fi
}
neg "image sans digest" '.image = "grafana/grafana-oss:12.4.3"'
neg "groupe hors enum" '.accessGroups = ["users"]'
neg "exposition externe" '.exposure = "external"'
neg "nom avec underscore" '.name = "canari_pg"'
neg "base reservee app" '.pgDatabase = "app"'
neg "base avec tiret" '.pgDatabase = "canari-pg"'
neg "RAM limite au-dela du plafond" '.memoryLimitMi = 1024'
neg "IRREPLACEABLE sans drill PASS" '.dataClass = "IRREPLACEABLE" | .restoreDrillStatus = "NOT_TESTED"'

# Mutations du TEMPLATE (pas des parametres) : chaque defaut connu doit etre refuse par le moteur.
negtpl() {
  local label="$1" filter="$2" p="$tmp/neg-tpl.json"
  jq "$filter" "$tmp/template.json" > "$p"
  if node "$tmp/tools/render.mjs" "$p" "$params" "$gp/skeleton" "$base" "$tmp/negtpl-work" >/dev/null 2>&1; then
    bad "accepte a tort (template): $label"
  else
    pass "refuse (template): $label"
  fi
}
negtpl "fetch:plain sur fichier unique (0 fichier extrait sur Backstage)" \
  '(.spec.steps[] | select(.action == "fetch:plain:file") | .action) |= "fetch:plain"'
negtpl "ancre absente (edition perdue en silence)" \
  '(.spec.steps[] | select(.id == "edit-catalog-kustomization") | .input.files[0].find) = "resources-absent:"'
negtpl "PR non brouillon" \
  '(.spec.steps[] | select(.action == "publish:github:pull-request") | .input) |= del(.draft)'
negtpl "branche avec slash" \
  '(.spec.steps[] | select(.action == "publish:github:pull-request") | .input.branchName) = "golden-path/x"'

step "8. ESO : aucune creationPolicy Owner, SecretStore avec url explicite"
if grep -rq 'creationPolicy: Owner' "$gp/skeleton"; then bad "creationPolicy Owner present dans le skeleton"; else pass "creationPolicy Orphan partout"; fi
n_url="$(grep -rc '        url: https://kubernetes.default.svc' "$gp/skeleton" | awk -F: '{s+=$2} END{print s}')"
if [ "$n_url" -eq 2 ]; then pass "SecretStore url explicite (2)"; else bad "SecretStore url attendu 2, trouve $n_url"; fi

step "9. deux services successifs : un bloc managed, deux roles (pas de YAML duplique)"
mkdir -p "$tmp/repo2"
cp -R "$tmp/merged/k8s" "$tmp/repo2/k8s"
p2="$tmp/params2.json"
jq '.name = "canari-2" | .pgDatabase = "canari2pg"' "$params" > "$p2"
if node "$tmp/tools/render.mjs" "$tmp/template.json" "$p2" "$gp/skeleton" "$tmp/repo2" "$tmp/work-2nd" >"$tmp/render2.log" 2>&1; then
  c2="$tmp/work-2nd/out/k8s/infrastructure/database/pg-shared-homelab/cluster.yaml"
  nm="$(grep -c '^  managed:' "$c2" || true)"
  nr="$(yq '.spec.managed.roles | length' "$c2" 2>/dev/null || echo ERR)"
  if [ "$nm" -eq 1 ] && [ "$nr" = "2" ]; then pass "2 services : 1 bloc managed, 2 roles (cluster.yaml valide)"; else bad "2e service : managed=$nm roles=$nr"; fi
else
  tail -5 "$tmp/render2.log"; bad "rendu du 2e service"
fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "RESULTAT: PASS (canari $name)"; else echo "RESULTAT: FAIL ($fails etape(s))"; exit 1; fi
