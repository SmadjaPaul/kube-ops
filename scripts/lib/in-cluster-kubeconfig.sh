#!/usr/bin/env bash
# PLT-390: explicit kubeconfig for a pod's own ServiceAccount (post-merge ARC runner).
# kubectl's implicit in-cluster fallback did not trigger in the runner job (it fell back to localhost:8080),
# so build one: server from KUBERNETES_SERVICE_HOST/PORT (default kubernetes.default.svc:443), the mounted
# ca.crt, and `tokenFile` pointing at the mounted token. The token value is never read or copied.
# Usage (sourced): in_cluster_kubeconfig SA_DIR  -> prints the path of a temp kubeconfig (caller deletes it).
in_cluster_kubeconfig() {
  local sa_dir=${1:-/var/run/secrets/kubernetes.io/serviceaccount} host port server f
  [ -r "$sa_dir/token" ] && [ -r "$sa_dir/ca.crt" ] || return 1
  host=${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}; port=${KUBERNETES_SERVICE_PORT:-443}
  case "$host" in *:*) server="https://[$host]:$port" ;; *) server="https://$host:$port" ;; esac
  f=$(mktemp "${TMPDIR:-/tmp}/in-cluster-kubeconfig.XXXXXX") || return 1
  chmod 600 "$f"
  cat >"$f" <<KCFG
apiVersion: v1
kind: Config
clusters:
- name: in-cluster
  cluster:
    server: $server
    certificate-authority: $sa_dir/ca.crt
users:
- name: serviceaccount
  user:
    tokenFile: $sa_dir/token
contexts:
- name: in-cluster
  context:
    cluster: in-cluster
    user: serviceaccount
current-context: in-cluster
KCFG
  printf '%s\n' "$f"
}
