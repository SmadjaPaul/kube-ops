# RomM V1

RomM is the active games-library workload for V1.

Architecture:

- RomM stable 5.2.0
- PostgreSQL via CloudNativePG
- CNPG/Barman WAL + weekly base backup to Hetzner Object Storage
- Longhorn bulk for the ROM library/resources
- Longhorn fast for saves/assets and embedded Valkey data
- Authentik native OIDC
- Gateway API on both internal and external gateways
- private ExternalDNS/UniFi for local-first access
- Velero/Kopia for non-database application volumes

## OIDC

Callback: `https://romm.smadja.dev/api/oauth/openid`

RomM 5.x requires a verified email claim. The Authentik blueprint intentionally provides a RomM-specific `email` mapping with `email_verified: true`.

Role mapping:
- `authentik-admins` -> RomM Admin
- `family` or `media` -> RomM User

Keep local password login enabled until at least one Authentik admin login is proven.

## Metadata

V1 enables Hasheous because it requires no API credential. Additional providers can be added later through Doppler without changing the storage/database architecture.

## Security note

The official 5.2.0 image currently runs as root by default. The namespace therefore audits/warns against Pod Security Restricted but does not enforce it yet. The container still drops Linux capabilities and disables privilege escalation. Do not force `runAsNonRoot` without validating a newer upstream image or a deliberate hardened derivative.
