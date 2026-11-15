# shellcheck shell=sh
# PLT-286: shared helpers for the restic CronJobs (POSIX sh: busybox and bash).
# Environment (Secret restic-backup, ExternalSecret from Doppler cluster/prd):
#   RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY.
# Never print these values: no `set -x`, no `env`, no echo of a variable.

: "${RESTIC_HOST:?RESTIC_HOST is required}"
: "${APP:?APP is required}"

restic_bin="${restic_bin:-${RESTIC_BIN:-restic}}"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# Open the repository; initialise it only when restic reports that it does
# not exist (exit code 10). A wrong password is exit code 12: the job fails
# and never creates a second repository over the first.
ensure_repository() {
  rc=0
  "$restic_bin" cat config >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) log "repository=present" ;;
    10)
      log "repository=absent action=init"
      "$restic_bin" init
      ;;
    12)
      log "repository=wrong-password; refusing to continue"
      return 12
      ;;
    *)
      log "repository=unreachable rc=$rc"
      return "$rc"
      ;;
  esac
}
