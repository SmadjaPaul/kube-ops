# RDT-Client official: staged hybrid media bridge (PLT-118)

Status: **STATIC STAGING ONLY**. This directory is deliberately NOT referenced
by the active media Kustomization. No Service, Pod, PVC or route is created in
the live cluster by merging this change.

Purpose: replace the custom Decypharr dependency for **selected local
downloads only**, using the upstream RDT-Client qBittorrent-compatible API,
TorBox and existing Sonarr/Radarr (Lidarr requires separate verification).
This does not replace AIOStreams/Stremio's remote playback path.

## Contract

- Official Docker Hub image: rogerfar/rdtclient:2.0.143. The reference is
  intentionally tag-only in this dormant candidate. Admission MUST resolve
  and pin the immutable registry multiarch digest, scan both architectures
  and verify image compatibility before importing the root.
- Upstream image uses s6 startup and PUID/PGID=2501. An isolated canary must
  qualify root-to-user drop, startup, persistence and capability minimization.
- Persistent application DB: rdt-client-state Longhorn PVC, mounted /data/db.
- Shared media: existing media-share Longhorn PVC, mounted /data. This is
  intentionally the SAME absolute root path exposed to Arr by its
  media-patch.yaml. Configure the RDT-Client local download directory to
  /data/downloads/rdt-client. Verify paths actually reported to Arr match the
  final files before disabling remote path mappings.
- SKIP_CHOWN=true avoids recursively changing the 2Ti media-share permissions.
  The init container changes only the root of the dedicated DB mount.
  Validate UID/GID 2501 write access in both locations without mutating
  existing library files.
- Only a private ClusterIP Service on TCP/6500 is staged, with NO HTTPRoute.
  Before any admission, prove authenticated local management/qBittorrent API
  behavior, and use an authorized temporary port-forward or a private
  authenticated management route.
- No TorBox credentials are embedded or borrowed from Decypharr here.
  Establish a supported managed-secret/bootstrap flow only after qualifying
  the official app's provider-key storage and runtime authentication.
- Important: the existing global media-access Cilium policy selects every
  Media Pod except AIOStreams and broadly allows egress 443. A live RDT Pod
  would inherit that rule. Before admission, explicitly exclude rdt-client
  from that selector and add separately qualified ingress and egress policies
  scoped to the required TorBox API/CDN FQDNs, DNS and Arr peers. Do NOT open
  world:443 or assume the API endpoint alone covers file downloads.
- In Kubernetes, a ReadWriteOnce claim can be mounted by multiple Pods only
  when the CSI driver and scheduling permit attachment on the same node.
  Confirm both applications see the same files on the single Talos node,
  including after an isolated Pod restart.

## Acceptance, before production mutation

1. Static Kustomize build of this directory and schema/security review.
2. Pin upstream release by immutable index digest; obtain supply-chain
   evidence and check image scan results (amd64 and arm64 as applicable).
3. Validate an isolated, authenticated RDT instance with dedicated empty
   state and a disposable authorized fixture; do not connect to the real
   queue or reuse Sonarr/Radarr production API tokens.
4. Prove TorBox configuration, API qBittorrent login, categories and per-hash
   isolation. A missing hash MUST NOT change unrelated downloads.
5. Prove accurate paths: RDT /data/downloads/rdt-client -> Arr identical
   absolute path -> Jellyfin local media-share. Confirm real file bytes,
   complete import and authorized playback, not merely an API 200.
6. Repeat with Radarr, then test Lidarr independently if it is needed.
   BookOrbit's category-less qBittorrent login is a separate qualification
   gate; staged BookOrbit stays inactive until compatible.
7. Measure idle and active CPU/RSS/IO with Prometheus and compare with the
   existing Decypharr runtime. Verify download concurrency, disk quota and
   retention to prevent filling the NAS.
8. Design Cilium exclusions and least-privilege policy; verify positive
   TorBox/Arr connectivity and negative unauthorized Internet destinations.
9. Qualify Velero/Kopia or Longhorn offsite backup of rdt-client-state and
   a successful isolated DB restore, plus restart/recovery without queue loss.
10. Only then create an admission PR adding rdt-client to the active media
    root, repoint Arr clients with a reversible configuration, and retire
    Decypharr in a **separate** PR once production E2E passes. Preserve all
    PVCs, download data and BookOrbit staging during the transition.

## Deliberately out of scope

No Riven/FUSE/Zurg, no replacement of working Arr applications, no
new external ingress, no new download sources or live downloads, no
decommission and no changes to AIOStreams egress/backup or BookOrbit CNPG.
The other agent's GHCR publication of Decypharr is independent, not a
prerequisite for this staged official-client pilot.

References:
- https://github.com/rogerfar/rdt-client
- https://github.com/rogerfar/rdt-client/blob/main/README-DOCKER.md
- https://support.torbox.app/en/articles/10167535-how-to-setup-rdtclient-with-torbox-docker
