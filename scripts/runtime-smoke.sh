#!/usr/bin/env bash
set -euo pipefail

for cmd in kubectl jq curl dig; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required" >&2; exit 2; }; done
source "$(dirname "$0")/lib/kube-preflight.sh"
require_kube_access

# OpenClaw's controller owns the generated HTTPRoute and publishes the
# disablement state on the owning OpenClawInstance.  Keep this lookup generic:
# a missing CR or missing owner relationship is indeterminate and must not
# suppress a real smoke failure.
openclaw_instances='{"items":[]}'
if ! openclaw_instances="$(kubectl get openclawinstances.openclaw.rocks -A -o json 2>/dev/null)" ||
  ! jq -e '.items | type == "array"' >/dev/null <<<"$openclaw_instances"; then
  openclaw_instances='{"items":[]}'
fi

route_disabled_by_design() {
  local route="$1"
  jq -e --argjson instances "$openclaw_instances" '
    any(
      (.metadata.ownerReferences[]?
        | select(.apiVersion == "openclaw.rocks/v1alpha1" and .kind == "OpenClawInstance")
        | .uid);
      . as $owner_uid |
      any($instances.items[]?;
        .metadata.uid == $owner_uid and
        ((.spec.suspended // false) == true or .status.phase == "Suspended")
      )
    )
  ' <<<"$route" >/dev/null
}

DNS_SERVER="${DNS_SERVER:-10.0.20.1}"
INTERNAL_VIP="${INTERNAL_VIP:-10.0.20.192}"
keep_artifacts=no
if [[ -n "${ARTIFACT_DIR:-}" ]]; then
  artifact_dir="$ARTIFACT_DIR"
  keep_artifacts=yes
else
  artifact_dir="$(mktemp -d "${TMPDIR:-/tmp}/kube-ops-runtime-smoke.XXXXXX")"
fi
if [[ "$keep_artifacts" == no ]]; then
  trap 'rm -rf "$artifact_dir"; kube_access_cleanup' EXIT
else
  trap 'kube_access_cleanup' EXIT
fi
mkdir -p "$artifact_dir"
ARTIFACT_DIR="$artifact_dir"
report="$ARTIFACT_DIR/results.jsonl"
: >"$report"

routes="$(kubectl get httproutes.gateway.networking.k8s.io -A -o json)"
failures=0
tested=0
skipped_disabled_by_design=0

while IFS= read -r route; do
  ns="$(jq -r '.metadata.namespace' <<<"$route")"
  name="$(jq -r '.metadata.name' <<<"$route")"
  probe="$(jq -r '.metadata.annotations["qa.smadja.dev/probe"] // "true"' <<<"$route")"
  [[ "$probe" == "false" ]] && continue

  internal="$(jq -r 'any(.spec.parentRefs[]?; .name=="internal")' <<<"$route")"
  [[ "$internal" == "true" ]] || continue

  accepted="$(jq -r 'any(.status.parents[]?; .parentRef.name=="internal" and any(.conditions[]?; .type=="Accepted" and .status=="True"))' <<<"$route")"
  refs="$(jq -r 'all(.status.parents[]? | select(.parentRef.name=="internal"); any(.conditions[]?; .type=="ResolvedRefs" and .status=="True"))' <<<"$route")"
  path="$(jq -r '.metadata.annotations["qa.smadja.dev/path"] // "/"' <<<"$route")"
  expected="$(jq -r '.metadata.annotations["qa.smadja.dev/expected-status"] // "200,204,301,302,303,307,308,401,403"' <<<"$route")"

  endpoint_count=0
  route_is_disabled_by_design=false
  if route_disabled_by_design "$route"; then
    route_is_disabled_by_design=true
    skipped_disabled_by_design=$((skipped_disabled_by_design + 1))
  else
    backend_refs="$(jq '[.spec.rules[]?.backendRefs[]? | select((.kind // "Service")=="Service")] | length' <<<"$route")"
    while IFS= read -r backend; do
      [[ -z "$backend" ]] && continue
      svc="$(jq -r '.name' <<<"$backend")"
      bns="$(jq -r --arg ns "$ns" '.namespace // $ns' <<<"$backend")"
      count="$(kubectl get endpointslices.discovery.k8s.io -n "$bns" -l "kubernetes.io/service-name=$svc" -o json 2>/dev/null | jq '[.items[].endpoints[]? | select(.conditions.ready != false)] | length' || echo 0)"
      endpoint_count=$((endpoint_count + count))
    done < <(jq -c '.spec.rules[]?.backendRefs[]? | select((.kind // "Service")=="Service")' <<<"$route")
  fi

  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    if [[ "$route_is_disabled_by_design" == true ]]; then
      jq -nc \
        --arg namespace "$ns" --arg route "$name" --arg host "$host" \
        --arg accepted "$accepted" --arg resolvedRefs "$refs" \
        --arg result SKIPPED_DISABLED_BY_DESIGN --arg reason disabled-by-design \
        --argjson readyEndpoints "$endpoint_count" \
        '{namespace:$namespace,route:$route,host:$host,accepted:($accepted=="true"),resolvedRefs:($resolvedRefs=="true"),readyEndpoints:$readyEndpoints,result:$result,reasons:$reason,disabledByDesign:true}' \
        | tee -a "$report"
      continue
    fi
    tested=$((tested + 1))
    dns_answers="$(dig @"$DNS_SERVER" +short A "$host" | paste -sd, -)"
    dns_ok=false
    if tr ',' '\n' <<<"$dns_answers" | grep -qx "$INTERNAL_VIP"; then dns_ok=true; fi

    code="$(curl --silent --show-error --output /dev/null --max-time 15       --resolve "${host}:443:${INTERNAL_VIP}" --write-out '%{http_code}' "https://${host}${path}" 2>/dev/null || printf '000')"
    http_ok=false
    if tr ',' '\n' <<<"$expected" | grep -qx "$code"; then http_ok=true; fi

    backend_ok=true
    if (( backend_refs > 0 && endpoint_count == 0 )); then backend_ok=false; fi

    result=PASS
    reasons=()
    [[ "$accepted" == "true" ]] || { result=FAIL; reasons+=("route-not-accepted"); }
    [[ "$refs" == "true" ]] || { result=FAIL; reasons+=("unresolved-backend-ref"); }
    [[ "$dns_ok" == "true" ]] || { result=FAIL; reasons+=("private-dns"); }
    [[ "$backend_ok" == "true" ]] || { result=FAIL; reasons+=("no-ready-endpoint"); }
    [[ "$http_ok" == "true" ]] || { result=FAIL; reasons+=("http-$code"); }

    [[ "$result" == PASS ]] || failures=$((failures + 1))
    reason_csv="$(IFS=,; echo "${reasons[*]:-}")"
    jq -nc       --arg namespace "$ns" --arg route "$name" --arg host "$host"       --arg accepted "$accepted" --arg resolvedRefs "$refs"       --arg dns "$dns_answers" --arg code "$code" --arg result "$result"       --arg reasons "$reason_csv" --argjson readyEndpoints "$endpoint_count"       '{namespace:$namespace,route:$route,host:$host,accepted:($accepted=="true"),resolvedRefs:($resolvedRefs=="true"),dns:$dns,httpStatus:$code,readyEndpoints:$readyEndpoints,result:$result,reasons:($reasons|if length > 0 then . else null end),disabledByDesign:false}'       | tee -a "$report"
  done < <(jq -r '.spec.hostnames[]?' <<<"$route")
done < <(jq -c '.items[]' <<<"$routes")

echo "RUNTIME_SMOKE_TESTED=$tested"
echo "RUNTIME_SMOKE_FAILURES=$failures"
echo "RUNTIME_SMOKE_SKIPPED_DISABLED_BY_DESIGN=$skipped_disabled_by_design"
echo "RUNTIME_SMOKE_ARTIFACT=$report"
echo "RUNTIME_SMOKE_ARTIFACT_PERSISTED=$keep_artifacts"
(( failures == 0 ))
