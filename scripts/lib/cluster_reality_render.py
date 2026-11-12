#!/usr/bin/env python3
"""Render docs/state/cluster-reality.md from kubectl JSON dumps (see scripts/cluster-reality.sh).

Reads only the JSON files in WORK (no cluster access, no Secret values).
Usage: cluster_reality_render.py REPO_ROOT WORK_DIR OUTPUT_FILE
"""
import collections
import datetime
import json
import os
import re
import sys

import yaml

ROOT, WORK, OUT = sys.argv[1:4]


def load(name):
    with open(os.path.join(WORK, name)) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Explicit judgement tables (D-05 data class, verdict). Edit here, not in the md.
# class: IRR = irremplaçable (D-05 à protéger), REC = reconstructible (hors backup),
#        SOCLE = infrastructure/état de plateforme, ? = à confirmer.
# ---------------------------------------------------------------------------
INFRA = {
    "agent-observers", "agent-sandbox-system", "agentgateway", "arc-runners", "arc-systems", "argo-rollouts",
    "argocd", "atlantis-apps", "atlantis-system", "auth", "cert-manager", "cilium-secrets", "cloudflared",
    "cnpg-system", "csi-proxmox", "external-dns-private", "external-secrets", "falco", "gatekeeper-system",
    "gateway", "keda", "kube-system", "kubearmor", "kubechecks", "kubelet-serving-cert-approver", "kyverno",
    "longhorn-system", "metrics-server", "monitoring", "node-feature-discovery", "openclaw-operator-system",
    "reloader", "security-system", "trivy-system", "velero", "vertical-pod-autoscaler", "argo-rollouts-demo",
}
D06 = ("D-06 : contrôleur à retirer sur preuve (coût mesuré, consommateur réel) ou à justifier",)
# ns -> (class, verdict, reason)
MAP = {
    # --- données irremplaçables (D-05)
    "immich": ("IRR", "GARDER", "photos/vidéos originales (D-05)"),
    "paperless": ("IRR", "GARDER", "documents (D-05)"),
    "invoice-ninja": ("IRR", "GARDER", "factures (D-05)"),
    "rustical-pilot": ("IRR", "GARDER", "calendriers/contacts (D-05)"),
    "wellness": ("IRR", "GARDER", "santé/sport (SparkyFitness, D-05)"),
    "hindsight-personal": ("IRR?", "GARDER", "mémoire d'agent, utilité à confirmer (D-05)"),
    "trilium": ("IRR?", "GARDER", "notes personnelles"),
    "mealie": ("IRR?", "GARDER", "recettes, lecture Hermes (D-08)"),
    "sure": ("IRR?", "GARDER", "finances perso, à confirmer"),
    "matrix": ("IRR?", "GARDER", "messagerie famille, à confirmer"),
    "home-assistant": ("IRR?", "GARDER", "config domotique ; cible N100 (D-11, proposée)"),
    "karakeep": ("IRR?", "GARDER", "marque-pages ; à confirmer"),
    "vikunja": ("IRR?", "GARDER", "tâches ; à confirmer"),
    "auth": ("IRR", "GARDER", "Authentik = autorité d'identité"),
    "openclaw-operator-system": ("REC", "GARDER", "opérateur OpenClaw desired state SUSPENDU via GitOps (replicas 0, PLT-217) ; CRD openclaw.rocks conservées"),
    # --- reconstructibles utiles
    "mqtt": ("REC", "GARDER", "bus domotique ; cible N100 (D-11, proposée)"),
    "ntfy": ("REC", "GARDER", "notifications"),
    "searxng": ("REC", "GARDER", "méta-recherche sans état"),
    "it-tools": ("REC", "GARDER", "sans état, scale-to-zero KEDA voulu (#405), coût nul"),
    "stirling-pdf": ("REC", "GARDER", "outil PDF sans état"),
    "pinepods": ("REC", "GARDER", "podcasts re-téléchargeables"),
    "romm": ("REC?", "GARDER", "bibliothèque ROM ; usage à mesurer"),
    "gpt-researcher": ("REC", "ALLÉGER", "usage non mesurable ; candidat scale 0 si inutilisé"),
    "executor": ("REC", "ALLÉGER", "préparé à 0 réplica dans Git ; activer ou retirer, décision Factory (D-09)"),
    "opencode": ("REC", "GARDER", "poste agent (D-13)"),
    "open-connector": ("REC", "GARDER", "connecteurs agents"),
    "mastra-factory": ("REC", "GARDER", "Factory MVP (D-09)"),
    "mastra-sandbox": ("REC", "GARDER", "Factory MVP (D-09)"),
    "factory-platform": ("REC", "GARDER", "Factory MVP (D-09)"),
    "media": ("REC", "DÉPLACER-ORACLE", "AIOStreams + Polyfin candidats Oracle (D-07, hypothèse pilote)"),
    # --- socle
    "argocd": ("SOCLE", "GARDER", "reconciler unique"),
    "cert-manager": ("SOCLE", "GARDER", "TLS"),
    "cilium-secrets": ("SOCLE", "GARDER", "CNI/Gateway"),
    "kube-system": ("SOCLE", "GARDER", "CNI, CoreDNS, Hubble"),
    "cloudflared": ("SOCLE", "GARDER", "accès public (tunnel)"),
    "cnpg-system": ("SOCLE", "GARDER", "opérateur Postgres/Barman"),
    "csi-proxmox": ("SOCLE", "GARDER", "stockage"),
    "longhorn-system": ("SOCLE", "GARDER", "stockage"),
    "external-dns-private": ("SOCLE", "GARDER", "DNS privé"),
    "external-secrets": ("SOCLE", "GARDER", "Doppler -> ESO"),
    "gateway": ("SOCLE", "GARDER", "Gateway API"),
    "kyverno": ("SOCLE", "GARDER", "moteur de policy cible (D-06)"),
    "kubelet-serving-cert-approver": ("SOCLE", "GARDER", "certificats kubelet"),
    "metrics-server": ("SOCLE", "GARDER", "métriques HPA/top"),
    "reloader": ("SOCLE", "GARDER", "rollout sur changement de secret"),
    "velero": ("SOCLE", "GARDER", "sauvegarde Kopia (D-05)"),
    "monitoring": ("SOCLE", "GARDER", "Prometheus/Loki/Grafana ; Tempo/Alloy à justifier"),
    "agentgateway": ("SOCLE", "GARDER", "passerelle agents/MCP"),
    "agent-sandbox-system": ("SOCLE", "GARDER", "sandbox agents (Factory)"),
    "agent-observers": ("SOCLE", "GARDER", "observateurs agents"),
    "arc-systems": ("SOCLE", "GARDER", "CI self-hosted"),
    "arc-runners": ("SOCLE", "GARDER", "CI self-hosted"),
    # --- contrôleurs D-06 : retrait sur preuve
    "falco": ("SOCLE", "ALLÉGER", D06[0]),
    "trivy-system": ("SOCLE", "ALLÉGER", D06[0]),
    "kubearmor": ("SOCLE", "ALLÉGER", D06[0]),
    "gatekeeper-system": ("SOCLE", "ALLÉGER", "D-06 : retrait après conversion des contraintes vers Kyverno"),
    "security-system": ("SOCLE", "ALLÉGER", D06[0]),
    "kubechecks": ("SOCLE", "ALLÉGER", "déjà à 0 réplica ; D-06 retrait sur preuve (route publique résiduelle à fermer)"),
    "keda": ("SOCLE", "ALLÉGER", D06[0]),
    "vertical-pod-autoscaler": ("SOCLE", "ALLÉGER", D06[0]),
    "argo-rollouts": ("SOCLE", "ALLÉGER", D06[0]),
    "node-feature-discovery": ("SOCLE", "ALLÉGER", D06[0]),
    # --- retraits décidés / démos
    "atlantis-system": ("REC", "RETIRER", "Atlantis retiré ; PVC de recovery gardé jusqu'à validation (suppression = Paul, D-13)"),
    "atlantis-apps": ("REC", "RETIRER", "Atlantis retiré ; PVC de recovery gardé jusqu'à validation (suppression = Paul, D-13)"),
    "argo-rollouts-demo": ("REC", "RETIRER", "démo PLT-141 de test, sans donnée"),
}
DRILL_RE = re.compile(r"^dr-|restore|recovery")
RETIRED_RE = re.compile(r"jelly(fin|seerr)|seerr|sonarr|radarr|prowlarr|bazarr|lidarr|readarr|recyclarr|health-coach")
SKIP_NS = {"default", "kube-node-lease", "kube-public"}
CLASS_LABEL = {"IRR": "irremplaçable", "IRR?": "irremplaçable (à confirmer)", "REC": "reconstructible",
               "REC?": "reconstructible (à confirmer)", "SOCLE": "socle", "?": "à confirmer"}


# ---------------------------------------------------------------------------
# Parse live data
# ---------------------------------------------------------------------------
version = load("version.json").get("gitVersion", "?")
apps = load("apps.json")["items"]
workloads = load("workloads.json")["items"]
pods = load("pods.json")["items"]
pvcs = load("pvc.json")["items"]
cnpgs = load("cnpg.json")["items"]
routes = load("routes.json")["items"]
eso = load("es.json")["items"]
all_ns = {n["metadata"]["name"] for n in load("ns.json")["items"]}


def prom(name):
    out = {}
    for r in load(f"prom-{name}.json").get("data", {}).get("result", []):
        out[r["metric"].get("namespace", "")] = float(r["value"][1])
    return out


cpu_avg, cpu_max, mem_avg, mem_max = (prom(n) for n in ("cpu_avg", "cpu_max", "mem_avg", "mem_max"))
loki_lines = len(load("loki.json").get("data", {}).get("result", []))

TRACK = "argocd.argoproj.io/tracking-id"
ns_apps = collections.defaultdict(collections.Counter)


def track(item):
    t = item["metadata"].get("annotations", {}).get(TRACK, "")
    if ":" in t:
        ns_apps[item["metadata"].get("namespace", "")][t.split(":", 1)[0]] += 1


for it in workloads + pvcs + routes + cnpgs:
    track(it)
for a in apps:  # destination namespace as fallback
    d = a["spec"]["destination"].get("namespace")
    if d and not ns_apps[d]:
        ns_apps[d][a["metadata"]["name"]] += 1

stat = collections.defaultdict(lambda: dict(desired=0, ready=0, zero=0, cron=0, cron_susp=0, wl=0, crash=0, wnames=[]))
for w in workloads:
    ns, kind, spec, st = w["metadata"]["namespace"], w["kind"], w.get("spec", {}), w.get("status", {})
    s = stat[ns]
    s["wnames"].append(w["metadata"]["name"])
    if kind == "CronJob":
        s["cron"] += 1
        s["cron_susp"] += 1 if spec.get("suspend") else 0
        continue
    s["wl"] += 1
    if kind == "DaemonSet":
        d, r = st.get("desiredNumberScheduled", 0), st.get("numberReady", 0)
    else:
        d, r = spec.get("replicas", 1), st.get("readyReplicas", 0)
    if d == 0:
        s["zero"] += 1
    s["desired"] += d
    s["ready"] += r
for p in pods:
    for c in p.get("status", {}).get("containerStatuses", []) or []:
        if c.get("state", {}).get("waiting", {}).get("reason") == "CrashLoopBackOff":
            stat[p["metadata"]["namespace"]]["crash"] += 1
            break

pvc_by = collections.defaultdict(lambda: [0, 0.0])
UNITS = {"Ki": 1 / 1024 ** 2, "Mi": 1 / 1024, "Gi": 1, "Ti": 1024}
for p in pvcs:
    q = p.get("spec", {}).get("resources", {}).get("requests", {}).get("storage", "0Gi")
    m = re.match(r"([\d.]+)(\w*)", q)
    pvc_by[p["metadata"]["namespace"]][0] += 1
    pvc_by[p["metadata"]["namespace"]][1] += float(m.group(1)) * UNITS.get(m.group(2), 0)
cnpg_by = collections.defaultdict(lambda: [0, 0])
for c in cnpgs:
    cnpg_by[c["metadata"]["namespace"]][0] += 1
    if c["metadata"].get("annotations", {}).get("cnpg.io/hibernation") == "on":
        cnpg_by[c["metadata"]["namespace"]][1] += 1

OIDC_RE = re.compile(r"oidc|authentik|oauth|sso", re.I)
oidc_ns = set()
for w in workloads:
    ns = w["metadata"]["namespace"]
    tpl = w.get("spec", {}).get("template", w.get("spec", {}).get("jobTemplate", {}).get("spec", {}).get("template", {}))
    for c in tpl.get("spec", {}).get("containers", []) or []:
        names = [e.get("name", "") for e in c.get("env", []) or []]
        names += [e.get("secretRef", {}).get("name", "") for e in c.get("envFrom", []) or []]
        names += [e.get("valueFrom", {}).get("secretKeyRef", {}).get("name", "") for e in c.get("env", []) or []]
        if any(OIDC_RE.search(n) for n in names):
            oidc_ns.add(ns)
for e in eso:  # names/keys only, never values
    txt = json.dumps({"n": e["metadata"]["name"], "d": e.get("spec", {}).get("data", []),
                      "f": e.get("spec", {}).get("dataFrom", [])})
    if OIDC_RE.search(txt):
        oidc_ns.add(e["metadata"]["namespace"])

route_by = collections.defaultdict(list)
for r in routes:
    gws = sorted({p["name"] for p in r["spec"].get("parentRefs", [])})
    for h in r["spec"].get("hostnames", []) or ["(sans hôte)"]:
        route_by[r["metadata"]["namespace"]].append((h, gws))


def fmt_routes(ns):
    rs = route_by.get(ns)
    if not rs:
        return "aucune"
    seen, parts = set(), []
    for h, gws in rs:
        if h in seen:
            continue
        seen.add(h)
        parts.append(f"{h} [{'public' if 'external' in gws else 'LAN'}]")
    s = "; ".join(parts[:2]) + (f" +{len(parts) - 2}" if len(parts) > 2 else "")
    if ns == "auth":
        return s + " IdP"
    return s + (" OIDC" if ns in oidc_ns else " auth non détectée")


def status_of(ns):
    s = stat.get(ns)
    if not s or (s["wl"] == 0 and s["cron"] == 0):
        return "sans workload", None
    if s["wl"] == 0:
        act = s["cron"] - s["cron_susp"]
        return f"cron {act} actif/{s['cron_susp']} suspendu", act > 0
    if s["crash"]:
        return f"NON CrashLoop x{s['crash']}", False
    if s["desired"] == 0:
        return "NON scaled 0", False
    if s["ready"] >= s["desired"]:
        extra = f", {s['zero']} à 0" if s["zero"] else ""
        return f"OUI {s['ready']}/{s['desired']}{extra}", True
    return f"DÉGRADÉ {s['ready']}/{s['desired']}", False


def mi(v):
    return "—" if v is None else f"{v / 1048576:.0f}"


def cores(v):
    return "—" if v is None else f"{v:.3f}"


rows, grouped = {}, collections.defaultdict(list)
for ns in sorted(all_ns - SKIP_NS):
    has = ns in stat or ns in pvc_by or ns in route_by or ns in cnpg_by or ns_apps.get(ns)
    if not has:
        continue
    (grouped["~drills" if DRILL_RE.search(ns) else ns]).append(ns)

recs = []
for key, nss in grouped.items():
    def tot(d):
        vals = [d[n] for n in nss if n in d]
        return sum(vals) if vals else None
    npvc = sum(pvc_by[n][0] for n in nss if n in pvc_by)
    gib = sum(pvc_by[n][1] for n in nss if n in pvc_by)
    ncnpg = sum(cnpg_by[n][0] for n in nss if n in cnpg_by)
    if key == "~drills":
        name = f"drills/recovery ({len(nss)} ns)"
        cls, verdict, reason = "REC", "ALLÉGER", "drills éphémères ; purger après preuve, suppression PVC = Paul (D-13), candidats RETIRER"
        appn = "hors Argo (manuel)" if not any(ns_apps.get(n) for n in nss) else "mixte"
        states = [status_of(n) for n in nss]
        run = sum(1 for _, ok in states if ok)
        state = f"{run}/{len(nss)} ns actifs"
        ok = run > 0
        route = "—"
    else:
        name = key
        cls, verdict, reason = MAP.get(key, (None, None, None))
        if cls is None:
            cls = "?" if (npvc or ncnpg) else "REC"
            verdict, reason = "GARDER", "non classé ; à confirmer"
        a = ns_apps.get(key)
        appn = a.most_common(1)[0][0] if a else "hors Argo"
        state, ok = status_of(key)
        route = fmt_routes(key)
    resid = sorted({w for n in nss for w in stat[n]["wnames"] if RETIRED_RE.search(w)}) if key in stat else []
    if resid:
        reason += f" ; résidus retirés : {','.join(resid)}"
    data = CLASS_LABEL[cls]
    if npvc or ncnpg:
        data += f" (PVC {npvc}/{gib:.0f}Gi" + (f", CNPG {ncnpg}" if ncnpg else "") + ")"
    recs.append(dict(ns=name, app=appn, state=state, ok=ok, cpu=(tot(cpu_avg), tot(cpu_max)),
                     mem=(tot(mem_avg), tot(mem_max)), route=route, data=data, verdict=verdict, reason=reason,
                     infra=key in INFRA))


def table(rs):
    out = ["| Namespace | Argo | État | CPU moy/pic (cœurs) | RAM moy/pic (Mi) | Route / exposition | Classe D-05 | Verdict |",
           "|---|---|---|---|---|---|---|---|"]
    for r in rs:
        out.append(f"| {r['ns']} | {r['app']} | {r['state']} | {cores(r['cpu'][0])}/{cores(r['cpu'][1])} | "
                   f"{mi(r['mem'][0])}/{mi(r['mem'][1])} | {r['route']} | {r['data']} | "
                   f"**{r['verdict']}** : {r['reason']} |")
    return out


# ---------------------------------------------------------------------------
# Git-only manifests: kustomize dirs not reachable from any Argo-discovered root
# ---------------------------------------------------------------------------
def read_kust(d):
    for n in ("kustomization.yaml", "kustomization.yml"):
        p = os.path.join(ROOT, d, n)
        if os.path.exists(p):
            return yaml.safe_load(open(p)) or {}
    return None


roots = {"k8s/bootstrap"}
for f in ("k8s/bootstrap/argocd-root/applications-applicationset.yaml",
          "k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml"):
    for doc in yaml.safe_load_all(open(os.path.join(ROOT, f))):
        for g in (doc or {}).get("spec", {}).get("generators", []):
            for d in g.get("git", {}).get("directories", []):
                roots.add(d["path"].rstrip("/"))
roots.add("k8s/optional/hermes-personal")  # hermes-personal-tenants ApplicationSet
for a in apps:  # any other live Application path
    for src in [a["spec"].get("source", {})] + (a["spec"].get("sources") or []):
        p = src.get("path", "")
        if p.startswith("k8s/"):
            roots.add(p.rstrip("/"))

reach, todo = set(), list(roots)
while todo:
    d = os.path.normpath(todo.pop())
    if d in reach:
        continue
    reach.add(d)
    k = read_kust(d)
    if k:
        for key in ("resources", "components", "bases"):
            for r in k.get(key, []) or []:
                if isinstance(r, str) and not re.match(r"https?:|git@", r):
                    p = os.path.normpath(os.path.join(d, r))
                    if os.path.isdir(os.path.join(ROOT, p)):
                        todo.append(p)

git_only = []
for base, depth in (("k8s/applications", 2), ("k8s/infrastructure", 2), ("k8s/optional", 1), ("k8s/poc", 1)):
    top = os.path.join(ROOT, base)
    for dp, dns, fns in os.walk(top):
        rel = os.path.relpath(dp, ROOT)
        lvl = len(os.path.relpath(dp, top).split(os.sep)) if dp != top else 0
        dns.sort()
        if lvl == depth and not any(r == rel or r.startswith(rel + "/") for r in reach) and any(
                f.endswith((".yaml", ".yml", ".json")) for f in fns):
            git_only.append(rel)
        if lvl >= depth:
            dns[:] = []
git_only = sorted(set(git_only))

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
app_rs = [r for r in recs if not r["infra"] and r["verdict"] != "RETIRER"]
infra_rs = [r for r in recs if r["infra"] or r["verdict"] == "RETIRER"]
running = sum(1 for r in recs if r["ok"])
notrun = [r["ns"] for r in recs if r["ok"] is False]
none = sum(1 for r in recs if r["ok"] is None)
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def top(key, idx, fmt, n=5):
    rs = sorted((r for r in recs if r[key][idx] is not None), key=lambda r: -r[key][idx])[:n]
    return ", ".join(f"{r['ns']} {fmt(r[key][idx])}" for r in rs)


bad_apps = [f"{a['metadata']['name']} ({a.get('status', {}).get('sync', {}).get('status')}/"
            f"{a.get('status', {}).get('health', {}).get('status')})" for a in apps
            if (a.get("status", {}).get("sync", {}).get("status"), a.get("status", {}).get("health", {}).get("status"))
            != ("Synced", "Healthy")]
verd = collections.Counter(r["verdict"] for r in recs)

L = ["# État réel du cluster", "",
     "**Première lecture de tout agent.** Cet état vient du cluster vivant (Argo, kubectl, Prometheus, Loki), "
     "pas des manifests. En cas de désaccord avec Git ou un ticket, ceci décrit le runtime observé ; Git reste l'autorité "
     "du désiré (AGENTS.md).", "",
     f"- Généré le {ts} par `bash scripts/cluster-reality.sh` (lecture seule, idempotent, aucun secret).",
     f"- Cluster Kubernetes {version}, {len(apps)} Applications Argo, {len(recs)} lignes (namespaces ; drills regroupés).",
     f"- En marche : {running} ; à l'arrêt/dégradé : {len(notrun)}"
     + (f" ({', '.join(notrun)})" if notrun else "") + f" ; sans workload : {none}.",
     "- Verdicts : " + ", ".join(f"{k} {v}" for k, v in sorted(verd.items())) + ".",
     f"- Applications Argo hors Synced/Healthy : {', '.join(bad_apps) if bad_apps else 'aucune'}.",
     "- CPU/RAM : moyenne et pic sur 24 h (Prometheus, sous-requête 5 min, somme des conteneurs par namespace ; RAM = working set).",
     "- Dernier accès utilisateur : " + (
         "non mesurable (Envoy Cilium n'émet aucun journal d'accès HTTP dans Loki ; aucune métrique par route). "
         "Activer les access logs Gateway pour mesurer." if loki_lines == 0 else
         "des lignes d'accès existent dans Loki mais ne sont pas exploitées par ce script."),
     "- Authentification : « OIDC » = secret/variable OIDC-Authentik détecté sur le workload (par nom, jamais par valeur) ; "
     "il n'y a pas de protection au niveau Gateway. « auth non détectée » = à vérifier.",
     "- Verdicts : jugement par table explicite dans `scripts/lib/cluster_reality_render.py`, selon la charte, D-05, D-06, D-07 ; "
     "RETIRER seulement sur décision ou absence d'usage et de données.", "",
     "## Top consommateurs (24 h)", "",
     f"- CPU moyen : {top('cpu', 0, lambda v: f'{v:.2f}')}",
     f"- CPU pic : {top('cpu', 1, lambda v: f'{v:.2f}')}",
     f"- RAM moyenne (Mi) : {top('mem', 0, mi)}",
     f"- RAM pic (Mi) : {top('mem', 1, mi)}",
     f"- Total cluster : CPU moy {sum(r['cpu'][0] or 0 for r in recs):.2f} cœurs, "
     f"RAM moy {sum(r['mem'][0] or 0 for r in recs) / 1073741824:.1f} Gi.", "",
     "## Applications", ""] + table(app_rs) + ["", "## Socle, contrôleurs et retraits décidés", ""] + table(infra_rs) + [
     "", "## Manifests dans Git mais absents du cluster", "",
     "Répertoires `k8s/applications`, `k8s/infrastructure`, `k8s/optional`, `k8s/poc` (niveau application) "
     "qui ne sont atteints par aucune racine Argo/Kustomize : ils ne sont pas déployés.", ""]
L += [f"- `{p}`" + (" (retiré par décision)" if RETIRED_RE.search(p) else "") for p in git_only] or ["- aucun"]
L += ["", f"Total : {len(git_only)}."]

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    f.write("\n".join(L) + "\n")
print(f"wrote {OUT}: {len(recs)} rows, running={running}, notrunning={len(notrun)}, git_only={len(git_only)}")
