#!/usr/bin/env bash
# Drill de restauration d'UNE application depuis pg-shared (homelab) : PITR dans un
# cluster temporaire (--mode pitr) ou pg_dump -Fc vers une base temporaire (--mode dump).
# Mesure le RTO et le RPO réels. Ne déclare jamais RPO <= 5 min sans mesure : sans
# mesure, le statut reste NOT_PROVEN.
#
# Usage :
#   bash scripts/pg-shared-app-restore-proof.sh --app <base> --other-db <base> [--other-db <base>...]
#     --source-namespace <ns> [--mode pitr|dump] [--namespace <ns>-drill] [--source-cluster pg-shared]
#     [--id <suffixe>] [--dry-run]
#   bash scripts/pg-shared-app-restore-proof.sh <options ci-dessus> --execute \
#     --confirm I-APPROVE-PG-SHARED-APP-RESTORE-DRILL
#
# Défaut : --dry-run. Aucun accès au cluster, aucune écriture.
# --execute exige la chaîne --confirm exacte ; sans elle, refus avant tout accès.
# Variables d'exécution (noms seulement, jamais de valeur) :
#   PG_PROOF_IMAGE      image PostgreSQL pinée par digest (@sha256:)
#   PG_PROOF_DB_SECRET  Secret applicatif de la source (clé `password`), utilisé par les Jobs
#   PG_PROOF_DB_USER    rôle de connexion (défaut app)
#   PG_PROOF_OBJECTSTORE  ObjectStore barman-cloud en LECTURE SEULE, dans le namespace de drill (pitr)
#   PG_PROOF_WRITE_BIN  binaire d'écriture approuvé ; absent = échec fermé (blocant B1)
#
# Garanties : gate de température nœud < 70 °C avant toute écriture ; aucun `delete` de PVC
# (refusé dans drill_write) ; cluster temporaire supprimé sur EXIT/INT/TERM ; PVC résiduels
# listés en lecture seule pour décision de Paul.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RO_BIN="${PG_PROOF_RO_BIN:-$HERE/kubectl-ro.sh}"
CONFIRM_TOKEN="I-APPROVE-PG-SHARED-APP-RESTORE-DRILL"
MAX_TEMP_C=70
MAX_RPO_S=300
MAX_RTO_S=1800
MARGIN_S="${PG_PROOF_MARGIN_S:-30}"
ARCHIVE_WAIT_S="${PG_PROOF_ARCHIVE_WAIT_S:-360}"
JOB_TIMEOUT_S=900
# Tctl du nœud homelab (requête de docs/operations/compute-baseline-2026-11-12.md).
# Capteur à confirmer par Paul (blocant B3 du runbook) : Tctl moyen 88 °C sur 7 j.
TEMP_QUERY_DEFAULT='max(node_hwmon_temp_celsius{job="proxmox-host",chip="pci0000:00_0000:00:18_3",sensor="temp1"})'
TEMP_QUERY="${PG_PROOF_TEMP_QUERY:-$TEMP_QUERY_DEFAULT}"
# Requête de fingerprint : somme md5 des tables publiques, hors table de marques du drill.
# shellcheck disable=SC2016  # SQL littéral : $q$ est du dollar-quoting PostgreSQL, pas une expansion shell
FP_SQL='select coalesce(md5(string_agg(table_name||$q$:$q$||n, $q$,$q$ order by table_name)),$q$none$q$) from (select table_name, (xpath($q$/row/c/text()$q$, query_to_xml(format($q$select count(*) as c from %I$q$, table_name), false, true, $q$$q$)))[1]::text as n from information_schema.tables where table_schema=$q$public$q$ and table_type=$q$BASE TABLE$q$ and table_name<>$q$restore_drill_marks$q$) s'

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }
die() {
  echo "REFUS: $*" >&2
  exit 2
}
ro_read() { bash "$RO_BIN" "$@"; }
iso_from_epoch() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

# Seule voie d'écriture. Refuse toute suppression de PVC, échoue fermé sans binaire approuvé.
is_pvc_delete() {
  [ "${1:-}" = delete ] || return 1
  case "$*" in
    *[Pp][Vv][Cc]* | *[Pp]ersistent[Vv]olume[Cc]laim*) return 0 ;;
  esac
  return 1
}

drill_write() {
  if is_pvc_delete "$@"; then
    echo "REFUS: suppression de PVC interdite par ce drill (décision Paul, D-13)" >&2
    return 64
  fi
  if [ -z "${PG_PROOF_WRITE_BIN:-}" ]; then
    echo "BLOCANT B1: aucun binaire d'écriture approuvé (kubectl-rw ne couvre ni Cluster ni exec)" >&2
    return 75
  fi
  "$PG_PROOF_WRITE_BIN" "$@"
}

# Attend la fin d'un Job (succeeded ou failed) via kubectl-ro.
wait_job() {
  local name="$1" ns="$2" waited=0 s f
  while [ "$waited" -lt "$JOB_TIMEOUT_S" ]; do
    s=$(ro_read get "job/$name" -n "$ns" -o json 2>/dev/null | jq -r '.status.succeeded // 0')
    f=$(ro_read get "job/$name" -n "$ns" -o json 2>/dev/null | jq -r '.status.failed // 0')
    [ "${s:-0}" -ge 1 ] 2>/dev/null && return 0
    [ "${f:-0}" -ge 1 ] 2>/dev/null && return 1
    sleep 10
    waited=$((waited + 10))
  done
  return 1
}

# Rend un Job psql : $1 nom, $2 namespace, $3 hôte, $4 Secret, $5 corps (texte brut),
# $6 variables d'environnement supplémentaires (bloc YAML déjà indenté, optionnel).
render_job() {
  local name="$1" ns="$2" host="$3" secret="$4" body="$5" extra="${6:-}"
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  namespace: $ns
  labels:
    app.kubernetes.io/part-of: pg-shared-restore-drill
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: psql
        image: $PG_PROOF_IMAGE
        env:
        - name: PGHOST
          value: "$host"
        - name: PGUSER
          value: "$PG_PROOF_DB_USER"
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: $secret
              key: password
$extra
        command: ["bash", "-ec"]
        args:
        - |
$(printf '%s\n' "$body" | sed 's/^/          /')
EOF
}

MODE=pitr
APP=""
OTHERS=()
TARGET=""
NS=pg-shared-restore-drill
SRC_NS=""
SRC=pg-shared
ID=""
EXECUTE=0
CONFIRM=""
PG_PROOF_DB_USER="${PG_PROOF_DB_USER:-app}"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --app)
      APP="${2:-}"
      shift 2
      ;;
    --other-db)
      OTHERS+=("${2:-}")
      shift 2
      ;;
    --target-time)
      TARGET="${2:-}"
      shift 2
      ;;
    --namespace)
      NS="${2:-}"
      shift 2
      ;;
    --source-namespace)
      SRC_NS="${2:-}"
      shift 2
      ;;
    --source-cluster)
      SRC="${2:-}"
      shift 2
      ;;
    --id)
      ID="${2:-}"
      shift 2
      ;;
    --dry-run)
      EXECUTE=0
      shift
      ;;
    --execute)
      EXECUTE=1
      shift
      ;;
    --confirm)
      CONFIRM="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "option inconnue: $1" ;;
  esac
done

# --- validation : aucun accès cluster avant ce bloc
case "$MODE" in pitr | dump) ;; *) die "--mode pitr|dump" ;; esac
[[ "$APP" =~ ^[a-z][a-z0-9_]{0,40}$ ]] || die "--app absent ou invalide"
case "$APP" in postgres | template0 | template1) die "base système refusée: $APP" ;; esac
[ "${#OTHERS[@]}" -ge 1 ] || die "au moins un --other-db requis (test de non-impact)"
for o in "${OTHERS[@]}"; do
  [[ "$o" =~ ^[a-z][a-z0-9_]{0,40}$ ]] || die "--other-db invalide: $o"
  [ "$o" != "$APP" ] || die "--other-db identique à --app"
done
[ -n "$SRC_NS" ] || die "--source-namespace requis"
[[ "$NS" =~ ^[a-z0-9-]+-drill$ ]] || die "--namespace doit se terminer par -drill (ex. pg-shared-restore-drill)"
[ "$NS" != "$SRC_NS" ] || die "namespace de drill égal à la source : refusé"
[[ "$SRC" =~ ^[a-z0-9-]{1,40}$ ]] || die "--source-cluster invalide"
[ -n "$ID" ] || ID=$(date -u +%Y%m%d%H%M%S)
[[ "$ID" =~ ^[a-z0-9]{1,20}$ ]] || die "--id invalide (minuscules et chiffres)"
RESTORE="pg-shared-restore-$ID"
RESTORE_HOST="$RESTORE-rw.$NS.svc"
SRC_HOST="$SRC-rw.$SRC_NS.svc"
RESTORE_SECRET="$RESTORE-app"
ALL_DBS="$APP ${OTHERS[*]}"
if [ "$MODE" = pitr ] && [ -n "$TARGET" ]; then
  die "--target-time est calculé après la graine (T_W + marge) : à omettre"
fi

if [ "$EXECUTE" = 0 ]; then
  cat <<EOF
MODE DRY-RUN (aucun accès cluster, aucune écriture)
Mode de restauration : $MODE
Source : cluster $SRC, namespace $SRC_NS ; base testée $APP ; bases témoins ${OTHERS[*]}
Cluster temporaire : $RESTORE dans le namespace $NS
Étapes (--execute + --confirm) :
  1. Gate température : requête '$TEMP_QUERY' via kubectl-ro ; refus si >= ${MAX_TEMP_C} °C ou valeur absente.
  2. Lecture : cluster $SRC Ready (kubectl-ro).
  3. Empreintes témoins avant (Job seed, lecture seule sur les témoins) et graine :
     table restore_drill_marks dans $ALL_DBS, T_W = epoch du commit (blocant B2).
  4. $([ "$MODE" = pitr ] && echo "Attente archivage WAL ${ARCHIVE_WAIT_S} s, puis Cluster $RESTORE (bootstrap.recovery, barman-cloud, serverName $SRC, targetTime = T_W + ${MARGIN_S} s)." || echo "Cluster initdb $RESTORE, puis Job pg_dump -Fc $APP | pg_restore vers $RESTORE_HOST.")
  5. RTO = création -> Ready (mesuré).
  6. Vérification (Job verify sur $RESTORE_HOST) : lignes et epoch max des marques de $APP.
  7. RPO = T_W - epoch max restauré (mesuré seulement).
  8. Non-impact : empreintes des témoins sur la source après drill = avant (Job fingerprint).
  9. Nettoyage garanti (EXIT/INT/TERM) : delete du Cluster $RESTORE ; PVC listés, jamais supprimés.
Verdict : PASS seulement si RPO mesuré <= ${MAX_RPO_S} s, RTO mesuré <= ${MAX_RTO_S} s, non-impact et empreintes OK.
STATUS=NOT_TESTED RPO=NOT_MEASURED RTO=NOT_MEASURED
EOF
  exit 0
fi

# --- exécution : confirmation explicite puis préflight
[ "$CONFIRM" = "$CONFIRM_TOKEN" ] || die "confirmation explicite absente ou fausse (--confirm $CONFIRM_TOKEN)"
[ -n "${PG_PROOF_IMAGE:-}" ] || die "PG_PROOF_IMAGE requise"
[[ "$PG_PROOF_IMAGE" == *@sha256:* ]] || die "PG_PROOF_IMAGE doit être pinée par digest"
[ -n "${PG_PROOF_DB_SECRET:-}" ] || die "PG_PROOF_DB_SECRET (nom seulement) requis"
if [ "$MODE" = pitr ]; then
  [ -n "${PG_PROOF_OBJECTSTORE:-}" ] || die "PG_PROOF_OBJECTSTORE requis en mode pitr (lecture seule)"
fi
command -v jq >/dev/null 2>&1 || die "jq absent"

CREATED=0
LEFT=0
WORK=$(mktemp -d) || die "répertoire de travail temporaire"
# shellcheck disable=SC2329  # appelée via trap EXIT
cleanup() {
  local rc=$?
  rm -rf "$WORK"
  if [ "$CREATED" = 1 ]; then
    if drill_write delete cluster.postgresql.cnpg.io "$RESTORE" -n "$NS" --wait=false >/dev/null 2>&1; then
      echo "CLEANUP=OK cluster $RESTORE supprimé"
    else
      LEFT=1
      echo "CLEANUP=LEFTOVER cluster $RESTORE (ns $NS) : suppression non effectuée, action Paul"
    fi
    echo "PVC_RESIDUELS (lecture seule, aucune suppression) :"
    ro_read get pvc -n "$NS" -l "cnpg.io/cluster=$RESTORE" -o name 2>/dev/null || echo "  (liste indisponible)"
  fi
  if [ "$rc" -eq 0 ] && [ "$LEFT" -eq 1 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 1. gate température
q_enc=$(printf '%s' "$TEMP_QUERY" | jq -sRr @uri)
raw=$(ro_read get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$q_enc") ||
  die "lecture température impossible (kubectl-ro)"
temp=$(printf '%s' "$raw" | jq -r '.data.result[0].value[1] // empty')
[ -n "$temp" ] || die "température absente : gate fermé"
awk -v v="$temp" -v m="$MAX_TEMP_C" 'BEGIN { exit !(v + 0 < m) }' ||
  die "nœud à ${temp} °C, seuil ${MAX_TEMP_C} °C : drill refusé"
echo "TEMP_C=$temp (seuil < ${MAX_TEMP_C})"

# 2. source Ready
src_ready=$(ro_read get "cluster.postgresql.cnpg.io/$SRC" -n "$SRC_NS" -o json 2>/dev/null |
  jq -r '[.status.conditions[]? | select(.type=="Ready") | .status] | first // "absent"')
[ "$src_ready" = True ] || die "cluster source $SRC non Ready ($src_ready)"
echo "SOURCE_READY=True"

# 3. empreintes témoins avant + graine (écriture limitée à restore_drill_marks)
SEED_BODY=$(
  cat <<'BODY'
set -eu
DBS='@DBS@'
for db in $DBS; do
  echo "FP_$db=$(psql -X -At -v ON_ERROR_STOP=1 -d "$db" -c '@FP_SQL@')"
done
for db in $DBS; do
  psql -X -v ON_ERROR_STOP=1 -d "$db" -c "create table if not exists restore_drill_marks(id bigserial primary key, committed_at timestamptz not null default clock_timestamp()); insert into restore_drill_marks default values;" >/dev/null
done
echo "T_W_EPOCH=$(psql -X -At -v ON_ERROR_STOP=1 -d '@APP@' -c 'select extract(epoch from max(committed_at)) from restore_drill_marks')"
BODY
)
SEED_BODY=${SEED_BODY//@DBS@/$ALL_DBS}
SEED_BODY=${SEED_BODY//@APP@/$APP}
SEED_BODY=${SEED_BODY//@FP_SQL@/$FP_SQL}
SEED_JOB="pg-proof-seed-$ID"
render_job "$SEED_JOB" "$SRC_NS" "$SRC_HOST" "$PG_PROOF_DB_SECRET" "$SEED_BODY" >"$WORK/seed.yaml" ||
  die "rendu du Job graine"
drill_write apply -f "$WORK/seed.yaml" || die "graine refusée (B1/B2)"
wait_job "$SEED_JOB" "$SRC_NS" || die "job graine en échec ou délai dépassé"
SEED_LOG=$(ro_read logs "job/$SEED_JOB" -n "$SRC_NS" 2>/dev/null)
TW=$(printf '%s\n' "$SEED_LOG" | sed -n 's/^T_W_EPOCH=//p' | tail -1)
[ -n "$TW" ] && [ "$TW" != "" ] || die "T_W absent des logs de la graine : RPO non mesurable"
echo "T_W_EPOCH=$TW"

# 4. restauration
START=$(date +%s)
if [ "$MODE" = pitr ]; then
  sleep "$ARCHIVE_WAIT_S"
  TARGET=$(iso_from_epoch $((${TW%.*} + MARGIN_S))) || die "calcul du targetTime"
  MANIFEST=$(
    cat <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $RESTORE
  namespace: $NS
  labels:
    app.kubernetes.io/part-of: pg-shared-restore-drill
spec:
  instances: 1
  imageName: $PG_PROOF_IMAGE
  storage:
    size: 10Gi
  bootstrap:
    recovery:
      source: pg-shared-origin
      recoveryTarget:
        targetTime: "$TARGET"
  externalClusters:
  - name: pg-shared-origin
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: $PG_PROOF_OBJECTSTORE
        serverName: $SRC
EOF
  )
else
  MANIFEST=$(
    cat <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $RESTORE
  namespace: $NS
  labels:
    app.kubernetes.io/part-of: pg-shared-restore-drill
spec:
  instances: 1
  imageName: $PG_PROOF_IMAGE
  storage:
    size: 10Gi
  bootstrap:
    initdb:
      database: $APP
      owner: $PG_PROOF_DB_USER
EOF
  )
fi
MANIFEST_FILE="$WORK/cluster.yaml"
printf '%s\n' "$MANIFEST" >"$MANIFEST_FILE"
CREATED=1
drill_write apply -f "$MANIFEST_FILE" || die "création du cluster temporaire refusée (B1)"

# 5. RTO : attente Ready
RTO=""
waited=0
while [ "$waited" -lt "$MAX_RTO_S" ]; do
  st=$(ro_read get "cluster.postgresql.cnpg.io/$RESTORE" -n "$NS" -o json 2>/dev/null |
    jq -r '[.status.conditions[]? | select(.type=="Ready") | .status] | first // "absent"')
  if [ "$st" = True ]; then
    RTO=$(($(date +%s) - START))
    break
  fi
  sleep 10
  waited=$((waited + 10))
done
if [ -z "$RTO" ]; then
  RTO="NOT_MEASURED_TIMEOUT"
  echo "RTO_DEPASSE: cluster non Ready après ${MAX_RTO_S} s"
fi
echo "RTO_S=$RTO"

if [ "$MODE" = dump ]; then
  DUMP_BODY=$(
    cat <<'BODY'
set -euo pipefail
echo "DUMP_START_EPOCH=$(date +%s)"
PGHOST='@SRC_HOST@' PGPASSWORD="$PGPASSWORD" pg_dump -Fc -d '@APP@' \
  | PGHOST='@RESTORE_HOST@' PGPASSWORD="$DST_PASSWORD" pg_restore --no-owner -d '@APP@'
echo "DUMP_DONE"
BODY
  )
  DUMP_BODY=${DUMP_BODY//@SRC_HOST@/$SRC_HOST}
  DUMP_BODY=${DUMP_BODY//@RESTORE_HOST@/$RESTORE_HOST}
  DUMP_BODY=${DUMP_BODY//@APP@/$APP}
  DUMP_JOB="pg-proof-dump-$ID"
  DUMP_FILE="$WORK/dump.yaml"
  DST_ENV=$(printf '        - name: DST_PASSWORD\n          valueFrom:\n            secretKeyRef:\n              name: %s\n              key: password' "$RESTORE_SECRET")
  render_job "$DUMP_JOB" "$NS" "$SRC_HOST" "$PG_PROOF_DB_SECRET" "$DUMP_BODY" "$DST_ENV" >"$DUMP_FILE" || die "rendu du Job dump"
  drill_write apply -f "$DUMP_FILE" || die "job dump refusé (B1)"
  wait_job "$DUMP_JOB" "$NS" || die "job dump en échec ou délai dépassé"
fi

# 6. vérification dans le cluster temporaire
VERIFY_BODY=$(
  cat <<'BODY'
set -eu
psql -X -At -v ON_ERROR_STOP=1 -d '@APP@' -c 'select $q$APP_ROWS=$q$||count(*) from restore_drill_marks'
psql -X -At -v ON_ERROR_STOP=1 -d '@APP@' -c 'select $q$APP_MAX_EPOCH=$q$||coalesce(extract(epoch from max(committed_at))::text, $q$none$q$) from restore_drill_marks'
BODY
)
VERIFY_BODY=${VERIFY_BODY//@APP@/$APP}
VERIFY_JOB="pg-proof-verify-$ID"
VERIFY_FILE="$WORK/verify.yaml"
render_job "$VERIFY_JOB" "$NS" "$RESTORE_HOST" "$RESTORE_SECRET" "$VERIFY_BODY" >"$VERIFY_FILE" || die "rendu du Job verify"
drill_write apply -f "$VERIFY_FILE" || die "job verify refusé (B1)"
wait_job "$VERIFY_JOB" "$NS" || die "job verify en échec ou délai dépassé"
VOUT=$(ro_read logs "job/$VERIFY_JOB" -n "$NS" 2>/dev/null)
APP_ROWS=$(printf '%s\n' "$VOUT" | sed -n 's/^APP_ROWS=//p' | tail -1)
APP_MAX=$(printf '%s\n' "$VOUT" | sed -n 's/^APP_MAX_EPOCH=//p' | tail -1)
echo "APP_ROWS=${APP_ROWS:-NOT_MEASURED} APP_MAX_EPOCH=${APP_MAX:-NOT_MEASURED}"

# 7. RPO : mesuré seulement si l'epoch restauré est lisible
RPO=""
if [ -n "$APP_MAX" ] && [ "$APP_MAX" != none ]; then
  RPO=$(awk -v t="$TW" -v a="$APP_MAX" 'BEGIN { d = t - a; if (d < 0) d = 0; printf "%d", d }')
fi

# 8. non-impact : empreintes témoins source après drill, comparées à celles de la graine
NONIMPACT=NOT_TESTED
FP_BODY=$(
  cat <<'BODY'
set -eu
DBS='@OTHERS@'
for db in $DBS; do
  echo "FP_$db=$(psql -X -At -v ON_ERROR_STOP=1 -d "$db" -c '@FP_SQL@')"
done
BODY
)
FP_BODY=${FP_BODY//@OTHERS@/${OTHERS[*]}}
FP_BODY=${FP_BODY//@FP_SQL@/$FP_SQL}
FP_JOB="pg-proof-fp-$ID"
FP_FILE="$WORK/fp.yaml"
render_job "$FP_JOB" "$SRC_NS" "$SRC_HOST" "$PG_PROOF_DB_SECRET" "$FP_BODY" >"$FP_FILE" &&
  drill_write apply -f "$FP_FILE" >/dev/null 2>&1 && wait_job "$FP_JOB" "$SRC_NS" &&
  FP_LOG=$(ro_read logs "job/$FP_JOB" -n "$SRC_NS" 2>/dev/null) &&
  NONIMPACT=PASS
if [ "$NONIMPACT" = PASS ]; then
  for db in "${OTHERS[@]}"; do
    before=$(printf '%s\n' "$SEED_LOG" | sed -n "s/^FP_$db=//p" | tail -1)
    after=$(printf '%s\n' "$FP_LOG" | sed -n "s/^FP_$db=//p" | tail -1)
    if [ -z "$before" ] || [ "$before" != "$after" ]; then NONIMPACT=FAIL; fi
  done
fi
rm -f "$WORK/"*.yaml 2>/dev/null

# 9. verdict : PASS seulement avec mesures
STATUS=NOT_PROVEN
if [ -n "$RPO" ] && [[ "$RTO" =~ ^[0-9]+$ ]]; then
  if [ "$RPO" -le "$MAX_RPO_S" ] && [ "$RTO" -le "$MAX_RTO_S" ] && [ "$NONIMPACT" = PASS ]; then
    STATUS=PASS
  else
    STATUS=FAIL
  fi
fi
echo "RPO_S=${RPO:-NOT_MEASURED} (seuil ${MAX_RPO_S})"
echo "NONIMPACT=$NONIMPACT"
echo "STATUS=$STATUS RTO_S=$RTO RPO_S=${RPO:-NOT_MEASURED} MODE=$MODE TARGET=${TARGET:-n/a}"
[ "$STATUS" = PASS ] && exit 0
exit 1
