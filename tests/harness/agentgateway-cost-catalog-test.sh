#!/usr/bin/env bash
# PLT-568 : contrat du catalogue de couts de la passerelle Agentgateway.
#
#   bash tests/harness/agentgateway-cost-catalog-test.sh
#
# Le catalogue (k8s/applications/platform/agentgateway/cost-catalog.yaml) porte le tarif public de
# chaque modele route par la passerelle (`config.llm.models` de
# k8s/applications/platform/agentgateway/resources.yaml), la source de ce tarif et la date de
# consultation. Le tableau Grafana « Agentgateway »
# (k8s/infrastructure/monitoring/prometheus-stack/grafana-agentgateway.yaml) applique ces tarifs :
# ses requetes Prometheus et sa table de tarif doivent porter exactement les memes valeurs.
#
# Le test refuse :
#   - un modele route sans tarif (le panneau de cout resterait vide pour ce modele) ;
#   - un tarif sans source https ni date de consultation ;
#   - un tarif applique par le tableau different du catalogue, dans un sens ou dans l'autre ;
#   - une entree de catalogue pour un modele qui n'est plus route.
#
# Perimetre : les modeles de texte de `config.llm.models`. Les routes de capacite (audio, image,
# video) ne sont pas facturees au jeton : elles ne produisent pas la metrique de jetons du
# tableau, donc elles n'ont pas de tarif par million de jetons.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

catalog="k8s/applications/platform/agentgateway/cost-catalog.yaml"
gateway="k8s/applications/platform/agentgateway/resources.yaml"
dashboard="k8s/infrastructure/monitoring/prometheus-stack/grafana-agentgateway.yaml"

for f in "$catalog" "$gateway" "$dashboard"; do
  [[ -f "$f" ]] || { echo "missing $f" >&2; exit 1; }
done
command -v yq >/dev/null || { echo "yq is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/agentgateway-cost-catalog.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 1. Les modeles routes par la passerelle : l'alias expose aux clients et le modele fournisseur.
yq -o=json eval-all '[select(.kind == "ConfigMap" and .metadata.name == "agentgateway-config")
  | .data["config.yaml"]]' "$gateway" >"$work/gateway.json"
jq -r '.[0]' "$work/gateway.json" >"$work/config.yaml"
yq -o=json '.llm.models' "$work/config.yaml" >"$work/models.json"

# 2. Le catalogue des tarifs.
yq -o=json '.catalog' "$catalog" >"$work/catalog.json"

# 3. Le tableau : le panneau de cout par modele, celui du cout total et la documentation.
yq -o=json eval-all '[select(.kind == "ConfigMap")]' "$dashboard" >"$work/dashboards.json"
jq -r '.[0].data[]' "$work/dashboards.json" >"$work/dashboard.json"

# Chaque terme de cout : le modele (selecteur), le type de jeton et le tarif applique.
jq -rn \
  --slurpfile models "$work/models.json" \
  --slurpfile catalog "$work/catalog.json" \
  --slurpfile dashboard "$work/dashboard.json" '
  def set_of($a): ($a | map(select(length > 0)) | unique | sort);
  def check($cond; $msg): if $cond then $msg else empty end;
  def term:
    {
      sel: (try (. | capture("gen_ai_request_model=~\"(?<sel>[^\"]+)\"").sel) catch null),
      tok: (try (. | capture("gen_ai_token_type=\"(?<tok>[^\"]+)\"").tok) catch null),
      rate: (try (. | capture("\\*\\s*(?<rate>[0-9.]+)\\s*/\\s*1000000").rate | tonumber) catch null)
    };
  def terms_of($panel): ([ $dashboard[0].panels[] | select(.title == $panel) | .targets[].expr ]
    | map(split(" + ") | .[]) | map(term));
  def doc: ([ $dashboard[0].panels[] | select(.type == "text") | .options.content ] | join("\n"));

  ($catalog[0]) as $cat
  | ($models[0] | map({alias: .name, model: .params.model})) as $routed
  | ({"input": "input", "output": "output", "cache_read": "input_cache_read"}) as $tokmap
  | [ $cat[] | . as $e
      | $tokmap | to_entries[] | . as $t
      | {
          e: $e,
          tok: $t.value,
          rate: (($e.usd_per_million_tokens[$t.key] // "") | tonumber),
          sel: set_of(([$e.model] + ($e.aliases // [])))
        } ] as $expected
  | (terms_of("Estimated cost per model (estimation, not an invoice)")) as $cost_terms
  | (terms_of("Estimated cost over the selected period (estimation)")) as $total_terms
  | (doc) as $doc

  # 1. Chaque modele route a un tarif, et son alias y est declare.
  | [ $routed[] | . as $m
      | ( [ $cat[] | select(.model == $m.model) ] ) as $cands
      | check(($cands | length) == 0;
              "the routed model \($m.model) (alias \($m.alias)) has no tariff"),
        check(($cands | length) > 0 and (($cands[0].aliases // []) | index($m.alias)) == null;
              "the alias \($m.alias) is not declared in the tariff of \($m.model)") ] +
  # 2. Chaque alias du catalogue est bien route, chaque entree du catalogue est bien routee.
  [ $cat[] | . as $e
      | ($e.aliases // [])[] as $a
      | check(([ $routed[] | select(.alias == $a) ] | length) == 0;
              "the tariff of \($e.model) declares the alias \($a) which is not routed") ] +
  [ $cat[] | . as $e
      | check(([ $routed[] | select(.model == $e.model) ] | length) == 0;
              "the tariff of \($e.model) matches no routed model") ] +
  # 3. Chaque tarif a ses trois taux, une source https et une date de consultation.
  [ $cat[] | . as $e
      | (["input", "output", "cache_read"][]) as $k
      | (($e.usd_per_million_tokens[$k] // "") | tostring) as $r
      | check($r == ""; "the tariff of \($e.model) has no \($k) rate"),
        check($r != "" and (try ($r | tonumber) catch 0) <= 0;
              "the \($k) rate of \($e.model) is not a positive number") ] +
  [ $cat[] | . as $e
      | (($e.source.url // "") | test("^https://")) as $url_ok
      | (($e.source.retrieved // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) as $date_ok
      | check($url_ok | not; "the tariff of \($e.model) has no https source"),
        check($date_ok | not; "the tariff of \($e.model) has no retrieval date") ] +
  # 4. Le tableau applique seulement des tarifs du catalogue.
  [ ($cost_terms + $total_terms)[] | . as $t
      | check($t.sel == null or $t.tok == null or $t.rate == null;
              "a cost query of the dashboard carries no model, no token type or no rate"),
        check(($t.sel != null and $t.tok != null and $t.rate != null)
              and ([ $expected[] | select(.tok == $t.tok and .rate == $t.rate
                    and .sel == set_of($t.sel | split("|"))) ] | length) == 0;
              "the dashboard applies a tariff that is not in the catalogue: \($t.sel) \($t.tok) = \($t.rate) USD/M") ] +
  # 5. Chaque tarif du catalogue est applique par les deux panneaux de cout.
  [ $expected[] | . as $x
      | check(([ $cost_terms[] | select(.tok == $x.tok and .rate == $x.rate
              and (set_of(.sel | split("|"))) == $x.sel) ] | length) == 0;
              "the cost panel does not apply the tariff of \($x.e.model) (\($x.tok) = \($x.rate) USD/M)") ] +
  [ $expected[] | . as $x
      | check(([ $total_terms[] | select(.tok == $x.tok and .rate == $x.rate
              and (set_of(.sel | split("|"))) == $x.sel) ] | length) == 0;
              "the total cost panel does not apply the tariff of \($x.e.model) (\($x.tok) = \($x.rate) USD/M)") ] +
  # 6. La documentation du tableau porte les tarifs, les sources et les dates.
  [ $cat[] | . as $e
      | (["input", "output", "cache_read"][]) as $k
      | (($e.usd_per_million_tokens[$k] // "") | tostring) as $r
      | check(($doc | contains("\($r) USD/M")) | not;
              "the tariff table of the dashboard does not show \($r) USD/M for \($e.model) (\($k))"),
        check(($doc | contains($e.source.url)) | not;
              "the dashboard does not cite the source \($e.source.url) of \($e.model)"),
        check(($doc | contains($e.source.retrieved)) | not;
              "the dashboard does not cite the retrieval date \($e.source.retrieved) of \($e.model)") ] +
  # 7. Le palier long (au-dela de 512k jetons dentree) est cite quand le catalogue le declare.
  [ $cat[] | . as $e
      | select($e.long_context != null) | .long_context as $lc
      | (["input", "output", "cache_read"][]) as $k
      | (($lc.usd_per_million_tokens[$k] // "") | tostring) as $r
      | check(($doc | contains("\($r) USD/M")) | not;
              "the dashboard does not show the long context rate \($r) USD/M of \($e.model)") ]
  | sort | unique | .[]
' >"$work/errors.txt"

if [[ -s "$work/errors.txt" ]]; then
  echo "agentgateway cost catalog contract: FAIL" >&2
  sed 's/^/  - /' "$work/errors.txt" >&2
  exit 1
fi

echo "agentgateway cost catalog contract: PASS ($(yq '.catalog | length' "$catalog") tariffs, every routed model priced)"
