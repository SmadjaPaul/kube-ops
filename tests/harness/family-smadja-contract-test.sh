#!/usr/bin/env bash
# PLT-176: family accounts are declared without credentials, are created only
# (never updated), and their group grants no application access.
set -euo pipefail
auth=k8s/infrastructure/auth/authentik/extra
bp="$auth/blueprints/family-smadja.yaml"
fail() { echo "FAMILY_SMADJA=FAIL $*" >&2; exit 1; }

grep -Eq '^[[:space:]]*-[[:space:]]*\./blueprints/family-smadja\.yaml' "$auth/kustomization.yml" \
  || fail 'family-smadja.yaml is not in the authentik-blueprints ConfigMap'

# No credential material in the blueprint.
if grep -Eqi '^[[:space:]]*(password|password_hash|token|key)[[:space:]]*:' "$bp"; then
  fail 'credential attribute in family-smadja.yaml'
fi
if grep -Eq '!Env' "$bp"; then
  fail 'family-smadja.yaml must not read environment values (no recovery address, no secret)'
fi

python3 - "$bp" "$auth/blueprints" <<'PY'
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
path, bp_dir = sys.argv[1], sys.argv[2]
entries = yaml.load(open(path), Loader=Loader)["entries"]

users = [e for e in entries if e.get("model") == "authentik_core.user"]
assert len(users) == 4, f"expected 4 users, got {len(users)}"
for u in users:
    a = u["attrs"]
    assert u.get("state") == "created", f"{a['username']}: state must be created"
    assert a.get("type") == "internal", f"{a['username']}: type must be internal"
    assert a["email"].endswith("@smadja.dev"), f"{a['username']}: e-mail must be @smadja.dev"
    assert a.get("groups") == [["!KeyOf", "smadja-family"]], f"{a['username']}: only smadja-family"
    assert "password" not in a and "password_hash" not in a, a["username"]

# Flow restricted to the group, without identification or e-mail stage.
stage_models = {e.get("id"): e["model"] for e in entries if "id" in e}
bound = [stage_models.get(e["identifiers"]["stage"][1]) for e in entries
         if e.get("model") == "authentik_flows.flowstagebinding"]
assert "authentik_stages_identification.identificationstage" not in bound
assert "authentik_stages_email.emailstage" not in bound
assert any(e.get("model") == "authentik_policies.policybinding"
           and e["identifiers"].get("target") == ["!KeyOf", "family-recovery-flow"]
           and e["identifiers"].get("group") == ["!KeyOf", "smadja-family"] for e in entries), \
    "family-recovery flow must be bound to smadja-family"

# Least privilege: no blueprint binds smadja-family to anything else.
for name in sorted(os.listdir(bp_dir)):
    text = open(os.path.join(bp_dir, name)).read()
    if name != os.path.basename(path) and "smadja-family" in text:
        raise SystemExit(f"{name} references smadja-family: application access is Paul's decision")
PY

echo 'FAMILY_SMADJA=PASS STATIC; ACCOUNTS AND RECOVERY ARE RUNTIME-ONLY'
