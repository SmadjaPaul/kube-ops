#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$repo_root/k8s/applications/platform/mastra-factory/checkpoint-s3-externalsecret.dormant.yaml"
deployment="$repo_root/k8s/applications/platform/mastra-factory/deployment.yaml"
kustomization="$repo_root/k8s/applications/platform/mastra-factory/kustomization.yaml"
fixture="$repo_root/tests/fixtures/recovery/factory-checkpoint-s3-qualification.yaml"

for file in "$manifest" "$deployment" "$kustomization" "$fixture"; do
  test -f "$file" || { echo "ERROR: missing checkpoint S3 contract file: $file" >&2; exit 1; }
done

yq -e '
  .kind == "ExternalSecret" and
  .metadata.name == "mastra-factory-checkpoint-s3" and
  .spec.secretStoreRef.name == "doppler-cluster" and
  .spec.target.name == "mastra-factory-checkpoint-s3" and
  ([.spec.data[].secretKey] | sort | join(",")) == "FACTORY_CHECKPOINT_INTERVAL_SECONDS,FACTORY_CHECKPOINT_S3_ACCESS_KEY_ID,FACTORY_CHECKPOINT_S3_BUCKET,FACTORY_CHECKPOINT_S3_ENDPOINT,FACTORY_CHECKPOINT_S3_PREFIX,FACTORY_CHECKPOINT_S3_REGION,FACTORY_CHECKPOINT_S3_SECRET_ACCESS_KEY" and
  ([.spec.data[].remoteRef.key] | sort | join(",")) == "FACTORY_CHECKPOINT_INTERVAL_SECONDS,FACTORY_CHECKPOINT_S3_ACCESS_KEY_ID,FACTORY_CHECKPOINT_S3_BUCKET,FACTORY_CHECKPOINT_S3_ENDPOINT,FACTORY_CHECKPOINT_S3_PREFIX,FACTORY_CHECKPOINT_S3_REGION,FACTORY_CHECKPOINT_S3_SECRET_ACCESS_KEY"
' "$manifest" >/dev/null

if grep -F 'checkpoint-s3-externalsecret.dormant.yaml' "$kustomization" >/dev/null; then
  echo 'ERROR: dormant checkpoint ExternalSecret must not be active before prerequisites exist' >&2
  exit 1
fi

yq -e '
  (.spec.template.metadata.annotations["secret.reloader.stakater.com/reload"] | contains("mastra-factory-checkpoint-s3")) and
  (([.spec.template.spec.containers[0].envFrom[] | select(.secretRef.name == "mastra-factory-checkpoint-s3") | .secretRef.optional] | length) == 1) and
  ([.spec.template.spec.containers[0].envFrom[] | select(.secretRef.name == "mastra-factory-checkpoint-s3") | .secretRef.optional][0] == true)
' "$deployment" >/dev/null

if grep -F 'cnpg-hetzner-credentials' "$manifest" >/dev/null || grep -F 'HETZNER_S3_ACCESS_KEY_ID' "$manifest" >/dev/null; then
  echo 'ERROR: checkpoint wiring must not reuse the CNPG/shared S3 identity' >&2
  exit 1
fi

yq -e '
  .kind == "FactoryCheckpointS3Qualification" and
  .spec.status == "not-executed" and
  .spec.scope == "synthetic-only" and
  .spec.productionTargetsExcluded == true and
  .spec.storage.bucket == "smadja-dev-factory-checkpoints" and
  .spec.storage.prefix == "factory-checkpoints/v1" and
  .spec.storage.isolationMode == "dedicated-hetzner-project" and
  .spec.storage.existingBackupsBucket == "smadja-dev-homelab-backups" and
  .spec.storage.prefixIsolation == "not-assumed" and
  .spec.storage.sharedCredentialReuse == "prohibited" and
  ([.spec.permissions.negativeCases[] | select(. == "list-existing-backups-bucket-denied-read-only")] | length) == 1 and
  .spec.fixture.status == "not-executed" and
  .spec.claimLoss.status == "not-executed" and
  .spec.claimLoss.disposableOnly == true and
  .spec.recoveryMetrics.rpo.status == "unknown" and
  .spec.recoveryMetrics.rto.status == "unknown" and
  .spec.garbageCollection.status == "inactive" and
  .spec.garbageCollection.deleteLiveReferences == false
' "$fixture" >/dev/null

printf '%s\n' 'MASTRA_FACTORY_CHECKPOINT_S3_CONTRACT=PASS'
