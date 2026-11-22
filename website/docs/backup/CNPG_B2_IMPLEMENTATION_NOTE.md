# CNPG B2 implementation note — superseded

This design is no longer active.

V1 uses the CloudNativePG Barman Cloud plugin directly against Cloudflare R2:

```text
endpoint: Doppler R2_S3_ENDPOINT (injected as AWS_ENDPOINT_URL_S3, never in Git)
bucket: homelab-backup-cnpg (jurisdiction eu)
prefix: <namespace>/<cluster name>   (serverName defaults to the Cluster name)
```

Each active CNPG cluster archives WAL continuously (`isWALArchiver: true`) and runs a staggered weekly base backup through a `ScheduledBackup` with `method: plugin`. The ObjectStore sets `AWS_REQUEST_CHECKSUM_CALCULATION` and `AWS_RESPONSE_CHECKSUM_VALIDATION` to `when_required` because R2 does not support every default flexible checksum. The recovery window is 14 days. The reference manifests are the `database-r2.yaml` files under `k8s/`.

Do not reintroduce MinIO, TrueNAS or Backblaze B2 for V1.
