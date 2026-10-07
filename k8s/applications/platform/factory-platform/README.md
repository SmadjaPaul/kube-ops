# Factory Platform V0

Internal deployment of the private `SmadjaPaul/factory-platform` image.

## Deployment contract

The app stays private and has no Gateway/HTTPRoute. Prometheus scrapes `/metrics`
through the ClusterIP Service.

Before merging this deployment, Doppler `cluster/prd` must provide:

- `APP_FACTORY_PLATFORM_GHCR_TOKEN` — a dedicated GitHub PAT classic with
  `read:packages` only, used exclusively to pull the private GHCR image
- existing `HETZNER_S3_ACCESS_KEY_ID`
- existing `HETZNER_S3_SECRET_ACCESS_KEY`

The GitHub username is the non-secret constant `SmadjaPaul`. The GHCR token is
materialized by External Secrets as a `kubernetes.io/dockerconfigjson`
imagePullSecret. No credential is committed to Git.

The historical general-purpose GitHub PAT is not reused: its GHCR authentication
preflight failed.

## Data/storage

- PostgreSQL is single-instance CNPG on `longhorn-bulk`.
- dbt staging/fact models are views; only the small overview mart is materialized.
- GitHub collection is bounded to the latest two pages every 30 minutes and uses
  idempotent upserts rather than appending duplicates.
- WAL is archived continuously and a weekly base backup is written to Hetzner Object Storage.
