#!/usr/bin/env python3
# Assertions structurelles sur l'arbre rendu (overlay du depot). Lecture seule.
# Usage: python3 -I assert_canary.py <arbre-fusionne> <params.json>
import glob, json, os, re, sys

import yaml  # PyYAML ; les tags Authentik (!Find, !Env, !KeyOf) sont ignores.


class Loader(yaml.SafeLoader):
    pass


Loader.add_multi_constructor("!", lambda loader, suffix, node: None)

root, params_path = sys.argv[1], sys.argv[2]
p = json.load(open(params_path))
name, pgdb = p["name"], p["pgDatabase"]
errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


def docs(pattern):
    out = []
    for f in sorted(glob.glob(os.path.join(root, pattern), recursive=True)):
        with open(f) as fh:
            for d in yaml.load_all(fh, Loader=Loader):
                if isinstance(d, dict):
                    out.append((f, d))
    return out


app = f"k8s/applications/catalog/{name}"
app_docs = docs(f"{app}/**/*.yaml")
kinds = lambda ds, k: [d for _, d in ds if d.get("kind") == k]

# 1. Pod : SA dedie, pas de token monte, pas de Secret lisible par le SA du pod.
dep = kinds(app_docs, "Deployment")
check(len(dep) == 1, "un Deployment attendu")
if dep:
    spec = dep[0]["spec"]["template"]["spec"]
    check(spec["serviceAccountName"] == name, "serviceAccountName doit etre le SA du pod")
    check(spec["automountServiceAccountToken"] is False, "token du pod non monte")
    sc = spec["containers"][0]["securityContext"]
    check(sc.get("readOnlyRootFilesystem") is True and sc.get("allowPrivilegeEscalation") is False, "securityContext durci")
    check(sc["capabilities"]["drop"] == ["ALL"], "drop ALL")
    check(spec["containers"][0]["resources"]["limits"]["cpu"] == f'{p["cpuLimitMillicores"]}m', "limite CPU")
    check(spec["containers"][0]["image"] == p["image"], "image exacte")
    check("@sha256:" in spec["containers"][0]["image"], "digest obligatoire")
    # Plafonds pilote
    check(p["cpuLimitMillicores"] <= 500 and p["memoryLimitMi"] <= 512, "plafonds pilote")

# 2. Aucun RoleBinding vers le SA du pod ; toute regle sur secrets : un seul nom, verbe get seul.
# Perimetre limite aux dossiers touches par le template (le reste du depot contient des charts Helm).
all_docs = (app_docs
            + docs("k8s/infrastructure/database/pg-shared-homelab/*.yaml")
            + docs("k8s/infrastructure/auth/authentik/extra/*.yaml")
            + docs("k8s/bootstrap/argocd-root/applications-project.yaml"))
for f, d in all_docs:
    if d.get("kind") == "RoleBinding":
        subj = [s for s in d.get("subjects", []) if s.get("kind") == "ServiceAccount"]
        check(not any(s.get("name") == name and s.get("namespace") == name for s in subj),
              f"{f}: le SA du pod ne doit avoir aucun binding")
    if d.get("kind") == "Role" and d["metadata"]["name"].startswith(("pg-shared-homelab-", "authentik-blueprint-")):
        for r in d.get("rules", []):
            if "secrets" in r.get("resources", []):
                check(len(r.get("resourceNames", [])) == 1 and r.get("verbs") == ["get"],
                      f"{f}: regle secrets trop large")

# 3. Distribution : SecretStore kubernetes, remoteNamespace databases/auth, SA secret-reader.
stores = kinds(app_docs, "SecretStore")
check({s["spec"]["provider"]["kubernetes"]["remoteNamespace"] for s in stores} == {"databases", "auth"},
      "SecretStore databases et auth attendus")
for s in stores:
    check(s["spec"]["provider"]["kubernetes"]["auth"]["serviceAccount"]["name"] == f"{name}-secret-reader",
          "SecretStore doit utiliser le SA secret-reader")

# 4. Base PostgreSQL : Database, role gere, Job d'isolation et CNP.
db = [d for f, d in all_docs if d.get("kind") == "Database" and d["spec"]["cluster"]["name"] == "pg-shared-homelab"]
check(len(db) == 1 and db[0]["spec"]["name"] == pgdb and db[0]["spec"]["owner"] == pgdb, "Database attendue")
jobs = [d for f, d in all_docs if d.get("kind") == "Job" and d["metadata"]["name"] == f"pg-shared-homelab-{pgdb}-isolation"]
check(len(jobs) == 1, "Job d'isolation PostSync attendu")
if jobs:
    script = json.dumps(jobs[0])
    check(f"REVOKE CONNECT ON DATABASE {pgdb} FROM PUBLIC" in script, "REVOKE attendu dans le Job")
    check(jobs[0]["metadata"]["annotations"]["argocd.argoproj.io/hook"] == "PostSync", "hook PostSync")
cluster = [d for f, d in all_docs if d.get("kind") == "Cluster"]
check(len(cluster) == 1 and cluster[0]["metadata"]["name"] == "pg-shared-homelab", "un seul Cluster pg-shared-homelab")
roles = []
for f, d in all_docs:
    if d.get("kind") == "Cluster" and d["metadata"]["name"] == "pg-shared-homelab":
        roles = d.get("spec", {}).get("managed", {}).get("roles", [])
check(any(r.get("name") == pgdb and r.get("passwordSecret", {}).get("name") == f"pg-shared-homelab-{name}" for r in roles),
      "role gere dans cluster.yaml")

# 5. Authentik : blueprint, redirect URI exacte, cle d'env unique, groupes valides.
bp_path = f"k8s/infrastructure/auth/authentik/extra/blueprints/apps-{name}.yaml"
bp_text = open(os.path.join(root, bp_path)).read() if os.path.exists(os.path.join(root, bp_path)) else ""
check(bp_text != "", "blueprint absent")
if bp_text:
    # Le blueprint contient des tags Authentik : on verifie le texte brut (regex) et la forme YAML.
    bp = yaml.load(bp_text, Loader=Loader)
    check(isinstance(bp, dict) and "entries" in bp, "blueprint YAML invalide")
    check(f'url: "https://{name}.{p["domain"]}{p["callbackPath"]}"' in bp_text, "redirect URI exacte")
    check("client_type: confidential" in bp_text, "client confidentiel")
    check(f"client_secret: !Env {pgdb.upper()}_OIDC_CLIENT_SECRET" in bp_text, "cle d'env du secret client")
    groups = [g for g in re.findall(r'\[name, "([^"]+)"\]\]', bp_text) if g in ("family", "friends", "authentik-admins")]
    check(sorted(set(groups)) == sorted(p["accessGroups"]), f"groupes du blueprint {groups}")
    scopes = re.findall(r'\[scope_name, "([^"]+)"\]', bp_text)
    check(sorted(scopes) == sorted(p["oidcScopes"]), f"scopes du blueprint {scopes}")
secret_src = [d for f, d in all_docs if d.get("kind") == "ExternalSecret" and d["metadata"]["name"] == f"authentik-blueprint-{name}"]
check(len(secret_src) == 1, "ExternalSecret du secret client")
if secret_src:
    keys = list(secret_src[0]["spec"]["target"]["template"]["data"].keys())
    check(keys == [f"{pgdb.upper()}_OIDC_CLIENT_SECRET"], f"cle du secret client {keys}")

# 6. Exposition, catalogue, AppProject, envFrom Authentik.
route = [d for d in app_docs if d[1].get("kind") == "HTTPRoute"]
check(route and route[0][1]["spec"]["parentRefs"][0]["name"] == "internal", "HTTPRoute internal uniquement")
check(route and route[0][1]["spec"]["hostnames"] == [f"{name}.{p['domain']}"], "hostname exact")
cat = [d for f, d in app_docs if d.get("kind") == "Component"]
ann = cat[0]["metadata"]["annotations"] if cat else {}
for key in ["cluster", "namespace", "exposure", "hostname", "data-class", "access-groups", "pg-database",
            "backup-rpo", "backup-rto", "golden-path"]:
    check(f"homelab.smadja.dev/{key}" in ann, f"annotation {key} absente")
check(ann.get("homelab.smadja.dev/access-groups") == ",".join(p["accessGroups"]), "access-groups")

def text(rel):
    fp = os.path.join(root, rel)
    return open(fp).read() if os.path.exists(fp) else ""

check(f"        name: authentik-blueprint-{name}" in text("k8s/infrastructure/auth/authentik/values.yaml"),
      "envFrom Authentik")
check(f"  - {name}\n" in text("k8s/applications/catalog/kustomization.yaml") or f"  - {name}" in text("k8s/applications/catalog/kustomization.yaml"),
      "catalogue Argo")
check(f"- namespace: {name}" in text("k8s/bootstrap/argocd-root/applications-project.yaml"), "destination AppProject")
check(f"./blueprints/apps-{name}.yaml" in text("k8s/infrastructure/auth/authentik/extra/kustomization.yml"),
      "configMapGenerator Authentik")

if errors:
    for e in errors:
        print("FAIL: " + e)
    sys.exit(1)
print(f"PASS: assertions canari ({name}, base {pgdb})")
