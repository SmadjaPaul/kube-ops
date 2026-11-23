---
name: oidc-integration
description: Integrate or debug Authentik OIDC without confusing identity failures with DNS/TLS/backend failures.
---

# OIDC integration

Before OAuth debugging prove backend readiness, internal DNS, valid TLS and OIDC discovery from the application pod.
Then compare client ID, callback URI, grant type, scopes and required claims with current upstream documentation.
Keep local login until the first admin OIDC login is proven when the app supports that recovery path.
The client secret is generated in the cluster (class T3 of `docs/architecture/secrets-migration-spec.md`): `Password` generator + ExternalSecret `oidc-<namespace>` in `auth` (`CreatedOnce`, `Orphan`), read by the app namespace through ClusterSecretStore `k8s-auth` (copy `<app>-oidc`). The client id is a Git literal; nothing is created in Doppler.
Scaffold it with `bash scripts/scaffold-app-secrets.sh APP --namespace NS --oidc CLIENT_ID` (dry-run, then `--write`): source, Role `resourceNames`, Authentik `envFrom` (`optional: true`) and Reloader list, copy. The Authentik blueprint reads the key with `!Env <CLIENT_ID_UPPER>_OIDC_CLIENT_SECRET`.
Rotate by renaming the source ExternalSecret (`docs/operations/secrets-generated-runbook.md`); never read values.
An app already wired to a Doppler key (`APP_<APP>_OIDC_CLIENT_SECRET`) stays as is until it is modified for another reason; migrating it is a rotation.
