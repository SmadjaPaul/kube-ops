#!/usr/bin/env python3
"""Plan statique des changements Kubernetes de kube-ops (rendu Kustomize, base contre head).

Ce n'est PAS un plan transactionnel : aucun acces cluster, aucun dry-run serveur,
aucun etat reel (PVC existant, PV, admission). Niveau de preuve : STATIC.

Usage:
  plan_diff.py pr   --repo DIR --base-ref REF --head-ref REF [--roots FILE] [--json OUT] [--md OUT]
  plan_diff.py diff --base-dir DIR --head-dir DIR [--json OUT] [--md OUT]

Codes de sortie (fermes) :
  0  PASS     : aucun destructif, aucune violation bloquante
  3  BLOCK    : destructif (classe B/C ou IMM) ou objet stateful sans Prune=false
  2  BLOCKED  : rendu impossible (un refus ne doit jamais ressembler a un vert)

Classes de reversibilite :
  A    reversible par Git ; aucune donnee perdue au retrait
  B    reversible sous preconditions : PV Retain, rebind manuel possible
  C    potentiellement irreversible : PV Delete, Cluster CNPG (restauration non prouvee),
       Namespace avec stateful, CRD, Secret genere, reclaim inconnu
  IMM  champ immuable ou reduction impossible : apply refuse ou recreation (bloque)

Regles de protection :
  Prune=false   : retrait Git -> objet conserve (orphelin). Seule protection contre le prune.
  Delete=false  : protege contre la suppression de l'Application. Ne protege pas du retrait Git.
Un objet retire ou modifie avec Prune=false n'est pas destructif (classe conservee, info).
"""
import argparse
import copy
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

import yaml

SYNC = "argocd.argoproj.io/sync-options"
PRUNE_FALSE = "Prune=false"
DELETE_FALSE = "Delete=false"
CNPG_GROUP = "postgresql.cnpg.io"
SCHEMA = "plan.v1"
EXIT_PASS, EXIT_BLOCKED, EXIT_BLOCK = 0, 2, 3
DEFAULT_ROOTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "roots.txt")
VOLATILE_META = ("resourceVersion", "uid", "generation", "managedFields", "creationTimestamp")


class RenderError(Exception):
    """Rendu impossible : le plan ne peut pas etre etabli (fail-closed)."""


_BaseLoader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)  # libyaml si disponible (plus rapide)


class _Loader(_BaseLoader):
    """Tolere les tags non standard des rendus Helm (ex. !value)."""


def _any_tag(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)


_Loader.add_multi_constructor("", _any_tag)


def sync_opts(obj):
    ann = (obj.get("metadata") or {}).get("annotations") or {}
    return {o.strip() for o in str(ann.get(SYNC, "")).split(",") if o.strip()}


def protected(obj):
    return PRUNE_FALSE in sync_opts(obj)


def delete_protected(obj):
    return DELETE_FALSE in sync_opts(obj)


def key_of(obj):
    md = obj.get("metadata") or {}
    api = str(obj.get("apiVersion", ""))
    group = api.split("/")[0] if "/" in api else ""
    return (group, obj.get("kind", ""), md.get("namespace") or "", md.get("name", ""))


def get(d, *path):
    for p in path:
        if not isinstance(d, dict):
            return None
        d = d.get(p)
    return d


def canon(obj):
    """Contenu compare : sans statut, metadonnees volatiles ni option de sync (traitee a part)."""
    o = copy.deepcopy(obj)
    o.pop("status", None)
    md = o.get("metadata") or {}
    for k in VOLATILE_META:
        md.pop(k, None)
    ann = md.get("annotations") or {}
    ann.pop("kubectl.kubernetes.io/last-applied-configuration", None)
    ann.pop(SYNC, None)
    if not ann:
        md.pop("annotations", None)
    if md:
        o["metadata"] = md
    if o.get("kind") == "Secret":
        # Valeurs de Secret : generees par Helm (genCA, randAlphaNum), jamais comparees ni affichees.
        keys = sorted((o.get("data") or {}).keys()) + sorted((o.get("stringData") or {}).keys())
        o.pop("data", None)
        o.pop("stringData", None)
        o["__secret_keys__"] = keys
    return o


def cluster_of(root):
    """Cluster d'une racine : oracle-a1 ou homelab. Deux clusters ne fusionnent jamais."""
    return "oracle-a1" if root.startswith("k8s/clusters/oracle-a1/") else "homelab"


def load_dir(path):
    """Retourne {cle: {"obj": objet, "roots": [racines]}} ; cle = (groupe, kind, ns, nom, cluster)."""
    objs = {}
    for f in sorted(glob.glob(os.path.join(path, "*.yaml"))):
        root = os.path.basename(f)[: -len(".yaml")].replace("__", "/")
        with open(f, encoding="utf-8") as fh:
            for doc in yaml.load_all(fh, Loader=_Loader):
                if not isinstance(doc, dict) or not doc.get("kind"):
                    continue
                k = key_of(doc) + (cluster_of(root),)
                entry = objs.setdefault(k, {"obj": doc, "roots": [], "divergent": False})
                if root not in entry["roots"]:
                    entry["roots"].append(root)
                if canon(entry["obj"]) != canon(doc):
                    entry["divergent"] = True
    return objs


def is_cnpg_cluster(k):
    return k[0] == CNPG_GROUP and k[1] == "Cluster"


def is_pvc(k):
    return k[1] == "PersistentVolumeClaim"


def stateful_namespaces(*stores):
    """Ensemble de (cluster, namespace) qui hebergent un PVC ou un Cluster CNPG."""
    ns = set()
    for store in stores:
        for k in store:
            if is_pvc(k) or is_cnpg_cluster(k):
                ns.add((k[4], k[2]))
    return ns


def is_stateful(k, stateful_ns):
    return is_pvc(k) or is_cnpg_cluster(k) or (k[1] == "Namespace" and (k[4], k[3]) in stateful_ns)


def sc_policies(*stores):
    """reclaimPolicy par (cluster, StorageClass) ; defaut Kubernetes = Delete."""
    pol = {}
    for store in stores:
        for k, e in store.items():
            if k[1] == "StorageClass":
                pol[(k[4], k[3])] = e["obj"].get("reclaimPolicy") or "Delete"
    return pol


def classify_removed(k, obj, base, policies, stateful_ns):
    if is_pvc(k):
        sc = get(obj, "spec", "storageClassName")
        if not sc:
            return "C", "PVC sans storageClassName : reclaim inconnu (fail-closed)"
        pol = policies.get((k[4], sc))
        if pol is None:
            return "C", f"StorageClass {sc} absente du rendu : reclaim inconnu (fail-closed)"
        if pol == "Retain":
            return "B", f"PVC retire ; PV de SC {sc} Retain : rebind manuel possible"
        return "C", f"PVC retire ; SC {sc} reclaimPolicy={pol} : donnees supprimees"
    if is_cnpg_cluster(k):
        return "C", "Cluster CNPG retire : restauration non prouvee (drill requis)"
    if k[1] == "Namespace":
        if (k[4], k[3]) in stateful_ns:
            return "C", "Namespace avec objets stateful : suppression en cascade"
        return "A", "Namespace sans objet stateful"
    if k[1] == "CustomResourceDefinition":
        return "C", "CRD retiree : cascade sur toutes les ressources de ce type"
    if k[1] == "Secret":
        return "C", "Secret genere par le rendu : regeneration non rejouable"
    if k[1] == "StatefulSet":
        pol = get(obj, "spec", "persistentVolumeClaimRetentionPolicy", "whenDeleted")
        if pol == "Delete":
            return "C", "StatefulSet retire avec whenDeleted=Delete : PVC supprimes"
        return "A", "StatefulSet retire ; PVC volumeClaimTemplates conserves"
    return "A", "sans etat"


def immutable_changes(k, a, b):
    """Changements qu'Argo/Kubernetes refuse ou qui recreent l'objet (IMM, bloquants)."""
    out = []
    if is_pvc(k):
        for p in ("storageClassName", "accessModes", "volumeName"):
            if get(a, "spec", p) != get(b, "spec", p):
                out.append(f"PVC spec.{p} immuable")
        qa = parse_qty(get(a, "spec", "resources", "requests", "storage"))
        qb = parse_qty(get(b, "spec", "resources", "requests", "storage"))
        if qa and qb and qb < qa:
            out.append("PVC reduction de taille impossible")
    if k[1] == "StatefulSet":
        for p in ("selector", "serviceName"):
            if get(a, "spec", p) != get(b, "spec", p):
                out.append(f"StatefulSet spec.{p} immuable")
        if get(a, "spec", "volumeClaimTemplates") != get(b, "spec", "volumeClaimTemplates"):
            out.append("StatefulSet volumeClaimTemplates immuable (recreation)")
    if is_cnpg_cluster(k):
        qa = parse_qty(get(a, "spec", "storage", "size"))
        qb = parse_qty(get(b, "spec", "storage", "size"))
        if qa and qb and qb < qa:
            out.append("Cluster CNPG storage.size reduit (refuse)")
        if get(a, "spec", "storage", "storageClass") != get(b, "spec", "storage", "storageClass"):
            out.append("Cluster CNPG storageClass modifie (recreation des instances)")
    return out


def parse_qty(q):
    if q is None:
        return None
    s = str(q)
    mult = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40,
            "K": 10**3, "M": 10**6, "G": 10**9, "T": 10**12}
    for suf in ("Ki", "Mi", "Gi", "Ti", "K", "M", "G", "T"):
        if s.endswith(suf):
            try:
                return float(s[: -len(suf)]) * mult[suf]
            except ValueError:
                return None
    try:
        return float(s)
    except ValueError:
        return None


def diff(base, head):
    """Compare deux ensembles d'objets (sorties de load_dir). Retourne un dict plan.v1 partiel."""
    policies = sc_policies(base, head)
    s_ns = stateful_namespaces(base, head)
    changes, violations, warnings = [], [], []
    counts = {"+": 0, "~": 0, "-": 0}

    def row(op, k, roots, cls, reason, destructive, prot_before, prot_after):
        changes.append({
            "op": op, "cluster": k[4], "kind": k[1], "apiVersion": k[0], "namespace": k[2], "name": k[3],
            "roots": roots, "class": cls, "reason": reason, "destructive": destructive,
            "protected_before": prot_before, "protected_after": prot_after,
        })

    for k in sorted(set(base) | set(head)):
        a, b = base.get(k), head.get(k)
        if a is None:
            counts["+"] += 1
            bo = b["obj"]
            stateful = is_stateful(k, s_ns)
            prot = protected(bo)
            cls, reason, destructive = "A", "objet ajoute", False
            if stateful and not prot:
                violations.append({"code": "STATEFUL_UNPROTECTED_NEW", "object": _label(k),
                                   "blocking": True,
                                   "detail": "objet stateful ajoute sans Prune=false"})
                destructive = True
                reason = "objet stateful ajoute sans Prune=false"
                cls = "C"
            elif stateful and not delete_protected(bo):
                warnings.append({"code": "DELETE_FALSE_MISSING", "object": _label(k),
                                 "blocking": False, "detail": "Delete=false absent"})
            if is_pvc(k) and not get(bo, "spec", "storageClassName"):
                violations.append({"code": "STATEFUL_SC_UNKNOWN", "object": _label(k),
                                   "blocking": True, "detail": "PVC sans storageClassName"})
                destructive = True
            row("+", k, b["roots"], cls, reason, destructive, False, prot)
            continue
        if b is None:
            counts["-"] += 1
            cls, reason = classify_removed(k, a["obj"], base, policies, s_ns)
            prot = protected(a["obj"])
            destructive = cls in ("B", "C") and not prot
            if prot and cls in ("B", "C"):
                reason += " ; Prune=false : conserve en orphelin"
            row("-", k, a["roots"], cls, reason, destructive, prot, False)
            continue
        # objet present des deux cotes
        pa, pb = protected(a["obj"]), protected(b["obj"])
        if k[1] == "Secret":
            if sorted(canon(a["obj"]).get("__secret_keys__", [])) != sorted(canon(b["obj"]).get("__secret_keys__", [])):
                counts["~"] += 1
                row("~", k, b["roots"], "C", "Secret genere : ensemble de cles modifie", False, pa, pb)
            continue
        ca, cb = canon(a["obj"]), canon(b["obj"])
        if pa and not pb and is_stateful(k, s_ns):
            violations.append({"code": "PRUNE_FALSE_REMOVED", "object": _label(k), "blocking": True,
                               "detail": "Prune=false retire d'un objet stateful"})
        if is_stateful(k, s_ns) and not pb:
            warnings.append({"code": "STATEFUL_UNPROTECTED_PRE_EXISTING", "object": _label(k),
                             "blocking": False, "detail": "stateful sans Prune=false (present avant et apres)"})
        if is_stateful(k, s_ns) and pb and not delete_protected(b["obj"]):
            warnings.append({"code": "DELETE_FALSE_MISSING", "object": _label(k),
                             "blocking": False, "detail": "Delete=false absent"})
        if ca != cb:
            counts["~"] += 1
            imm = immutable_changes(k, a["obj"], b["obj"])
            if imm:
                row("~", k, b["roots"], "IMM", "; ".join(imm), True, pa, pb)
            else:
                row("~", k, b["roots"], "A", "objet modifie", False, pa, pb)
        elif sync_opts(a["obj"]) != sync_opts(b["obj"]):
            counts["~"] += 1
            sa_, sb_ = ",".join(sorted(sync_opts(a["obj"]))) or "-", ",".join(sorted(sync_opts(b["obj"]))) or "-"
            row("~", k, b["roots"], "A", f"options de sync : {sa_} -> {sb_}", False, pa, pb)
    for store, side in ((base, "base"), (head, "head")):
        for k, e in store.items():
            if e.get("divergent"):
                warnings.append({"code": "DUPLICATE_DIVERGENT", "object": _label(k), "blocking": False,
                                 "detail": f"meme objet rendu differemment par plusieurs racines ({side})"})
    destructive = [c for c in changes if c["destructive"]]
    blocking = [v for v in violations if v["blocking"]]
    status = "BLOCK" if destructive or blocking else "PASS"
    return {"counts": counts, "changes": changes, "violations": violations,
            "warnings": warnings, "status": status}


def _label(k):
    ns = f"{k[2]}/" if k[2] else ""
    grp = f" ({k[0]})" if k[0] else ""
    return f"[{k[4]}] {k[1]} {ns}{k[3]}{grp}"


def render(repo, ref, roots, out_dir):
    """Rend les racines au commit `ref` (git archive, aucun working tree touche)."""
    tmp = tempfile.mkdtemp(prefix="plan-src-")
    try:
        arch = subprocess.run(["git", "-C", repo, "archive", ref], capture_output=True)
        if arch.returncode != 0:
            raise RenderError(f"git archive {ref} : {arch.stderr.decode(errors='replace')[:200].strip()}")
        subprocess.run(["tar", "-x", "-C", tmp], input=arch.stdout, check=True)
        os.makedirs(out_dir, exist_ok=True)
        absent, rendered = [], []
        for root in roots:
            src = os.path.join(tmp, root)
            if not os.path.isdir(src):
                absent.append(root)
                continue
            r = subprocess.run(["kustomize", "build", "--enable-helm", src], capture_output=True, text=True)
            if r.returncode != 0:
                # La fin de stderr porte la cause reelle (ex. echec helm pull) : on la garde en entier.
                raise RenderError(f"{root} : {r.stderr.strip()[-1500:]}")
            with open(os.path.join(out_dir, root.replace("/", "__") + ".yaml"), "w", encoding="utf-8") as fh:
                fh.write(r.stdout)
            rendered.append(root)
        return rendered, absent
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def read_roots(path):
    roots = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if s and not s.startswith("#"):
                roots.append(s)
    return roots


def markdown(result, meta):
    c = result["counts"]
    lines = [
        f"### Plan statique kube-ops : {result['status']}",
        "",
        f"Base `{meta.get('base', '-')}` -> head `{meta.get('head', '-')}`. "
        f"Niveau de preuve : STATIC (rendu Kustomize, sans cluster). "
        f"Plan : +{c['+']} ~{c['~']} -{c['-']}.",
        "",
    ]
    if meta.get("error"):
        lines += [f"**BLOQUE : rendu impossible.** {meta['error']}", ""]
    if result["changes"]:
        lines += ["| op | objet | racines | classe | destructif | protege avant -> apres | raison |",
                  "|---|---|---|---|---|---|---|"]
        for ch in result["changes"]:
            lines.append(
                f"| {ch['op']} | {_label((ch['apiVersion'], ch['kind'], ch['namespace'], ch['name'], ch['cluster']))} "
                f"| {', '.join(ch['roots'])} | {ch['class']} | {'oui' if ch['destructive'] else 'non'} "
                f"| {'oui' if ch['protected_before'] else 'non'} -> {'oui' if ch['protected_after'] else 'non'} "
                f"| {ch['reason']} |")
        lines.append("")
    else:
        lines += ["Aucun objet Kubernetes modifie dans les racines rendues.", ""]
    if result["violations"]:
        lines.append("**Violations (bloquantes) :**")
        lines += [f"- `{v['code']}` {v['object']} : {v['detail']}" for v in result["violations"]]
        lines.append("")
    if result["warnings"]:
        lines.append("**Avertissements (non bloquants) :**")
        lines += [f"- `{w['code']}` {w['object']} : {w['detail']}" for w in result["warnings"]]
        lines.append("")
    lines.append("Sortie : 0 PASS, 3 BLOCK, 2 BLOCKED. Garde advisory : le job ne bloque pas le merge (semaine 1).")
    return "\n".join(lines) + "\n"


def write_outputs(args, payload, md_text):
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
    if args.md:
        with open(args.md, "w", encoding="utf-8") as fh:
            fh.write(md_text)
    sys.stdout.write(md_text)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pr")
    p.add_argument("--repo", required=True)
    p.add_argument("--base-ref", required=True)
    p.add_argument("--head-ref", required=True)
    p.add_argument("--roots", default=DEFAULT_ROOTS)
    p.add_argument("--json")
    p.add_argument("--md")
    d = sub.add_parser("diff")
    d.add_argument("--base-dir", required=True)
    d.add_argument("--head-dir", required=True)
    d.add_argument("--json")
    d.add_argument("--md")
    args = ap.parse_args(argv)

    if args.cmd == "diff":
        result = diff(load_dir(args.base_dir), load_dir(args.head_dir))
        payload = {"schema": SCHEMA, "evidence": "STATIC", **result}
        write_outputs(args, payload, markdown(result, {}))
        return EXIT_BLOCK if result["status"] == "BLOCK" else EXIT_PASS

    work = tempfile.mkdtemp(prefix="plan-pr-")
    meta = {"base": args.base_ref, "head": args.head_ref}
    try:
        roots = read_roots(args.roots)
        try:
            base_roots, base_absent = render(args.repo, args.base_ref, roots, os.path.join(work, "base"))
            head_roots, head_absent = render(args.repo, args.head_ref, roots, os.path.join(work, "head"))
        except (RenderError, subprocess.CalledProcessError, OSError) as exc:
            result = {"counts": {"+": 0, "~": 0, "-": 0}, "changes": [], "violations": [],
                      "warnings": [], "status": "BLOCKED"}
            meta["error"] = str(exc)
            payload = {"schema": SCHEMA, "evidence": "STATIC", "roots": {"rendered": [], "absent": []},
                       "error": str(exc), **result}
            write_outputs(args, payload, markdown(result, meta))
            return EXIT_BLOCKED
        result = diff(load_dir(os.path.join(work, "base")), load_dir(os.path.join(work, "head")))
        payload = {"schema": SCHEMA, "evidence": "STATIC", "base": args.base_ref, "head": args.head_ref,
                   "roots": {"rendered_base": base_roots, "rendered_head": head_roots,
                             "absent_base": base_absent, "absent_head": head_absent}, **result}
        write_outputs(args, payload, markdown(result, meta))
        return EXIT_BLOCK if result["status"] == "BLOCK" else EXIT_PASS
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
