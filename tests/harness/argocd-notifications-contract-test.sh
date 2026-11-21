#!/usr/bin/env bash
# PLT-396: Argo CD Notifications -> ntfy, Application health Lua, infra retry.
# Static contract on values.yaml / ExternalSecret / ApplicationSet; the Lua is
# executed with python `lupa` when installed (SKIP otherwise, never a pass).
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
v="$root/k8s/infrastructure/controllers/argocd/values.yaml"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ $(yq -r '.notifications.enabled' "$v") == true ]] || fail "notifications disabled"
[[ $(yq -r '.notifications.secret.create' "$v") == false ]] || fail "chart must not create the notifications secret"
yq -r '.notifications.notifiers["service.webhook.ntfy"]' "$v" | grep -q '^url: \$ntfy-url$' || fail "ntfy URL must come from the secret key ntfy-url"
for t in on-sync-failed on-health-degraded; do
  yq -r ".notifications.triggers[\"trigger.$t\"]" "$v" | grep -q "project != 'previews'" || fail "$t does not exclude previews"
  yq -r ".notifications.triggers[\"trigger.$t\"]" "$v" | grep -q 'oncePer:' || fail "$t has no oncePer"
  yq -r '.notifications.subscriptions[0].triggers[]' "$v" | grep -qx "$t" || fail "$t not subscribed"
done
es="$root/k8s/infrastructure/controllers/argocd/externalsecret-notifications.yaml"
[[ $(yq -r '.spec.target.name' "$es") == argocd-notifications-secret ]] || fail "ExternalSecret target name"
[[ $(yq -r '.spec.data[0].remoteRef.key' "$es") == ALERTMANAGER_NTFY_URL ]] || fail "ExternalSecret must reuse the existing Doppler key"
grep -q externalsecret-notifications.yaml "$root/k8s/infrastructure/controllers/argocd/kustomization.yaml" || fail "ExternalSecret not in kustomization"
limit=$(yq -r 'select(.kind=="ApplicationSet").spec.template.spec.syncPolicy.retry.limit' "$root/k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml" | grep -v '^---$' | head -1)
(( limit >= 3 && limit <= 5 )) || fail "infrastructure retry limit $limit not in 3..5"

lua=$(yq -r '.configs.cm["resource.customizations.health.argoproj.io_Application"]' "$v")
[[ -n $lua && $lua != null ]] || fail "Application health Lua missing"
# A self-managed Application (root tracks itself) must not wait for its own
# health: it deadlocked the root sync on 21/11 (PLT-396).
grep -q 'tracking-id' <<<"$lua" || fail "Application health Lua must short-circuit self-managed Applications (tracking-id)"
if python3 -I -c 'import lupa' 2>/dev/null; then
  LUA_SRC=$lua python3 -I - <<'PY'
import os, sys
from lupa import LuaRuntime
rt = LuaRuntime(unpack_returned_tuples=True)
fn = rt.eval("function(obj)\n" + os.environ["LUA_SRC"] + "\nend")
def run(obj): 
    r = fn(rt.table_from(obj)); return r["status"]
H = lambda h, s: {"status": {"health": {"status": h}, "sync": {"status": s}}}
cases = [({}, "Progressing"), (H("Healthy", "Synced"), "Healthy"), (H("Healthy", "OutOfSync"), "Progressing"),
         (H("Progressing", "Synced"), "Progressing"), (H("Degraded", "Synced"), "Degraded"), (H("Degraded", "OutOfSync"), "Degraded")]
def T(name, tid, h, s):
    o = H(h, s); o["metadata"] = {"name": name, "annotations": {"argocd.argoproj.io/tracking-id": tid}}; return o
cases += [(T("root", "root:argoproj.io/Application:argocd/root", "Healthy", "OutOfSync"), "Healthy"),
          (T("root", "root:argoproj.io/Application:argocd/root", "Progressing", "OutOfSync"), "Healthy"),
          (T("apps-ai", "root:argoproj.io/Application:argocd/apps-ai", "Healthy", "OutOfSync"), "Progressing")]
def conv(o):
    return rt.table_from({k: conv(v) if isinstance(v, dict) else v for k, v in o.items()})
for obj, want in cases:
    got = fn(conv(obj))["status"]
    if got != want: sys.exit(f"FAIL: Lua {obj} -> {got}, want {want}")
print("lua cases PASS")
PY
else
  echo "SKIP: python lupa not installed, Lua not executed"
fi
echo "argocd-notifications-contract PASS"
