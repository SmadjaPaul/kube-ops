#!/usr/bin/env python3
# Garde d'admission service-contract (Backstage pilote, contrat CONTRAT-SERVICE.md).
#
# Admission != template : cette garde s'applique a TOUTE PR qui ajoute ou modifie un
# service (dossier k8s/applications/catalog/<name>/), qu'elle vienne du golden path
# service-postgres-oidc@v1 ou soit ecrite a la main. Aucune annotation de generation
# n'est lue pour decider : seules les ressources comptent.
#
# Base de comparaison : merge-base(--base, --head). Les arbres base et head sont
# extraits par `git archive` (aucune ecriture dans le depot). Parsing : yq (YAML 1.2,
# meme outil que les autres gardes), JSON lu par python3 -I (stdlib seule).
#
# Classes de refus :
#   FAIL    violation technique (nom, groupe, redirect, role PG, secret, baseline...)
#   MANDAT  protection MANDAT : modification d'un service, blueprint, groupe existant,
#           exposition externe, creation de groupe (admission humaine uniquement)
#   HORS    fichier hors perimetre du contrat (edition non additive, ajout sans rapport)
# MANDAT et HORS deviennent ADMIS-HUMAIN si la variable SERVICE_CONTRACT_HUMAN_ADMISSION
# est definie (identifiant de l'admission, documente). Jamais definie par la CI.
#
# Usage : python3 -I tests/harness/service-contract-guard.py [--repo DIR] [--base REF]
#         [--head REF] [--audit]
# Sortie : 0 PASS, 1 FAIL, 2 erreur d'outillage (fail closed).
# --audit : diagnostic de l'etat d'un arbre (R9 seul), jamais bloquant.
import argparse
import difflib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit

DOMAIN = "smadja.dev"
CLUSTER = "homelab"
ALLOWED_GROUPS = ("family", "friends", "authentik-admins")
PG_CLUSTER = "pg-shared-homelab"
PG_NS = "databases"
PG_RESERVED = ("app", "postgres", "template0", "template1")
PLAN_MAX_CPU_M = 500
PLAN_MAX_MEM_MI = 512
HUMAN_ENV = "SERVICE_CONTRACT_HUMAN_ADMISSION"
CATALOG = "k8s/applications/catalog"
BLUEPRINTS = "k8s/infrastructure/auth/authentik/extra/blueprints"
GROUPS_FILE = BLUEPRINTS + "/groups.yaml"
PG_DIR = "k8s/infrastructure/database/pg-shared-homelab"
PG_CLUSTER_FILE = PG_DIR + "/cluster.yaml"
ISOLATION_GUARD = "tests/harness/pg-shared-homelab-isolation-guard-test.sh"
# Fichiers existants que le template peut editer, par AJOUT PUR seulement (contrat).
ADDITIVE = (
    "k8s/applications/catalog/kustomization.yaml",
    PG_DIR + "/kustomization.yaml",
    PG_CLUSTER_FILE,
    "k8s/infrastructure/auth/authentik/extra/kustomization.yml",
    "k8s/infrastructure/auth/authentik/values.yaml",
    "k8s/bootstrap/argocd-root/applications-project.yaml",
)
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,18}[a-z0-9]$")
PGDB_RE = re.compile(r"^[a-z][a-z0-9]{1,39}$")
DIGEST_RE = re.compile(r"@sha256:[0-9a-f]{64}$")
SECRET_KEY_RE = re.compile(r"(PASSWORD|PASSWD|SECRET|TOKEN|APIKEY|API_KEY|PRIVATE_KEY)$", re.I)
TEXT_SECRET_RE = [
    ("cle privee PEM", re.compile(r"-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----")),
    ("jeton GitHub", re.compile(r"\bghp_[A-Za-z0-9]{30,}")),
    ("jeton GitHub fine-grained", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}")),
    ("cle AWS", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("jeton Slack", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
]
REQUIRED_ANNOTATIONS = (
    "cluster", "namespace", "exposure", "hostname", "data-class",
    "access-groups", "pg-database", "backup-rpo", "backup-rto",
)
YQ_EXPR = '. as $d | {"file": filename, "doc": $d}'
ROLE_KINDS = ("Role", "ClusterRole")


class GuardError(Exception):
    """Erreur d'outillage ou d'entree : arret, sortie 2 (fail closed)."""


class Report:
    def __init__(self):
        self.items = []  # (kind, rule, message)

    def fail(self, rule, msg):
        self.items.append(("FAIL", rule, msg))

    def mandat(self, rule, msg):
        self.items.append(("MANDAT", rule, msg))

    def hors(self, rule, msg):
        self.items.append(("HORS", rule, msg))


# ---------- acces aux arbres ----------

def git_bytes(repo, *args):
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    if proc.returncode != 0:
        raise GuardError("git %s: %s" % (" ".join(args), proc.stderr.decode("utf-8", "replace").strip()))
    return proc.stdout


def git_text(repo, *args):
    return git_bytes(repo, *args).decode("utf-8", "replace")


def extract(repo, ref, dest, paths):
    data = git_bytes(repo, "archive", "--format=tar", ref, "--", *paths)
    os.makedirs(dest, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as tf:
        if hasattr(tarfile, "data_filter"):
            tf.extractall(dest, filter="data")
        else:
            tf.extractall(dest)


def read(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
        return fh.read()


def yq_one(root, rels):
    return subprocess.run(["yq", "-o=json", "-I=0", YQ_EXPR, *rels], cwd=root, capture_output=True, text=True)


def load_docs(root, rels):
    """{rel: [doc, ...]} pour les YAML de root. Erreur de parse hors template = arret.
    Les fichiers contenant du templating Helm ({{ }}) non parsables sont ignores et comptes
    (meme politique que la garde pg-shared-homelab)."""
    docs = {}
    plain, templ = [], []
    for rel in rels:
        (templ if "{{" in read(root, rel) else plain).append(rel)

    def ingest(text):
        for line in text.splitlines():
            if not line.strip():
                continue
            obj = json.loads(line)
            if obj["doc"] is not None:
                docs.setdefault(obj["file"], []).append(obj["doc"])

    if plain:
        proc = yq_one(root, plain)
        if proc.returncode == 0:
            ingest(proc.stdout)
        else:
            for rel in plain:
                one = yq_one(root, [rel])
                if one.returncode != 0:
                    raise GuardError("YAML illisible: %s: %s" % (rel, one.stderr.strip()[:200]))
                ingest(one.stdout)
    skipped = []
    for rel in templ:
        one = yq_one(root, [rel])
        if one.returncode == 0:
            ingest(one.stdout)
        else:
            skipped.append(rel)
    return docs, skipped


def flat(doc):
    if not isinstance(doc, dict):
        return []
    if doc.get("kind") == "List":
        out = []
        for item in doc.get("items") or []:
            out.extend(flat(item))
        return out
    return [doc]


def objects(docs, prefix=""):
    for rel in sorted(docs):
        if prefix and not rel.startswith(prefix):
            continue
        for doc in docs[rel]:
            for obj in flat(doc):
                yield rel, obj


def meta(obj):
    m = obj.get("metadata")
    return m if isinstance(m, dict) else {}


def spec(obj):
    s = obj.get("spec")
    return s if isinstance(s, dict) else {}


def ns_of(obj):
    if obj.get("kind") == "Namespace":
        return meta(obj).get("name")
    return meta(obj).get("namespace")


def key_of(rel, obj):
    return (obj.get("kind"), ns_of(obj), meta(obj).get("name"))


def is_cnpg(obj, kind):
    return obj.get("kind") == kind and str(obj.get("apiVersion", "")).startswith("postgresql.cnpg.io/")


def quantity_m(q):
    s = str(q)
    return float(s[:-1]) if s.endswith("m") else float(s) * 1000.0


def quantity_mi(q):
    s = str(q)
    units = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "Ti": 1024 * 1024, "K": 1000 / 1048576,
             "M": 1000000 / 1048576, "G": 1000000000 / 1048576}
    for suffix in ("Ki", "Mi", "Gi", "Ti", "K", "M", "G"):
        if s.endswith(suffix):
            return float(s[: -len(suffix)]) * units[suffix]
    return float(s) / 1048576


def group_refs(node, out=None):
    """Noms de groupes lus par `!Find [authentik_core.group, [name, X]]` (yq -> liste)."""
    out = [] if out is None else out
    if isinstance(node, list):
        if (len(node) == 2 and node[0] == "authentik_core.group" and isinstance(node[1], list)
                and len(node[1]) == 2 and node[1][0] == "name"):
            out.append(node[1][1])
        for item in node:
            group_refs(item, out)
    elif isinstance(node, dict):
        for value in node.values():
            group_refs(value, out)
    return out


def blueprint_entries(docs, rel):
    entries = []
    for doc in docs.get(rel, []):
        if isinstance(doc, dict) and isinstance(doc.get("entries"), list):
            entries.extend(e for e in doc["entries"] if isinstance(e, dict))
    return entries


# ---------- index de l'etat de base (ce qui est deja pris sur main) ----------

def base_index(bdocs):
    ix = {"ns": set(), "db": set(), "roles": set(), "hosts": set(), "catalog": set(),
          "bp_ids": set(), "bp_files": set(), "groups": set()}
    for rel in bdocs:
        m = re.match(r"^" + CATALOG + r"/([^/]+)/", rel)
        if m:
            ix["catalog"].add(m.group(1))
        if rel.startswith(BLUEPRINTS + "/"):
            ix["bp_files"].add(rel)
    for rel, obj in objects(bdocs):
        ns = ns_of(obj)
        if ns:
            ix["ns"].add(ns)
        if is_cnpg(obj, "Database"):
            ix["db"].add(meta(obj).get("name"))
            ix["db"].add(spec(obj).get("name"))
        if obj.get("kind") == "HTTPRoute":
            ix["hosts"].update(spec(obj).get("hostnames") or [])
        if rel == PG_CLUSTER_FILE and is_cnpg(obj, "Cluster"):
            for role in (spec(obj).get("managed") or {}).get("roles") or []:
                ix["roles"].add(role.get("name"))
    for rel in ix["bp_files"]:
        for entry in blueprint_entries(bdocs, rel):
            for value in (entry.get("identifiers") or {}).values():
                if isinstance(value, str):
                    ix["bp_ids"].add(value)
    for entry in blueprint_entries(bdocs, GROUPS_FILE):
        if entry.get("model") == "authentik_core.group":
            name = (entry.get("identifiers") or {}).get("name")
            if name:
                ix["groups"].add(name)
    return ix


# ---------- verifications ----------

def check_service(n, ctx):
    rep, hdocs, ix = ctx.rep, ctx.head_docs, ctx.ix
    svc = [(r, o) for r, o in objects(hdocs, CATALOG + "/" + n + "/")]
    svc_files = sorted({r for r, _ in svc})
    info = {"pgdb": None, "host": None, "groups": []}

    if not NAME_RE.match(n):
        rep.fail("R1", "%s: nom hors contrat (regex %s)" % (n, NAME_RE.pattern))
    cinfo = [o for r, o in svc if r.endswith("/catalog-info.yaml")]
    if len(cinfo) != 1 or cinfo[0].get("kind") != "Component":
        rep.fail("R1", "%s: catalog-info.yaml absent ou invalide" % n)
        return info
    ann = meta(cinfo[0]).get("annotations") or {}

    def A(k):
        return ann.get("homelab.smadja.dev/" + k)

    missing = [k for k in REQUIRED_ANNOTATIONS if not A(k)]
    if missing:
        rep.fail("R1", "%s: annotations absentes: %s" % (n, ", ".join(missing)))
        return info
    if A("cluster") != CLUSTER:
        rep.fail("R1", "%s: cluster %r refuse (pilote : %s seul)" % (n, A("cluster"), CLUSTER))
    if A("namespace") != n:
        rep.fail("R1", "%s: annotation namespace %r differe du nom" % (n, A("namespace")))
    host = A("hostname")
    info["host"] = host
    if host != "%s.%s" % (n, DOMAIN):
        rep.fail("R3", "%s: hostname %r hors %s.%s" % (n, host, n, DOMAIN))
    if A("exposure") == "external":
        rep.mandat("R7", "%s: exposition external (MANDAT : Gateway/internal seul)" % n)
    elif A("exposure") != "internal":
        rep.fail("R7", "%s: exposition %r inconnue" % (n, A("exposure")))

    pgdb = A("pg-database")
    info["pgdb"] = pgdb
    if not PGDB_RE.match(pgdb or "") or pgdb in PG_RESERVED:
        rep.fail("R5", "%s: pg-database %r invalide ou reserve" % (n, pgdb))
    if pgdb in ix["db"] or pgdb in ix["roles"] or pgdb in ix["ns"]:
        rep.fail("R1", "%s: base/role %s deja pris sur main" % (n, pgdb))
    for label, value in (("namespace", n), ("hostname", host), ("Authentik", n)):
        if value and (value in ix["ns"] or value in ix["catalog"]):
            rep.fail("R1", "%s: %s %s deja pris sur main" % (n, label, value))
    if n in ix["bp_ids"] or (BLUEPRINTS + "/apps-%s.yaml" % n) in ix["bp_files"]:
        rep.fail("R1", "%s: blueprint Authentik deja present sur main" % n)
    if host in ix["hosts"]:
        rep.fail("R1", "%s: hostname %s deja route sur main" % (n, host))

    groups = [g.strip() for g in (A("access-groups") or "").split(",") if g.strip()]
    info["groups"] = groups
    if not groups:
        rep.fail("R2", "%s: access-groups vide" % n)
    for g in groups:
        if g not in ALLOWED_GROUPS:
            rep.fail("R2", "%s: groupe %s non autorise (autorises : %s)" % (n, g, ", ".join(ALLOWED_GROUPS)))
        elif g not in ix["groups"]:
            rep.fail("R2", "%s: groupe %s absent de groups.yaml sur main" % (n, g))

    # Blueprint Authentik du service : bindings, redirect, client confidentiel.
    bp = BLUEPRINTS + "/apps-%s.yaml" % n
    if bp not in hdocs:
        rep.fail("R3", "%s: blueprint %s absent" % (n, bp))
    else:
        entries = blueprint_entries(hdocs, bp)
        bound = set(group_refs(entries))
        if bound != set(groups):
            rep.fail("R2", "%s: bindings Authentik %s differents de access-groups %s"
                     % (n, sorted(bound), sorted(groups)))
        providers = [e for e in entries if e.get("model") == "authentik_providers_oauth2.oauth2provider"]
        if len(providers) != 1:
            rep.fail("R3", "%s: %d provider OAuth2 (attendu 1)" % (n, len(providers)))
        for prov in providers:
            attrs = prov.get("attrs") or {}
            if attrs.get("client_type") != "confidential":
                rep.fail("R3", "%s: client OIDC non confidentiel (%r)" % (n, attrs.get("client_type")))
            uris = attrs.get("redirect_uris") or []
            if len(uris) != 1:
                rep.fail("R3", "%s: %d redirect_uris (attendu 1)" % (n, len(uris)))
            for item in uris:
                url = item.get("url") if isinstance(item, dict) else item
                mode = item.get("matching_mode") if isinstance(item, dict) else "strict"
                parts = urlsplit(str(url))
                ok = (parts.scheme == "https" and parts.hostname == host and parts.port is None
                      and not parts.username and not parts.query and not parts.fragment
                      and re.fullmatch(r"/[A-Za-z0-9_./-]+", parts.path or "") is not None
                      and ".." not in parts.path and mode == "strict")
                if not ok:
                    rep.fail("R3", "%s: redirect_uri %s differe de https://%s<callback> (strict)"
                             % (n, url, host))
        raw = read(ctx.head_dir, bp)
        if re.search(r"client_secret:", raw) and not re.search(
                r"client_secret:\s*!Env\s+[A-Z][A-Z0-9_]*\s*$", raw, re.M):
            rep.fail("R6", "%s: client_secret litteral dans le blueprint (attendu !Env)" % n)

    # Exposition : HTTPRoute uniquement sur Gateway/internal, hostname identique.
    routes = [o for r, o in svc if o.get("kind") == "HTTPRoute"]
    if not routes:
        rep.fail("R7", "%s: aucune HTTPRoute" % n)
    for route in routes:
        for ref in spec(route).get("parentRefs") or []:
            if ref.get("name") == "external" or ref.get("namespace") == "external":
                rep.mandat("R7", "%s: HTTPRoute sur Gateway external (MANDAT)" % n)
            elif (ref.get("name"), ref.get("namespace")) != ("internal", "gateway"):
                rep.fail("R7", "%s: parentRef %s/%s hors Gateway/internal" % (n, ref.get("namespace"), ref.get("name")))
        if spec(route).get("hostnames") != [host]:
            rep.fail("R7", "%s: hostnames %s differents de %s" % (n, spec(route).get("hostnames"), host))

    # Charges de travail : baseline et identite de pod.
    pods = []
    for r, o in svc:
        k = o.get("kind")
        s = spec(o)
        if k in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
            pod = ((s.get("template") or {}).get("spec"))
        elif k == "CronJob":
            pod = ((((s.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec"))
        elif k == "Pod":
            pod = s
        else:
            continue
        pods.append((r, o, pod or {}))
    if not pods:
        rep.fail("R8", "%s: aucune charge de travail" % n)
    for r, o, pod in pods:
        check_pod(n, r, pod, svc, rep)
    if not any(o.get("kind") == "CiliumNetworkPolicy" for _, o in svc):
        rep.fail("R8", "%s: CiliumNetworkPolicy absente" % n)

    # Identite : SA du pod distinct du secret-reader, sans token monte.
    reader = "%s-secret-reader" % n
    sa_objs = {meta(o).get("name"): o for _, o in svc if o.get("kind") == "ServiceAccount"}
    if reader not in sa_objs or sa_objs[reader].get("automountServiceAccountToken") is not False:
        rep.fail("R6", "%s: SA %s absent ou token monte" % (n, reader))

    check_secrets(n, pgdb, svc, ctx)
    check_database(n, pgdb, ctx)
    return info


def check_pod(n, rel, pod, svc, rep):
    sa = pod.get("serviceAccountName") or "default"
    if sa == "default" or sa == "%s-secret-reader" % n:
        rep.fail("R6", "%s: SA du pod %s interdit (doit etre dedie, distinct du secret-reader)" % (n, sa))
    if pod.get("automountServiceAccountToken") is not False:
        rep.fail("R6", "%s: automountServiceAccountToken doit etre false sur le pod" % n)
    sas = {meta(o).get("name"): o for _, o in svc if o.get("kind") == "ServiceAccount"}
    if sa in sas and sas[sa].get("automountServiceAccountToken") is not False:
        rep.fail("R6", "%s: SA %s monte son token" % (n, sa))
    pod_sc = pod.get("securityContext") or {}
    containers = (pod.get("containers") or []) + (pod.get("initContainers") or [])
    if not containers:
        rep.fail("R8", "%s: %s sans conteneur" % (n, rel))
    for c in containers:
        cname = c.get("name")
        img = str(c.get("image", ""))
        if not DIGEST_RE.search(img):
            rep.fail("R8", "%s: image %s sans digest @sha256:" % (n, img))
        res = c.get("resources") or {}
        req, lim = res.get("requests") or {}, res.get("limits") or {}
        for label, src in (("requests.cpu", req.get("cpu")), ("requests.memory", req.get("memory")),
                           ("limits.cpu", lim.get("cpu")), ("limits.memory", lim.get("memory"))):
            if src is None:
                rep.fail("R8", "%s/%s: %s absent" % (n, cname, label))
        try:
            if lim.get("cpu") is not None and quantity_m(lim["cpu"]) > PLAN_MAX_CPU_M:
                rep.fail("R8", "%s/%s: limite CPU %s au-dela du plafond pilote 500m" % (n, cname, lim["cpu"]))
            if lim.get("memory") is not None and quantity_mi(lim["memory"]) > PLAN_MAX_MEM_MI:
                rep.fail("R8", "%s/%s: limite RAM %s au-dela du plafond pilote 512Mi" % (n, cname, lim["memory"]))
            if req.get("cpu") is not None and lim.get("cpu") is not None and quantity_m(req["cpu"]) > quantity_m(lim["cpu"]):
                rep.fail("R8", "%s/%s: requete CPU > limite" % (n, cname))
            if req.get("memory") is not None and lim.get("memory") is not None and quantity_mi(req["memory"]) > quantity_mi(lim["memory"]):
                rep.fail("R8", "%s/%s: requete RAM > limite" % (n, cname))
        except ValueError:
            rep.fail("R8", "%s/%s: quantite de ressources illisible" % (n, cname))
        for probe in ("readinessProbe", "livenessProbe"):
            if not c.get(probe):
                rep.fail("R8", "%s/%s: %s absente" % (n, cname, probe))
        sc = c.get("securityContext") or {}
        if sc.get("allowPrivilegeEscalation") is not False:
            rep.fail("R8", "%s/%s: allowPrivilegeEscalation doit etre false" % (n, cname))
        if sc.get("readOnlyRootFilesystem") is not True:
            rep.fail("R8", "%s/%s: readOnlyRootFilesystem doit etre true" % (n, cname))
        drop = [str(x).upper() for x in ((sc.get("capabilities") or {}).get("drop") or [])]
        if "ALL" not in drop:
            rep.fail("R8", "%s/%s: capabilities.drop doit contenir ALL" % (n, cname))
        if sc.get("runAsNonRoot") is not True and pod_sc.get("runAsNonRoot") is not True:
            rep.fail("R8", "%s/%s: runAsNonRoot non impose" % (n, cname))
        for env in c.get("env") or []:
            if "value" in env and env.get("value") not in (None, "") and SECRET_KEY_RE.search(str(env.get("name", ""))):
                rep.fail("R6", "%s/%s: variable %s a une valeur litterale (secret attendu via secretRef)"
                         % (n, cname, env.get("name")))


def check_secrets(n, pgdb, svc, ctx):
    """ExternalSecret/SecretStore associes au service : seulement ses propres secrets."""
    rep = ctx.rep
    own = {"pg-shared-homelab-%s" % n, "authentik-blueprint-%s" % n}
    for rel, o in objects(ctx.head_docs):
        if (o.get("kind") not in ("ExternalSecret", "SecretStore")) or not str(o.get("apiVersion", "")).startswith("external-secrets.io/"):
            continue
        if key_of(rel, o) in ctx.base_keys:
            continue
        name = str(meta(o).get("name", ""))
        ns = ns_of(o)
        if not (ns == n or (ns in ("databases", "auth") and (n in name or pgdb in name))):
            continue
        if o.get("kind") == "SecretStore":
            prov = (spec(o).get("provider") or {}).get("kubernetes")
            if not isinstance(prov, dict) or ns != n:
                rep.fail("R6", "%s: SecretStore %s/%s hors kubernetes ou hors namespace app" % (n, ns, name))
                continue
            if prov.get("remoteNamespace") not in ("databases", "auth"):
                rep.fail("R6", "%s: SecretStore %s lit le namespace %s" % (n, name, prov.get("remoteNamespace")))
            if ((prov.get("auth") or {}).get("serviceAccount") or {}).get("name") != "%s-secret-reader" % n:
                rep.fail("R6", "%s: SecretStore %s n'utilise pas %s-secret-reader" % (n, name, n))
        else:
            keys = [d.get("remoteRef", {}).get("key") for d in spec(o).get("data") or [] if isinstance(d, dict)]
            keys += [((e.get("extract") or {}).get("key")) for e in spec(o).get("dataFrom") or [] if isinstance(e, dict)]
            if any(e.get("find") for e in spec(o).get("dataFrom") or [] if isinstance(e, dict)):
                rep.fail("R6", "%s: ExternalSecret %s utilise find (hors perimetre)" % (n, name))
            for key in keys:
                if key and key not in own:
                    rep.fail("R6", "%s: ExternalSecret %s lit %s (hors secrets propres %s)"
                             % (n, name, key, ", ".join(sorted(own))))


def check_database(n, pgdb, ctx):
    rep = ctx.rep
    dbs = [(r, o) for r, o in objects(ctx.head_docs) if is_cnpg(o, "Database") and spec(o).get("name") == pgdb]
    if len(dbs) != 1:
        rep.fail("R5", "%s: %d Database pour la base %s (attendu 1)" % (n, len(dbs), pgdb))
    for rel, d in dbs:
        if ns_of(d) != PG_NS or spec(d).get("cluster", {}).get("name") != PG_CLUSTER:
            rep.fail("R5", "%s: Database %s hors %s/%s" % (n, pgdb, PG_NS, PG_CLUSTER))
        if spec(d).get("owner") != pgdb:
            rep.fail("R5", "%s: owner de la base %s = %s (attendu le role de l'app %s)"
                     % (n, pgdb, spec(d).get("owner"), pgdb))
    cluster_docs = ctx.head_docs.get(PG_CLUSTER_FILE, [])
    roles = []
    for doc in cluster_docs:
        for o in flat(doc):
            if is_cnpg(o, "Cluster"):
                roles.extend((spec(o).get("managed") or {}).get("roles") or [])
    mine = [r for r in roles if r.get("name") == pgdb]
    if len(mine) != 1:
        rep.fail("R5", "%s: %d role PG %s dans managed.roles (attendu 1)" % (n, len(mine), pgdb))
    for role in mine:
        if role.get("ensure") != "present":
            rep.fail("R5", "%s: role %s non present" % (n, pgdb))
        for flag in ("superuser", "createdb", "createrole", "replication", "bypassrls"):
            if role.get(flag) is True:
                rep.fail("R5", "%s: role %s avec %s=true (interdit)" % (n, pgdb, flag))
        if role.get("inRoles"):
            rep.fail("R5", "%s: role %s avec inRoles (interdit)" % (n, pgdb))
        if (role.get("passwordSecret") or {}).get("name") != "pg-shared-homelab-%s" % n:
            rep.fail("R5", "%s: passwordSecret du role %s != pg-shared-homelab-%s" % (n, pgdb, n))
    jobname = "pg-shared-homelab-%s-isolation" % pgdb
    jobs = [o for r, o in objects(ctx.head_docs, PG_DIR + "/") if o.get("kind") == "Job" and meta(o).get("name") == jobname]
    if len(jobs) != 1:
        rep.fail("R5", "%s: Job d'isolation %s absent" % (n, jobname))
    elif ("REVOKE CONNECT ON DATABASE %s FROM PUBLIC" % pgdb) not in json.dumps(jobs[0]):
        rep.fail("R5", "%s: Job %s ne revoque pas CONNECT sur %s" % (n, jobname, pgdb))


def check_global(ctx):
    rep, head, ix = ctx.rep, ctx.head_docs, ctx.ix
    admitted = ctx.admitted
    adm_pgdb = {ctx.info[n]["pgdb"] for n in admitted if ctx.info.get(n)}
    adm_secret_own = set()
    for n in admitted:
        adm_secret_own |= {"pg-shared-homelab-%s" % n, "authentik-blueprint-%s" % n}

    # R4 : protections MANDAT, independantes du perimetre (toute PR).
    for st, path in ctx.changes:
        if path.startswith(BLUEPRINTS + "/") and st in ("M", "D") and path in ctx.bdocs:
            rep.mandat("R4", "blueprint Authentik existant %s %s (MANDAT)" % (
                {"M": "modifie", "D": "supprime"}[st], path))
    for rel in sorted(head):
        if rel.startswith(BLUEPRINTS + "/") and rel not in ix["bp_files"]:
            for entry in blueprint_entries(head, rel):
                if entry.get("model") == "authentik_core.group":
                    name = (entry.get("identifiers") or {}).get("name")
                    rep.mandat("R4", "creation de groupe %s dans %s (MANDAT)" % (name, rel))
        if rel.startswith(BLUEPRINTS + "/") and rel not in ix["bp_files"]:
            for entry in blueprint_entries(head, rel):
                for g in group_refs(entry):
                    if g not in ALLOWED_GROUPS:
                        rep.fail("R2", "%s: binding sur groupe %s non autorise" % (rel, g))

    # R5 : aucun nouveau Cluster CNPG ; roles et Databases nouveaux seulement pour un service admis.
    for rel, o in objects(head):
        if is_cnpg(o, "Cluster") and key_of(rel, o) not in ctx.base_keys:
            rep.fail("R5", "nouveau Cluster CNPG %s (%s) : interdit (base partagee)" % (meta(o).get("name"), rel))
        if is_cnpg(o, "Database") and key_of(rel, o) not in ctx.base_keys and spec(o).get("name") not in adm_pgdb:
            rep.fail("R5", "Database %s nouvelle hors service admis" % spec(o).get("name"))
    head_roles = [r for doc in head.get(PG_CLUSTER_FILE, []) for o in flat(doc) if is_cnpg(o, "Cluster")
                  for r in (spec(o).get("managed") or {}).get("roles") or []]
    for role in head_roles:
        if role.get("name") not in ix["roles"] and role.get("name") not in adm_pgdb:
            rep.fail("R5", "role PG %s nouveau hors service admis" % role.get("name"))

    # R6 : RBAC. Aucun droit secret sans resourceNames, aucun cluster-wide, binding limite.
    roles_by_key = {}
    for rel, o in objects(head):
        if o.get("kind") in ROLE_KINDS:
            roles_by_key[(o.get("kind"), ns_of(o), meta(o).get("name"))] = o
    for rel, o in objects(head):
        if key_of(rel, o) in ctx.base_keys:
            continue
        k = o.get("kind")
        if k in ROLE_KINDS:
            for rule in o.get("rules") or []:
                res = rule.get("resources") or []
                if "secrets" not in res and "*" not in res:
                    continue
                verbs = set(rule.get("verbs") or [])
                names = rule.get("resourceNames") or []
                if not names:
                    rep.fail("R6", "%s %s: droits sur secrets sans resourceNames (%s)" % (k, meta(o).get("name"), rel))
                if not verbs or verbs - {"get"}:
                    rep.fail("R6", "%s %s: verbes %s sur secrets (seul get est admis)" % (k, meta(o).get("name"), sorted(verbs)))
                bad = [x for x in names if x not in adm_secret_own]
                if bad:
                    rep.fail("R6", "%s %s: resourceNames %s hors secrets propres" % (k, meta(o).get("name"), bad))
                if k == "ClusterRole":
                    rep.fail("R6", "ClusterRole %s donne acces aux secrets (interdit)" % meta(o).get("name"))
        elif k == "ClusterRoleBinding":
            rep.fail("R6", "nouveau ClusterRoleBinding %s (interdit pour un service)" % meta(o).get("name"))
        elif k == "RoleBinding" and ns_of(o) in ("databases", "auth"):
            for sub in o.get("subjects") or []:
                sname = str(sub.get("name", ""))
                sns = sub.get("namespace")
                target = sname[: -len("-secret-reader")] if sname.endswith("-secret-reader") else None
                if sub.get("kind") != "ServiceAccount" or target is None or sns != target or target not in admitted:
                    rep.fail("R6", "RoleBinding %s/%s : sujet %s/%s hors SA <app>-secret-reader admis"
                             % (ns_of(o), meta(o).get("name"), sns, sname))
                    continue
                ref = roles_by_key.get(("Role", ns_of(o), (o.get("roleRef") or {}).get("name")))
                if ref is None:
                    rep.fail("R6", "RoleBinding %s : Role referencee introuvable" % meta(o).get("name"))
                    continue
                own = {"pg-shared-homelab-%s" % target, "authentik-blueprint-%s" % target}
                for rule in ref.get("rules") or []:
                    if set(rule.get("resourceNames") or []) - own:
                        rep.fail("R6", "Role %s : secrets hors ceux de %s" % (meta(ref).get("name"), target))
        if o.get("kind") == "Secret" and not (key_of(rel, o) in ctx.base_keys):
            rep.fail("R6", "Secret %s ecrit dans Git (%s) : interdit" % (meta(o).get("name"), rel))

    # R7 : toute nouvelle HTTPRoute sur external = MANDAT.
    for rel, o in objects(head):
        if o.get("kind") == "HTTPRoute" and key_of(rel, o) not in ctx.base_keys:
            for ref in spec(o).get("parentRefs") or []:
                if ref.get("name") == "external":
                    rep.mandat("R7", "HTTPRoute %s sur Gateway external (MANDAT)" % meta(o).get("name"))

    for st, path in ctx.changes:
        if st in ("A", "M") and path in ctx.skipped and not path.startswith(RENDERED_CHART_PREFIXES):
            rep.fail("R8", "%s : YAML templaté non analysable dans une PR (refus, pas d ignorance silencieuse)" % path)

    # R6 : motifs de secrets litteraux dans les fichiers ajoutes ou modifies sous k8s/.
    for st, path in ctx.changes:
        if st not in ("A", "M") or not path.startswith("k8s/"):
            continue
        try:
            text = read(ctx.head_dir, path)
        except (OSError, UnicodeDecodeError):
            continue
        for label, pat in TEXT_SECRET_RE:
            if pat.search(text):
                rep.fail("R6", "%s : motif de secret litteral (%s)" % (path, label))

    # R9 : chaque namespace rendu doit figurer dans les destinations du projet Argo.
    maps, projects = project_maps(head)
    for st, path in ctx.changes:
        if st not in ("A", "M") or not path.startswith("k8s/") or path not in head:
            continue
        check_namespaces(path, head[path], maps, projects, rep)

    # Perimetre (HORS) : seulement quand une PR touche un service.
    if admitted or ctx.services:
        for st, path in ctx.changes:
            if not path.startswith("k8s/") or path.startswith(BLUEPRINTS + "/"):
                continue
            if st in ("M", "D") and path.startswith(CATALOG + "/"):
                continue  # service existant : deja MANDAT R4
            if st == "A":
                if not any(n in os.path.basename(path) or path.startswith(CATALOG + "/%s/" % n)
                           for n in ctx.services):
                    rep.hors("perimetre", "fichier ajoute hors perimetre du service (%s)" % path)
            elif st == "M" and path in ADDITIVE:
                ops = difflib.SequenceMatcher(None, read(ctx.base_dir, path).splitlines(),
                                              read(ctx.head_dir, path).splitlines(), autojunk=False).get_opcodes()
                if any(op[0] in ("replace", "delete") for op in ops):
                    rep.hors("additif", "modification non additive de %s (contrat : ajout pur)" % path)
            elif st in ("M", "D"):
                rep.hors("additif", "fichier existant %s %s hors contrat" % (
                    {"M": "modifie", "D": "supprime"}[st], path))


def project_maps(head):
    maps, projects = [], {}
    for rel, o in objects(head):
        if o.get("kind") == "ApplicationSet":
            project = ((spec(o).get("template") or {}).get("spec") or {}).get("project")
            for gen in spec(o).get("generators") or []:
                for d in ((gen.get("git") or {}).get("directories") or []):
                    maps.append((d.get("path", ""), project))
        if o.get("kind") == "AppProject":
            dests = {d.get("namespace") for d in spec(o).get("destinations") or [] if isinstance(d, dict)}
            projects[meta(o).get("name")] = dests
    return maps, projects


def check_namespaces(path, docs, maps, projects, rep):
    cands = [(d, p) for d, p in maps if path.startswith(d.rstrip("/") + "/")]
    if not cands:
        return
    proj = max(cands, key=lambda c: len(c[0]))[1]
    if proj not in projects:
        rep.fail("R9", "projet Argo %s introuvable pour %s" % (proj, path))
        return
    dests = projects[proj]
    for doc in docs:
        for o in flat(doc):
            ns = ns_of(o)
            if ns and ns not in dests and "*" not in dests:
                rep.fail("R9", "namespace %s absent des destinations du projet %s (rendu par %s) : Argo refuse la synchro"
                         % (ns, proj, path))


# ---------- orchestration ----------

class Ctx:
    pass


def run(args):
    repo = os.path.abspath(args.repo)
    tool_ok = shutil.which("yq") and shutil.which("git")
    if not tool_ok:
        raise GuardError("git et yq sont requis")
    head_sha = git_text(repo, "rev-parse", "--verify", args.head + "^{commit}").strip()
    tmp = tempfile.mkdtemp(prefix="service-contract-")
    try:
        head_dir = os.path.join(tmp, "head")
        extract(repo, head_sha, head_dir, ["k8s"])
        present = subprocess.run(["git", "-C", repo, "cat-file", "-e", head_sha + ":" + ISOLATION_GUARD],
                                 capture_output=True).returncode == 0
        if present:
            extract(repo, head_sha, head_dir, [ISOLATION_GUARD])
        hdocs, skipped_h = load_docs(head_dir, sorted(
            os.path.relpath(os.path.join(d, f), head_dir)
            for d, _, fs in os.walk(os.path.join(head_dir, "k8s"))
            for f in fs if f.endswith((".yaml", ".yml"))))

        if args.audit:
            return audit(hdocs, skipped_h)

        base_sha = git_text(repo, "merge-base", args.base, head_sha).strip()
        base_dir = os.path.join(tmp, "base")
        extract(repo, base_sha, base_dir, ["k8s"])
        bdocs, skipped_b = load_docs(base_dir, sorted(
            os.path.relpath(os.path.join(d, f), base_dir)
            for d, _, fs in os.walk(os.path.join(base_dir, "k8s"))
            for f in fs if f.endswith((".yaml", ".yml"))))
        changes = []
        for line in git_text(repo, "diff", "--no-renames", "--name-status", base_sha, head_sha).splitlines():
            parts = line.split("\t")
            if len(parts) == 2:
                changes.append((parts[0][0], parts[1]))

        ctx = Ctx()
        ctx.rep = Report()
        ctx.base_dir, ctx.head_dir = base_dir, head_dir
        ctx.bdocs, ctx.head_docs = bdocs, hdocs
        ctx.changes = changes
        ctx.skipped = set(skipped_h)
        ctx.ix = base_index(bdocs)
        ctx.base_keys = {key_of(r, o) for r, o in objects(bdocs)}
        ctx.info = {}
        ctx.services = sorted({m.group(1) for _, p in changes
                               for m in [re.match(r"^" + CATALOG + r"/([^/]+)/", p)] if m})
        ctx.admitted = []
        for n in ctx.services:
            if n in ctx.ix["catalog"]:
                ctx.rep.mandat("R4", "service existant %s modifie ou supprime (MANDAT)" % n)
                continue
            ctx.info[n] = check_service(n, ctx) or {}
            ctx.admitted.append(n)
        check_global(ctx)
        # Garde d'isolation pg-shared-homelab (existante), sur l'arbre head.
        iso = os.path.join(head_dir, ISOLATION_GUARD)
        if present:
            proc = subprocess.run(["bash", iso], cwd=head_dir, capture_output=True, text=True)
            if proc.returncode != 0:
                ctx.rep.fail("R5", "garde pg-shared-homelab-isolation en echec: %s"
                             % (proc.stdout + proc.stderr).strip().splitlines()[-1:])
        else:
            ctx.rep.fail("R5", "garde pg-shared-homelab-isolation absente de l'arbre")
        return report(ctx, args, skipped_h)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# Templates Helm du renderer platform-app : non parsables en YAML brut, mais leur
# sortie RENDUE est validée (schéma, déterminisme, kubeconform, refus) par
# .github/workflows/platform-app-contract.yaml. Liste nominative, pas de joker.
RENDERED_CHART_PREFIXES = ("k8s/charts/platform-app/templates/",)


def report(ctx, args, skipped):
    human = os.environ.get(HUMAN_ENV, "").strip()
    # En CI, une PR qui ne vient pas du Scaffolder (branche golden-path/*) n'est pas une
    # demande de creation de service : modifier un service existant ou un fichier protege y
    # releve de la revue humaine (le merge de Paul est l'admission), pas d'un echec de CI.
    # Les violations techniques (FAIL) restent bloquantes. En local (sans GITHUB_EVENT_NAME)
    # et pour les branches golden-path/*, le comportement strict est inchange.
    # Une PR qui CREE un service (ctx.admitted non vide) reste stricte quelle que soit sa
    # branche : une PR ecrite a la main doit respecter les memes invariants que le template.
    advisory = (os.environ.get("GITHUB_EVENT_NAME") == "pull_request"
                and not os.environ.get("GITHUB_HEAD_REF", "").startswith("golden-path/")
                and not ctx.admitted)
    failing = 0
    seen = set()
    for kind, rule, msg in ctx.rep.items:
        line = "%s %s: %s" % (kind, rule, msg)
        if line in seen:
            continue
        seen.add(line)
        if kind in ("MANDAT", "HORS") and human:
            print("ADMIS-HUMAIN [%s] %s (%s=%s)" % (rule, msg, HUMAN_ENV, human))
            continue
        if kind in ("MANDAT", "HORS") and advisory:
            print("CONSEIL (revue humaine) [%s] %s" % (rule, msg))
            continue
        failing += 1
        print("%s [%s] %s" % (kind, rule, msg))
    services = ",".join(ctx.services) or "-"
    if skipped:
        print("NOTE: %d fichier(s) Helm templates non parsables ignores (politique pg-shared-homelab)" % len(skipped))
    if failing:
        print("SERVICE_CONTRACT_GUARD=FAIL services=%s refus=%d" % (services, failing))
        return 1
    print("SERVICE_CONTRACT_GUARD=PASS services=%s" % services)
    return 0


def audit(hdocs, skipped):
    """Diagnostic (non bloquant) : namespaces rendus absents de leur projet Argo."""
    maps, projects = project_maps(hdocs)

    class Sink:
        def __init__(self):
            self.items = []

        def fail(self, rule, msg):
            self.items.append(("PREEXISTANT", rule, msg))

    sink = Sink()
    for rel in sorted(hdocs):
        check_namespaces(rel, hdocs[rel], maps, projects, sink)
    for _, rule, msg in sink.items:
        print("PREEXISTANT [%s] %s" % (rule, msg))
    print("SERVICE_CONTRACT_AUDIT=REPORT findings=%d (non bloquant)" % len(sink.items))
    return 0


def main(argv):
    default_repo = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    ap = argparse.ArgumentParser(description="garde d'admission service-contract")
    ap.add_argument("--repo", default=default_repo)
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--audit", action="store_true")
    args = ap.parse_args(argv)
    try:
        return run(args)
    except GuardError as exc:
        print("ERREUR (fail closed): %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
