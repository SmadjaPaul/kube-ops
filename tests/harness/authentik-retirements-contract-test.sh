#!/usr/bin/env bash
# PRD-122: an Authentik application or provider that leaves the blueprints stays
# in Authentik until a blueprint says `state: absent`. This offline check
# compares the blueprints loaded by Authentik with a versioned inventory. Every
# inventory object is either declared or listed in apps-retired.yaml, never both.
# Nothing is derived from the absence of a service.
# Outposts are inventory objects too; only the `Proxy Outpost` can be retired.
# Also checked: a SAML provider with signing_kp signs the assertion or the
# response (Authentik 2026.8.6 serializer, providers/saml/api/providers.py).
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 - k8s/infrastructure/auth/authentik/extra <<'PY'
import copy, os, sys, yaml

ROOT = sys.argv[1]
RETIRED = "apps-retired.yaml"
APP = "authentik_core.application"
OUTPOST = "authentik_outposts.outpost"
SAML = "authentik_providers_saml.samlprovider"
RETIRABLE_OUTPOSTS = {"Proxy Outpost"}  # never the embedded outpost

class Tag:
    def __init__(self, name, value):
        self.name, self.value = name, value

class Loader(yaml.SafeLoader):
    pass

def tag(loader, suffix, node):
    if isinstance(node, yaml.SequenceNode):
        return Tag(suffix, loader.construct_sequence(node, deep=True))
    if isinstance(node, yaml.MappingNode):
        return Tag(suffix, loader.construct_mapping(node, deep=True))
    return Tag(suffix, loader.construct_scalar(node))

Loader.add_multi_constructor("!", tag)

class Refused(Exception):
    pass

def is_provider(model):
    return model.startswith("authentik_providers_") and model.endswith("provider")

def key_of(entry, where):
    """Inventory key of an application, provider or outpost entry, None for other models."""
    model = entry.get("model")
    if not isinstance(model, str):
        raise Refused(f"{where}: model must be a plain string")
    if model not in (APP, OUTPOST) and not is_provider(model):
        return None
    field = "slug" if model == APP else "name"
    value = (entry.get("identifiers") or {}).get(field)
    if not isinstance(value, str) or not value:
        raise Refused(f"{where}: {model} needs a plain identifiers.{field}")
    if model == APP:
        return ("application", value)
    if model == OUTPOST:
        return ("outpost", value)
    return ("provider", model, value)

def finds(node):
    if isinstance(node, Tag):
        if node.name == "Find":
            yield node.value
        yield from finds(node.value)
    elif isinstance(node, dict):
        for value in node.values():
            yield from finds(value)
    elif isinstance(node, list):
        for value in node:
            yield from finds(value)

def check(loaded, blueprints, inventory):
    """loaded: file names Authentik mounts; blueprints: name -> document."""
    if RETIRED not in loaded:
        raise Refused(f"{RETIRED} is not in the authentik-blueprints ConfigMap")
    declared, retired = set(), set()
    for name in loaded:
        for entry in blueprints[name].get("entries") or []:
            state = entry.get("state", "present")
            key = key_of(entry, name)
            if entry["model"] == SAML and state != "absent":
                attrs = entry.get("attrs") or {}
                if attrs.get("signing_kp") and not (attrs.get("sign_assertion") is True
                                                    or attrs.get("sign_response") is True):
                    raise Refused(f"{name}: {key} signing_kp needs sign_assertion or sign_response")
            if name == RETIRED:
                if key is None or (key[0] == "outpost" and key[1] not in RETIRABLE_OUTPOSTS):
                    raise Refused(f"{name}: only applications and providers (and the Proxy Outpost), "
                                  f"not {entry['model']} {key}")
                if state != "absent":
                    raise Refused(f"{name}: {key} must have state: absent")
                if set(entry) != {"model", "state", "identifiers"} or len(entry["identifiers"]) != 1:
                    raise Refused(f"{name}: {key} takes model, state and one identifier only")
                if key in retired:
                    raise Refused(f"{name}: {key} listed twice")
                retired.add(key)
            elif key is not None:
                if state == "absent":
                    raise Refused(f"{name}: retire {key} in {RETIRED}, not here")
                declared.add(key)
    # A slug is unique per application, a name is unique across provider models.
    both = {(k[0], k[-1]) for k in declared} & {(k[0], k[-1]) for k in retired}
    if both:
        raise Refused(f"declared and retired: {sorted(both)}")
    gone = inventory - declared - retired
    if gone:
        raise Refused(f"removed from the blueprints but not in {RETIRED}: {sorted(gone)}")
    unknown = (declared | retired) - inventory
    if unknown:
        raise Refused(f"missing from the inventory: {sorted(unknown)}")
    dead = {(k[0], k[-1]) for k in retired}
    for name in loaded:
        for value in finds(blueprints[name].get("entries") or []):
            model = value[0]
            kind = "application" if model == APP else "provider"
            if kind == "provider" and not (model == "authentik_core.provider" or is_provider(model)):
                continue
            for condition in value[1:]:
                if condition[0] in ("slug", "name") and (kind, condition[1]) in dead:
                    raise Refused(f"{name}: !Find uses the retired {kind} {condition[1]}")

def read_inventory(path):
    rows = set()
    for line in open(path):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        row = tuple(line.split("\t"))
        if not ((len(row) == 2 and row[0] in ("application", "outpost"))
                or (len(row) == 3 and row[0] == "provider")):
            raise Refused(f"inventory: bad line {line!r}")
        if row in rows:
            raise Refused(f"inventory: duplicate line {line!r}")
        rows.add(row)
    return rows

kustomization = yaml.safe_load(open(os.path.join(ROOT, "kustomization.yml")))
loaded = [os.path.basename(f) for g in kustomization["configMapGenerator"]
          if g["name"] == "authentik-blueprints" for f in g["files"]]
blueprints = {n: yaml.load(open(os.path.join(ROOT, "blueprints", n)), Loader=Loader) for n in loaded}
inventory = read_inventory(os.path.join(ROOT, "authentik-objects.inventory.tsv"))

try:
    check(loaded, blueprints, inventory)
except Refused as error:
    sys.exit(f"AUTHENTIK_RETIREMENTS=FAIL {error}")

# Negative cases: each one mutates a copy of the real input and must be refused.
GRAFANA = "apps-grafana.yaml"
PROVIDER = "authentik_providers_oauth2.oauth2provider"

def entries(b, name):
    return b[name]["entries"]

def drop(b, model):
    b[GRAFANA]["entries"] = [e for e in entries(b, GRAFANA) if e["model"] != model]

def absent(model, **identifiers):
    return {"model": model, "state": "absent", "identifiers": identifiers}

def rename_provider(l, b, i):
    for e in entries(b, GRAFANA):
        if e["model"] == PROVIDER:
            e["identifiers"] = {"name": "renamed"}
    i.add(("provider", PROVIDER, "renamed"))

def retire_grafana(l, b, i):
    old = [e for e in entries(b, GRAFANA) if e["model"] == PROVIDER][0]["identifiers"]["name"]
    l.remove(GRAFANA)
    entries(b, RETIRED).extend([absent(APP, slug="grafana"), absent(PROVIDER, name=old)])

def wrong_model(l, b, i):
    for e in entries(b, RETIRED):
        if e["model"] == PROVIDER:
            e["model"] = "authentik_providers_proxy.proxyprovider"
            return

def saml_attrs(b):
    return [e for e in entries(b, "apps-fleet.yaml") if e["model"] == SAML][0]["attrs"]

NEGATIVES = {
    "application removed": ("removed from the blueprints", lambda l, b, i: drop(b, APP)),
    "blueprint unlisted": ("removed from the blueprints", lambda l, b, i: l.remove(GRAFANA)),
    "provider renamed": ("removed from the blueprints", rename_provider),
    "retirement dropped": ("removed from the blueprints", lambda l, b, i: entries(b, RETIRED).pop(0)),
    "wrong provider model": ("removed from the blueprints", wrong_model),
    "declared and retired": ("declared and retired",
        lambda l, b, i: entries(b, RETIRED).append(absent(APP, slug="grafana"))),
    "not in inventory": ("missing from the inventory",
        lambda l, b, i: i.discard(("application", "grafana"))),
    "group retired": ("only applications and providers",
        lambda l, b, i: entries(b, RETIRED).append(absent("authentik_core.group", name="family"))),
    "attrs in retirement": ("one identifier only",
        lambda l, b, i: entries(b, RETIRED)[0].update(attrs={"name": "x"})),
    "retirement not absent": ("must have state: absent",
        lambda l, b, i: entries(b, RETIRED)[0].update(state="present")),
    "absent elsewhere": ("retire",
        lambda l, b, i: entries(b, GRAFANA).append(absent(APP, slug="other"))),
    "retirements unlisted": ("is not in the authentik-blueprints",
        lambda l, b, i: l.remove(RETIRED)),
    "find retired provider": ("!Find uses the retired provider",
        lambda l, b, i: (i.add(("outpost", "x")), entries(b, GRAFANA).append({"model": OUTPOST,
            "identifiers": {"name": "x"},
            "attrs": {"providers": [Tag("Find", ["authentik_core.provider", ["name", "jellyfin"]])]}}))),
    "embedded outpost retired": ("only applications and providers",
        lambda l, b, i: entries(b, RETIRED).append(absent(OUTPOST, name="authentik Embedded Outpost"))),
    "user retired": ("only applications and providers",
        lambda l, b, i: entries(b, RETIRED).append(absent("authentik_core.user", username="x"))),
    "flow retired": ("only applications and providers",
        lambda l, b, i: entries(b, RETIRED).append(absent("authentik_flows.flow", slug="x"))),
    "outpost retirement dropped": ("removed from the blueprints",
        lambda l, b, i: b[RETIRED].update(entries=[e for e in entries(b, RETIRED) if e["model"] != OUTPOST])),
    "saml signing without signature": ("signing_kp needs",
        lambda l, b, i: saml_attrs(b).update(sign_assertion=False, sign_response=False)),
    "saml signing flags absent": ("signing_kp needs",
        lambda l, b, i: saml_attrs(b).pop("sign_assertion")),
}
for label, (expected, mutate) in NEGATIVES.items():
    case = copy.deepcopy((loaded, blueprints, inventory))
    mutate(*case)
    try:
        check(*case)
    except Refused as error:
        assert expected in str(error), f"{label}: wrong refusal: {error}"
    else:
        sys.exit(f"AUTHENTIK_RETIREMENTS=FAIL negative case accepted: {label}")

# A complete retirement is accepted.
case = copy.deepcopy((loaded, blueprints, inventory))
retire_grafana(*case)
check(*case)
print(f"AUTHENTIK_RETIREMENTS=PASS STATIC inventory={len(inventory)} negatives={len(NEGATIVES)}")
PY
