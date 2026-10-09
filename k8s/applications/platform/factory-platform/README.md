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
- `APP_FACTORY_PLATFORM_GITHUB_APP_TOKEN` — a GitHub App installation token
  with read-only access to pull requests, reviews and Actions for the five
  explicitly configured repositories
- `APP_FACTORY_PLATFORM_INGEST_API_KEY` — a randomly generated secret for
  explicitly authorized internal event writers; when absent, writes fail
  closed with HTTP 503

The GitHub username is the non-secret constant `SmadjaPaul`. The GHCR token is
materialized by External Secrets as a `kubernetes.io/dockerconfigjson`
imagePullSecret. No credential is committed to Git.

The historical general-purpose GitHub PAT is not reused: its GHCR authentication
preflight failed.

## Data/storage

- PostgreSQL is single-instance CNPG on `longhorn-bulk`.
- dbt staging/fact models are views; only the small overview mart is materialized.
- GitHub collection is bounded to the latest two pages every 30 minutes and uses
  per-repository watermarks, one-hour overlap and idempotent upserts rather than
  appending duplicates. Run evidence records inserted events, duplicates and
  errors.
- WAL is archived continuously and a weekly base backup is written to Hetzner Object Storage.
