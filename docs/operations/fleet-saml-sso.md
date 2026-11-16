# Fleet SAML SSO via Authentik (PLT-316)

Authentik is the SAML identity provider; Fleet is the service provider. Access is limited to the groups `admin` and
`authentik-admins` (policy bindings, `policy_engine_mode: any`).

## Declared in Git

| Item | Value |
|---|---|
| Blueprint | `k8s/infrastructure/auth/authentik/extra/blueprints/apps-fleet.yaml` (listed in `extra/kustomization.yml`) |
| Provider | `k8s.smadja.dev/identity/fleet`, ACS `https://fleet.smadja.dev/api/v1/fleet/sso/callback`, audience `https://fleet.smadja.dev` |
| Schema check | every provider field exists in the Authentik 2026.8.3 `blueprints/schema.json` (model `authentik_providers_saml.samlprovider`) |
| Metadata URL (Fleet side) | `https://auth.smadja.dev/application/saml/fleet/metadata/` |

## Fleet side (not in this repository's manifests)

Fleet stores SSO settings in its database. Apply them with GitOps Fleet (`fleetctl apply` of a `kind: config` document, settings under `spec`) or `PATCH /api/v1/fleet/config`, with an admin API token that never appears in Git or logs:

```yaml
apiVersion: v1
kind: config
spec:
  sso_settings:
    enable_sso: true
    entity_id: https://fleet.smadja.dev
    metadata_url: https://auth.smadja.dev/application/saml/fleet/metadata/
    idp_name: Authentik
    enable_jit_provisioning: false
```

Without JIT provisioning, a Fleet user with the same e-mail address must already exist before the first SAML login. That user must also have `sso_enabled: true`; a matching e-mail address alone is not sufficient.

## Verification levels

- STATIC/CI: schema check above, `kustomize build` of the auth tree.
- RECONCILED: Argo `infra-auth` Synced/Healthy and the application `fleet` visible in Authentik.
- RUNTIME/USER: SSO login with a member of `admin`, refusal for an account outside the groups. A password login on
  auth.smadja.dev is a human or browser-operator step, not an executor one.

## Rollback

1. In Fleet, set `enable_sso: false` first. The local Fleet admin account is untouched and keeps working at every step.
2. Revert the PR (removes the blueprint and its line in `extra/kustomization.yml`).
3. Removing a file-based blueprint only removes its blueprint instance: Authentik keeps the objects it created. Delete the
   application `fleet` and the provider `k8s.smadja.dev/identity/fleet` in the Authentik admin UI (the policy bindings go
   with the application).
