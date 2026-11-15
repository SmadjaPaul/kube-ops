#!/usr/bin/env bash
# PLT-176: the `friends` group opens only applications with zero marginal cost,
# and no enrollment stage adds `friends` together with `family`.
set -euo pipefail
bp=k8s/infrastructure/auth/authentik/extra/blueprints
ALLOWED="polyfin bookorbit romm"
fail() { echo "AUTHENTIK_FRIENDS=FAIL $*" >&2; exit 1; }

grep -Eq 'identifiers: \{name: friends\}' "$bp/groups.yaml" || fail 'friends group missing in groups.yaml'

python3 - "$bp" "$ALLOWED" <<'PY'
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
bp_dir, allowed = sys.argv[1], set(sys.argv[2].split())

def group_name(ref):
    # !Find [authentik_core.group, [name, "x"]] or !KeyOf x
    if isinstance(ref, list) and ref and ref[0] == "!Find":
        return ref[1][1][1]
    if isinstance(ref, list) and ref and ref[0] == "!KeyOf":
        return ref[1]
    return None

bound = set()
for name in sorted(os.listdir(bp_dir)):
    if not name.endswith(".yaml"):
        continue
    doc = yaml.load(open(os.path.join(bp_dir, name)), Loader=Loader) or {}
    entries = doc.get("entries") or []
    slugs = {e.get("id"): (e.get("identifiers") or {}).get("slug") for e in entries
             if e.get("model") == "authentik_core.application"}
    for e in entries:
        ident = e.get("identifiers") or {}
        if e.get("model") == "authentik_policies.policybinding" and group_name(ident.get("group")) == "friends":
            if e.get("state") == "absent":
                continue
            slug = slugs.get(ident["target"][1]) if isinstance(ident.get("target"), list) else None
            if slug not in allowed:
                raise SystemExit(f"{name}: friends bound to {slug!r}, outside the zero-marginal-cost list {sorted(allowed)}")
            bound.add(slug)
        if e.get("model") == "authentik_stages_user_write.userwritestage":
            if group_name((e.get("attrs") or {}).get("create_users_group")) == "friends":
                raise SystemExit(f"{name}: no enrollment stage for friends before Paul approves one")
        if e.get("model") == "authentik_core.user":
            groups = [group_name(g) for g in (e.get("attrs") or {}).get("groups") or []]
            if "friends" in groups and "family" in groups:
                raise SystemExit(f"{name}: a friend never gets family")
assert bound == allowed, f"friends bindings {sorted(bound)} != {sorted(allowed)}"
PY

echo 'AUTHENTIK_FRIENDS=PASS STATIC; NO FRIEND ACCOUNT EXISTS'
