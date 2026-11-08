#!/usr/bin/env bash
set -euo pipefail
root=k8s/applications/media
pkg="$root/bookorbit"
oidc_blueprint=k8s/infrastructure/auth/authentik/extra/blueprints/apps-bookorbit.yaml
oidc_secret=k8s/infrastructure/auth/authentik/extra/bookorbit-oidc-externalsecret.yaml
assert_contains() {
  local needle=$1
  local file=$2
  if ! grep -Fq -- "$needle" "$file"; then
    echo "BOOKORBIT_STAGE=FAIL: missing '$needle' in $file" >&2
    return 1
  fi
}

assert_contains '- bookorbit' "$root/kustomization.yaml"
assert_contains 'ghcr.io/bookorbit/bookorbit:3.6.0@sha256:bbb5da52e96dbbff1dd36f55454f9845e6cde264b4b3428a3ea783124a4ca62e' "$pkg/app.yaml"
assert_contains 'value: /data/book-dock' "$pkg/app.yaml"
assert_contains 'value: /data/media/books' "$pkg/app.yaml"
assert_contains 'APP_BOOKORBIT_BOOK_REQUEST_ENCRYPTION_KEY' "$pkg/external-secret.yaml"
assert_contains 'APP_BOOKORBIT_JWT_SECRET' "$pkg/external-secret.yaml"
# Velero must back up only the BookOrbit data volume, not the shared 2-TiB media.
assert_contains 'backup.velero.io/backup-volumes: data' "$pkg/app.yaml"
velero=k8s/infrastructure/controllers/velero/schedules/daily-bookorbit.yaml
assert_contains 'defaultVolumesToFsBackup: false' "$velero"
assert_contains 'snapshotVolumes: false' "$velero"
if grep -Eq 'defaultVolumesToFsBackup: true|backup\.velero\.io/backup-volumes: (media|data,media)' "$velero" "$pkg/app.yaml"; then
  echo "BOOKORBIT_BACKUP_SCOPE=FAIL: shared media volume may be backed up" >&2
  exit 1
fi
assert_contains 'bookorbit-postgresql' "$pkg/database.yaml"
assert_contains 'bookorbit-postgresql-weekly' "$pkg/backup.yaml"
assert_contains 'APP_BOOKORBIT_CNPG_S3_ACCESS_KEY_ID' "$pkg/backup.yaml"
assert_contains 'APP_BOOKORBIT_CNPG_S3_SECRET_ACCESS_KEY' "$pkg/backup.yaml"
if grep -Eq 'HETZNER_S3_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)' "$pkg/backup.yaml"; then
  echo "BOOKORBIT_STAGE=FAIL: shared Hetzner S3 identity is not allowed" >&2
  exit 1
fi
if grep -Fq -- 'name: external' "$pkg/app.yaml"; then
  echo "BOOKORBIT_STAGE=FAIL: staged admission must remain private" >&2
  exit 1
fi
assert_contains 'name: internal' "$pkg/app.yaml"
assert_contains 'OIDC' "$pkg/README.md"
assert_contains 'owner-approved admission candidate' "$pkg/README.md"
assert_contains 'explicitly retires Decypharr' "$pkg/README.md"
assert_contains 'client_id: bookorbit' "$oidc_blueprint"
assert_contains 'client_secret: !Env BOOKORBIT_CLIENT_SECRET' "$oidc_blueprint"
assert_contains 'https://bookorbit.smadja.dev/oauth2-callback' "$oidc_blueprint"
assert_contains 'bookorbit://oauth2-callback' "$oidc_blueprint"
assert_contains 'APP_BOOKORBIT_OIDC_CLIENT_SECRET' "$oidc_secret"
assert_contains 'apps-bookorbit.yaml' k8s/infrastructure/auth/authentik/extra/kustomization.yml
assert_contains 'bookorbit-oidc-externalsecret.yaml' k8s/infrastructure/auth/authentik/extra/kustomization.yml
if grep -Eq 'client_id: bookorbit-v36-staged|APP_BOOKORBIT_OAUTH_CLIENT_SECRET|bookorbit-authentik-(blueprint|secret)\.staged' \
  "$oidc_blueprint" "$oidc_secret"; then
  echo "BOOKORBIT_ADMISSION=FAIL: staged OIDC contract remains referenced" >&2
  exit 1
fi
echo "BOOKORBIT_ADMITTED=PASS (STATIC_ONLY; NO RUNTIME PROOF)"
