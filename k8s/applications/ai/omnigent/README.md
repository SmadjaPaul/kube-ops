# Omnigent

GitOps-owned autonomous software-factory control plane, pinned to the runtime
already proven in `home-ops`: Omnigent v0.14.0.

## kube-ops runtime shape

- GitOps: Argo CD;
- server: `ghcr.io/omnigent-ai/omnigent-server-kubernetes:v0.14.0`, one replica;
- database: dedicated single-instance CloudNativePG cluster;
- database and artifact persistence: `proxmox-csi`;
- database WAL/base backups: Barman Cloud plugin to Hetzner Object Storage;
- runtime secret delivery: External Secrets through
  `ClusterSecretStore/doppler-cluster`;
- auth: existing Authentik baseline at `omnigent.smadja.dev`;
- encrypted Credential Store: bounded OpenBao Transit only;
- managed sessions: Kubernetes Jobs in `omnigent-sandboxes`;
- runner ServiceAccount: no API token and no general Kubernetes RBAC;
- server sandbox RBAC: namespace-scoped only;
- config/secret rollouts: Stakater Reloader.

## Secret migration contract

Do not generate replacement values for an existing GitHub App or OIDC client
during the cluster rebuild. Reuse the values from the previous environment and
materialize the required names in Doppler `cluster/prd`.

The active ExternalSecrets require:

- `APP_OMNIGENT_OIDC_CLIENT_SECRET`;
- `APP_OMNIGENT_OIDC_COOKIE_SECRET`;
- `APP_OMNIGENT_GITHUB_APP_CLIENT_ID`;
- `APP_OMNIGENT_GITHUB_APP_CLIENT_SECRET`;
- `APP_OMNIGENT_GITHUB_APP_SLUG`;
- `APP_OMNIGENT_GITHUB_APP_REDIRECT_URI`;
- `APP_OMNIGENT_LITELLM_API_KEY`;
- `OPENBAO_SEAL_KEY`;
- shared Hetzner keys already required by the CNPG backup contract.

Never print secret values in migration evidence.

## Acceptance

Static rendering is necessary but not runtime acceptance. Before declaring the
port complete, prove:

1. Argo reconciles Omnigent, CNPG and OpenBao without degraded resources.
2. CNPG reports WAL archiving to the Omnigent Hetzner ObjectStore.
3. real-user Authentik OIDC login succeeds.
4. GitHub Connect still sees the expected GitHub App identity.
5. Omnigent launches a managed Kubernetes sandbox Job.
6. the Job can clone a private repository, create a branch, push it and open a PR.
7. the runner cannot read Kubernetes Secrets or mutate the HOME desired state.
8. changing `omnigent-config` or `omnigent-runtime` causes the expected
   Reloader rollout.

The Kubernetes migration is not a reason to upgrade Omnigent at the same time.
Upgrade v0.14.0 separately after this acceptance passes.
