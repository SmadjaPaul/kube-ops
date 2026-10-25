#!/usr/bin/env bash
set -euo pipefail
root=k8s/applications/media/aiostreams
auth=k8s/infrastructure/auth/authentik/extra
# This contract deliberately fails if the draft OIDC admission is silently
# connected to existing roots, rather than being reviewed as its own PR.
! grep -Eq '^[[:space:]]*-[[:space:]]*(oidc-external-secret|oidc-deployment-patch)\.dormant\.yaml' "$root/kustomization.yaml"
! grep -Eq '^[[:space:]]*-[[:space:]]*aiostreams-oidc-externalsecret\.dormant\.yaml' "$auth/kustomization.yml"
! grep -Eq '^[[:space:]]*-[[:space:]]*\./blueprints/apps-aiostreams\.yaml' "$auth/kustomization.yml"
grep -Fq 'value: "false"' "$root/deployment.yaml"
grep -Fq 'APP_AIOSTREAMS_OIDC_CLIENT_SECRET' "$root/oidc-external-secret.dormant.yaml"
grep -Fq 'APP_AIOSTREAMS_OIDC_CLIENT_SECRET' "$auth/aiostreams-oidc-externalsecret.dormant.yaml"
grep -Fq 'AIOSTREAMS_OIDC_CLIENT_SECRET' "$root/oidc-deployment-patch.dormant.yaml"
grep -Fq 'https://auth.smadja.dev/application/o/aiostreams/' "$root/oidc-deployment-patch.dormant.yaml"
grep -Fq 'authentik-admins=admin' "$root/oidc-deployment-patch.dormant.yaml"
grep -Fq 'value: ""' "$root/oidc-deployment-patch.dormant.yaml"
! grep -Fq 'world' "$root/networkpolicy.yaml"
echo "AIOSTREAMS_OIDC=PASS STATIC / DORMANT; NO PROVIDER OR LOGIN CLAIM"
