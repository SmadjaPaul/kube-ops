# Media V2 architecture decision — 2026-10-26

## Scope and decision

For a **hybrid** homelab (TorBox remote streaming by default, selected local
files only), keep the already deployed and nearly-qualified Arr automation
instead of replacing it with a new Riven/FUSE architecture. No custom media
bridge development is required as a production architecture choice.

| Goal | Existing component / target | Decision |
| --- | --- | --- |
| Family streaming | Stremio + AIOStreams + TorBox | Keep; direct client playback E2E still required |
| Film/TV/anime requests | Seerr + Sonarr + Radarr + Prowlarr | Keep active |
| Local downloads | Official RDT-Client + TorBox | Stage only; qualify before replacing Decypharr |
| Local playback | Jellyfin + media-share | Keep active |
| Music automation | Lidarr; Jellyfin for playback | Keep; qualify Lidarr/downloader contract separately |
| Music client | Eclipse | Optional client evaluation; no custom plugin/server |
| Ebooks/comics/manga/audiobooks | BookOrbit | Remains staged; CNPG/S3/OIDC/restore and qBit adapter gates remain |
| Retro games | RomM | Keep existing workload |
| Video virtual FS | Riven, Zurg, CatBox model | No Kubernetes FUSE / privileged mount in this pilot |

## Why this decision is reversible

Decypharr stays deployed and untouched while the RDT candidate remains
outside the active Kustomization. Sonarr/Radarr clients remain unchanged.
The staged Docker Hub image is not admitted until pinning, network-policy
hardening, authenticated canary, backup and E2E work are complete. Do not
delete Decypharr PVC, its queue, or its TorBox configuration as part of this
PR. Do not treat the custom Decypharr upstream PR as the desired long-term
runtime.

AIOStreams is already Ready and its OIDC discovery and deny-egress checks
passed, but its SQLite PVC currently lacks a qualified backup/restore.
That is an independent P0 and **must not** be marked protected by this PR.

## Kubernetes-specific operating constraints

- Existing media-share is a 2Ti Longhorn ReadWriteOnce volume. Local RDT
  downloads MUST use the same /data prefix as Arr, and leave existing files
  untouched. Validate the single-node attachment and full import path.
- Restrict downloads by quota/concurrency/retention; a TorBox video should
  only consume NAS storage when explicitly selected for retention.
- The broad media-access Cilium egress must NOT be inherited by RDT after
  admission. Stage a tested narrow policy and update its selector first.
- Official RDT-Client can support several Debrid providers, but changing
  from TorBox is unnecessary until an actual compatibility blocker is
  demonstrated.
- Treat provider API key, RDT credentials and Arr API keys as secrets.
  No value may enter Git, CI logs or Linear.
- Confirm security and capability requirements of the upstream s6
  container; keep UI private and require effective application auth.
- Backup RDT state before admitting it; separately protect AIOStreams
  SQLite and finish BookOrbit restore gates.

## Delivery gates

A: Static staged GitOps contract, no resources reconciled: THIS PR.
B: Official immutable image and isolated RDT + TorBox canary: NOT EXECUTED.
C: Auth/category/hash, file import, Jellyfin read, Lidarr and BookOrbit
   separate compatibility gates: NOT EXECUTED.
D: Cilium least privilege, monitoring and state restore: NOT EXECUTED.
E: Reversible active-root admission and production E2E: NOT EXECUTED.
F: Separate Decypharr retirement with PVC preservation policy: NOT EXECUTED.

Linear: PLT-118 (Media E2E), PLT-121 (AIOStreams), PLT-122
(BookOrbit/Decypharr). Only mark stages proven by the exact corresponding
STATIC / RECONCILED / RUNTIME / E2E evidence.
