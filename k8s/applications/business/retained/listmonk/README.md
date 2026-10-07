# Listmonk retained data

Listmonk is retired from the active business runtime. This retention-only
root keeps the existing namespace, uploads PVC, CNPG cluster and Barman/WAL
resources under the existing `apps-listmonk` Argo Application so removing the
workload cannot implicitly delete its data.

The `Delete=false,Prune=false` annotations are an additional guard. A future
data purge requires a separate explicit decision and change.
