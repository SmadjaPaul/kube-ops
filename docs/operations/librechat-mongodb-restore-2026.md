# LibreChat MongoDB isolated restore runbook — PLT-165

This runbook is dormant preparation. It is not an Argo resource and it does
not authorize an activation, a source PVC change, or a production restore.
Run it only after the LibreChat child Application is admitted and the operator
has an approved maintenance window for a disposable target namespace.

## Preconditions

- `personal-librechat` is `Synced/Healthy`, MongoDB is ready, and the private
  HTTPRoute is already proven at `RUNTIME` level.
- The test identities and their Authentik group membership are synthetic or
  explicitly approved test identities. No production conversation is used as
  a fixture.
- `velero` reports an available `BackupStorageLocation` and the
  `velero-daily-librechat` schedule exists. `Longhorn` is storage, not the
  backup authority.
- The operator records the UTC start time, source application revision,
  source namespace, source MongoDB StatefulSet UID, source PVC UID and the
  backup name/UID. Do not record Secret values.

## 1. Create a synthetic MongoDB fixture

Create one marker in a dedicated collection using an ephemeral operator pod or
the MongoDB pod with a `secretKeyRef`. The password must remain in the process
environment; it must never appear in shell history, command output, Git or
this evidence file.

The fixture is deliberately independent of LibreChat's private schema:

```javascript
db.plt165_restore_fixture.insertOne({
  fixtureId: "plt165-librechat-<UTC-ID>",
  payload: "synthetic-restore-sentinel",
  createdAt: ISODate("<UTC timestamp>")
})
```

Capture only the generated `fixtureId` and the resulting document count. Do
not capture connection strings, credentials or the full Secret object.

## 2. Produce and correlate an off-site backup

Use the repository's existing Velero path and an operator-approved one-off
backup. The backup must include the `librechat` namespace and filesystem
backup for the MongoDB PVC. Before continuing, verify all of the following:

1. `Backup.status.phase=Completed`.
2. The backup has a completed `PodVolumeBackup` for the MongoDB volume.
3. The backup's namespace and resource list include the MongoDB StatefulSet
   and its PVC; the source PVC UID matches the recorded UID.
4. The backup is stored in the configured off-site location and its TTL is
   visible. A schedule object by itself is not backup proof.

Record resource names, UIDs, phases and UTC timestamps only. Preserve the
source namespace and PVC; do not delete, scale, restart or reinitialize them.

## 3. Restore into an isolated namespace

Use a new, unique namespace such as
`librechat-restore-<UTC-ID>`, labelled
`plt165.smadja.dev/purpose=isolated-mongodb-restore` and
`backup.smadja.dev/restore-drill=true`. Apply a deny-all Cilium policy before
the restore is allowed to start. Permit only DNS and the operator's temporary
MongoDB probe; deny Gateway, Authentik, Agentgateway, Hindsight and all public
egress.

Restore with an explicit namespace mapping from `librechat` to the fresh
namespace. Restore only the MongoDB data path and the minimum objects needed
to start MongoDB. Do not restore or admit:

- `Application`, `ExternalSecret`, `HTTPRoute` or Authentik objects;
- LibreChat application Deployments or any model/API credential;
- source namespace objects outside the MongoDB StatefulSet, PVC and its
  non-sensitive configuration;
- any object that would create a Gateway, public route or cross-namespace
  access.

Before accepting the restore, inspect the generated object list and reject the
operation if a source namespace, source PVC, public route, ExternalSecret or
credential-bearing application workload would be recreated outside the
isolated namespace.

The restore target is disposable. Never delete or replace the source PVC to
make the target work, and never attach the restored volume to the source
namespace.

## 4. Prove the restored data and isolation

Wait for the restored MongoDB StatefulSet and PVC to become ready. Using the
same secret-ref pattern (without printing the value), query only the dedicated
fixture collection and assert:

- `fixtureId` exists exactly once;
- `payload` equals `synthetic-restore-sentinel`;
- the returned namespace, StatefulSet UID and PVC UID belong to the isolated
  target;
- no LibreChat, Authentik, Agentgateway or Hindsight endpoint is reachable
  from the target probe.

Record the target resource names, UIDs, readiness, fixture result and UTC
timestamps. A `Completed` Velero Restore without this data assertion is not a
restore proof.

## 5. Cleanup and acceptance

After evidence is exported, verify the source namespace and source PVC are
unchanged. Remove only the explicitly identified disposable restore namespace
and its restore-owned objects during the approved cleanup window. Re-run a
read-only inventory to confirm no restore residue remains and that the
original Velero backup, schedule, source PVC and off-site objects are still
present.

The acceptance record must contain the backup UID, PVB UID, source PVC UID,
target namespace, target PVC UID, fixture ID, restore phase, isolation probe
result and exact UTC timestamps. It must not contain passwords, tokens, Secret
data, kubeconfigs or connection strings.

Until this sequence has been executed against an admitted LibreChat backup,
MongoDB restore remains `not-executed`; the preparation package is not
`RUNTIME` or `USER` evidence.
