---
title: Post-V1 application catalogue
description: Coverage map between the canonical home-ops catalogue and kube-ops.
---

# Post-V1 application catalogue

Source catalogue: `SmadjaPaul/home-ops/docs/platform/application-catalog.md`.

This document is a coverage map, not an instruction to deploy every listed service at once.

## Covered in kube-ops

| Domain | Applications |
|---|---|
| Personal/media | Immich, Jellyfin, Audiobookshelf |
| Life | Home Assistant; Frigate manifests retained but disabled |
| Productivity | Karakeep |
| AI | Open WebUI, LiteLLM, Qdrant, OpenCode, OpenClaw, GPT Researcher, Pocket-TTS, Whisper ASR, Omnigent |
| Data | PostgreSQL via CloudNativePG |
| Tools | IT-Tools |
| Additional upstream apps | Arr stack, Jellyseerr, SABnzbd, Pinepods, Kiwix, Trilium, Babybuddy, Perplexica |

## Catalogue gaps

| Domain | Not yet covered |
|---|---|
| Personal cloud | oCIS, Paperless-ngx, Vaultwarden, Roundcube |
| Media | Navidrome, Calibre-Web Automated, RomM |
| Life | SparkyFitness, Mealie, Actual Budget, Dawarich |
| Productivity | Vikunja, Memos, Outline, FreshRSS |
| Dev | Woodpecker CI, Harbor, Coder; Forgejo remains N100/external rather than a kube-ops app |
| Creation | Penpot, WordPress, Postiz |
| Data | Airflow 3, Garage S3, DuckDB, dbt, Metabase |
| Tools | SearXNG, Stirling PDF, PairDrop, ntfy, Changedetection.io |

Renovate is a repository automation concern rather than a long-running application and should be evaluated separately from this runtime list.

## La Suite gap

The previous `home-ops` repository already contains architectural/runtime work for:

- Docs;
- Transfers;
- Drive;
- Meet.

Those are not yet carried into `kube-ops`. The recommended order remains Docs first, then Transfers/Drive, with Meet separate because LiveKit/TURN/UDP changes the network contract.

## Business stack

The business expansion is tracked separately from the general catalogue because it introduces mail/customer-facing infrastructure:

### Wave 1 — low-footprint

- Stalwart;
- Bulwark Webmail;
- Listmonk.

### Wave 2 — capacity-gated

- Twenty CRM;
- Chatwoot;
- La Suite Messages.

### External mail delivery

- Migadu remains the current SMTP provider during bootstrap.
- Amazon SES is an external-infrastructure option for outbound delivery and belongs in `homelab-infra`, not in Kubernetes.
- TMail Web is not selected as the primary webmail: Bulwark is the preferred Stalwart-native JMAP client. The existing TMail/JMAP manifests may remain reference-only until a concrete compatibility need appears.

## Capacity rule

The single Talos VM starts at 6 vCPU / 32 GiB. Do not activate all Wave 2 workloads merely because manifests exist. Observe memory, CPU, PostgreSQL and storage pressure after Wave 1 + Omnigent, then activate Wave 2 one application at a time.

## Hardware-bound deferrals

Zigbee2MQTT and Matter Server remain disabled until their Smadja-specific coordinator/BLE bindings are known. The upstream `10.0.10.160` coordinator and `10.25.150.x` load-balancer addresses are not valid local defaults.

## Edge binding

The upstream Cilium `10.25.150.x` LB pool is disabled. A small free range on the Servers VLAN must be proven from live UniFi/DHCP evidence before Cloudflared/L2 exposure is activated.
