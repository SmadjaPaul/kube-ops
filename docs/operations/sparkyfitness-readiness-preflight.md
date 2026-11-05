# SparkyFitness — read-only admission report (PLT-138)

Existing v1.11 candidate: `k8s/optional/sparkyfitness`, still **dormant**.

This small helper surfaces which dependencies are manifest contracts and
which statuses are actually observable. It will **never** deploy, sync,
fetch Kubernetes Secret values, read secret values from Doppler,
create accounts, or run backups. A Kubernetes status is never treated as
a valid S3 isolation test, OIDC login or restore receipt.

Run from the repository root:

```sh
python3 scripts/sparkyfitness-readiness.py
python3 -m unittest discover -s scripts -p 'test_sparkyfitness_readiness.py'
# Optional, only after the canonical read-only kube-access bootstrap:
python3 scripts/sparkyfitness-readiness.py --runtime
```

The default check validates only names, stage wiring and selected
critical constraints. The optional runtime probe performs
`kubectl get ... -o json` exclusively for the **allowlisted**
Argo Application, CNPG Cluster, four ExternalSecrets, Barman
ObjectStore and ScheduledBackup in `wellness`/`argocd`.
It prints only status verdicts, never raw JSON, key values, identity
tokens or diagnostic stderr from Kubernetes. Missing RBAC or objects
are `BLOCKED`, not negative assertions about user accounts.

**Passing all these checks is insufficient to import the Argo Application.**
The separate admission gates remain:

- Confirm actual Doppler key-name presence, values only within
  the authorized runtime environment; never echo them.
- Prove independent Hetzner S3 credentials and a denied cross-prefix
  write/read (including CNPG Barman permissions).
- Prove CNPG bootstrap managed role `sparky_admin` and restricted
  `sparky_app` plus two-user RLS denial; qualified migrations.
- Prove a local first administrator and user preprovisioning without
  enabling anonymous signup. Upstream v1.11
  `disableSignup=true` blocks new SSO users, too.
- Perform real CNPG and PVC isolated restores before any family
  promotion; then user workout + food + history.
- Capture CPU, RAM and disk I/O from the actual workload.

Do not confuse `ScheduledBackup` existence with a completed backup
or successful restore. See `docs/operations/sparkyfitness-v111-admission.md`.
