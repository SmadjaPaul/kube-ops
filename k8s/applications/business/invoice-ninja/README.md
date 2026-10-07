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
- Migadu: human mailbox and low-volume Invoice Ninja SMTP.

The public Stripe webhook commits to D1 before any projection here. Never make
checkout availability depend on this namespace.

The upstream Debian image performs root-owned first-boot filesystem preparation;
the namespace therefore uses Pod Security Baseline rather than a custom image.

Before real customer data, run a restore drill that validates MySQL application
consistency in addition to volume recovery.
