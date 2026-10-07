# Business stack

The active business surface is deliberately narrow: **Invoice Ninja** is the
Studio Lechaplais operational back office for clients, quotes, projects,
timesheets and invoices.

The public `lechaplais.com` checkout remains Cloudflare/Stripe/D1/R2 owned and
must not synchronously depend on this cluster. Paid e-shop orders are projected
into Invoice Ninja asynchronously/best-effort and can be replayed.

Retired here: Listmonk, Twenty, Chatwoot, La Suite Messages, Stalwart and
Bulwark. Marketing/events belong to PostHog; human mail belongs to Migadu;
French e-invoice/e-reporting transport belongs to the external PA.

Invoice Ninja follows the upstream topology: Debian app + nginx, MySQL and
Redis. Do not replace its MySQL database with CNPG/PostgreSQL.
