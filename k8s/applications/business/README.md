# Business stack

This directory keeps the post-V1 business applications close to the Kubernetes
desired state while separating **present in Git** from **enabled in the Argo root**.

## Active now

- Listmonk: single replica, CNPG, Proxmox CSI uploads, Hetzner CNPG backup.

## Staged

- Stalwart + Bulwark: wait for the declarative Stalwart bootstrap and mail-edge
  contract. Migadu remains the external SMTP provider during bootstrap.
- Twenty: CNPG + lean Redis + Proxmox CSI, capacity-gated.
- Chatwoot: official Helm chart with CNPG + lean Redis + Migadu SMTP,
  capacity-gated.
- La Suite Messages: v0.9.0 production backend/frontend, CNPG + lean Redis +
  Hetzner application S3, Authentik as generic OIDC provider and Migadu as
  outbound SMTP relay. OpenSearch, inbound MTA and Rspamd are intentionally
  deferred.

## Messages activation contract

Before uncommenting `messages` in the business root:

1. Hetzner buckets exist:
   - `smadja-dev-messages-media`
   - `smadja-dev-messages-imports`
   - `smadja-dev-messages-blobs`
2. `cluster/prd` contains the required secret names:
   - `APP_MESSAGES_DJANGO_SECRET_KEY`
   - `APP_MESSAGES_OIDC_CLIENT_SECRET`
   - `APP_MESSAGES_MDA_API_SECRET`
   - `APP_MESSAGES_SALT_KEY`
   - existing `HETZNER_S3_*` and `MIGADU_SMTP_*` keys.
3. The existing Authentik baseline exposes a confidential `messages` OIDC
   client with callbacks:
   - `https://messages.smadja.dev/api/v1.0/callback/`
   - `https://messages.smadja.dev/api/v1.0/logout-callback/`
4. Create the intended Messages `MailDomain` with `oidc_autojoin=true`.
   Do not automatically create domains from every Authentik user email domain.
5. Run the migration hook and prove one OIDC login + outbound relay before
   enabling inbound SMTP/search.

## Capacity rule

The target Talos VM is 6 vCPU / 32 GiB. Enable staged workloads one at a time
after observing memory, CPU, PostgreSQL and PVC pressure.
