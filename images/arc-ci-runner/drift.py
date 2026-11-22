#!/usr/bin/env python3
"""Derive des versions d'outils : fichiers de version d'un depot contre l'image arc-ci-runner.

  drift.py --local DIR [--manifest /etc/arc-ci-runner/tools.json]
      Lit les fichiers de version de DIR (checkout d'un job), compare a l'image
      et ecrit « outil telecharge, absent de l'image » dans $GITHUB_STEP_SUMMARY.
      Ne fait jamais echouer le job (fail-open).
  drift.py --image-toml images/arc-ci-runner/mise.toml --repo-dir DIR [--repo-dir ...] --json
      Liste les (outil, version) demandes par les depots et absentes de mise.toml.

Sources : .node-version, .nvmrc, .terraform-version, .tool-versions, mise.toml
([tools]), package.json engines.node. Seules les versions exactes comptent.
"""
import json, os, re, sys, tomllib

EXACT = re.compile(r"^v?(\d+\.\d+\.\d+)$")
ALIASES = {"nodejs": "node", "tofu": "opentofu"}

def norm(v):
    v = str(v).strip().lstrip("v")
    return v if re.fullmatch(r"\d+(\.\d+){2}", v) else None

RANGES = set()  # (outil, prefixe) pour les versions non exactes (ex. node 22)

def wanted(d):
    out = set()
    def add(t, v):
        t = ALIASES.get(t, t)
        r = re.fullmatch(r'v?(\d+(?:\.\d+)?)(?:\.[x*])?', str(v).strip())
        if r:
            RANGES.add((t, r.group(1) + '.'))
        v = norm(v)
        if v:
            out.add((t, v))
    for f, t in ((".node-version", "node"), (".nvmrc", "node"), (".terraform-version", "terraform")):
        p = os.path.join(d, f)
        if os.path.isfile(p):
            txt = open(p).read().split()
            add(t, txt[0] if txt else "")
    p = os.path.join(d, ".tool-versions")
    if os.path.isfile(p):
        for line in open(p):
            parts = line.split("#")[0].split()
            for v in parts[1:2]:
                add(parts[0], v)
    for f in ("mise.toml", ".mise.toml"):
        p = os.path.join(d, f)
        if os.path.isfile(p):
            tools = tomllib.load(open(p, "rb")).get("tools", {})
            for t, v in tools.items():
                for x in (v if isinstance(v, list) else [v]):
                    add(t.split(":")[-1], x["version"] if isinstance(x, dict) and "version" in x else x)
    p = os.path.join(d, "package.json")
    if os.path.isfile(p):
        eng = json.load(open(p)).get("engines", {}).get("node")
        if eng:
            add("node", eng)
    return out

def image_set_from_toml(path):
    tools = tomllib.load(open(path, "rb")).get("tools", {})
    s = set()
    for t, v in tools.items():
        for x in (v if isinstance(v, list) else [v]):
            n = norm(x)
            if n:
                s.add((ALIASES.get(t.split(":")[-1], t.split(":")[-1]), n))
    return s

def image_set_from_manifest(path):
    data = json.load(open(path))
    s = set()
    for t, items in data.items():
        for it in items:
            n = norm(it.get("version", ""))
            if n:
                s.add((ALIASES.get(t.split(":")[-1], t.split(":")[-1]), n))
    return s

def apply(toml_path, miss, prune_unused=None):
    """Ajoute les versions manquantes a mise.toml (liste si l'outil a deja une version).
    prune_unused : ensemble (outil, version) encore demandes ; si fourni, retire des
    listes les versions que plus aucun depot n'utilise (jamais la derniere)."""
    lines = open(toml_path).read().split("\n")
    for tool, ver in miss:
        for i, l in enumerate(lines):
            m = re.match(r'^("?[\w:.-]+"?)\s*=\s*(.*?)(\s*#.*)?$', l)
            if not m or m.group(1).strip('"').split(":")[-1] != tool:
                continue
            val = m.group(2).strip()
            cur = re.findall(r'"([^"]+)"', val)
            if ver not in cur:
                cur.append(ver)
            lines[i] = f'{m.group(1)} = [' + ", ".join(f'"{c}"' for c in cur) + "]" + (m.group(3) or "")
            break
        else:
            sys.exit(f"outil {tool} absent de {toml_path} : a ajouter a la main")
    if prune_unused is not None:
        for i, l in enumerate(lines):
            m = re.match(r'^("?[\w:.-]+"?)\s*=\s*\[(.*)\](\s*#.*)?$', l)
            if not m:
                continue
            tool = m.group(1).strip('"').split(":")[-1]
            cur = re.findall(r'"([^"]+)"', m.group(2))
            keep = [c for c in cur if (tool, c) in prune_unused or any(tool == t and c.startswith(p) for t, p in RANGES)] or cur[-1:]
            lines[i] = f'{m.group(1)} = [' + ", ".join(f'"{c}"' for c in keep) + "]" + (m.group(3) or "")
    open(toml_path, "w").write("\n".join(lines))

def main(a):
    if "--apply" in a:
        toml = a[a.index("--image-toml") + 1]
        dirs = [a[i + 1] for i, x in enumerate(a) if x == "--repo-dir"]
        want = set().union(*[wanted(d) for d in dirs])
        img = image_set_from_toml(toml)
        known = {t for t, _ in img}  # outils hors image (ex. talosctl) ignores
        miss = sorted((t, v) for t, v in want - img if t in known)
        apply(toml, miss, want if "--prune" in a else None)
        print(json.dumps([{"tool": t, "version": v} for t, v in miss]))
        return 0
    if "--local" in a:
        d = a[a.index("--local") + 1]
        man = a[a.index("--manifest") + 1] if "--manifest" in a else "/etc/arc-ci-runner/tools.json"
        try:
            img = image_set_from_manifest(man)
            known = {t for t, _ in img}
            miss = sorted((t, v) for t, v in wanted(d) - img if t in known)
        except Exception as e:  # fail-open
            print(f"drift: ignore ({e})")
            return 0
        if miss:
            msg = "\n".join(f"- {t} {v}: outil telecharge, absent de l'image arc-ci-runner" for t, v in miss)
            print(msg)
            s = os.environ.get("GITHUB_STEP_SUMMARY")
            if s:
                with open(s, "a") as f:
                    f.write("### Derive de l'image arc-ci-runner\n" + msg + "\n")
        return 0
    toml = a[a.index("--image-toml") + 1]
    dirs = [a[i + 1] for i, x in enumerate(a) if x == "--repo-dir"]
    img = image_set_from_toml(toml)
    known = {t for t, _ in img}
    miss = sorted((t, v) for t, v in set().union(*[wanted(d) for d in dirs]) - img if t in known)
    print(json.dumps([{"tool": t, "version": v} for t, v in miss]))
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
