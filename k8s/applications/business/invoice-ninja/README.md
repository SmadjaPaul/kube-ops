# Invoice Ninja — Studio Lechaplais

Pinned upstream: Invoice Ninja 5.13.43 Debian image, MySQL 8.4, Redis and the
upstream nginx-unprivileged runtime pattern.

Invoice Ninja now ships an official Helm chart. This Kustomize wrapper stays
intentionally thin because the current upstream chart does not expose the
generic OIDC environment or the repository's ESO/Gateway API integration
without post-render patches. Re-evaluate the chart when those extension points
are upstream.

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
