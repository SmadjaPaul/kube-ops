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

# PLT-394 : l'app est declaree par son descripteur (Application app-bookorbit).
assert_contains 'name: bookorbit' "$root/bookorbit/argocd-app.yaml"
assert_contains 'ghcr.io/bookorbit/bookorbit:3.9.0@sha256:79cd9c66c990a82944514e3e82d5be5987f21eda96cb37a378ed1484043716fc' "$pkg/app.yaml"
assert_contains 'value: /data/book-dock' "$pkg/app.yaml"
assert_contains 'value: /data/media/books' "$pkg/app.yaml"
assert_contains 'APP_BOOKORBIT_BOOK_REQUEST_ENCRYPTION_KEY' "$pkg/external-secret.yaml"
assert_contains 'APP_BOOKORBIT_JWT_SECRET' "$pkg/external-secret.yaml"
assert_contains 'APP_BOOKORBIT_AI_ENCRYPTION_KEY' "$pkg/external-secret.yaml"
# Velero must back up only the BookOrbit data volume, not the shared 2-TiB media.
if ! grep -Eq '^[[:space:]]*backup\.velero\.io/backup-volumes:[[:space:]]*"?data"?[[:space:]]*(#.*)?$' "$pkg/app.yaml"; then
  echo "BOOKORBIT_BACKUP_SCOPE=FAIL: backup-volumes must be exactly 'data'" >&2
  exit 1
fi
velero=k8s/infrastructure/controllers/velero/schedules/daily-bookorbit.yaml
assert_contains 'defaultVolumesToFsBackup: false' "$velero"
assert_contains 'snapshotVolumes: false' "$velero"
if grep -Eq 'defaultVolumesToFsBackup: true|backup\.velero\.io/backup-volumes: (media|data,media)' "$velero" "$pkg/app.yaml"; then
  echo "BOOKORBIT_BACKUP_SCOPE=FAIL: shared media volume may be backed up" >&2
  exit 1
fi
assert_contains 'bookorbit-postgresql' "$pkg/database.yaml"
assert_contains 'bookorbit-postgresql-weekly' "$pkg/backup.yaml"
assert_contains 'R2_CNPG_WRITER_ACCESS_KEY_ID' "$pkg/backup.yaml"
assert_contains 'R2_CNPG_WRITER_SECRET_ACCESS_KEY' "$pkg/backup.yaml"
assert_contains 'bookorbit-r2-store' "$pkg/database.yaml"
assert_contains 'storageLocation: r2' "$velero"
if grep -Eqi 'HETZNER|hetzner|your-objectstorage' "$pkg/backup.yaml" "$pkg/database.yaml" "$velero"; then
  echo "BOOKORBIT_STAGE=FAIL: BookOrbit backups must target R2 only, not Hetzner" >&2
  exit 1
fi
# PRD-122 : seule exposition admise = une HTTPRoute book.smadja.dev sur internal + external,
# derriere Cloudflare Access (homelab-infra MANDAT 28). L'ancien nom n'est servi nulle part.
command -v yq >/dev/null || { echo "BOOKORBIT_EXPOSURE=FAIL: yq required" >&2; exit 1; }
assert_equals() {
  if [[ $2 != "$3" ]]; then
    echo "BOOKORBIT_EXPOSURE=FAIL: $1: expected '$3', got '$2'" >&2
    return 1
  fi
}
route='select(.kind == "HTTPRoute")'
assert_equals 'route count' "$(yq -N "$route | .metadata.name" "$pkg"/*.yaml)" 'bookorbit'
assert_equals 'parents' "$(yq -N "$route | .spec.parentRefs[] | .namespace + \"/\" + .name" "$pkg/app.yaml" | sort | paste -sd, -)" 'gateway/external,gateway/internal'
assert_equals 'hostnames' "$(yq -N "$route | .spec.hostnames[]" "$pkg/app.yaml")" 'book.smadja.dev'
assert_contains 'smadja.cloudflareaccess.com' "$pkg/app.yaml"
assert_contains 'Rollback: remove `external` first' "$pkg/app.yaml"
for variable in APP_URL CLIENT_URL; do
  assert_equals "$variable" "$(yq -N "select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$variable\") | .value" "$pkg/app.yaml")" 'https://book.smadja.dev'
done
assert_contains 'auth_probe: /api/v1/opds' "$pkg/app-test.yaml"
if grep -rFq -- 'bookorbit.smadja.dev' k8s; then
  echo "BOOKORBIT_EXPOSURE=FAIL: former hostname bookorbit.smadja.dev still referenced under k8s/" >&2
  exit 1
fi
assert_equals 'OIDC redirect URIs' "$(grep -o '{url: [^,]*' "$oidc_blueprint" | tr -d '"' | paste -sd' ' -)" \
  '{url: https://book.smadja.dev/oauth2-callback {url: bookorbit://oauth2-callback'
assert_contains 'meta_launch_url: https://book.smadja.dev' "$oidc_blueprint"
assert_contains 'OIDC' "$pkg/README.md"
assert_contains 'owner-approved admission candidate' "$pkg/README.md"
assert_contains 'explicitly retires Decypharr' "$pkg/README.md"
assert_contains 'client_id: bookorbit' "$oidc_blueprint"
assert_contains 'client_secret: !Env BOOKORBIT_CLIENT_SECRET' "$oidc_blueprint"
assert_contains 'https://book.smadja.dev/oauth2-callback' "$oidc_blueprint"
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
