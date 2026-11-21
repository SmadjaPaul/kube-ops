#!/usr/bin/env bash
# app-test : le test d'une application sur les 7 golden paths (PLT-390).
#
#   scripts/app-test.sh APP NAMESPACE [--phase static|runtime|all] [--cluster homelab|oracle-a1]
#                       [--chaos] [--app-dir DIR]
#   just app-test APP NAMESPACE [--phase ...] [--cluster ...]
#
# Sortie (interface figee, appelee par le lot 2 preview et le lot 3 post-merge) :
#   CHECK <id> PASS|FAIL|SKIP|BLOCKED <raison courte>     une ligne par verification
#   DEPLOY_HEALTH=PASS|FAIL|UNKNOWN                      seulement si le runtime a tourne (--phase runtime|all)
#   APP_TEST=PASS|FAIL|BLOCKED
# DEPLOY_HEALTH : sante du deploiement lui-meme (pods Ready, pas de restarts recents), lue sur le check
# selfheal runtime, etat brut (ni exception ni cliquet). FAIL = pods non Ready ou restarts recents ; PASS = pods
# Ready ; UNKNOWN sinon (aucun pod, scale a zero, BLOCKED). Signal machine du post-merge (revert seulement sur FAIL).
# Code : 0 PASS, 1 FAIL, 2 BLOCKED (acces cluster, outil manquant, rendu impossible).
#
# Ids : oidc exposure backup renovate observability selfheal network.
# Avec --phase all, une ligne par id : statut agrege (FAIL > BLOCKED > PASS > SKIP), raison
# prefixee s: (static) / r: (runtime). Une ligne `CHECK exceptions FAIL` s'ajoute seulement si
# app-test.yaml est invalide.
#
# static  : rendu `kustomize build --enable-helm` de k8s/applications/**/APP (render-cache),
#           aucun acces cluster. L'app est jugee sur ce qu'elle declare (NAMESPACE non utilise).
# runtime : lecture seule via scripts/kubectl-ro.sh. --chaos supprime UN pod via
#           scripts/kubectl-rw.sh, uniquement si NAMESPACE = pr-* (jamais en prod).
#
# Portee runtime : l'app, pas le namespace. Les routes, services, workloads/pods, PVC et clusters CNPG
# sont ceux du rendu de l'app (un namespace partage comme media est le cas normal). Cliquet : un FAIL
# deja gele pour cette app dans policy/app-test-baseline.tsv devient PASS "baselined" (--no-ratchet
# l'ignore) ; seule une regression echoue.
#
# Exceptions : fichier optionnel `app-test.yaml` dans le dossier de l'app (format minimal) :
#     auth: none | oidc      # none = pas d'auth devant la route externe ; oidc = OIDC natif declare
#     backup: none           # rien a sauvegarder (sans etat)
#     auth_probe: /api/x     # chemin protege sonde sans cookie quand l'auth est native (/ sert 200 sinon)
#     admin: true            # le hostname ne doit jamais etre expose publiquement
#     exceptions:            # une raison NON VIDE est obligatoire pour chaque cle
#       auth: "..."          # exige par `auth: none`
#       backup: "..."        # exige par `backup: none`
#       exposure|renovate|observability|selfheal|network|rootfs: "..."
# Une exception sans raison est un FAIL.
#
# Variables : APP_TEST_ROOT (racine du depot, tests hors ligne), APP_TEST_RESTART_MAX (3),
# APP_TEST_BACKUP_MAX_AGE_H (26), APP_TEST_PUBLIC_PROBE (commande de test : prend un hostname,
# affiche "CODE LOCATION" ou "nodns"), KUBECTL_RO_SCRIPT / KUBECTL_RW_SCRIPT (wrappers factices).
set -o pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${APP_TEST_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
cd "$ROOT" || exit 2

usage() { echo "usage: app-test.sh APP NAMESPACE [--phase static|runtime|all] [--cluster homelab|oracle-a1] [--chaos] [--no-ratchet] [--app-dir DIR]" >&2; exit 2; }
blocked_all() { echo "CHECK setup BLOCKED $1"; echo "APP_TEST=BLOCKED"; exit 2; }

[[ $# -ge 2 ]] || usage
APP=$1; NS=$2; shift 2
PHASE=all; CLUSTER=homelab; CHAOS=no; APP_DIR=""; RATCHET=yes
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) [[ $# -ge 2 ]] || usage; PHASE=$2; shift 2 ;;
    --cluster) [[ $# -ge 2 ]] || usage; CLUSTER=$2; shift 2 ;;
    --chaos) CHAOS=yes; shift ;;
    --no-ratchet) RATCHET=no; shift ;;
    --app-dir) [[ $# -ge 2 ]] || usage; APP_DIR=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$PHASE" in static|runtime|all) ;; *) usage ;; esac
case "$CLUSTER" in homelab|oracle-a1) ;; *) usage ;; esac
# Ces valeurs entrent dans PromQL et dans des chemins : on les restreint.
[[ $APP =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "ERROR: APP doit etre un nom DNS-1123" >&2; exit 2; }
[[ $NS =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "ERROR: NAMESPACE doit etre un nom DNS-1123" >&2; exit 2; }
for cmd in jq yq; do command -v "$cmd" >/dev/null || blocked_all "outil manquant: $cmd"; done

work="$(mktemp -d "${TMPDIR:-/tmp}/app-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
RES="$work/results.tsv"; : >"$RES"
# Cliquet (policy/app-test-baseline.tsv) : un FAIL deja gele pour cette app/id devient PASS "baselined" ;
# seule une regression echoue. --no-ratchet montre la dette brute.
BASELINE_FILE=policy/app-test-baseline.tsv
res() { # res ID PHASE STATUS REASON
  local st=$3 rs=$4
  if [[ $st == FAIL && $RATCHET == yes && -f $BASELINE_FILE ]] && grep -qxF "$APP"$'\t'"$1"$'\tFAIL' "$BASELINE_FILE"; then
    st=PASS; rs="baselined (dette gelee): $rs"
  fi
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$st" "$rs" >>"$RES"
}
IDS="oidc exposure backup renovate observability selfheal network"

# ------------------------------------------------------------------ localisation de l'app
if [[ -z $APP_DIR ]]; then
  found=()
  while IFS= read -r d; do [[ -n $d ]] && found+=("$d"); done < <(find k8s/applications -mindepth 2 -maxdepth 3 -type d -name "$APP" 2>/dev/null | sort)
  ((${#found[@]} == 1)) || blocked_all "dossier de l'app introuvable ou ambigu sous k8s/applications (${#found[@]} trouve(s)); utiliser --app-dir"
  APP_DIR=${found[0]}
fi
[[ -f $APP_DIR/kustomization.yaml || -f $APP_DIR/kustomization.yml ]] || blocked_all "pas de kustomization dans $APP_DIR"

# ------------------------------------------------------------------ exceptions
EXC="$work/exc.json"
if [[ -f $APP_DIR/app-test.yaml ]]; then
  yq -o=json '.' "$APP_DIR/app-test.yaml" >"$EXC" 2>/dev/null || blocked_all "app-test.yaml illisible"
  jq -e 'type=="object"' "$EXC" >/dev/null 2>&1 || echo '{}' >"$EXC"
else
  echo '{}' >"$EXC"
fi
exc_problems="$(jq -r '
  (keys - ["auth","auth_probe","backup","admin","exceptions"] | map("cle inconnue: \(.)")[]),
  (if has("auth_probe") and ((.auth_probe|type) != "string" or (.auth_probe|test("^/[A-Za-z0-9._~/-]*$")|not)) then "auth_probe doit etre un chemin simple /..." else empty end),
  (if has("auth") and (.auth|IN("none","oidc")|not) then "auth doit valoir none|oidc" else empty end),
  (if has("backup") and .backup != "none" then "backup doit valoir none" else empty end),
  ((.exceptions // {}) | to_entries[]
    | select(.key | IN("auth","backup","exposure","renovate","observability","selfheal","network","rootfs") | not)
    | "exception inconnue: \(.key)"),
  ((.exceptions // {}) | to_entries[] | select((.value|type) != "string" or (.value|gsub("\\s";"")|length) == 0)
    | "exception \(.key) sans raison"),
  (if .auth == "none" and (((.exceptions // {}).auth // "")|gsub("\\s";"")|length) == 0 then "auth: none sans raison (exceptions.auth)" else empty end),
  (if .backup == "none" and (((.exceptions // {}).backup // "")|gsub("\\s";"")|length) == 0 then "backup: none sans raison (exceptions.backup)" else empty end)
' "$EXC" 2>/dev/null)"

# raison d'une exception generique (exceptions.<id>), vide si absente
exc_reason() { jq -r --arg k "$1" '((.exceptions // {})[$k] // "") | gsub("^\\s+|\\s+$";"") | .[0:70]' "$EXC"; }

# ------------------------------------------------------------------ prelude jq partage
read -r -d '' PRE <<'JQ' || true
def podspec: if .kind=="CronJob" then .spec.jobTemplate.spec.template.spec elif .kind=="Pod" then .spec else .spec.template.spec end;
def tmpl: if .kind=="CronJob" then .spec.jobTemplate.spec.template elif .kind=="Pod" then . else .spec.template end;
def isworkload: .kind|IN("Deployment","StatefulSet","DaemonSet","CronJob","Job");
def islong: .kind|IN("Deployment","StatefulSet","DaemonSet");
def wid: "\(.kind)/\(.metadata.name)";
def wls: [.[] | select(isworkload)];
def cs: (podspec.containers // []);
def allcs: ((podspec.containers // []) + (podspec.initContainers // []));
def wns: (.metadata.namespace // $ns);
def clip: if length > 55 then .[0:52] + "..." else . end;
def selmatch($labels): ((.matchLabels // {}) | to_entries | all($labels[.key] == .value));
JQ

# ------------------------------------------------------------------ phase statique : rendu
DOCS="$work/docs.json"; CTX="$work/ctx.json"
render_dir() { # render_dir DIR : tableau JSON des objets rendus sur stdout
  local d=$1 f
  if [[ -z ${APP_TEST_ROOT:-} && -f $SELF_DIR/lib/render-cache.sh ]]; then
    f="$(bash "$SELF_DIR/lib/render-cache.sh" render "$d" 2>"$work/render.err")" || return 1
  else
    f="$work/render.$RANDOM.yaml"
    kustomize build --enable-helm "$d" >"$f" 2>"$work/render.err" || return 1
  fi
  yq eval-all -o=json -I=0 '.' "$f" 2>>"$work/render.err" | jq -s 'map(select(type=="object"))'
}

static_ready=no
# Le rendu sert aux deux phases : la phase runtime en tire la PORTEE de l'app (ses routes, workloads,
# services, PVC, clusters CNPG), car un namespace partage (media, catalog...) heberge plusieurs apps.
if true; then
  if ! command -v kustomize >/dev/null; then
    [[ $PHASE == runtime ]] || for id in $IDS; do res "$id" static BLOCKED "outil manquant: kustomize"; done
  elif ! render_dir "$APP_DIR" >"$DOCS" || ! jq -e 'length > 0' "$DOCS" >/dev/null 2>&1; then
    msg="$(tail -1 "$work/render.err" 2>/dev/null | tr -d '\n' | cut -c1-100)"
    scope_err="rendu kustomize impossible: ${msg:-vide}"
    [[ $PHASE == runtime ]] || for id in $IDS; do res "$id" static BLOCKED "$scope_err"; done
  else
    static_ready=yes
    parts=("$DOCS")
    for d in k8s/infrastructure/controllers/velero/schedules k8s/infrastructure/network/policies; do
      [[ -f $d/kustomization.yaml ]] || continue
      if render_dir "$d" >"$work/ctx.$(basename "$d").json" 2>/dev/null; then parts+=("$work/ctx.$(basename "$d").json"); fi
    done
    jq -s 'add | map(select(.kind|IN("Schedule","ScheduledBackup","CiliumNetworkPolicy","NetworkPolicy","SecurityPolicy")))' "${parts[@]}" >"$CTX"
  fi
fi

scope_ready=$static_ready
[[ $PHASE == runtime ]] && static_ready=no

# static_run ID PASS_NOTE JQPROG : chaque ligne produite est un probleme, sauf SKIP:<raison>.
# Un FAIL devient SKIP si exceptions.<ID> porte une raison. EXTRA (fichier) ajoute des problemes.
static_run() {
  local id=$1 note=$2 prog=$3 out line skip="" s n
  [[ $static_ready == yes ]] || return 0
  if ! out="$(jq -r --arg ns "$NS" --arg generic "$GENERIC_ALERTS" --slurpfile exc "$EXC" --slurpfile ctx "$CTX" "$PRE
$prog" "$DOCS" 2>"$work/jq.err")"; then
    res "$id" static BLOCKED "erreur jq: $(head -1 "$work/jq.err" | cut -c1-90)"; return 0
  fi
  [[ -f $work/extra.$id ]] && out="$out"$'\n'"$(cat "$work/extra.$id")"
  local probs=()
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    case "$line" in SKIP:*) skip=${line#SKIP:} ;; *) probs+=("$line") ;; esac
  done <<<"$out"
  n=${#probs[@]}
  if ((n > 0)); then
    s="$(printf '%s; ' "${probs[@]:0:3}")"; s=${s%; }; ((n > 3)) && s="$s (+$((n - 3)))"
    local er; er="$(exc_reason "$id")"
    if [[ -n $er ]]; then res "$id" static SKIP "exception $id: $er"; else res "$id" static FAIL "$s"; fi
  elif [[ -n $skip ]]; then res "$id" static SKIP "$skip"
  else res "$id" static PASS "$note"; fi
}

# couverture d'alerte generique : alertes kube-prometheus-stack (KubePodCrashLooping, KubePodNotReady)
GENERIC_ALERTS=no
vals=k8s/infrastructure/monitoring/prometheus-stack/values.yaml
if [[ -f $vals ]] && ! yq -e '.defaultRules.create == false or .defaultRules.rules.kubernetesApps == false' "$vals" >/dev/null 2>&1; then GENERIC_ALERTS=yes; fi

if [[ $static_ready == yes ]]; then

# 1. oidc -----------------------------------------------------------------------------------
static_run oidc "auth native OIDC ou forward-auth declaree" '
  ([ .[] | select(.kind=="HTTPRoute" and any(.spec.parentRefs[]?; .name=="external")) ]) as $ext
  | if ($ext|length) == 0 then "SKIP:aucune HTTPRoute sur la gateway external"
    elif $exc[0].auth == "none" then
      (if ((($exc[0].exceptions // {}).auth // "") | gsub("\\s";"") | length) > 0
       then "SKIP:exception auth none: \(($exc[0].exceptions.auth) | .[0:60])"
       else "exception auth: none sans raison" end)
    else
      ( [ wls[] | cs[] | ((.env // [])[] | "\(.name) \(.value // "")"), ((.args // [])[]), ((.command // [])[]) ]
        | any(test("OIDC|OPENID|OAUTH|authentik|auth\\.smadja\\.dev"; "i")) ) as $native
      | ($exc[0].auth == "oidc") as $declared
      | $ext[] as $r
      | ( any($r.spec.rules[]?.filters[]?; .type == "ExtensionRef")
          or (($r.metadata.annotations // {}) | has("auth.smadja.dev/forward-auth"))
          or any($ctx[0][]?; .kind == "SecurityPolicy" and any(.spec.targetRefs[]?; .name == $r.metadata.name)) ) as $fwd
      | if $native or $declared or $fwd then empty
        else "HTTPRoute/\($r.metadata.name) sur external sans auth (forward-auth, OIDC natif ou auth: none + raison)" end
    end'

# 2. exposure -------------------------------------------------------------------------------
static_run exposure "routes admin internes, aucun LB/NodePort/Ingress" '
  ([ .[] | select(.kind=="Service" and (.spec.type | IN("LoadBalancer","NodePort"))) | "Service/\(.metadata.name) de type \(.spec.type)" ][]),
  ([ .[] | select(.kind=="Ingress") | "Ingress/\(.metadata.name) (classe \(.spec.ingressClassName // "defaut")): seul Gateway API est prevu" ][]),
  (if $exc[0].admin == true then
     [ .[] | select(.kind=="HTTPRoute" and any(.spec.parentRefs[]?; .name=="external")) | "route admin HTTPRoute/\(.metadata.name) sur la gateway external (doit etre internal)" ][]
   else empty end)'

# 3. backup ---------------------------------------------------------------------------------
static_run backup "chaque PVC / Cluster CNPG a une couverture Velero, Longhorn ou Barman" '
  . as $docs
  | if $exc[0].backup == "none" then
      (if ((($exc[0].exceptions // {}).backup // "") | gsub("\\s";"") | length) > 0
       then "SKIP:exception backup none: \(($exc[0].exceptions.backup) | .[0:60])"
       else "exception backup: none sans raison" end)
    else
      ( [ .[] | select(.kind=="PersistentVolumeClaim") | {ns:wns, name:.metadata.name, labels:(.metadata.labels // {})} ]
        + [ .[] | select(.kind=="StatefulSet") | . as $s | (.spec.volumeClaimTemplates // [])[]
            | {ns:($s|wns), name:"\(.metadata.name)@\($s.metadata.name)", labels:(.metadata.labels // {})} ] ) as $pvcs
      | ([ .[] | select(.kind=="Cluster" and ((.apiVersion // "")|startswith("postgresql.cnpg.io"))) | {ns:wns, name:.metadata.name} ]) as $cnpg
      | if ($pvcs|length) == 0 and ($cnpg|length) == 0 then "SKIP:aucun PVC ni Cluster CNPG (sans etat)"
        else
          ( $pvcs[]
            | . as $p
            | select(($p.labels["backup.smadja.dev/strategy"] != "rebuildable") and ($p.labels["velero.io/exclude-from-backup"] != "true"))
            | select(($p.labels | keys | any(startswith("recurring-job"))) | not)
            | select(
                ([ $ctx[0][]? | select(.kind=="Schedule" and ((.apiVersion // "")|startswith("velero.io")))
                   | . as $s | ($s.spec.template // {}) as $t
                   | select((($t.includedNamespaces // []) | length) == 0 or (($t.includedNamespaces // []) | any(. == $p.ns or . == "*")))
                   | select((($t.excludedNamespaces // []) | any(. == $p.ns)) | not)
                   | select($t.defaultVolumesToFsBackup == true
                            or any($docs[]; isworkload and ((tmpl.metadata.annotations // {}) | has("backup.velero.io/backup-volumes"))))
                   | select(((($t.labelSelector // null) == null) and ((($t.orLabelSelectors // []) | length) == 0))
                            or any($docs[]; isworkload and (wns == $p.ns)
                                   and ((tmpl.metadata.labels // {}) as $l
                                        | ([($t.labelSelector // empty)] + ($t.orLabelSelectors // [])) | any(selmatch($l)))))
                 ] | length) == 0)
            | "PVC \($p.ns)/\($p.name | split("@")[0]) sans Schedule Velero ni RecurringJob (Schedule ou label backup.smadja.dev/strategy=rebuildable)" ),
          ( $cnpg[] | . as $c
            | select(([ $ctx[0][]? | select(.kind=="ScheduledBackup" and ((.metadata.namespace // $ns) == $c.ns) and .spec.cluster.name == $c.name) ] | length) == 0)
            | "Cluster CNPG \($c.ns)/\($c.name) sans ScheduledBackup" )
        end
    end'

# 4. renovate -------------------------------------------------------------------------------
# Detection : chaque image doit figurer dans un fichier couvert par un manager de renovate.json.
rm -f "$work/extra.renovate"
if [[ ! -f renovate.json ]]; then
  echo "renovate.json absent" >"$work/extra.renovate"
else
  has_helm=no
  ls "$APP_DIR"/kustomization.y*ml >/dev/null 2>&1 && grep -qE '^[[:space:]]*helmCharts:' "$APP_DIR"/kustomization.y*ml && has_helm=yes
  while IFS= read -r img; do
    [[ -z $img ]] && continue
    base="${img%%@*}"; base="${base%:*}"
    short="${base##*/}"
    files="$(grep -rlF --include='*.yaml' --include='*.yml' -- "$short" "$APP_DIR" 2>/dev/null | grep -v '/app-test.yaml$' || true)"
    if [[ -z $files ]]; then
      [[ $has_helm == yes ]] || echo "image $(printf '%s' "$base" | cut -c1-45) absente des fichiers de l'app (hors helmCharts)" >>"$work/extra.renovate"
      continue
    fi
    n="$(printf '%s\n' "$files" | jq -R -s --slurpfile r renovate.json '
      def rx: if (startswith("/") and endswith("/")) then .[1:-1]
              else gsub("\\.";"\\.") | gsub("\\*\\*/";"@@") | gsub("\\*";"[^/]*") | gsub("@@";"(.*/)?") | "^" + . + "$" end;
      split("\n") | map(select(length > 0)) as $fs
      | ([ ($r[0].kubernetes.managerFilePatterns // [])[], ($r[0].kustomize.managerFilePatterns // [])[], ($r[0]["helm-values"].managerFilePatterns // [])[] ] | map(rx)) as $pats
      | [ $fs[] | . as $f | select(any($pats[]; . as $p | $f | test($p))) ] | length')"
    [[ ${n:-0} -gt 0 ]] || echo "image $(printf '%s' "$base" | cut -c1-45) dans un fichier hors des managers de renovate.json" >>"$work/extra.renovate"
  done < <(jq -r --arg ns "$NS" "$PRE"' wls[] | allcs[] | .image' "$DOCS" | sort -u)
fi
static_run renovate "images epinglees par digest, fichiers suivis par Renovate" '
  [ wls[] | . as $w | allcs[] | select((.image // "") | test("@sha256:[a-f0-9]{64}") | not)
    | "\($w | wid): image \(.image | clip) sans digest @sha256" ][]'

# 5. observability ---------------------------------------------------------------------------
static_run observability "probes, monitor de scrape et regle d alerte presents" '
  . as $docs
  | ([ wls[] | select(islong) | . as $w | cs[] | . as $c
       | ([ (if $c.readinessProbe then empty else "readinessProbe" end), (if ($c.livenessProbe or $c.startupProbe) then empty else "livenessProbe" end) ][]) as $m
       | "\($w | wid)/\($c.name) sans \($m)" ][]),
    (if ([ $docs[] | select(.kind|IN("ServiceMonitor","PodMonitor","Probe")) ] | length) == 0
     then "aucun ServiceMonitor/PodMonitor/Probe (ou exception observability)" else empty end),
    (if ([ $docs[] | select(.kind=="PrometheusRule") ] | length) == 0 and $generic != "yes"
     then "aucune PrometheusRule et couverture generique absente" else empty end)'

# 6. selfheal --------------------------------------------------------------------------------
static_run selfheal "requests/limits, probes et PDB conformes" '
  . as $docs
  | ([ wls[] | . as $w | allcs[] | . as $c
       | ([ [ ["requests","cpu"], ["requests","memory"], ["limits","cpu"], ["limits","memory"] ][]
           | . as $p | select((($c.resources // {}) | getpath($p)) == null) | $p | join(".")] ) as $miss
       | select(($miss | length) > 0)
       | "\($w | wid)/\($c.name) sans resources.\($miss | join(","))" ][]),
    ([ wls[] | select(islong) | . as $w | cs[] | . as $c
       | select(($c.readinessProbe == null) or (($c.livenessProbe // $c.startupProbe) == null))
       | "\($w | wid)/\($c.name) sans probe readiness+liveness" ][]),
    ([ wls[] | select(.kind|IN("Deployment","StatefulSet")) | select((.spec.replicas // 1) > 1) | . as $w
       | select(([ $docs[] | select(.kind=="PodDisruptionBudget" and (wns == ($w|wns))
              and ((tmpl | .metadata.labels // {}) as $l | (.spec.selector // {}) | selmatch($l)))] | length) == 0)
       | "\($w | wid) replicas>1 sans PodDisruptionBudget" ][])'

# 7. network ---------------------------------------------------------------------------------
static_run network "NetworkPolicy deny par defaut et securityContext PSA restricted" '
  . as $docs
  | ([ wls[] | wns ] | unique) as $nss
  | ($nss[] | . as $n
     | select(([ ($docs + $ctx[0])[] | select(.kind|IN("CiliumNetworkPolicy","NetworkPolicy")) | select((.metadata.namespace // $ns) == $n)
                 | select((.spec.ingress // .spec.egress // .spec.ingressDeny // .spec.egressDeny // .spec.policyTypes) != null) ] | length) == 0)
     | "namespace \(.) sans CiliumNetworkPolicy/NetworkPolicy"),
    ([ wls[] | . as $w | podspec as $ps | allcs[] | . as $c | ($c.securityContext // {}) as $sc | ($ps.securityContext // {}) as $psc
       | ([ (if ($sc.runAsNonRoot // $psc.runAsNonRoot) == true or (($sc.runAsUser // $psc.runAsUser // 0) > 0) then empty else "runAsNonRoot" end),
            (if $sc.allowPrivilegeEscalation == false then empty else "allowPrivilegeEscalation=false" end),
            (if (($sc.capabilities.drop // []) | map(ascii_upcase) | index("ALL")) != null then empty else "drop ALL" end),
            (if (($sc.seccompProfile // $psc.seccompProfile).type // "") | IN("RuntimeDefault","Localhost") then empty else "seccomp" end),
            (if $sc.privileged == true then "privileged" else empty end),
            (if ($exc[0].exceptions // {} | has("rootfs")) or $sc.readOnlyRootFilesystem == true then empty else "readOnlyRootFilesystem" end)
          ] | join(",")) as $miss
       | select($miss != "")
       | "\($w | wid)/\($c.name) securityContext: \($miss)" ][])'
fi # static_ready

# ------------------------------------------------------------------ phase runtime
if [[ $PHASE != static ]]; then
  # shellcheck source=lib/kube-read.sh
  source "$SELF_DIR/lib/kube-read.sh"
  # shellcheck source=lib/output-mode.sh
  source "$SELF_DIR/lib/output-mode.sh"
  export KUBECTL_RO_CLUSTER="$CLUSTER"
  kro_session_begin "$work"
  max_age_h="${APP_TEST_BACKUP_MAX_AGE_H:-26}"
  restart_max="${APP_TEST_RESTART_MAX:-3}"

  rr() { res "$1" runtime "$2" "$3"; } # rr ID STATUS RAISON ; FAIL -> SKIP si exceptions.<ID>
  rr_fail() { local er; er="$(exc_reason "$1")"; if [[ -n $er ]]; then rr "$1" SKIP "exception $1: $er"; else rr "$1" FAIL "$2"; fi; }
  kget() { kro get "$@" -o json 2>"$work/kget.err"; } # kget KIND... -n NS
  kerr() { head -c 300 "$work/kget.err" | grep -v '^KUBE_ACCESS' | tr '\r\n' '  ' | sanitize_line; }
  is_pr_ns() { [[ $NS == pr-* ]]; }

  # Sonde HTTP publique. La resolution passe par DNS-over-HTTPS (Cloudflare) : le LAN intercepte le
  # DNS UDP (split-DNS UniFi) et renverrait le VIP interne, donc le chemin public ne serait pas teste.
  public_probe() { # public_probe HOST [PATH] -> "CODE LOCATION" | nodns
    if [[ -n ${APP_TEST_PUBLIC_PROBE:-} ]]; then "$APP_TEST_PUBLIC_PROBE" "$@"; return; fi
    local ip
    ip="$(curl -sS --max-time 8 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null \
      | jq -r '[.Answer[]? | select(.type == 1) | .data][0] // empty' 2>/dev/null)"
    [[ -n $ip ]] || { echo nodns; return; }
    curl -sS -o /dev/null --max-time 10 --resolve "$1:443:$ip" -w '%{http_code} %{redirect_url}' "https://$1${2:-/}" 2>/dev/null || echo "000 curl-error"
  }
  PROBE_OK=yes
  command -v curl >/dev/null || PROBE_OK=no

  ns_state=ok
  if ! kget namespace "$NS" >"$work/ns.json"; then
    if grep -q "NotFound" "$work/kget.err"; then ns_state=absent; else ns_state=blocked; fi
  fi
  if [[ $ns_state == blocked ]]; then
    for id in $IDS; do rr "$id" BLOCKED "acces cluster impossible: $(kerr)"; done
  elif [[ $ns_state == absent ]]; then
    for id in $IDS; do rr "$id" FAIL "namespace $NS absent du cluster $CLUSTER"; done
  elif [[ $scope_ready != yes ]]; then
    for id in $IDS; do rr "$id" BLOCKED "portee de l'app indisponible: $scope_err"; done
  else
    # PORTEE de l'app (namespace partage = cas normal) : tout ce qui est lu est filtre sur les
    # ressources rendues de l'app (noms de routes/services/clusters, selectors des workloads).
    jq --arg ns "$NS" --slurpfile ctx "$CTX" "$PRE"'
      . as $d
      | ([ wls[] | select(islong) | (tmpl.metadata.labels // {}) ]) as $wl
      | {routes: [ .[] | select(.kind=="HTTPRoute") | .metadata.name ],
         svcs: [ .[] | select(.kind=="Service") | .metadata.name ],
         wls: [ .[] | select(islong) | {name: .metadata.name, sel: (.spec.selector.matchLabels // {})} ],
         cnpg: [ .[] | select(.kind=="Cluster" and ((.apiVersion // "")|startswith("postgresql.cnpg.io"))) | .metadata.name ],
         npvc: (([ .[] | select(.kind=="PersistentVolumeClaim") ] | length) + ([ .[] | select(.kind=="StatefulSet") | (.spec.volumeClaimTemplates // [])[] ] | length)),
         ownns: any(.[]; .kind=="Namespace"),
         scheds: [ $ctx[0][] | select(.kind=="Schedule" and ((.apiVersion // "")|startswith("velero.io")))
                   | . as $s | ($s.spec.template // {}) as $t
                   | select((($t.excludedNamespaces // []) | any(. == $ns)) | not)
                   | select(((($t.labelSelector // null) == null) and ((($t.orLabelSelectors // []) | length) == 0))
                            or any($wl[]; . as $l | ([($t.labelSelector // empty)] + ($t.orLabelSelectors // [])) | any(selmatch($l))))
                   | select((($t.includedNamespaces // []) | length) == 0 or (($t.includedNamespaces // []) | any(. == "*" or . == ($d | map(select(islong)) | .[0].metadata.namespace // $ns))))
                   | .metadata.name ]}' "$DOCS" >"$work/scope.json"
    # pods de l'app (ni Succeeded, ni Failed/Evicted, ni en suppression: PLT-398) : proprietaire = workload de l'app (ou Cluster CNPG de l'app) et selector satisfait
    scope_pods() { # scope_pods FILE -> {"items":[pods de l app non Succeeded]}
      jq --slurpfile sc "$work/scope.json" '{items: [ .items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed" and (.metadata.deletionTimestamp | not)) | . as $p
        | select( any($sc[0].wls[]; . as $w
                      | ($p.metadata.ownerReferences // [] | any(.name == $w.name or (.name | startswith($w.name + "-"))))
                      and ($w.sel | to_entries | all($p.metadata.labels[.key] == .value)))
                  or any(($p.metadata.ownerReferences // [])[]; .kind == "Cluster" and (.name | IN($sc[0].cnpg[]))) ) ]}' "$1"
    }
    if kget pods -n "$NS" >"$work/pods-all.json"; then scope_pods "$work/pods-all.json" >"$work/pods.json"
    else rr selfheal BLOCKED "lecture pods impossible: $(kerr)"; echo '{"items":[]}' >"$work/pods.json"; fi
    kget services -n "$NS" >"$work/svc-all.json" || echo '{"items":[]}' >"$work/svc-all.json"
    jq --slurpfile sc "$work/scope.json" '{items: [ .items[] | select(.metadata.name | IN($sc[0].svcs[])) ]}' "$work/svc-all.json" >"$work/svc.json"
    kget httproutes.gateway.networking.k8s.io -n "$NS" >"$work/routes-all.json" 2>/dev/null || echo '{"items":[]}' >"$work/routes-all.json"
    jq --slurpfile sc "$work/scope.json" '{items: [ .items[] | select(.metadata.name | IN($sc[0].routes[])) ]}' "$work/routes-all.json" >"$work/routes.json"

    ext_hosts="$(jq -r '.items[] | select(any(.spec.parentRefs[]?; .name=="external")) | .spec.hostnames[]?' "$work/routes.json" | sort -u)"
    all_hosts="$(jq -r '.items[] | .spec.hostnames[]?' "$work/routes.json" | sort -u)"
    auth_mode="$(jq -r '.auth // ""' "$EXC")"
    auth_probe="$(jq -r '.auth_probe // "/"' "$EXC")"

    # 1. oidc
    if [[ -z $ext_hosts ]]; then rr oidc SKIP "aucune route externe parmi les routes de l'app"
    elif [[ $auth_mode == none ]]; then rr oidc SKIP "exception auth none: $(exc_reason auth)"
    elif [[ $PROBE_OK == no ]]; then rr oidc BLOCKED "curl absent: sonde publique impossible"
    else
      bad=(); okn=0; unk=()
      for h in $ext_hosts; do
        out="$(public_probe "$h" "$auth_probe")"; code="${out%% *}"; loc="${out#* }"
        case "$code" in
          301|302|303|307|308) if [[ $loc == *authentik* || $loc == *auth.smadja.dev* || $loc == *"/application/o/"* ]]; then okn=$((okn + 1)); else bad+=("$h $code vers $(printf '%s' "$loc" | cut -c1-40)"); fi ;;
          401|403) okn=$((okn + 1)) ;;
          200|204) bad+=("$h${auth_probe} repond $code sans cookie$([[ $auth_probe == / && $auth_mode == oidc ]] && echo ' (OIDC natif: declarer auth_probe)')") ;;
          nodns) unk+=("$h sans DNS public") ;;
          *) bad+=("$h $code inattendu") ;;
        esac
      done
      if ((${#bad[@]} > 0)); then rr oidc FAIL "$(printf '%s; ' "${bad[@]}" | sed 's/; $//' | cut -c1-200)"
      elif ((${#unk[@]} > 0 && okn == 0)); then rr oidc BLOCKED "${unk[0]}"
      else rr oidc PASS "$okn hostname(s): 302 Authentik ou 401/403"; fi
    fi

    # 2. exposure
    bad="$(jq -r '.items[] | select(.spec.type | IN("LoadBalancer","NodePort")) | "Service/\(.metadata.name) \(.spec.type)"' "$work/svc.json" | head -3 | paste -sd';' -)"
    if [[ -n $bad ]]; then rr_fail exposure "$bad"
    elif [[ $(jq -r '.admin // false' "$EXC") == true && -n $all_hosts ]]; then
      if [[ $PROBE_OK == no ]]; then rr exposure BLOCKED "curl absent: sonde publique impossible"
      else
        leak=()
        for h in $all_hosts; do
          out="$(public_probe "$h")"; code="${out%% *}"
          case "$code" in 2*|3*|401|403) leak+=("$h repond $code publiquement") ;; esac
        done
        if ((${#leak[@]} > 0)); then rr_fail exposure "$(printf '%s; ' "${leak[@]}" | sed 's/; $//' | cut -c1-200)"
        else rr exposure PASS "app admin: aucun hostname public ne repond"; fi
      fi
    else rr exposure PASS "aucun Service LoadBalancer/NodePort"; fi

    # 3. backup
    if [[ $(jq -r '.backup // ""' "$EXC") == none ]]; then rr backup SKIP "exception backup none: $(exc_reason backup)"
    elif is_pr_ns; then rr backup SKIP "namespace de preview $NS: pas de backup attendu"
    else
      pvcn="$(jq '.npvc' "$work/scope.json")"; cnpgn="$(jq '.cnpg | length' "$work/scope.json")"
      if [[ $pvcn == 0 && $cnpgn == 0 ]]; then rr backup SKIP "l'app ne declare aucun PVC ni Cluster CNPG"
      elif ! kget backups.velero.io -n velero >"$work/vb.json"; then rr backup BLOCKED "lecture backups Velero impossible: $(kerr)"
      else
        vlast="$(jq -r --arg ns "$NS" --slurpfile sc "$work/scope.json" '
          ($sc[0].scheds) as $mine
          | [.items[] | select(.status.phase == "Completed")
           | select(($mine | length) == 0 or ((.metadata.labels["velero.io/schedule-name"] // "") | IN($mine[])))
           | select(((.spec.includedNamespaces // []) | length == 0) or ((.spec.includedNamespaces // []) | any(. == $ns or . == "*")))
           | select(((.spec.excludedNamespaces // []) | any(. == $ns)) | not)
           | .status.completionTimestamp | fromdateiso8601] | max // empty
          | ((now - .) / 3600 | floor) | tostring' "$work/vb.json")"
        clast=""
        if [[ $cnpgn != 0 ]] && kget backups.postgresql.cnpg.io -n "$NS" >"$work/cb.json"; then
          clast="$(jq -r --slurpfile sc "$work/scope.json" '[.items[] | select(.status.phase == "completed" and (.spec.cluster.name | IN($sc[0].cnpg[]))) | .status.stoppedAt | fromdateiso8601] | max // empty | ((now - .) / 3600 | floor) | tostring' "$work/cb.json")"
        fi
        okv=yes; okc=yes
        [[ $pvcn == 0 || ( -n $vlast && $vlast -lt $max_age_h ) ]] || okv=no
        # CNPG : seuil derive du ScheduledBackup (hebdomadaire/mensuel -> 8 j), sinon le seuil Velero
        cmax=$max_age_h
        if [[ $cnpgn != 0 ]] && kget scheduledbackups.postgresql.cnpg.io -n "$NS" >"$work/sb.json" 2>/dev/null \
           && jq -e --slurpfile sc "$work/scope.json" '[.items[] | select(.spec.cluster.name | IN($sc[0].cnpg[])) | (.spec.schedule | split(" ")) | select(length >= 6 and (.[3] != "*" or .[5] != "*"))] | length > 0' "$work/sb.json" >/dev/null; then cmax=192; fi
        [[ $cnpgn == 0 || ( -n $clast && $clast -lt $cmax ) ]] || okc=no
        if [[ $okv == yes && $okc == yes ]]; then
          rr backup PASS "dernier backup$([[ $pvcn != 0 ]] && echo " Velero il y a ${vlast} h")$([[ $cnpgn != 0 ]] && echo " CNPG il y a ${clast} h")"
        else rr_fail backup "aucun backup reussi < ${max_age_h} h de l'app (Velero: ${vlast:-aucun}$([[ $cnpgn != 0 ]] && echo ", CNPG: ${clast:-aucun}"))"; fi
      fi
    fi

    # 5. observability
    prom='/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query='
    q="$(jq -rn --arg ns "$NS" '"up{namespace=\"\($ns)\"}" | @uri')"
    npods="$(jq '[.items[] | select(.status.phase != "Succeeded")] | length' "$work/pods.json" 2>/dev/null)"; npods=${npods:-0}
    if kro get --raw "$prom$q" >"$work/up-all.json" 2>"$work/kget.err" && jq -e '.status == "success"' "$work/up-all.json" >/dev/null 2>&1; then
      # cibles de l'app seulement : pod de l'app, ou service/job portant le nom d'un Service rendu de l'app
      jq --slurpfile sc "$work/scope.json" --slurpfile pd "$work/pods.json" '
        ([ $pd[0].items[].metadata.name ]) as $pods
        | {status, data: {result: [ .data.result[] | .metric as $m
            | select(($m.pod // "") as $x | ($x != "" and ($pods | index($x)) != null)
                     or (($m.service // "") as $v | $v != "" and ($sc[0].svcs | index($v)) != null)
                     or (($m.job // "") as $v | $v != "" and ($sc[0].svcs | index($v)) != null)) ]}}' "$work/up-all.json" >"$work/up.json"
      tot="$(jq '.data.result | length' "$work/up.json")"; down="$(jq -r '[.data.result[] | select(.value[1] != "1") | .metric.job // .metric.pod // "?"] | unique | join(",")' "$work/up.json")"
      if ((tot == 0)); then
        if [[ $npods == 0 ]]; then rr observability SKIP "aucun pod (scale a zero), aucune cible"
        else rr_fail observability "aucune cible up de l app dans $NS (pods/services rendus de l app)"; fi
      elif [[ -n $down ]]; then rr_fail observability "cible(s) up==0: ${down:0:80}"
      else rr observability PASS "$tot cible(s) up==1 (Prometheus local)"; fi
    else rr observability BLOCKED "requete Prometheus impossible: $(kerr)"; fi

    # 6. selfheal
    deploy_kind=unknown
    if [[ -s $work/pods.json ]]; then
      sh="$(jq -r --argjson max "$restart_max" '
        [.items[] | select(.status.phase != "Succeeded")] as $p
        | ($p | length) as $n
        | ($p | map(select(any(.status.conditions[]?; .type == "Ready" and .status == "True") | not) | .metadata.name) | .[0:3] | join(",")) as $nr
        | ([ $p[] | .metadata.name as $pn | .status.containerStatuses[]? | select(.restartCount > $max)
             | select(((.lastState.terminated.finishedAt // "1970-01-01T00:00:00Z") | fromdateiso8601) > (now - 86400))
             | "\($pn)/\(.name) \(.restartCount) restarts" ] | .[0:3] | join(",")) as $rs
        | "\($n)|\($nr)|\($rs)"' "$work/pods.json")"
      n="${sh%%|*}"; rest="${sh#*|}"; nr="${rest%%|*}"; rs="${rest#*|}"
      if [[ $n == 0 && $(jq '(.wls | length) + (.cnpg | length)' "$work/scope.json") == 0 ]]; then
        # dossier sans workload (RBAC, template, ressources seules) : rien a auto-reparer
        rr selfheal SKIP "l'app ne declare aucun workload ni Cluster CNPG"
      elif [[ $n == 0 ]]; then
        if kget scaledobjects.keda.sh -n "$NS" 2>/dev/null | jq -e --slurpfile sc "$work/scope.json" '[.items[] | select((.spec.minReplicaCount // 1) == 0 and (.spec.scaleTargetRef.name | IN($sc[0].wls[].name)))] | length > 0' >/dev/null 2>&1; then
          rr selfheal SKIP "scale a zero (KEDA): aucun pod a evaluer"
        else rr_fail selfheal "aucun pod de l app dans $NS"; fi
      elif [[ -n $nr ]]; then deploy_kind=broken; rr_fail selfheal "pods non Ready: $nr"
      elif [[ -n $rs ]]; then deploy_kind=broken; rr_fail selfheal "restarts recents > $restart_max: $rs"
      else
        deploy_kind=healthy
        rr selfheal PASS "$n pod(s) Ready, restarts <= $restart_max"
        if [[ $CHAOS == yes ]]; then
          if ! is_pr_ns; then rr selfheal SKIP "--chaos refuse hors namespace pr-* (jamais de suppression en prod)"
          else
            victim="$(jq -r '[.items[] | select(.status.phase == "Running")][0].metadata.name // empty' "$work/pods.json")"
            if [[ -z $victim ]]; then rr selfheal BLOCKED "chaos: aucun pod Running a supprimer"
            elif ! bash "${KUBECTL_RW_SCRIPT:-$SELF_DIR/kubectl-rw.sh}" delete "$NS" "pod/$victim" >"$work/chaos.out" 2>&1; then
              rr selfheal BLOCKED "chaos: kubectl-rw delete refuse ($(head -c 120 "$work/chaos.out" | tr '\n' ' '))"
            else
              healed=no
              for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
                sleep "${APP_TEST_CHAOS_INTERVAL:-10}"
                if kget pods -n "$NS" >"$work/pods2-all.json" && scope_pods "$work/pods2-all.json" >"$work/pods2.json" && jq -e --arg v "$victim" '
                     [.items[] | select(.status.phase != "Succeeded")] as $p
                     | ($p | length) > 0 and all($p[]; .metadata.name != $v and any(.status.conditions[]?; .type == "Ready" and .status == "True"))' "$work/pods2.json" >/dev/null; then healed=yes; break; fi
              done
              if [[ $healed == yes ]]; then rr selfheal PASS "chaos: pod $victim supprime, remplace et Ready < 120 s"
              else rr selfheal FAIL "chaos: pods non Ready 120 s apres suppression de $victim"; fi
            fi
          fi
        fi
      fi
    fi

    # 7. network
    enf="$(jq -r '.metadata.labels["pod-security.kubernetes.io/enforce"] // "absent"' "$work/ns.json")"
    if [[ $(jq '.ownns' "$work/scope.json") != true ]]; then
      # namespace partage : le label PSA n'est pas une propriete de l'app, information seulement
      rr network PASS "namespace partage: PSA enforce=$enf non impute a l'app"
    elif [[ $enf == restricted ]]; then rr network PASS "PSA enforce=restricted"
    else rr_fail network "label PSA enforce=$enf (restricted attendu)"; fi

    # 4. renovate : aucun signal runtime (le digest est une propriete de Git).
    [[ $PHASE == runtime ]] && rr renovate SKIP "verification statique uniquement (digest = propriete de Git)"
  fi
fi

# ------------------------------------------------------------------ agregation et sortie
rank() { case "$1" in FAIL) echo 4 ;; BLOCKED) echo 3 ;; PASS) echo 2 ;; SKIP) echo 1 ;; *) echo 0 ;; esac; }
overall=PASS
if [[ -n $exc_problems ]]; then
  echo "CHECK exceptions FAIL $(printf '%s' "$exc_problems" | paste -sd';' - | cut -c1-200)"
  overall=FAIL
fi
for id in $IDS; do
  st=""; sr=""; rt=""; rr_="" ; sst=""; rst=""
  while IFS=$'\t' read -r _ ph status reason; do
    if [[ $ph == static ]]; then sst=$status; sr=$reason; else rst=$status; rr_=$reason; fi
  done < <(awk -F'\t' -v id="$id" '$1==id' "$RES")
  if [[ -z $sst && -z $rst ]]; then echo "CHECK $id BLOCKED aucun resultat produit"; [[ $overall == FAIL ]] || overall=BLOCKED; continue; fi
  best=""; for s in $sst $rst; do if (( $(rank "$s") > $(rank "${best:-X}") )); then best=$s; fi; done
  if [[ -n $sst && -n $rst ]]; then
    # une phase qui reussit n'ajoute pas de bruit a une ligne FAIL/BLOCKED
    reason=""
    if [[ $best == PASS || $best == SKIP ]]; then reason="s: $sr | r: $rr_"
    else
      [[ $sst == "$best" ]] && reason="s: $sr"
      [[ $rst == "$best" ]] && reason="${reason:+$reason | }r: $rr_"
      [[ $sst != "$best" && $sst != SKIP ]] && reason="$reason (static $sst)"
      [[ $rst != "$best" && $rst != SKIP ]] && reason="$reason (runtime $rst)"
    fi
  elif [[ -n $sst ]]; then reason=$sr; else reason=$rr_; fi
  reason="$(printf '%s' "$reason" | tr '\t\r\n' '   ' | cut -c1-260)"
  echo "CHECK $id $best $reason"
  case "$best" in FAIL) overall=FAIL ;; BLOCKED) [[ $overall == FAIL ]] || overall=BLOCKED ;; esac
done
if [[ $PHASE != static ]]; then
  # Etat BRUT des pods (avant exception et cliquet) : la dette selfheal gelee ou declaree concerne la conformite
  # (probes, PDB, requests) et ne doit jamais masquer un deploiement casse (drill #1688 : pods non Ready
  # "baselined"). "aucun pod" (dossier sans workload), scale a zero ou BLOCKED restent UNKNOWN.
  dh=UNKNOWN
  case "${deploy_kind:-unknown}" in broken) dh=FAIL ;; healthy) dh=PASS ;; esac
  echo "DEPLOY_HEALTH=$dh"
fi
echo "APP_TEST=$overall"
case "$overall" in PASS) exit 0 ;; FAIL) exit 1 ;; *) exit 2 ;; esac
