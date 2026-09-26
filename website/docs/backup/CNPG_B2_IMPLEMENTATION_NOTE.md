# CNPG B2 implementation note — superseded

This design is no longer active.

V1 uses the CloudNativePG Barman Cloud plugin directly against Hetzner Object Storage:

```text
endpoint: https://fsn1.your-objectstorage.com
bucket: smadja-dev-homelab-backups
prefixes:
  cnpg/authentik
  cnpg/immich
  cnpg/litellm
  cnpg/pinepods
```

Each active CNPG cluster archives WAL continuously with bounded parallelism and runs a staggered weekly base backup. The ObjectStore recovery window is 14 days.

Do not reintroduce MinIO, TrueNAS or Backblaze B2 for V1.
