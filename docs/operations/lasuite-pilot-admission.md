# La Suite — Docs and Fichiers GitOps staging

STATUS: **SCAFFOLD ONLY — NOT DEPLOYABLE**. This directory is deliberately
outside the Argo ApplicationSet roots. The two Argo Applications also have no
automated sync policy. The pinned Git release tags reference upstream Helm
charts, with single-replica services and private Gateway API route candidates.

Source: https://github.com/suitenumerique/docs (v6.0.4)
Source: https://github.com/suitenumerique/drive (v0.25.3)

Required before adding this to a live root:
1. Pin verified OCI digests, check Helm render and test upgrade/migrations;
   perform Trivy, SBOM/provenance qualification.
2. Supply Authentik OIDC configuration and secrets via Doppler/ESO, test
   issuer, callback, SSO, cross-user access isolation and logout.
3. Deploy persistent PostgreSQL (Docs backend, Docs Yhub, Drive), and
   Valkey/Redis (Docs backend, Yhub and Drive). Yhub Redis can contain
   unsaved edits: test durable recovery and state consistency.
4. Provision separate Hetzner S3 buckets and scoped credentials as IaC in
   homelab-infra, plus robust CNPG Barman and stateful Redis backups.
5. Set all required upstream backend/envVars + frontend/yhub envVars from
   non-plaintext Secrets. Disable obsolete yProvider if the pinned chart
   supports that mode; do not assume defaults are production-safe.
6. Implement CiliumNetworkPolicy for each workload and dependencies, check
   correct Gateway HTTPS/WSS and host-based CSRF. Do not expose to the
   public Internet without a separate approved network review.
7. The staged routes omit the media proxy and preview auth/rewrite flows.
   Qualify signed S3 URLs, protected previews, uploads, CORS, and Docs Yhub
   external collaboration APIs before claiming functionality.
8. Qualify WOPI/Collabora separately: Office editing is NOT included in this
   candidate. Do not enable an unpinned or unscanned Collabora image.
9. Collabora CODE is now staged through the official Helm chart 1.3.7
   with CODE tag 26.04.5.2.1 and a single replica, but the WOPI trust
   relationship is NOT configured in Drive. The admin and RSA proof keys must
   be provisioned as separate Doppler secrets and their contents verified.
   Test restricted pod security, browser WebSockets, WOPI host allowlist,
   document editing and CSP. The example internal route includes /cool/adminws
   and /cool/getMetrics, so MUST NOT be admitted without an explicit Gateway
   deny/auth layer. Never attach it to Gateway/external as-is.
10. Verify the Docs ↔ Drive workflows, and a delegated Mastra OAuth token
   limited to a user or folder, including revocation and audit.
11. Restore from an independent backup, measure CPU/RAM/IO, and run the
    actual browser and mobile user journey before Argo admission.

No Factory, Longhorn cleanup, AIOStreams, Polyfin or live application roots
are modified here. The staged routes stay unreachable until admitted.
