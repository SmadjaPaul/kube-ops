# Recyclarr V1 — staged

This package is intentionally not referenced by the media root yet.

It tracks Recyclarr 8.7.2 and vendors the official v8 French MULTi.VF 1080p
TRaSH templates for Radarr and Sonarr. The CronJob is also `suspend: true`
so activating the package alone cannot mutate Arr quality profiles.

Activation gates:

1. bootstrap the existing Radarr and Sonarr API keys into Doppler `cluster/prd`
   as `APP_RADARR_API_KEY` and `APP_SONARR_API_KEY`;
2. verify `recyclarr-arr-api` becomes Ready;
3. run a manual `recyclarr sync --preview` Job and review the diff;
4. run one real sync;
5. only then set `suspend: false`.

The chosen profile is French MULTi.VF HD Bluray + WEB 1080p. It avoids a
default 4K/remux policy that would multiply household storage consumption.
