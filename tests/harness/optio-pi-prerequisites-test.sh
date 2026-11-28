#!/usr/bin/env bash
# PLT-542 : contrat hors reseau des prerequis des taches Pi d'Optio.
#   * cle de passerelle `optio-pi` : un seul alias (text/strong), budget bloquant, secret lu et monte ;
#   * secret de tirage GHCR present mais reference par aucun pod ni ServiceAccount ;
#   * optio-secret-sync : ecrit OPENAI_API_KEY (portee user), garde une valeur posee par une personne,
#     n'affiche jamais la valeur et ne bloque jamais l'entretien.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
gateway="$ROOT/k8s/applications/platform/agentgateway"
optio="$ROOT/k8s/applications/platform/optio"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

yq -r 'select(.kind == "ConfigMap" and .metadata.name == "agentgateway-config") | .data."config.yaml"' \
  "$gateway/resources.yaml" >"$tmp/config.yaml"
key='.llm.policies.apiKey.keys[] | select(.metadata.name == "optio-pi")'
# shellcheck disable=SC2016 # litteral attendu dans la configuration
[ "$(yq -r "$key | .key" "$tmp/config.yaml")" = '$OPTIO_PI_AGENTGATEWAY_KEY' ] || fail "cle optio-pi absente"
[ "$(yq -r "$key | .allowedModels | join(\",\")" "$tmp/config.yaml")" = "text/strong" ] ||
  fail "optio-pi doit admettre le seul alias text/strong"
[ "$(yq -r "$key | .budgets[] | .limit.unit + \" \" + (.limit.amount | tostring) + \" \" + .onBudgetExceeded" "$tmp/config.yaml")" \
  = "Tokens 5000000 Block" ] || fail "budget optio-pi inattendu"
grep -q 'secretRef: {name: llm-optio--pi}' "$gateway/resources.yaml" || fail "envFrom llm-optio--pi absent"
grep -qE '^      - llm-optio--pi( |$)' "$gateway/pr-triage-key.yaml" || fail "Role sans llm-optio--pi"
grep -qxF '  - optio-pi-key.yaml' "$gateway/kustomization.yaml" || fail "optio-pi-key.yaml hors kustomization"

if grep -qE 'imagePullSecrets' "$optio"/*.yaml; then
  fail "aucun imagePullSecrets dans l'application optio : seule la politique de l'image Pi le pose"
fi

# Script du CronJob execute avec de faux modules Optio.
yq -r 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].command[2]' \
  "$optio/secret-sync.yaml" >"$tmp/sync.js"
sed -i.bak \
  -e 's#await import("./src/services/secret-service.ts")#globalThis.fakeSecrets#' \
  -e 's#await import("./src/db/client.ts")#globalThis.fakeDb#' \
  -e 's#await import("drizzle-orm")#globalThis.fakeOrm#' "$tmp/sync.js"

cat >"$tmp/run.js" <<'JS'
const fs = require("node:fs");
const store = new Map();
const initial = process.env.CASE_EXISTING;
if (initial) store.set("OPENAI_API_KEY", initial);
globalThis.fakeSecrets = {
  retrieveSecret: async (name) => { if (!store.has(name)) throw new Error("none"); return store.get(name); },
  storeSecret: async (name, value, scope) => {
    if (scope !== "user") throw new Error("scope");
    store.set(name, value);
    process.stdout.write(`STORE ${name}\n`);
  },
};
globalThis.fakeOrm = { sql: (strings) => strings.join("?") };
globalThis.fakeDb = { db: { execute: async (query) =>
  query.includes("select id from secrets") && store.has("OPENAI_API_KEY") ? [{ id: "row-uuid" }] : [] } };
eval(fs.readFileSync(process.argv[2], "utf8"));
JS

new_key="$(printf 'a%.0s' {1..48})"
old_key="$(printf 'b%.0s' {1..48})"
run_case() { # existing pi_key
  CASE_EXISTING="$1" PI_GATEWAY_KEY="$2" OPTIO_GATEWAY_USER_ID=user GATEWAY_KEY=gatewayvalue \
    GATEWAY_URL=http://gateway node "$tmp/run.js" "$tmp/sync.js" 2>&1
}
expect() { grep -qF -- "$2" <<<"$1" || fail "attendu '$2' dans : $1"; }
refuse() { if grep -qF -- "$2" <<<"$1"; then fail "interdit '$2' dans : $1"; fi; }

out="$(run_case "" "$new_key")"
expect "$out" "SYNC_STATUS=PASS OPENAI_API_KEY written credential=secret:row-uuid"
expect "$out" "JANITOR_STATUS=PASS"
refuse "$out" "$new_key"
out="$(run_case "$new_key" "$new_key")"
expect "$out" "SYNC_STATUS=PASS OPENAI_API_KEY unchanged credential=secret:row-uuid"
refuse "$out" "STORE OPENAI_API_KEY"
out="$(run_case "$old_key" "$new_key")"
expect "$out" "SYNC_STATUS=PASS OPENAI_API_KEY written"
out="$(run_case "sk-proj-person-owned" "$new_key")"
expect "$out" "SYNC_STATUS=FAIL OPENAI_API_KEY existing value kept"
expect "$out" "JANITOR_STATUS=PASS"
refuse "$out" "STORE OPENAI_API_KEY"
refuse "$out" "sk-proj-person-owned"
out="$(run_case "" "")"
refuse "$out" "OPENAI_API_KEY"
expect "$out" "JANITOR_STATUS=PASS"

echo "OPTIO_PI_PREREQUISITES=PASS"
