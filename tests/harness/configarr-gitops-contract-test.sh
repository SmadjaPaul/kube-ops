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

grep -Eq '^[[:space:]]*-[[:space:]]*configarr([[:space:]]|$)' "$main" || {
  echo "CONFIGARR_CONTRACT=FAIL package is not admitted to media root"; exit 1;
}

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
grep -Fq 'sonarr.media.svc.cluster.local:8989' "$cfg" || { echo "CONFIGARR_CONTRACT=FAIL sonarr service port"; exit 1; }
grep -Fq 'radarr.media.svc.cluster.local:7878' "$cfg" || { echo "CONFIGARR_CONTRACT=FAIL radarr service port"; exit 1; }
grep -Fq 'prowlarr.media.svc.cluster.local:9696' "$cfg" || { echo "CONFIGARR_CONTRACT=FAIL prowlarr service port"; exit 1; }
grep -Fq 'delete_unmanaged:' "$cfg"
grep -Fq 'enabled: false' "$cfg"
grep -Fq 'sync_indexers: false' "$cfg"
grep -Fq 'DRY_RUN=true' "$package/README.md"
grep -Fq 'app.kubernetes.io/name: configarr-preview' "$net"

# A password must never be committed literally. The two known Decypharr
# qBittorrent-compatible clients intentionally use Kubernetes-injected env.
if grep -E '^[[:space:]]*password:' "$cfg" |
   grep -Ev '^[[:space:]]*password:[[:space:]]*!env (RADARR_API_KEY|SONARR_API_KEY)[[:space:]]*$' |
   grep -q .; then
  echo "CONFIGARR_CONTRACT=FAIL password is not an approved !env reference"; exit 1
fi
test "$(grep -Ec '^[[:space:]]*password:[[:space:]]*!env (RADARR_API_KEY|SONARR_API_KEY)[[:space:]]*$' "$cfg")" -eq 2 || {
  echo "CONFIGARR_CONTRACT=FAIL expected two Decypharr env secret references"; exit 1
}
if grep -Eq '^[[:space:]]*api_key:[[:space:]]*["\x27]?[A-Za-z0-9_-]{16,}' "$cfg"; then
  echo "CONFIGARR_CONTRACT=FAIL literal API credential"; exit 1
fi

echo "CONFIGARR_GITOPS_CONTRACT=PASS (STATIC ONLY; NO RUNTIME ADMISSION)"
