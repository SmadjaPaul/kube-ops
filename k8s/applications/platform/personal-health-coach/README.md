# Personal Health Coach (staged)

This is an independent, proposal-only Mastra runtime. It has no user route and
remains synthetic-only until the dedicated GHCR pull credential is provisioned.

The synthetic image is pinned by digest and has no HTTPRoute. It uses no
Factory identity, database, or write-capable connector. The runtime activation
requires only the dedicated `APP_PERSONAL_HEALTH_COACH_GHCR_TOKEN` Doppler key
with `read:packages` on this package. No secret values belong in this repository.
