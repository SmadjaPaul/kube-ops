# Factory Intelligence V3 — linked platform deployment

**Coordinated change:** this kube-ops PR depends on
`SmadjaPaul/factory-platform:feat/dp-mastra-otel-cube-v3-20261014`.

## Scope

- Internal-only Cube views for FactoryOverview, FactoryDelivery,
  FactoryTestQuality and sampled FactoryModelUsage. `factory_analytics`
  JWT role is required by the existing Cube `queryRewrite`.
- Alloy OTLP traces still reach Tempo. A second, private OTLP/HTTP JSON
  destination filters to Mastra/Agentgateway GenAI usage spans, removes
  unapproved attributes, and sends only diagnostics to Factory's authenticated
  `/v1/otlp/traces`. Logs stay in Loki, and native Prometheus metrics
  remain scraped as before.
- The receiver token is delivered to Alloy via ESO from the existing
  `APP_FACTORY_PLATFORM_INGEST_API_KEY` Doppler secret, not stored in Git.
- Remove Paperclip from the Factory GitHub collector repository list.
- Set `FACTORY_OTLP_TENANT_ID=smadja-internal` on the DP API; never read tenant
  identity from OTLP span tags or request headers.

## Gates before merge

1. Merge and publish both `factory-platform` API and dbt images at immutable
   digests. The existing kube-ops images **still run old code** until upgraded.
2. Verify source image / dbt compilation, schema tests, security and JWT.
3. Render Alloy chart 1.13.0 and validate new otelcol.filter/transform/otlphttp
   components with `alloy validate` before changing the live collector.
4. Confirm ESO sync in monitoring, Cilium egress/ingress to Factory,
   OTLP JSON content type, `compression=none`, and the bounded 200-span
   exporter batch. Test unauthorized, malformed and redacted traces.
5. Exercise one *real* Mastra model call in Tempo and the projected mart.
   A successful dbt-only trace is not sufficient evidence of GenAI usage.
6. Compare Cube metrics with SQL, prevent untrusted data access and verify
   delivery dimensions have unique event-based primary keys.
7. Measure single-node memory/CPU requests and Alloy exporter backlog.
   Disable/revert only the DP mirror if Factory is unavailable; Tempo should
   keep accepting the original trace stream.

## Exclusions

Do not treat the sampled `FactoryModelUsage` Cube as a ledger of all
requests or billed tokens. The accepted tasks and costs come from explicit
business events and the Agentgateway spend ledger. Growth marts and the DP
publication runner are intentionally preserved.
