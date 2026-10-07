# Factory Platform V0

Internal deployment of the private `SmadjaPaul/factory-platform` image.

## Deployment contract

The app stays private and has no Gateway/HTTPRoute. Prometheus scrapes `/metrics`
through the ClusterIP Service.

Before merging this deployment, Doppler must provide:

- `FACTORY_PLATFORM_GHCR_USERNAME`
- `FACTORY_PLATFORM_GHCR_TOKEN` — a dedicated GitHub Packages credential with
  read-only package access
- existing `HETZNER_S3_ACCESS_KEY_ID`
- existing `HETZNER_S3_SECRET_ACCESS_KEY`

The GHCR credential is materialized by External Secrets as a
`kubernetes.io/dockerconfigjson` imagePullSecret. No credential is committed to Git.

## Data/storage

- PostgreSQL is single-instance CNPG on `longhorn-bulk`.
- dbt staging/fact models are views; only the small overview mart is materialized.
- GitHub collection is bounded to the latest two pages every 30 minutes and uses
  idempotent upserts rather than appending duplicates.
- WAL is archived continuously and a weekly base backup is written to Hetzner Object Storage.
