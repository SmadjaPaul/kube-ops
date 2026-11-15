#!/usr/bin/env bash
# PLT-176: human accounts declared in Git carry no credential, are created only
# (never updated), get access through groups only, and set their password from
# an admin link that cannot start anonymously.
set -euo pipefail
auth=k8s/infrastructure/auth/authentik/extra
groups="$auth/blueprints/groups.yaml"
flow="$auth/blueprints/flows-password-setup.yaml"
fail() { echo "AUTHENTIK_HUMAN_USERS=FAIL $*" >&2; exit 1; }

for f in groups.yaml flows-password-setup.yaml; do
  grep -Eq "^[[:space:]]*-[[:space:]]*\./blueprints/${f//./\\.}" "$auth/kustomization.yml" \
    || fail "$f is not in the authentik-blueprints ConfigMap"
done

# No credential material and no environment value in either file.
for f in "$groups" "$flow"; do
  if grep -Eqi '^[[:space:]]*(password|password_hash|token|key)[[:space:]]*:' "$f"; then
    fail "credential attribute in $f"
  fi
  if grep -Eq '!Env' "$f"; then
    fail "$f must not read environment values (no recovery address, no secret)"
  fi
done

python3 - "$groups" "$flow" "$auth/blueprints" <<'PY'
import os, sys, yaml

class Loader(yaml.SafeLoader):
    pass

def tag(loader, suffix, node):
    if isinstance(node, yaml.SequenceNode):
        return ["!" + suffix, loader.construct_sequence(node, deep=True)]
    if isinstance(node, yaml.MappingNode):
        return ["!" + suffix, loader.construct_mapping(node, deep=True)]
    return ["!" + suffix, loader.construct_scalar(node)]

Loader.add_multi_constructor("!", tag)
groups_path, flow_path, bp_dir = sys.argv[1:4]
g_entries = yaml.load(open(groups_path), Loader=Loader)["entries"]
f_entries = yaml.load(open(flow_path), Loader=Loader)["entries"]

group_ids = {e["id"]: e["attrs"]["name"] for e in g_entries
             if e.get("model") == "authentik_core.group"}
superuser_ids = {e["id"] for e in g_entries if e.get("model") == "authentik_core.group"
                 and e["attrs"].get("is_superuser")}
users = [e for e in g_entries if e.get("model") == "authentik_core.user"]
assert users, "no human account declared in groups.yaml"
for u in users:
    a = u["attrs"]
    name = a["username"]
    assert u.get("state") == "created", f"{name}: state must be created (never update an account)"
    assert a.get("type") == "internal", f"{name}: type must be internal"
    assert a["email"].endswith("@smadja.dev"), f"{name}: e-mail must be the smadja.dev mailbox"
    assert "password" not in a and "password_hash" not in a, name
    refs = a.get("groups") or []
    assert refs, f"{name}: access must come from a group"
    for r in refs:
        assert r[0] == "!KeyOf" and r[1] in group_ids, f"{name}: group must be declared here"
        assert r[1] not in superuser_ids, f"{name}: no superuser group from Git"
    assert "roles" not in a, f"{name}: no role from Git"

# Password setup flow: no identification or e-mail stage, gated by a policy.
ids = {e.get("id"): e for e in f_entries if "id" in e}
bound = [ids[e["identifiers"]["stage"][1]]["model"] for e in f_entries
         if e.get("model") == "authentik_flows.flowstagebinding"]
assert "authentik_stages_identification.identificationstage" not in bound
assert "authentik_stages_email.emailstage" not in bound
binding = [e for e in f_entries if e.get("model") == "authentik_policies.policybinding"
           and e["identifiers"].get("target") == ["!KeyOf", "password-setup-flow"]]
assert len(binding) == 1, "password-setup flow must have exactly one policy binding"
pol = ids[binding[0]["identifiers"]["policy"][1]]["attrs"]["expression"]
for needle in ("is_authenticated", '"internal"', "not user.is_superuser"):
    assert needle in pol, f"password-setup policy must check {needle}"

# No family-specific leftovers.
for name in sorted(os.listdir(bp_dir)):
    text = open(os.path.join(bp_dir, name)).read()
    for old in ("smadja-family", "family-recovery"):
        if old in text:
            raise SystemExit(f"{name} still references {old}")
PY

echo 'AUTHENTIK_HUMAN_USERS=PASS STATIC; ACCOUNTS AND PASSWORD SETUP ARE RUNTIME-ONLY'
