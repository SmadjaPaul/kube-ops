# Decypharr V1 — staged pilot

This package is intentionally not referenced by the media root.

It follows the low-privilege pattern demonstrated by the MySweetPea reference:
Decypharr v2.5 (official GHCR image, pinned by digest) is configured with `mount.type=none` and `default_download_action=strm`.
That avoids FUSE, `SYS_ADMIN`, privileged pods and host mounts. The media-share
PVC is mounted only so STRM/library artifacts can share the existing media tree.

No Debrid provider is selected in Git. No API key exists in this package.

Activation gates:

1. choose a provider supported by Decypharr (Real-Debrid, TorBox, Debrid-Link,
   AllDebrid or Premiumize) or explicitly choose the built-in NNTP path;
2. create a provider-specific Doppler/ESO secret contract;
3. configure Radarr/Sonarr/Lidarr API tokens without committing them;
4. keep `download_uncached=false` for the first pilot;
5. test one legal/public-domain item end-to-end;
6. prove local media remains playable during a Debrid outage.

For this homelab Decypharr is an optional accelerator/gateway, not the source
of truth. Local storage + normal Usenet/torrent workflows remain the resilient
baseline until the pilot proves otherwise.
