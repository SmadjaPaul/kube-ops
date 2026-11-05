# RustiCal: fully isolated SQLite/Velero restore drill (PLT-137)

**Stage only. Not imported into any active GitOps root.**
This is a **synthetic** test fixture, not a production deployment and not
evidence of a completed Kubernetes/Velero restore. No real calendar,
contact, user, OIDC client, secret, PVC, production namespace, Argo
Application or HTTPRoute is used or altered by this package.

## Security boundary

- `source/`: new namespace `rustical-restore-source`, an isolated
  1Gi Longhorn-fast claim, pinned RustiCal v0.18.0 image, local SQLite
  database and **local-only** synthetic user accounts. No Authentik,
  Doppler, Gateway, public route or cluster-wide service account.
- `target/`: **only** the isolated namespace and Cilium policy.
  There is deliberately no target PVC or Deployment initially.
- `target-reader/`: isolated reader Deployment/Service and policy,
  but no PVC creation. Use only **after** Velero actually restored
  `rustical-restore-fixture-data` into the target namespace.
- Pod network: only allows inbound `rustical-restore-probe:4000`
  **from within the same namespace**; no explicit outbound egress.
  Validate Cilium endpoint enforcement before adding test records.
- Never import `source`, `target` or `target-reader` into the
  active ApplicationSet. Promotion is an independent reviewed PR.
- Test may consume PVC capacity; measure resource use and remove
  exclusively these synthetic targets after explicit operator approval.

The upstream exact v0.18.0 config accepts
`RUSTICAL_DATA_STORE__SQLITE__DB_URL=/var/lib/rustical/db.sqlite3`.
RustiCal enforces WAL (`crates/store_sqlite/src/lib.rs`). A copy of
the `.db` alone is **not** a backup.

## Static qualification only

```sh
kustomize build k8s/optional/rustical-restore-drill/source
kustomize build k8s/optional/rustical-restore-drill/target
kustomize build k8s/optional/rustical-restore-drill/target-reader
node --test scripts/rustical-restore-drill-contract.test.mjs
python3 scripts/rustical-sqlite-wal-synthetic.py
```

Expected: source has **one** PVC+Deployment+Service+CNP+Namespace
in `rustical-restore-source`; target **only** Namespace+CNP;
target-reader Deployment+Service+CNP+Namespace but **no** PVC.
None may render an HTTPRoute, ESO, Secret, ClusterRole or
namespaced resource in the production `rustical`/`rustical-pilot`.

## Runtime drill — only with explicit operator authority

1. Revalidate `main`, current Argo, Longhorn and Velero capacity.
   Authorize an isolated, time-bounded synthetic drill and an explicit
   cleanup scope. No blind `kubectl apply -k` to production.
2. Admit `source` in the temporary namespace via the standard
   reviewed GitOps workflow (dedicated non-automated Application, no
   root import or prune). Verify PVC Bound, Pod Ready, CNP Valid.
3. Create **only** two synthetic local principals using upstream
   `rustical principals create <id> --password`; feed unique
   temporary passwords via stdin from protected file descriptors.
   Never use `--for-testing-password-from-arg`, environment credentials
   in shell history, or publish the passwords. Do not use real SSO.
4. From a scoped probe, create a calendar event and a vCard belonging
   to each synthetic principal using the actual CalDAV/CardDAV
   endpoints; record opaque IDs/checksums, not contact contents.
   Verify user B cannot fetch A's resources.
5. Ensure **write quiescence / consistent SQLite backup** during
   Velero/Kopia (an online snapshot via SQLite backup API, or a proven
   quiesce/checkpoint with stable WAL). Confirm Velero **backup,
   PodVolumeBackup and snapshot data** actually succeeded, not merely
   the Backup CR reporting Completed. Confirm the source is synthetic
   by namespace, Pod UID and PVC UID. Do not use a live family backup.
6. Prepare `target/` only in `rustical-restore-target`; perform
   a namespace-mapped Velero restore using the **exact synthetic backup**
   and inspect PodVolumeRestore/volume mappings. Avoid carrying
   production Argo tracking/ownerRefs/hostnames into the target.
   Do not precreate the target PVC or read a restored PV by guessing.
7. Only after proof of restored PVC contents and no source PVC
   reference, admit `target-reader/`. Restart/read through real DAV
   APIs and verify both synthetic calendar/contact checksums plus
   cross-user access denied.
8. Record RPO, backup and restore time, pod CPU/RAM/I/O,
   `sqlite quick_check`, filesystem/PVR results and negative tests.
   Restore test MUST fail closed on missing PVR, WAL inconsistency,
   namespace mapping surprises or errors.
9. Close temporary pilot by an authorized scoped cleanup after
   backup evidence is safely retained; never delete any production
   PVC, secret or backup. Only THEN propose a separate persistent
   RustiCal production promotion PR.

**Important:** For Velero with Kopia/file-system backup, the exact
pod-volume restore workflow varies by plugin and version: do **not**
assume `--include-resources pvc` alone restores the file bytes.
Inspect effective backup/restore volume attachments and PVRs. No
script in this repo initiates a Velero backup or restore.

See `docs/operations/rustical-sqlite-wal-restore-qualification.md`
and `scripts/rustical-sqlite-wal-synthetic.py`.
