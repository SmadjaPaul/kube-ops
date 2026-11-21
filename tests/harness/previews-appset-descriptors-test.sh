#!/usr/bin/env bash
# PLT-394 : les ApplicationSets `previews` et `previews-guardrails` decouvrent les apps de preview
# par le descripteur argocd-app.yaml (matrix PR x git files + selector `preview: "true"`), plus par
# un `directories`. Test statique, sans cluster : modele local des generateurs (glob, label
# `preview:<app>`, selector) applique a l'arbre reel k8s/applications.
#
# Verifie : (1) forme des deux generateurs (identiques, files, selector, PR generator en premier) ;
# (2) pour chaque PR simulee, l'ensemble des Applications de preview == apps dont le descripteur a
# `preview: true` ET que le label designe ; nommage preview-pr<n>-<app> et namespace pr-<n>-<app>.
# Lecture seule, aucun secret.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
command -v yq >/dev/null || { echo "ERROR: yq is required" >&2; exit 2; }
command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 2; }
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
d=k8s/bootstrap/argocd-root
a=$d/previews-applicationset.yaml
g=$d/previews-guardrails-applicationset.yaml

# 1. forme
for f in "$a" "$g"; do
  [[ "$(yq '.spec.generators[0].matrix.generators[0] | has("pullRequest")' "$f")" == true ]] || bad "$f: first matrix generator must be pullRequest"
  [[ "$(yq '.spec.generators[0].matrix.generators[1].git | has("files") and (has("directories") | not)' "$f")" == true ]] || bad "$f: second matrix generator must be git files (no directories)"
  [[ "$(yq '.spec.generators[0].matrix.generators[1].git.files | length' "$f")" == 1 ]] || bad "$f: exactly one files path expected"
  [[ "$(yq '.spec.generators[0].matrix.generators[1].git.files[0].path' "$f")" == 'k8s/applications/*/{{-'*'/argocd-app.yaml' ]] || bad "$f: files path must be k8s/applications/*/<app>/argocd-app.yaml"
  [[ "$(yq -o=json -I=0 '.spec.generators[0].selector' "$f")" == '{"matchLabels":{"preview":"true"}}' ]] || bad "$f: selector must be matchLabels preview: 'true' (on the generator, not nested)"
  [[ "$(yq '.spec.generators[0].matrix.generators[1] | has("selector")' "$f")" == false ]] || bad "$f: no nested selector (ignored without applyNestedSelectors)"
  [[ "$(yq '.spec.generators | length' "$f")" == 1 ]] || bad "$f: exactly one generator"
done
[[ "$(yq -o=json -I=0 '.spec.generators' "$a")" == "$(yq -o=json -I=0 '.spec.generators' "$g")" ]] || bad "previews and previews-guardrails must use the same generators (same PR, same app)"

# 2. modele local
python3 -I - "$a" <<'PY' || fail=1
import fnmatch, glob, os, re, subprocess, sys, json
appset = sys.argv[1]
y = lambda e: subprocess.check_output(["yq", "-o=json", e, appset], text=True)
path_tpl = json.loads(y(".spec.generators[0].matrix.generators[1].git.files[0].path"))
name_tpl = json.loads(y(".spec.template.metadata.name"))
ns_tpl = json.loads(y(".spec.template.spec.destination.namespace"))
assert name_tpl == "preview-pr{{ .number }}-{{ .path.basename }}", name_tpl
assert ns_tpl == "pr-{{ .number }}-{{ .path.basename }}", ns_tpl

def app_from_labels(labels):
    # miroir du template Go : dernier label `preview:<app>` valide, sinon __none__
    a = ""
    for l in labels:
        if l.startswith("preview:"):
            a = l[len("preview:"):]
    return a if re.fullmatch(r"[a-z0-9][a-z0-9-]{0,37}", a) else "__none__"

def descriptor(p):
    out = subprocess.check_output(["yq", "-o=json", ".", p], text=True)
    return json.loads(out)

def flat_preview(desc):  # flatten + fmt %v : true -> "true", absent -> pas de cle
    return None if "preview" not in desc else ("true" if desc["preview"] is True else "false" if desc["preview"] is False else str(desc["preview"]))

dirs = sorted(p for p in glob.glob("k8s/applications/*/*") if os.path.isdir(p))
descs = {p: descriptor(p + "/argocd-app.yaml") for p in dirs if os.path.isfile(p + "/argocd-app.yaml")}
# prevu : apps dont le descripteur declare preview: true
opted = {os.path.basename(p) for p, dsc in descs.items() if flat_preview(dsc) == "true"}

def generate(number, labels):
    if "preview" not in labels:  # le PR generator filtre sur le label `preview`
        return set()
    app = app_from_labels(labels)
    res = set()
    for p, dsc in descs.items():
        if fnmatch.fnmatchcase(p + "/argocd-app.yaml", "k8s/applications/*/%s/argocd-app.yaml" % app) and flat_preview(dsc) == "true":
            b = os.path.basename(p)
            res.add((f"preview-pr{number}-{b}", f"pr-{number}-{b}", b))
    return res

errors = []
def check(cond, msg):
    if not cond: errors.append(msg)

check(opted, "no app opted in to previews: preview: true expected on at least one descriptor")
# avant PLT-394 : toute app label-designee ; apres : seulement celles qui ont opte
for b in sorted({os.path.basename(p) for p in dirs}):
    got = generate(7, ["preview", "preview:" + b])
    want = {(f"preview-pr7-{b}", f"pr-7-{b}", b)} if b in opted else set()
    check(got == want, f"preview:{b} -> {sorted(got)} (expected {sorted(want)})")
for labels in (["preview"], ["preview:it-tools"], ["preview", "preview:../x"], ["preview", "preview:IT-TOOLS"],
               ["preview", "preview:*"], ["preview", "preview:" + "a" * 39], ["preview", "preview:nope"]):
    check(generate(3, labels) == set(), f"labels {labels} must generate nothing")
# plusieurs labels : le dernier gagne, une seule app par PR
got = generate(9, ["preview", "preview:ntfy", "preview:it-tools"])
check(len(got) <= 1, "one app per PR")
print("OK: previews appsets (%d app(s) opted in: %s; %d descriptor(s), %d app dir(s))" % (len(opted), ", ".join(sorted(opted)), len(descs), len(dirs)))
if errors:
    for e in errors: print("FAIL:", e, file=sys.stderr)
    sys.exit(1)
PY
exit $fail
