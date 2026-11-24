#!/usr/bin/env bash
# Lot 3 of docs/architecture/secrets-migration-spec.md: static test of scripts/scaffold-app-secrets.sh.
# Works on a COPY of the repository in mktemp (nothing is written in the working tree, no fixed port,
# no network, no secret value):
#   1. --help, dry-run (writes nothing), refusals (plain-text secret, names out of convention,
#      cross-namespace, T6-looking local key, unknown option, missing target);
#   2. --write for a fictitious app `--oidc --pg-shared --local-key session`, expected files and insertions;
#   3. idempotence by refusal (second --write refused, tree unchanged);
#   4. kustomize build of the touched folders, eso-generated-secrets-contract-test.sh and
#      scripts/policy-check.sh on the result;
#   5. mutation: without the resourceNames insertion the contract test must fail;
#   6. the output of the script holds no secret value; --data-key writes nothing and prints the T6 PR.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tool=scripts/scaffold-app-secrets.sh
for t in yq python3 kustomize helm kyverno rsync; do
  command -v "$t" >/dev/null || { echo "ERROR: $t is required" >&2; exit 1; }
done
tmp="$(mktemp -d "${TMPDIR:-/tmp}/scaffold-app-secrets-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mk_copy() { # mk_copy DIR : repository copy with a fixture application folder
  mkdir -p "$1"
  # Tracked files only (working-tree content): the real tree may hold untracked Helm charts pulled by other checks.
  (cd "$repo_root" && git ls-files -z) | rsync -a --from0 --files-from=- "$repo_root/" "$1/"
  mkdir -p "$1/k8s/applications/tools/demoapp"
  cat >"$1/k8s/applications/tools/demoapp/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demoapp-ns
resources:
  - namespace.yaml
YAML
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: demoapp-ns\n' >"$1/k8s/applications/tools/demoapp/namespace.yaml"
}
run() { # run COPY ARGS... (merged output)
  local c=$1; shift
  SCAFFOLD_ROOT="$c" bash "$repo_root/$tool" "$@"
}
snapshot() { (cd "$1" && find k8s -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1); }
expect_refuse() { # expect_refuse WANT COPY ARGS...
  local want=$1 c=$2; shift 2
  local before after out
  before=$(snapshot "$c")
  if out=$(run "$c" "$@" 2>&1); then fail "accepted: $*"; fi
  [[ $out == *"$want"* ]] || fail "'$*' refused without '$want': $out"
  after=$(snapshot "$c")
  [[ $before == "$after" ]] || fail "'$*' modified the tree although refused"
}

# --- 1. help and refusals ------------------------------------------------------------------
help_out=$(bash "$repo_root/$tool" --help) || fail "--help exits non-zero"
for w in "--namespace" "--oidc" "--pg-shared" "--local-key" "--data-key" "--external" "--write"; do
  [[ $help_out == *"$w"* ]] || fail "--help does not mention $w"
done

c="$tmp/repo"; mk_copy "$c"
base=$(snapshot "$c")
args=(demoapp --namespace demoapp-ns --oidc demoapp --pg-shared --local-key session)

dry=$(run "$c" "${args[@]}") || fail "dry-run failed: $dry"
[[ $dry == *"mode=DRY-RUN"* && $dry == *"CREATE k8s/infrastructure/auth/authentik/extra/oidc-demoapp-ns.yaml"* ]] || fail "dry-run does not list the files"
[[ $(snapshot "$c") == "$base" ]] || fail "dry-run wrote something"

expect_refuse "never accepts a secret value" "$c" "${args[@]}" --client-secret x
expect_refuse "never accepts a secret value" "$c" "${args[@]}" --password
expect_refuse "write '--option VALUE'" "$c" "${args[@]}" --oidc=demoapp
expect_refuse "does not match" "$c" Demo_App --namespace demoapp-ns --local-key session
expect_refuse "does not match" "$c" demoapp --namespace Demo_NS --local-key session
expect_refuse "cross-namespace read" "$c" demoapp --namespace demoapp--other --local-key session
expect_refuse "reserved" "$c" demoapp --namespace auth --oidc demoapp
expect_refuse "reserved" "$c" demoapp --namespace databases --pg-shared
expect_refuse "short client id" "$c" demoapp --namespace demoapp-ns --oidc 0123456789abcdef0123456789abcdef
expect_refuse "data-encryption key (T6)" "$c" demoapp --namespace demoapp-ns --local-key encryption
expect_refuse "data-encryption key (T6)" "$c" demoapp --namespace demoapp-ns --local-key secret-key
expect_refuse "data-encryption key (T6)" "$c" demoapp --namespace demoapp-ns --local-key master-key
expect_refuse "--pg-shared: APP must be" "$c" demo-app --namespace demoapp-ns --pg-shared --app-dir k8s/applications/tools/demoapp
expect_refuse "reserved by pg-shared-homelab" "$c" app --namespace demoapp-ns --pg-shared --app-dir k8s/applications/tools/demoapp
expect_refuse "no unique application directory" "$c" ghostapp --namespace ghost-ns --local-key session
expect_refuse "unknown option" "$c" demoapp --namespace demoapp-ns --frobnicate
expect_refuse "nothing to scaffold" "$c" demoapp --namespace demoapp-ns
expect_refuse "unknown kind" "$c" demoapp --namespace demoapp-ns --external s3

# --- 2. --write ----------------------------------------------------------------------------
out=$(run "$c" "${args[@]}" --write) || fail "--write failed: $out"
a=k8s/infrastructure/auth/authentik; p=k8s/infrastructure/database/pg-shared-homelab; d=k8s/applications/tools/demoapp
for f in $a/extra/oidc-demoapp-ns.yaml $p/pg-demoapp-ns.yaml $p/demoapp-database.yaml \
         $d/demoapp-oidc-externalsecret.yaml $d/demoapp-db-externalsecret.yaml $d/demoapp-session-generated-secret.yaml; do
  [[ -f $c/$f ]] || fail "missing $f"
done
grep -q -- '- eso-k8s-sentinel-none' "$c/$a/extra/eso-k8s-reader-rbac.yaml" || fail "sentinel lost (auth)"
grep -q -- '- oidc-demoapp-ns$' "$c/$a/extra/eso-k8s-reader-rbac.yaml" || fail "oidc-demoapp-ns not in resourceNames"
grep -q -- '- eso-k8s-sentinel-none' "$c/$p/eso-k8s-reader-rbac.yaml" || fail "sentinel lost (databases)"
grep -q -- '- pg-demoapp-ns$' "$c/$p/eso-k8s-reader-rbac.yaml" || fail "pg-demoapp-ns not in resourceNames"
grep -q -- '- oidc-demoapp-ns.yaml' "$c/$a/extra/kustomization.yml" || fail "extra kustomization not updated"
grep -q -- '- pg-demoapp-ns.yaml' "$c/$p/kustomization.yaml" || fail "pg kustomization not updated"
grep -q -- '- demoapp-database.yaml' "$c/$p/kustomization.yaml" || fail "Database not in pg kustomization"
grep -q 'name: pg-demoapp-ns' "$c/$p/cluster.yaml" || fail "managed role not added"
[[ $(yq -r '.spec.managed.roles[-1].name' "$c/$p/cluster.yaml") == demoapp ]] || fail "managed role name (appended last)"
yq -e '.spec.envFrom' "$c/$a/values.yaml" >/dev/null 2>&1 || true
grep -A2 'name: oidc-demoapp-ns' "$c/$a/values.yaml" | grep -q 'optional: true' || fail "envFrom entry lacks optional: true"
grep -q 'authentik-blueprint-librechat,oidc-demoapp-ns"' "$c/$a/values.yaml" || fail "Reloader list not extended"
for f in demoapp-oidc-externalsecret demoapp-db-externalsecret demoapp-session-generated-secret; do
  grep -q -- "- $f.yaml" "$c/$d/kustomization.yaml" || fail "app kustomization lacks $f"
done
# Source shapes (spec 4.2) and copies (spec 4.4).
src=$c/$a/extra/oidc-demoapp-ns.yaml
[[ $(yq -r 'select(.kind=="ExternalSecret") | .spec.refreshPolicy + "/" + .spec.target.creationPolicy + "/" + .metadata.annotations["kube-ops.io/secret-class"]' "$src") == CreatedOnce/Orphan/T3 ]] || fail "T3 source shape"
[[ $(yq -r 'select(.kind=="ExternalSecret") | .spec.target.template.data | keys | .[0]' "$src") == DEMOAPP_OIDC_CLIENT_SECRET ]] || fail "T3 key name"
[[ $(yq -r '.spec.secretStoreRef.name + "/" + .spec.data[0].remoteRef.key + "/" + .spec.target.creationPolicy' "$c/$d/demoapp-oidc-externalsecret.yaml") == k8s-auth/oidc-demoapp-ns/Owner ]] || fail "T3 copy shape"
[[ $(yq -r '.spec.secretStoreRef.name + "/" + .spec.data[0].remoteRef.key' "$c/$d/demoapp-db-externalsecret.yaml") == k8s-databases/pg-demoapp-ns ]] || fail "T1 copy shape"
[[ $(yq -r 'select(.kind=="ExternalSecret") | .metadata.annotations["kube-ops.io/secret-class"] + "/" + .spec.target.template.type' "$c/$p/pg-demoapp-ns.yaml") == T1/kubernetes.io/basic-auth ]] || fail "T1 source shape"
[[ $(yq -r 'select(.kind=="ExternalSecret") | .metadata.namespace + "/" + (.spec.secretStoreRef // "none" | tostring) + "/" + .metadata.annotations["kube-ops.io/secret-class"]' "$c/$d/demoapp-session-generated-secret.yaml") == "demoapp-ns/none/T4" ]] || fail "T4 source shape"
grep -q 'name: pg-shared-homelab-demoapp-isolation' "$c/$p/demoapp-database.yaml" || fail "isolation Job missing"

# --- 2b. conformity with the lot 1 template (app-database.example.tmpl) ---------------------
# The `>>> yaml` blocks of the template are rendered for APP=demoapp APP_NS=demoapp-ns and compared,
# as normalized JSON, with what the script generated: names, labels, annotations, store, keys.
tmpl=$repo_root/k8s/infrastructure/database/pg-shared-homelab/app-database.example.tmpl
tblock() { # tblock NAME -> rendered block as sorted compact JSON lines (one per document)
  awk -v want="$1" '/^# >>> yaml /{on=($4==want); next} /^# <<< yaml$/{on=0; next} on{sub(/^# ?/,""); print}' "$tmpl" \
    | perl -pe 's/APP_NS/demoapp-ns/g; s/\bAPP\b/demoapp/g' | yq -o=json -I=0 -N 'sort_keys(..)'
}
gblock() { yq -o=json -I=0 -N 'sort_keys(..)' "$@"; }
[[ -n $(tblock source) ]] || fail "template block 'source' not found"
[[ $(tblock source) == "$(gblock "$c/$p/pg-demoapp-ns.yaml")" ]] || fail "T1 source differs from the lot 1 template"
[[ $(tblock copy) == "$(gblock "$c/$d/demoapp-db-externalsecret.yaml")" ]] || fail "T1 copy differs from the lot 1 template"
[[ $(tblock database) == "$(gblock "$c/$p/demoapp-database.yaml" | sed -n 1p)" ]] || fail "Database differs from the lot 1 template"
[[ $(tblock cluster-role | yq -o=json -I=0 '.managed.roles[0]') == "$(yq -o=json -I=0 'sort_keys(..) | .spec.managed.roles[-1]' "$c/$p/cluster.yaml")" ]] || fail "managed role differs from the lot 1 template"
jobq='select(.kind == "Job") | [.metadata, .spec.backoffLimit, .spec.template.spec.restartPolicy, .spec.template.spec.containers[0].env] | sort_keys(..)'
[[ $(tblock isolation-job | yq -o=json -I=0 "$jobq" | grep -v '^\[\]$') == "$(yq -o=json -I=0 "$jobq" "$c/$p/demoapp-database.yaml" | grep -v '^\[\]$')" ]] || fail "isolation Job (name, hook, env, secretKeyRef) differs from the lot 1 template"
yq -e '.spec.template.spec.containers[0].env[] | select(.name == "PGUSER") | .valueFrom.secretKeyRef.name == "pg-demoapp-ns"' "$c/$p/demoapp-database.yaml" >/dev/null 2>&1 \
  || yq -e 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.name == "PGUSER") | .valueFrom.secretKeyRef.name == "pg-demoapp-ns"' "$c/$p/demoapp-database.yaml" >/dev/null || fail "Job does not read pg-demoapp-ns"

# --- 3. idempotence by refusal -------------------------------------------------------------
after=$(snapshot "$c")
expect_refuse "already exists" "$c" "${args[@]}" --write
[[ $(snapshot "$c") == "$after" ]] || fail "refused re-run changed the tree"

# --- 6a. no secret value in the output (names only) ----------------------------------------
if grep -Eq '[A-Za-z0-9+=]{32,}' <<<"$out"; then fail "output holds a long opaque string"; fi
[[ $out == *"nothing to create or copy by hand for T1, T3, T4, T5"* ]] || fail "output does not state that Doppler is not needed"

# --- 4. render and contracts on the result -------------------------------------------------
sed -i.bak 's/^- it-tools$/- it-tools\n- demoapp/' "$c/k8s/applications/tools/kustomization.yaml"; rm -f "$c/k8s/applications/tools/kustomization.yaml.bak"
for dir in $a/extra $p $d; do
  kustomize build --enable-helm "$c/$dir" >"$tmp/render.yaml" 2>"$tmp/render.err" || { cat "$tmp/render.err" >&2; fail "kustomize build $dir"; }
done
# Before the contract test: its render cache pulls Helm charts into the copy, which the guard cannot parse.
(cd "$c" && bash tests/harness/pg-shared-homelab-isolation-guard-test.sh >"$tmp/iso.out" 2>&1) || { tail -20 "$tmp/iso.out" >&2; fail "isolation guard on the scaffold result"; }
(cd "$c" && bash tests/harness/eso-generated-secrets-contract-test.sh >"$tmp/contract.out" 2>&1) || { tail -20 "$tmp/contract.out" >&2; fail "eso-generated-secrets-contract-test on the scaffold result"; }
(cd "$c" && V1_CONTRACT_ROOTS=k8s/infrastructure/auth,k8s/infrastructure/database,k8s/applications/tools bash scripts/policy-check.sh >"$tmp/policy.out" 2>&1) || { tail -30 "$tmp/policy.out" >&2; fail "policy-check on the scaffold result"; }

# --- 5. mutation: the contract must notice a missing resourceNames insertion -----------------
mut="$tmp/mutant"; mkdir -p "$mut"
rsync -a "$c/" "$mut/"
sed -i.bak '/- oidc-demoapp-ns$/d' "$mut/$a/extra/eso-k8s-reader-rbac.yaml"; rm -f "$mut/$a/extra/eso-k8s-reader-rbac.yaml.bak"
if (cd "$mut" && bash tests/harness/eso-generated-secrets-contract-test.sh >"$tmp/mut.out" 2>&1); then
  fail "contract test still passes without the resourceNames insertion (mutation survived)"
fi
grep -q 'VIOLATION' "$tmp/mut.out" || fail "mutant refused without a VIOLATION line: $(tail -3 "$tmp/mut.out")"

# --- 6b. --data-key and --external ---------------------------------------------------------
c2="$tmp/repo2"; mk_copy "$c2"; b2=$(snapshot "$c2")
dk=$(run "$c2" demoapp --namespace demoapp-ns --data-key encryption --write) || fail "--data-key failed: $dk"
[[ $(snapshot "$c2") == "$b2" ]] || fail "--data-key wrote a file"
[[ $dk == *"APP_DEMOAPP_ENCRYPTION_KEY"* && $dk == *"prevent_destroy"* && $dk == *"NO generator written"* ]] || fail "--data-key does not print the T6 PR"
ex=$(run "$c2" demoapp --namespace demoapp-ns --external cloudflare-dns --external r2-writer --write) || fail "--external failed: $ex"
[[ $(yq -r '.spec.data[0].remoteRef.key' "$c2/$d/demoapp-cloudflare-externalsecret.yaml") == CLOUDFLARE_API_TOKEN ]] || fail "cloudflare reuse"
[[ $(yq -r '.spec.data[0].remoteRef.key' "$c2/$d/demoapp-r2-externalsecret.yaml") == R2_CNPG_WRITER_ACCESS_KEY_ID ]] || fail "r2 writer reuse"

echo "scaffold-app-secrets test: PASS"
