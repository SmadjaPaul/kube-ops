#!/usr/bin/env bash
set -euo pipefail
root=k8s/applications/media
pkg="$root/bookorbit"
assert_contains() {
  local needle=$1
  local file=$2
  if ! grep -Fq -- "$needle" "$file"; then
    echo "BOOKORBIT_STAGE=FAIL: missing '$needle' in $file" >&2
    return 1
  fi
}

if grep -Fxq -- '- bookorbit' "$root/kustomization.yaml"; then
  echo "BOOKORBIT_STAGE=FAIL: not yet admitted"
  exit 1
fi
assert_contains 'ghcr.io/bookorbit/bookorbit:3.5.0@sha256:1534bc7d696179141875b0298ea7916be4469eb2eb9250347873eaaa9728b5a8' "$pkg/app.yaml"
assert_contains 'value: /data/book-dock' "$pkg/app.yaml"
assert_contains 'value: /data/media/books' "$pkg/app.yaml"
assert_contains 'APP_BOOKORBIT_BOOK_REQUEST_ENCRYPTION_KEY' "$pkg/external-secret.yaml"
assert_contains 'APP_BOOKORBIT_JWT_SECRET' "$pkg/external-secret.yaml"
assert_contains 'port: "8282"' "$pkg/networkpolicy.yaml"
assert_contains 'bookorbit-postgresql' "$pkg/database.yaml"
assert_contains 'bookorbit-postgresql-weekly' "$pkg/backup.yaml"
assert_contains 'OIDC' "$pkg/README.md"
assert_contains 'setCategory' "$pkg/README.md"
echo "BOOKORBIT_STAGED=PASS (STATIC_ONLY; NO RUNTIME PROOF)"
