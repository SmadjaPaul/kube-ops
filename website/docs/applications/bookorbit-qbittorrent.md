---
sidebar_position: 3
title: BookOrbit torrent client
description: Dedicated qBittorrent runtime, storage contract, and MAM activation gates
---

# BookOrbit torrent client

BookOrbit 3.9.0 uses a dedicated qBittorrent instance for torrent acquisitions. TorBox remains BookOrbit's client for other sources. The qBittorrent workload is reconciled by the existing `apps-media` Argo Application; it has its own Deployment, Service, policy, and configuration PVC in namespace `media`.

## Runtime contract

- Qualification uses the pinned qBittorrent 5.2.4 image for a legal public torrent. This is not MAM client approval.
- The WebUI/API is a `ClusterIP` Service at `http://qbittorrent-mam.media.svc.cluster.local:8080`. No Gateway route, Ingress, NodePort, or LoadBalancer is created.
- qBittorrent and BookOrbit run as UID/GID 2501 and mount the same `media-share` claim at `/data`. Downloads use `/data/torrents/books`; BookOrbit stages imports at `/data/book-dock` and reads the library at `/data/media/books`.
- An init container tests write access and hardlinks between those three paths before qBittorrent starts. It only creates and removes uniquely named probe files. It does not change ownership or permissions.
- qBittorrent's global ratio and time limits are unlimited. BookOrbit may set per-torrent goals; neither qBittorrent nor this deployment removes torrent data automatically. Config and fast-resume files are persisted on `longhorn-fast` and included in the daily offsite backup. The large shared media PVC stays excluded.
- Cilium allows BookOrbit and the node health probes to reach the WebUI. qBittorrent egress permits DNS and public tracker/peer destinations while excluding private and reserved IPv4 ranges. It has no inbound peer route and no MAM hostname allowance.

## MAM preparation and gate

The public plugin `orbit-plugins/bookorbit-plugins-extra` is pinned at commit `138644f62198d1a1dc335b427f3d8d1b894ad954`, installed from a read-only ConfigMap, and verified with its offline fixture suite. No MyAnonaMouse source, session credential, or MAM egress is configured.

The audited plugin source contains calls to `/tor/js/loadSearchJSONbasic.php`, `/tor/download.php`, `/t/`, `/jsonLoad.php`, and optionally `/json/dynamicSeedbox.php` on MyAnonaMouse hosts. The repository describes these as plugin behavior, but that source is not official MAM authorization. The integration stays unusable until the approved qBittorrent version and the plugin's allowed interfaces are confirmed.

## Rollback

Stop new BookOrbit grabs first. Keep qBittorrent running while any torrent still has a seeding obligation. Once those obligations finish, revert the Git change; Argo removes the Deployment, Service, and policy. The config PVC is protected from prune and deletion, and the shared media PVC is never removed by this rollback.
