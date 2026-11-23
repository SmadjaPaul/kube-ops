# Oracle cluster (`oracle-a1`, OKE)

Own Argo CD on this repository (D-2026-11-21-01, one Argo CD per cluster, same descriptor contract as the
homelab, `docs/operations/argo-app-descriptor.md`). Pull mode: the homelab holds no credential of this
cluster and nothing here routes to the LAN. The cluster was recreated empty on 2026-11-21: OKE BASIC,
one arm64 A1 node (2 OCPU, 12 GB), CNI `OCI_VCN_IP_NATIVE`, pods `10.248.0.0/16`, services
`10.249.0.0/16`, private API, no LoadBalancer allowed.

## Layout

| Path | Role |
| --- | --- |
| `bootstrap/` | Operator bootstrap, never synced: Argo CD (chart 10.3.3, v3.5.1, ApplicationSet controller on, no dex, no notifications), project `bootstrap`, Application `root`. |
| `argocd-root/` | What `root` reconciles: projects `infrastructure` and `apps`, ApplicationSet `infrastructure` (explicit folder list, Applications `infra-<folder>`), ApplicationSet `apps` (reads `k8s/applications/*/*/argocd-app.oracle-a1.yaml`, Applications `app-<name>`). |
| `guardrails/` | Baseline: ValidatingAdmissionPolicy denying `Service type: LoadBalancer` (PLT-260, Always Free), and `baseline-pod-hardening` (PLT-405, from #1620): no privileged container, hostNetwork, hostPID, hostIPC or hostPath, including ephemeral containers. Exempt namespaces (binding `NotIn`): `kube-system` (Cilium, CSI, kube-proxy) and `netbird` (hostPath `/var/lib/netbird-router`). Another exemption is a reviewed PR on this binding. |
| `agent-operator/` | Read-only agent identity (ServiceAccount, RBAC without Secret data). |
| `external-secrets/` | External Secrets Operator (base `k8s/infrastructure/controllers/external-secrets`) with only the ClusterSecretStore `doppler-cluster`. The overlay removes what OKE cannot run: PrometheusRule and ServiceMonitors (no Prometheus Operator CRD), stores `k8s-auth` and `k8s-databases`. The base is untouched (homelab render identical). |
| `netbird-router/` | NetBird routing peer `oke-oracle-a1-router` (namespace `netbird`, PSA `privileged`, needs NET_ADMIN/SYS_ADMIN/SYS_RESOURCE) : admin and agent path to the private API (PLT-256). Setup key from ExternalSecret `NETBIRD_SETUP_KEY_OKE` via `doppler-cluster`. Image `netbirdio/netbird:0.83.0` has a `linux/arm64` manifest. |
| `observability/` | Export to Grafana Cloud (PLT-306): Alloy + kube-state-metrics, label `cluster="oracle-a1"`, no local storage. Secret `alloy-grafana-cloud` from `doppler-cluster`. Revived for `scripts/verify-delivery.sh` (PLT-407). |
| `cilium/` | Cilium 1.20.5 in CNI chaining on the OCI VCN-native CNI (PLT-384, [Cilium OKE guide](https://docs.cilium.io/en/stable/installation/cni-chaining-oracle-oke/)): `cni.chainingTarget=oci`, `cni.exclusive=false`, native routing, no masquerade, kube-proxy kept, IPAM `cluster-pool` on `100.64.0.0/16` (internal to Cilium; pod IPs still come from the VCN). It only enforces policies (NetworkPolicy, CNP, CCNP). Hubble server in the agent only (no relay, UI or TLS). |
| `baseline/` | Network baseline (PLT-384): CCNP `deny-imds` (169.254.169.254 on 80/443 denied for every pod; 53 stays open, it is the VCN resolver) with its pair `allow-egress-unisolated` (allow-all egress except namespaces labelled `platform.smadja.dev/egress-isolated=true`), default-deny of the app namespace `whoami`, quotas and LimitRanges, and the CronJob `baseline-probe` (every 15 min, an unprivileged pod checks IMDS refused and whoami reachable; last log line `BASELINE_PROBE=PASS`). Check: `bash tests/oke-baseline/acceptance.sh` (read-only). |
| `arc-controller/`, `arc-runner/` | Post-merge independent of the homelab (PLT-407). Controller `gha-runner-scale-set-controller` 0.15.0 in `arc-systems`; scale set `kube-ops-oke-arc` (0..1 ephemeral arm64 runner, namespace `arc-runners-oke`, label egress-isolated, closed egress list in `egress-policy.yaml`). The runner's identity is ServiceAccount `kube-ops-post-merge-oke` (read-only RBAC, one named Secret `ntfy-publish-url`); the GitHub App credentials and the ntfy URL come from `doppler-cluster`. Job `verify-oke` of `.github/workflows/post-merge-verify.yaml` runs `scripts/post-merge-verify.sh --only-cluster oracle-a1` there (`KUBECTL_RO_IN_CLUSTER_CLUSTER=oracle-a1`): Argo revision, `app-test --phase runtime`, ntfy on NOTIFY, never a revert. The homelab runner verifies homelab apps only. |
| `cert-manager/`, `cnpg-operator/`, `cnpg-barman-plugin/` | Shared PostgreSQL stack (PLT-408): CloudNativePG operator (chart 0.28.2), barman-cloud plugin v0.11.0 (WAL archive and base backups to R2), cert-manager v1.21.3 only for the plugin's self-signed gRPC TLS (no ACME issuer). Versions track the homelab base; all images publish `linux/arm64`. |
| `cnpg-cluster/` | `Cluster pg-shared` (namespace `databases`, 1 instance, PostgreSQL 17.7 pinned by multi-arch index digest, PVC `oci-bv` 50Gi = OCI minimum; boot 50 GB + this volume stay within the 200 GB Free Tier). WAL archive and daily base backup (`ScheduledBackup pg-shared-daily`, 03:50 UTC) to R2 `homelab-backup-cnpg/oracle-a1/pg-shared-v2/` (writer identity via `doppler-cluster`). `serverName pg-shared-v2` because the archive of the cluster destroyed on 21/11 still occupies `oracle-a1/pg-shared/`. The off-Oracle restore is PROVEN (PLT-408 drill, 22/11); the drill imports are removed. |
| other folders | Legacy overlays (Flannel era: `hindsight`, `media`, `cloudflared`). Reconciled by nothing; stale. Revive one only by adding it to the `infrastructure` ApplicationSet list (and its namespaces to the `apps` project negations) after review, never silently. |

## Bootstrap (once, by Paul or an agent holding an admin kubeconfig)

The API is private: open the OCI Bastion (break-glass) or NetBird path first. Then, from this repository:

```
bash scripts/oke-bootstrap.sh --kubeconfig <admin-kubeconfig> --dry-run   # render only, no API call
bash scripts/oke-bootstrap.sh --kubeconfig <admin-kubeconfig>
```

(`just oke-bootstrap --kubeconfig <file>` is the same.) The script renders `bootstrap/`, applies
namespace, CRDs and Argo CD, waits for the CRDs, applies project `bootstrap` and `root`, waits for the
workloads and lists the Argo objects. Idempotent (server-side apply), it never reads or prints a Secret.
Afterwards `root` pulls `argocd-root/` from `main` and `infra-guardrails`, `infra-agent-operator` and
`infra-external-secrets` must become Synced/Healthy. Order: Argo CD, ESO, the Doppler token Secret
(gesture below), then `infra-netbird-router` (it retries until the store is Ready; ESO objects use
sync-wave 0, the store wave 1) and the NetBird peer appears in group `OKE Routers`.
Nothing is committed that needs the cluster: merge to `main` first, the Argo CD reads `main`.

### One-off gesture by Paul: Doppler token for External Secrets

`infra-external-secrets` syncs without it, but the store `doppler-cluster` stays not Ready, so
`netbird-router` (and any later ExternalSecret) gets no secret until the Secret
`doppler-access-token` exists in `external-secrets`. It is not in Git. Once the namespace exists
(created by the Application), create it from a read-only Doppler token of the config that
`doppler-cluster` serves. The store sets no project: the token decides, and that is `oke/prd`
(PLT-258: the dedicated config `oke/prd`, only the keys OKE consumes as references to `cluster/prd`, created by `scripts/doppler-oke-config.sh` in homelab-infra; the previous token `oracle-a1-eso-20261115` read all of `cluster/prd` and is revoked once `doppler-cluster` is Ready on the new one). Run it where `kubectl` reaches
the API (NetBird or Bastion) and `doppler` is logged in as Paul; the value goes through a pipe,
never to the terminal or a file; the Secret key must be exactly `token`:

```
doppler configs tokens create oracle-a1-eso-oke --project oke --config prd --access read --plain \
  | tr -d '\n' \
  | kubectl --kubeconfig <admin-kubeconfig> -n external-secrets create secret generic doppler-access-token \
      --from-file=token=/dev/stdin
```

Check without reading the value: `kubectl -n external-secrets get clustersecretstore doppler-cluster`
shows `Valid` / `Ready`, then `kubectl -n netbird get externalsecret netbird-router-setup-key`.

Prerequisite in homelab-infra (not here): `terraform/netbird` writes `NETBIRD_SETUP_KEY_OKE` to
Doppler `infrastructure/prd` by default (`doppler_project`), not to `cluster/prd`. The ExternalSecret
reads `cluster/prd`, so the key must exist there (set `doppler_project = "cluster"` for that
secret, or copy it); never widen the OKE token to `infrastructure/prd`, which holds operator
credentials. The same root creates the setup key bound to the NetBird group `OKE Routers` (one-off,
`auto_groups`), which is how the pod joins that group; the key must be unused and unexpired when the
pod first starts (enrolment state then lives in `/var/lib/netbird-router` on the node).

Admin session (Paul, NetBird connected): there is no admin kubeconfig in Doppler. `scripts/oke-admin.sh`
generates one on the fly from the OCI API key in Doppler (`infrastructure/prd OCI_CLI_*`) on the private
endpoint, into a temp dir deleted on exit:

```bash
bash scripts/oke-admin.sh kubectl -n argocd get applications.argoproj.io,applicationsets.argoproj.io
bash scripts/oke-admin.sh bash scripts/agent-operator-oke-token.sh --provision
```

Then, by Paul: Argo CD admin access is a local account (port-forward only, no ingress); the agent
identity is `scripts/agent-operator-oke-token.sh --provision` (server and CA are taken from the admin
session, which must be a private VCN `10.0.x.y` address), then `kubectl-ro.sh --cluster oracle-a1 ...`.

## Cilium: rollback

The ApplicationSet keeps resources on deletion (`preserveResourcesOnDeletion`), and the chart leaves
`/etc/cni/net.d/05-cilium.conflist` on the node (`cni.uninstall: false`, fail-closed). Removing `cilium`
from the ApplicationSet list is therefore NOT enough. In order:

1. Policies only (Cilium kept): revert the `baseline/` change or remove `baseline` from the list, then delete
   the two CCNPs with an admin kubeconfig (`kubectl delete ccnp deny-imds allow-egress-unisolated`; delete
   both together, never `allow-egress-unisolated` alone).
2. Cilium itself: remove `cilium` (and `baseline`) from the list and merge; with an admin kubeconfig delete
   the rendered objects (`kustomize build --enable-helm k8s/clusters/oracle-a1/cilium | kubectl delete -f -`).
3. The conflist stays on the node and new pods would then fail in ContainerCreating: replace the node
   (cycle the node pool from homelab-infra `terraform/oci`, the node is cattle and the cluster holds no data)
   or remove `/etc/cni/net.d/05-cilium.conflist` on it. Existing pods keep running throughout.

## Rules

- One cluster per app: `argocd-app.oracle-a1.yaml` or `argocd-app.yaml`, never both.
- No LoadBalancer (VAP and OCI quota zero); expose through Cloudflare Tunnel only, each hostname a decision of Paul.
- No application data on this cluster until a restore off Oracle is proven (PLT-190, `docs/operations/pg-shared-oke-backup-drill.md`). Enforced by `scripts/check-argo-app-descriptors.sh` (PVC, CNPG `Cluster`, StatefulSet with volumeClaimTemplates refused); exception: `disposableData: "<reason>"` in the descriptor, for disposable and rebuildable data only. Single infrastructure exception (PLT-408): `cnpg-cluster/` (`pg-shared`), reconciled by the `infrastructure` ApplicationSet, because the off-Oracle restore drill needs a live, archiving cluster on OKE to prove anything; it holds only the drill database until the drill is PROVEN, and its archive goes off Oracle (R2) from the first WAL.
- Images must have a `linux/arm64` manifest. Single node: PDBs use `maxUnavailable: 1`.
- Policies are enforced by Cilium (chaining, `cilium/`), and every pod is denied the OCI IMDS (`baseline/`). Limits: a hostNetwork pod (kube-system only) shares the node stack and is not covered; a pod started before the Cilium agent is not a Cilium endpoint until it restarts (`acceptance.sh` lists them as WARN). A new namespace that must not get the default allow-all egress carries `platform.smadja.dev/egress-isolated=true` and its own default-deny. `policy-check.sh` and `app-test.sh` no longer exempt OKE apps: an OKE app carries its own CiliumNetworkPolicy or NetworkPolicy (PLT-405).
- Secrets: nothing in Git. External Secrets reads Doppler `oke/prd` (references to `cluster/prd`) through `doppler-cluster` with a read-only token that only Paul creates (gesture above). An ExternalSecret of a new app must name a key present in that config.

## Proving the privileged-pod denial (PLT-405)

The agent identity is read-only on OKE (no `create`, and `kubectl-ro.sh` refuses every dry-run), so the real
admission refusal cannot be shown by an agent.

- Static proof (CI, `oke-baseline` workflow): `tests/oke-baseline/vap-pod-hardening-test.py` evaluates the committed CEL
  expressions of `guardrails/pod-hardening.yaml` on privileged, hostNetwork, hostPID, hostIPC, hostPath, ephemeral-container
  and Deployment objects (denied) and on healthy ones (admitted), and checks the binding (Deny, exemptions exactly
  `kube-system` and `netbird`).
- Real proof, a gesture for Paul with a write identity (server-side dry-run, nothing is created):

  ```sh
  kubectl --context <oke-admin> create namespace vap-probe --dry-run=server -o name   # sanity: write identity works
  kubectl --context <oke-admin> -n default run vap-probe --image=busybox --privileged=true --dry-run=server -o name
  ```

  Expected: `Error from server (Forbidden): ... ValidatingAdmissionPolicy 'baseline-pod-hardening' ... privileged containers are denied on oracle-a1`.
  The same command with `-n kube-system` must be admitted (exemption).
