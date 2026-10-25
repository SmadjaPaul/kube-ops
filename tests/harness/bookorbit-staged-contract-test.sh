#!/usr/bin/env bash
set -euo pipefail
root=k8s/applications/media
pkg="$root/bookorbit"
if grep -Fxq -- '- bookorbit' "$root/kustomization.yaml"; then
  echo "BOOKORBIT_STAGE=FAIL: not yet admitted"
  exit 1
fi
grep -Fq 'ghcr.io/bookorbit/bookorbit:3.5.0' "$pkg/app.yaml"
grep -Fq 'value: /data/book-dock' "$pkg/app.yaml"
grep -Fq 'value: /data/media/books' "$pkg/app.yaml"
grep -Fq 'APP_BOOKORBIT_BOOK_REQUEST_ENCRYPTION_KEY' "$pkg/external-secret.yaml"
grep -Fq 'APP_BOOKORBIT_JWT_SECRET' "$pkg/external-secret.yaml"
grep -Fq 'port: "8282"' "$pkg/networkpolicy.yaml"
grep -Fq 'bookorbit-postgresql' "$pkg/database.yaml"
grep -Fq 'bookorbit-postgresql-weekly' "$pkg/backup.yaml"
grep -Fq 'OIDC' "$pkg/README.md"
grep -Fq 'setCategory' "$pkg/README.md"
echo "BOOKORBIT_STAGED=PASS (STATIC_ONLY; NO RUNTIME PROOF)"
