# Invoice Ninja — Studio Lechaplais

Pinned upstream: Invoice Ninja 5.13.43 Debian image (immutable OCI digest),
MySQL 8.4, Redis and the upstream nginx-unprivileged runtime pattern.

Invoice Ninja ships an official Helm chart, but its current chart still tracks
an older application line and does not expose the repository's generic OIDC,
ESO and Gateway API contracts cleanly. This Kustomize wrapper therefore stays
thin and uses the current upstream Debian runtime directly. Re-evaluate the
chart when those gaps are upstream.

Authority:
- Invoice Ninja: clients, quotes, projects/timesheets, invoices and portal.
- D1: e-shop orders, immutable license agreements and entitlements.
- Stripe: payment.
- SuperPDP: French PA/e-invoice/e-reporting transport.
- PostHog: analytics/marketing/automated messages.
- Migadu: human mailbox and low-volume Invoice Ninja SMTP, currently deferred.
- Internal MCP: pinned MIT `DSS-AI/invoice-ninja-mcp`, reachable only from
  OpenClaw/Paperclip namespaces through `invoice-ninja-mcp:8539/mcp`.

The public Stripe webhook commits to D1 before any projection here. Never make
checkout availability depend on this namespace.

The MCP has no public HTTPRoute. It uses a dedicated Invoice Ninja API token plus
separate OpenClaw/Paperclip bearer tokens. Its instance policy starts with all
invoice creation/status/send/cancel capabilities disabled; agents can still read
business state and prepare bounded CRM/quote/project changes. Enabling invoice
mutations is a separate reviewed decision.

The upstream Debian image performs root-owned first-boot filesystem preparation;
the namespace therefore uses Pod Security Baseline rather than a custom image.

A daily `mysqldump --single-transaction` runs at 04:15 UTC into the existing
`invoice-ninja-storage` PVC. Velero runs at 04:35 UTC and therefore captures both
the application storage and the latest logical SQL dump without introducing a
second backup destination or long-lived backup credential.

Before real customer data, run a restore drill that proves both paths: restore
the namespace/PVCs with Velero, then validate that `logical-backups/mysql-latest.sql`
can rebuild the Invoice Ninja database into an empty MySQL instance.


## Mail bootstrap

Invoice Ninja intentionally starts with `MAIL_MAILER=log`. The Migadu domain is
not currently visible through the Migadu API, so SMTP is not a deployment
prerequisite and `APP_INVOICE_NINJA_MAIL_PASSWORD` is not part of the runtime
ExternalSecret.

When `lechaplais.com` becomes API-visible and the Terraform mailbox root has
applied successfully, enable SMTP in a separate reviewed PR. Do not make
Invoice Ninja availability depend on that external bootstrap.
