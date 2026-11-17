#!/usr/bin/env bash
# app-status.v1 : etat d'une application generee (platform.smadja.dev/v1), lecture seule.
#
# Usage: bash scripts/app-status.sh <app> [--cluster homelab|oracle-a1] [--commit <sha>|main-head]
#   stdout : un document JSON app-status.v1 (docs/contracts/app-status-v1.schema.json)
#   exit   : 0 PASS, 1 FAIL, 3 PENDING, 4 UNKNOWN (2 = usage ou dependance manquante)
#
# Tout acces cluster passe par scripts/kubectl-ro.sh (verbe get uniquement, identite agent-operator).
# Argo : Application gen-<app> (nom donne par l'ApplicationSet apps-generated). Smoke : GET du healthPath
# par le proxy de services de l'API Kubernetes (aucun port expose, aucune nouvelle ressource).
# Jamais de secret : seuls des champs de statut sont lus, le corps de la reponse du smoke est jete.
#
# Hooks de test (hors cluster) : APP_STATUS_KUBECTL (remplace "bash scripts/kubectl-ro.sh"),
# APP_STATUS_NOW (horodatage fixe), APP_STATUS_APP_YAML (chemin d'un app.yaml).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
REPO_URL=https://github.com/SmadjaPaul/kube-ops.git

usage() { echo "usage: app-status.sh <app> [--cluster homelab|oracle-a1] [--commit <sha>|main-head]" >&2; exit 2; }

app=""; cluster=homelab; commit_arg=main-head
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cluster) [ "$#" -ge 2 ] || usage; cluster=$2; shift 2 ;;
    --commit) [ "$#" -ge 2 ] || usage; commit_arg=$2; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "app-status: option inconnue '$1'" >&2; usage ;;
    *) [ -z "$app" ] || usage; app=$1; shift ;;
  esac
done
[ -n "$app" ] || usage
[[ "$app" =~ ^[a-z][a-z0-9-]{1,18}[a-z0-9]$ ]] || { echo "app-status: nom d'application invalide '$app'" >&2; exit 2; }
case "$cluster" in homelab|oracle-a1) ;; *) echo "app-status: cluster '$cluster' inconnu (homelab|oracle-a1)" >&2; exit 2 ;; esac
command -v jq >/dev/null || { echo "app-status: jq requis" >&2; exit 2; }

# shellcheck source=lib/output-mode.sh
source "$HERE/lib/output-mode.sh"

ns="svc-$app"
now=${APP_STATUS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/app-status.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- commit demande
commit=""
case "$commit_arg" in
  main-head)
    commit=${APP_STATUS_MAIN_HEAD:-$(git ls-remote "$REPO_URL" refs/heads/main 2>/dev/null | awk 'NR==1{print $1}')} ;;
  *)
    if [[ "$commit_arg" =~ ^[0-9a-f]{40}$ ]]; then commit=$commit_arg
    elif [[ "$commit_arg" =~ ^[0-9a-f]{7,39}$ ]]; then commit=$(git -C "$ROOT" rev-parse --verify --quiet "$commit_arg^{commit}" 2>/dev/null || true)
    else echo "app-status: --commit attend un SHA ou main-head" >&2; exit 2; fi ;;
esac
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || commit=""

# --- app.yaml au commit demande (sinon copie de travail) : healthPath, profil
yaml_rel="k8s/apps-generated/$app/app.yaml"
yaml_text=""
if [ -n "${APP_STATUS_APP_YAML:-}" ]; then
  yaml_text=$(cat "$APP_STATUS_APP_YAML" 2>/dev/null || true)
else
  [ -z "$commit" ] || yaml_text=$(git -C "$ROOT" show "$commit:$yaml_rel" 2>/dev/null || true)
  [ -n "$yaml_text" ] || yaml_text=$(cat "$ROOT/$yaml_rel" 2>/dev/null || true)
fi
yaml_field() { # yaml_field PARENT KEY : champ de 2e/3e niveau du format genere (app.yaml deterministe)
  awk -v p="$1" -v k="$2" '
    $0 ~ "^  " p ":" {in_p=1; next}
    in_p && /^  [A-Za-z]/ {in_p=0}
    in_p && $0 ~ "^    " k ":" {v=$0; sub("^    " k ":[ ]*", "", v); gsub(/^"|"$/, "", v); print v; exit}' <<<"$yaml_text"
}
health_path=$(yaml_field runtime healthPath)
backup_policy=$(yaml_field backup policy)

# --- acces cluster (lecture seule)
read -r -a KRO <<<"${APP_STATUS_KUBECTL:-bash $HERE/kubectl-ro.sh}"
kro() { "${KRO[@]}" --cluster "$cluster" "$@"; }

cluster_error=""
argo_json=""; argo_name=""
for cand in "gen-$app" "$app" "apps-$app"; do
  if out=$(kro get application.argoproj.io "$cand" -n argocd -o json 2>"$tmp/err"); then
    argo_json=$out; argo_name=$cand; break
  fi
  if grep -q 'NotFound' "$tmp/err"; then continue; fi
  cluster_error=$(head -n 3 "$tmp/err" | tr '\n' ' ' | sanitize_line); [ -n "$cluster_error" ] || cluster_error="kubectl-ro indisponible"
  break
done

objs='{"items":[]}'
if [ -z "$cluster_error" ] && [ -n "$argo_json" ]; then
  if out=$(kro get deployments,pods,services -n "$ns" -o json 2>"$tmp/err"); then objs=$out
  else cluster_error=$(head -n 3 "$tmp/err" | tr '\n' ' ' | sanitize_line); [ -n "$cluster_error" ] || cluster_error="lecture de $ns impossible"; fi
fi

# --- extraction
argo_sync=NotFound; argo_health=NotFound; argo_phase=NotFound; argo_msg=""; synced_rev=""; rev_mismatch=0
[ -z "$cluster_error" ] || { argo_sync=Unknown; argo_health=Unknown; argo_phase=None; }
if [ -n "$argo_json" ]; then
  argo_sync=$(jq -r '.status.sync.status // "Unknown"' <<<"$argo_json")
  argo_health=$(jq -r '.status.health.status // "Unknown"' <<<"$argo_json")
  argo_phase=$(jq -r '.status.operationState.phase // "None"' <<<"$argo_json")
  argo_msg=$(jq -r '.status.operationState.message // ""' <<<"$argo_json" | sanitize_line)
  synced_rev=$(jq -r '[(.status.sync.revisions // [.status.sync.revision])[] | select(. != null and . != "")] | .[0] // ""' <<<"$argo_json")
  # toutes les sources (chart + values) doivent etre a la revision demandee
  if [ -n "$commit" ]; then
    rev_mismatch=$(jq -r --arg c "$commit" '[(.status.sync.revisions // [.status.sync.revision])[] | select(. != null and . != "")] | (length == 0) or any(. != $c)' <<<"$argo_json")
    [ "$rev_mismatch" = true ] && rev_mismatch=1 || rev_mismatch=0
  fi
fi
[[ "$synced_rev" =~ ^[0-9a-f]{40}$ ]] || synced_rev=""

workloads=$(jq --arg ns "$ns" '{
  namespace:$ns,
  deployments:[.items[] | select(.kind=="Deployment") | {name:.metadata.name, desired:(.spec.replicas // 1), ready:(.status.readyReplicas // 0)}],
  pods:{
    ready:([.items[] | select(.kind=="Pod" and .status.phase!="Succeeded") | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length),
    total:([.items[] | select(.kind=="Pod" and .status.phase!="Succeeded")] | length)}}' <<<"$objs")
pods_ready=$(jq -r '.pods.ready' <<<"$workloads")
not_ready=$(jq -r '[.deployments[] | select(.ready < .desired) | "\(.name) \(.ready)/\(.desired)"] | join(", ")' <<<"$workloads")
n_deploy=$(jq -r '.deployments | length' <<<"$workloads")

svc_port=$(jq -r --arg a "$app" '[.items[] | select(.kind=="Service" and .metadata.name==$a) | (.spec.ports[] | select(.name=="http") | .port)] | .[0] // empty' <<<"$objs")
if [ -z "$health_path" ]; then
  health_path=$(jq -r '[.items[] | select(.kind=="Deployment") | .spec.template.spec.containers[0].readinessProbe.httpGet.path] | .[0] // empty' <<<"$objs")
fi

# --- smoke : GET healthPath par le proxy API (lecture seule)
smoke_name=http-health; smoke_target="$app:${svc_port:-?}${health_path:-}"; smoke_result=not_run; smoke_evidence=""
if [ -n "$cluster_error" ]; then
  smoke_evidence="cluster illisible"
elif [ -z "$argo_json" ]; then
  smoke_evidence="Application Argo absente : rien a sonder"
elif [ -z "$health_path" ] || [ -z "$svc_port" ]; then
  smoke_evidence="healthPath ou Service introuvable (app.yaml absent au commit et pas de sonde Deployment)"
elif [ "$pods_ready" -lt 1 ]; then
  smoke_evidence="aucun pod pret dans $ns"
else
  path="/api/v1/namespaces/$ns/services/$app:$svc_port/proxy$health_path"
  if kro get --raw "$path" >"$tmp/body" 2>"$tmp/err"; then
    smoke_result=pass
    smoke_evidence="GET $health_path via proxy API Kubernetes : reponse 2xx ($(wc -c <"$tmp/body" | tr -d ' ') octets, corps non conserve)"
  else
    line=$(head -n 3 "$tmp/err" | tr '\n' ' ' | sanitize_line)
    if grep -qiE 'forbidden|refus' "$tmp/err"; then
      smoke_result=unavailable
      smoke_evidence="acces au proxy de $ns refuse (RBAC de l'identite de lecture ou filtre kubectl-ro) : $line"
    else
      smoke_result=fail
      smoke_evidence="GET $health_path via proxy : ${line:-echec}"
    fi
  fi
fi

# --- checks optionnels : stateless => not_applicable
if [ "$backup_policy" = stateless ]; then
  checks=$(jq -n '[("db","backup","restore") | {name:., result:"not_applicable", evidence:"profil web stateless (backup.policy: stateless)"}]')
else
  checks='[]'
fi

# --- statut final
status=PASS; reason=""; level=RUNTIME
set_status() { status=$1; reason=$2; }
short() { printf '%s' "${1:0:7}"; }
if [ -n "$cluster_error" ]; then
  set_status UNKNOWN "cluster illisible ($cluster/kubectl-ro) : $cluster_error"; level=STATIC
elif [ -z "$commit" ]; then
  set_status UNKNOWN "commit demande non resolu (git ls-remote ou --commit invalide)"
elif [ -z "$argo_json" ]; then
  if [ -n "$yaml_text" ]; then
    set_status PENDING "Application gen-$app absente : app.yaml present au commit $(short "$commit"), ApplicationSet pas encore reconciliee"
  else
    set_status FAIL "Application gen-$app absente et $yaml_rel absent au commit $(short "$commit")"
  fi
elif [ "$argo_phase" = Failed ] || [ "$argo_phase" = Error ]; then
  set_status FAIL "operation Argo $argo_phase : ${argo_msg:-sans message}"
elif [ "$rev_mismatch" = 1 ]; then
  if [ -n "$synced_rev" ]; then set_status PENDING "Argo a synchronise $(short "$synced_rev"), commit demande $(short "$commit")"
  else set_status PENDING "Argo n'a synchronise aucune revision, commit demande $(short "$commit")"; fi
elif [ "$argo_sync" != Synced ]; then
  if [ "$argo_phase" = Running ] || [ "$argo_health" = Progressing ]; then set_status PENDING "Argo $argo_sync, synchronisation en cours"
  else set_status FAIL "Argo $argo_sync ($argo_health, operation $argo_phase)"; fi
elif [ "$argo_health" = Progressing ]; then
  set_status PENDING "Argo Progressing : ${not_ready:-workloads en cours de demarrage}"
elif [ "$argo_health" != Healthy ]; then
  set_status FAIL "Argo health $argo_health"
elif [ "$n_deploy" -eq 0 ]; then
  set_status FAIL "aucun Deployment dans $ns"
elif [ -n "$not_ready" ]; then
  set_status FAIL "Deployment non pret : $not_ready"
elif [ "$smoke_result" = fail ]; then
  set_status FAIL "smoke KO : $smoke_evidence"
elif [ "$smoke_result" != pass ]; then
  set_status UNKNOWN "smoke non execute ($smoke_result) : $smoke_evidence"
fi

jq -n \
  --arg app "$app" --arg cluster "$cluster" --arg commit "$commit" --arg rev "$synced_rev" \
  --arg argoApp "$argo_name" --arg sync "$argo_sync" --arg health "$argo_health" --arg phase "$argo_phase" \
  --argjson workloads "$workloads" \
  --arg sname "$smoke_name" --arg starget "$smoke_target" --arg sresult "$smoke_result" --arg sev "$smoke_evidence" \
  --argjson checks "$checks" --arg status "$status" --arg reason "$reason" --arg level "$level" --arg ts "$now" '
  {schemaVersion:"app-status.v1", app:$app, cluster:$cluster,
   requested:{commit:(if $commit=="" then null else $commit end)},
   synced:{revision:(if $rev=="" then null else $rev end)},
   argo:{application:(if $argoApp=="" then null else $argoApp end), sync:$sync, health:$health, operationPhase:$phase},
   workloads:$workloads,
   smoke:{name:$sname, target:$starget, result:$sresult, evidence:$sev},
   checks:$checks, status:$status}
  + (if $reason=="" then {} else {reason:$reason} end)
  + {evidenceLevel:$level, timestamp:$ts}'

case "$status" in PASS) exit 0 ;; FAIL) exit 1 ;; PENDING) exit 3 ;; *) exit 4 ;; esac
