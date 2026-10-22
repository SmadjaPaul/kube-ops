#!/usr/bin/env bash
set -euo pipefail

# Strict staging invariants: no main media-root activation and no writes.
root="k8s/applications/media"
package="$root/configarr"
main="$root/kustomization.yaml"
cron="$package/cronjob.yaml"
cfg="$package/configmap.yaml"
secret="$package/external-secret.yaml"
net="$package/networkpolicy.yaml"

for file in "$main" "$cron" "$cfg" "$secret" "$net" "$package/kustomization.yaml"; do
  test -s "$file" || { echo "CONFIGARR_CONTRACT=FAIL missing $file"; exit 1; }
done

if grep -Eq '^[[:space:]]*-[[:space:]]*configarr([[:space:]]|$)' "$main"; then
  echo "CONFIGARR_CONTRACT=FAIL package is prematurely in media root"; exit 1
fi

# Evaluate safety-critical booleans structurally; textual greps alone can be
# satisfied by comments or other fields and must not authorize an unsafe run.
yq -e '.spec.suspend == true' "$cron" >/dev/null
yq -e '.spec.jobTemplate.spec.template.spec.automountServiceAccountToken == false' "$cron" >/dev/null
yq -e '.spec.jobTemplate.spec.template.spec.containers[0].env | map(select(.name == "DRY_RUN" and .value == "true")) | length == 1' "$cron" >/dev/null
yq -e '.spec.jobTemplate.spec.template.spec.containers[0].env | map(select(.name == "CONFIGARR_ENFORCE_CONFIG_VALIDATION" and .value == "true")) | length == 1' "$cron" >/dev/null
yq -e '.spec.jobTemplate.spec.template.spec.containers[0].env | map(select(.name == "TELEMETRY_ENABLED" and .value == "false")) | length == 1' "$cron" >/dev/null

for expression in   'suspend: true'   'value: "true"'   'name: DRY_RUN'   'name: CONFIGARR_ENFORCE_CONFIG_VALIDATION'   'name: CONFIGARR_DIFF_OUTPUT_FILE'   'name: TELEMETRY_ENABLED'   'automountServiceAccountToken: false'   'concurrencyPolicy: Forbid'   'readOnlyRootFilesystem: true'   'image: ghcr.io/raydak-labs/configarr:1.35.0@sha256:13ef4d9a6ebc13178c8c74813dd12e11ea7331e186a492d79d938513887b96d4'; do
  grep -Fq "$expression" "$cron" || { echo "CONFIGARR_CONTRACT=FAIL missing $expression"; exit 1; }
done

for key in APP_RADARR_API_KEY APP_SONARR_API_KEY APP_PROWLARR_API_KEY; do
  grep -Fq "$key" "$secret" || { echo "CONFIGARR_CONTRACT=FAIL missing $key"; exit 1; }
done
for app in radarr sonarr prowlarr; do
  grep -Fq "$app.media.svc.cluster.local:80" "$cfg" || { echo "CONFIGARR_CONTRACT=FAIL $app"; exit 1; }
done
grep -Fq 'delete_unmanaged:' "$cfg"
grep -Fq 'enabled: false' "$cfg"
grep -Fq 'sync_indexers: false' "$cfg"
grep -Fq 'DRY_RUN=true' "$package/README.md"
grep -Fq 'app.kubernetes.io/name: configarr-preview' "$net"

if grep -Eq '^(.*password:|.*api_key:[[:space:]]*["\x27]?[A-Za-z0-9_-]{16,})' "$cfg"; then
  echo "CONFIGARR_CONTRACT=FAIL inline credential-like value"; exit 1
fi

echo "CONFIGARR_GITOPS_CONTRACT=PASS (STATIC ONLY; NO RUNTIME ADMISSION)"
