# Invoice Ninja restore procedure

This is a human-gated drill procedure. It is intentionally written for an
isolated namespace and must not be run against `invoice-ninja` in place.

## Coverage contract

- Kubernetes objects and the four application PVCs are covered by the Velero
  schedule `velero-daily-invoice-ninja` at `04:35 UTC`.
- MySQL is additionally dumped by
  `invoice-ninja-mysql-logical-backup` at `04:15 UTC` into
  `invoice-ninja-storage/logical-backups/mysql-latest.sql`.
- The Velero run is intentionally after the logical dump so the dump is
  included in the off-cluster backup.

## Velero namespace restore

Choose a fresh drill namespace and the latest `Completed` backup. Do not use a
backup whose phase is `InProgress`, `PartiallyFailed`, or `Failed`.

```bash
DRILL_NS=invoice-ninja-restore-YYYYMMDD
BACKUP_NAME=velero-daily-invoice-ninja-YYYYMMDDHHMMSS

kubectl create namespace "$DRILL_NS"
velero restore create "invoice-ninja-restore-$(date -u +%Y%m%d%H%M%S)" \
  --from-backup "$BACKUP_NAME" \
  --namespace-mappings "invoice-ninja:$DRILL_NS" \
  --exclude-resources "secrets,externalsecrets.external-secrets.io,httproutes.gateway.networking.k8s.io" \
  --wait

kubectl -n "$DRILL_NS" wait --for=condition=available deployment/invoice-ninja --timeout=10m
kubectl -n "$DRILL_NS" wait --for=condition=ready pod -l app.kubernetes.io/name=invoice-ninja-mysql --timeout=10m
kubectl -n "$DRILL_NS" wait --for=condition=ready pod -l app.kubernetes.io/name=invoice-ninja-redis --timeout=10m
```

Secrets and ExternalSecrets are excluded deliberately: use drill-only,
Secret-backed credentials if the restored application needs to start. The
HTTPRoute is excluded deliberately so it cannot attach to either Gateway.
Validate the restored objects, PVCs, and pod readiness locally; do not publish
a second DNS record or expose the drill namespace.

## Logical SQL validation

The logical dump is on the restored `invoice-ninja-storage` PVC, mounted by the
restored application at `/var/www/html/storage`. Copy only that artifact to a
disposable MySQL check workload in the drill namespace, import it there, and
run a schema/table-count check. Supply the disposable workload's password
interactively or from its Secret-backed environment; do not print it.

```bash
APP_POD="$(kubectl -n "$DRILL_NS" get pod \
  -l app.kubernetes.io/name=invoice-ninja \
  -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$DRILL_NS" cp \
  "$APP_POD:/var/www/html/storage/logical-backups/mysql-latest.sql" \
  ./invoice-ninja-mysql-latest.sql

# The disposable MySQL check workload must be created by the drill harness
# with a Secret-backed MYSQL_ROOT_PASSWORD and a /restore mount.
kubectl -n "$DRILL_NS" cp ./invoice-ninja-mysql-latest.sql \
  invoice-ninja-mysql-restore-check-0:/restore/mysql-latest.sql
kubectl -n "$DRILL_NS" exec statefulset/invoice-ninja-mysql-restore-check -- \
  sh -c 'MYSQL_PWD="$(cat /run/secrets/mysql-root-password)" mysql -h 127.0.0.1 -uroot ninja < /restore/mysql-latest.sql'
```

Acceptance requires: the SQL file is non-empty, import exits zero, the
expected Invoice Ninja schema exists, and the restored application can reach
the imported database. Remove the isolated namespace and local SQL artifact
only after recording the drill result and obtaining the normal operator
approval for cleanup.

## Human action for the blocked MCP

The only missing Doppler key observed for this application is
`APP_INVOICE_NINJA_API_TOKEN`. Create it with the value issued by Invoice
Ninja; never commit or print that value:

```bash
read -r -s APP_INVOICE_NINJA_API_TOKEN
printf '\\n'
printf '%s' "$APP_INVOICE_NINJA_API_TOKEN" | doppler secrets set \
  APP_INVOICE_NINJA_API_TOKEN \
  --project infrastructure --config prd
unset APP_INVOICE_NINJA_API_TOKEN
```

After ESO reports `Ready=True`, the MCP Deployment should become eligible for
normal reconciliation. OIDC login and a real user action remain separate
browser-gated acceptance tests.
