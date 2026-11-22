# Backblaze B2 setup — superseded

Backblaze B2 is **not** part of the Smadja V1 backup architecture.

The V1 decision is:

```text
CNPG   -> Cloudflare R2 / homelab-backup-cnpg
Velero -> Cloudflare R2 / homelab-backup-velero
```

The S3 endpoint comes from Doppler (`R2_S3_ENDPOINT`) and is never written in Git.

This file is retained only to avoid stale links from repository history. Do not create Backblaze buckets, B2 application keys, Bitwarden secrets, or B2 schedules for V1.

See:

- `../getting-started/smadja-v1-clean-install-agent-runbook.md`
- `../infrastructure/controllers/velero-backup.md`
