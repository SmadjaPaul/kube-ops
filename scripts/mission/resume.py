#!/usr/bin/env python3
"""Reprise sans mémoire d'une mission (PLT-370 critère 4, version minimale).

Usage (depuis la racine du dépôt) :
  python3 scripts/mission/resume.py <mission-key> [--repo DIR] [--offline] [--no-gh] [--new-attempt]

Le dépôt seul suffit. Entrées :
- `missions/<key>.state.json` (versionné) : liste ordonnée des étapes, niveau requis,
  branche attendue, et `claimed` (ce que l'agent affirme). Une affirmation n'est pas une preuve.
- Git : commits portant les trailers de mission (toutes refs locales et distantes).
- GitHub (`gh`, sauf `--no-gh` ou `--offline`) : PR de la branche de l'étape et état des checks.

Contrat de commit de mission (un commit par preuve, trailers en fin de message) :
  Mission-Key: <key>
  Mission-Step: <step-id>        (preuve d'une étape)
  Mission-Attempt: <n>           (tentative qui a produit le commit)

Règles :
- Une étape est PROUVÉE si un commit porte Mission-Key et Mission-Step égaux à l'étape.
  Niveau par Git : STATIC. Niveau CI si la PR de la branche de l'étape a toutes ses checks en SUCCESS.
- Une étape exigeant RECONCILED, RUNTIME ou USER n'est jamais prouvée par Git : resume le signale
  et s'arrête dessus. Le coordinateur fournit cette preuve hors dépôt.
- Une étape prouvée n'est jamais rejouée. Le réel (Git, GitHub) l'emporte sur `claimed`.
- Une nouvelle tentative = numéro maximal observé + 1. `--new-attempt` l'écrit dans le fichier d'état.

Codes de sortie : 0 (rapport affiché), 2 (fichier d'état absent ou invalide).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

LEVELS = ("STATIC", "CI", "RECONCILED", "RUNTIME", "USER")
GIT_MAX_LEVEL = "CI"
KEY_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,63}$")
STEP_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
TRAILER_RE = re.compile(r"^(Mission-Key|Mission-Step|Mission-Attempt):[ \t]*(\S+)[ \t]*$", re.M)
REPO_ROOT = Path(__file__).resolve().parents[2]
CI_OK = {"SUCCESS", "SKIPPED", "NEUTRAL"}
CI_BAD = {"FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"}


def rank(level: str) -> int:
    return LEVELS.index(level)


# --- Git ----------------------------------------------------------------------

def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout


def read_commits(repo: Path) -> list[dict]:
    """Commits de toutes les refs, avec leurs trailers Mission-*. Dépôt vide : liste vide."""
    try:
        text = git(repo, "log", "--all", "--format=%H%x1e%B%x1f")
    except subprocess.CalledProcessError:
        return []
    commits = []
    for record in text.split("\x1f"):
        sha, sep, body = record.strip("\n").partition("\x1e")
        if not sep or not sha.strip():
            continue
        trailers: dict[str, list[str]] = {}
        for name, value in TRAILER_RE.findall(body):
            trailers.setdefault(name, []).append(value)
        commits.append({"sha": sha.strip(), "trailers": trailers})
    return commits


def ref_branches(repo: Path) -> set[str]:
    """Noms de branches locales et origin/* présents (sans le préfixe origin/)."""
    names = set()
    for line in git(repo, "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes/origin").splitlines():
        if line.startswith("refs/heads/"):
            names.add(line[len("refs/heads/"):])
        elif line.startswith("refs/remotes/origin/") and not line.endswith("/HEAD"):
            names.add(line[len("refs/remotes/origin/"):])
    return names


def mission_evidence(commits: list[dict], key: str) -> tuple[dict[str, list[tuple[str, int]]], list[tuple[str, int]], int]:
    """Preuves par étape, traces sans étape, tentative maximale observée."""
    proofs: dict[str, list[tuple[str, int]]] = {}
    traces: list[tuple[str, int]] = []
    max_attempt = 0
    for commit in commits:
        t = commit["trailers"]
        if key not in t.get("Mission-Key", []):
            continue
        attempt = int(t["Mission-Attempt"][0]) if t.get("Mission-Attempt", ["x"])[0].isdigit() else 0
        max_attempt = max(max_attempt, attempt)
        steps = t.get("Mission-Step")
        if steps:
            for step in steps:
                proofs.setdefault(step, []).append((commit["sha"], attempt))
        else:
            traces.append((commit["sha"], attempt))
    return proofs, traces, max_attempt


# --- GitHub -------------------------------------------------------------------

def ci_summary(checks: list[dict]) -> str:
    if not checks:
        return "AUCUN"
    states = [((c.get("conclusion") or c.get("state") or "").upper() or "PENDING") for c in checks]
    if any(s in CI_BAD for s in states):
        return "FAILURE"
    if all(s in CI_OK for s in states):
        return "SUCCESS"
    return "PENDING"


def github_prs(repo: Path, branches: list[str]) -> dict[str, dict] | None:
    """PR par branche. None si gh échoue : l'état CI est alors NOT_TESTED."""
    result: dict[str, dict] = {}
    for branch in branches:
        proc = subprocess.run(
            ["gh", "pr", "list", "--head", branch, "--state", "all", "--limit", "5",
             "--json", "number,state,statusCheckRollup"],
            cwd=repo, capture_output=True, text=True,
        )
        if proc.returncode != 0:
            return None
        items = json.loads(proc.stdout or "[]")
        if not items:
            result[branch] = {"pr": None, "ci": "AUCUN"}
            continue
        pr = items[0]
        result[branch] = {"pr": f"#{pr['number']} {pr['state']}", "ci": ci_summary(pr.get("statusCheckRollup") or [])}
    return result


# --- Évaluation (fonction pure, testée hors réseau) ----------------------------

def evaluate(mission: dict, proofs, traces, max_attempt: int, branches: set[str], prs: dict[str, dict] | None) -> dict:
    steps_out = []
    for step in mission["steps"]:
        sid, required = step["id"], step["required"]
        branch = step.get("branch")
        pr = (prs or {}).get(branch) if branch else None
        ci = pr["ci"] if pr else ("NOT_TESTED" if prs is None and branch else None)
        proof = proofs.get(sid, [])
        level = None
        if proof:
            level = GIT_MAX_LEVEL if ci == "SUCCESS" else "STATIC"
        proved = level is not None and rank(level) >= rank(required)
        if proved:
            status, reason = "PROUVE", f"{level} par Git ({proof[0][0][:10]}, tentative {proof[0][1]})"
        elif proof:
            if rank(required) > rank(GIT_MAX_LEVEL):
                status = "NON_PROUVE"
                reason = f"exige {required}, preuve hors Git (coordinateur)"
            else:
                status = "NON_PROUVE"
                reason = f"trailer présent, CI {ci or 'n/a'}"
        else:
            status = "A_FAIRE"
            if branch and branch in branches:
                reason = f"branche {branch} présente, aucun trailer Mission-Step"
            elif branch:
                reason = f"branche {branch} absente"
            else:
                reason = "aucune preuve Git"
        steps_out.append({
            "id": sid, "title": step.get("title", ""), "required": required, "status": status,
            "reason": reason, "branch": branch, "pr": pr["pr"] if pr else None, "ci": ci,
            "claimed": step.get("claimed", "pending"),
            "contradicted": step.get("claimed") == "done" and not proved,
        })

    next_step = next((s for s in steps_out if s["status"] != "PROUVE"), None)
    warnings = []
    seen_open = False
    for s in steps_out:
        if s["status"] != "PROUVE":
            seen_open = True
        elif seen_open:
            warnings.append(f"incohérence : {s['id']} prouvé alors qu'une étape précédente ne l'est pas")
    observed = max(int(mission.get("attempt", 0) or 0), max_attempt)
    return {
        "steps": steps_out,
        "next": next_step,
        "next_attempt": observed + 1,
        "observed_attempt": observed,
        "traces": traces,
        "warnings": warnings,
        "done": [s["id"] for s in steps_out if s["status"] == "PROUVE"],
    }


def render(mission: dict, report: dict, source: str, gh_state: str) -> str:
    key = mission["mission_key"]
    out = [f"MISSION {key} ({mission.get('title', '')})",
           f"Source : Git (refs locales et origin) ; GitHub : {gh_state} ; {source}",
           f"Tentative suivante : {report['next_attempt']} (dernière observée : {report['observed_attempt']})",
           "", "ÉTAT RÉEL (le réel prime sur le fichier)"]
    for i, s in enumerate(report["steps"], 1):
        flag = " CONTREDIT (fichier=done)" if s["contradicted"] else ""
        out.append(f"  [{i}] {s['id']:<15} {s['status']:<10} requis {s['required']:<10}{flag}".rstrip())
        out.append(f"       {s['reason']}")
        if s["branch"]:
            out.append(f"       branche {s['branch']} ; PR {s['pr'] or 'aucune'} ; CI {s['ci'] or 'n/a'}")
    out.append("")
    out.append("NE PAS REJOUER (prouvées) : " + (", ".join(report["done"]) or "aucune"))
    for sha, att in report["traces"]:
        out.append(f"TRACE sans étape : {sha[:10]} (tentative {att}) : travail non prouvé, à reprendre")
    for w in report["warnings"]:
        out.append(f"ATTENTION : {w}")
    nxt = report["next"]
    if nxt is None:
        out.append("PROCHAINE ÉTAPE : aucune, toutes les étapes sont prouvées par Git.")
    elif rank(nxt["required"]) > rank(GIT_MAX_LEVEL):
        out.append(f"PROCHAINE ÉTAPE : {nxt['id']} : exige {nxt['required']}, non prouvable par Git. "
                   "Le coordinateur fournit la preuve, resume ne la produit pas.")
    else:
        out.append(f"PROCHAINE ÉTAPE : {nxt['id']} ({nxt['title']}) : {nxt['reason']}.")
    return "\n".join(out)


# --- CLI ----------------------------------------------------------------------

def load_mission(repo: Path, key: str) -> dict:
    path = repo / "missions" / f"{key}.state.json"
    if not path.is_file():
        raise ValueError(f"fichier d'état absent : {path}")
    mission = json.loads(path.read_text())
    if mission.get("mission_key") != key:
        raise ValueError("mission_key du fichier différent de l'argument")
    steps = mission.get("steps")
    if not isinstance(steps, list) or not steps:
        raise ValueError("steps vide ou absent")
    ids = [s.get("id") for s in steps]
    if len(set(ids)) != len(ids):
        raise ValueError("identifiants d'étape dupliqués")
    for s in steps:
        if not STEP_RE.match(str(s.get("id"))) or s.get("required") not in LEVELS:
            raise ValueError(f"étape invalide : {s}")
    return mission


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("key")
    parser.add_argument("--repo", default=str(REPO_ROOT))
    parser.add_argument("--offline", action="store_true", help="pas de fetch ni de gh (tests, hors réseau)")
    parser.add_argument("--no-gh", action="store_true", help="pas d'interrogation GitHub")
    parser.add_argument("--new-attempt", action="store_true", help="écrit la nouvelle tentative dans le fichier d'état")
    args = parser.parse_args(argv)

    if not KEY_RE.match(args.key):
        print(f"ERREUR : clé de mission invalide : {args.key}", file=sys.stderr)
        return 2
    repo = Path(args.repo).resolve()
    try:
        mission = load_mission(repo, args.key)
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"ERREUR : {exc}", file=sys.stderr)
        return 2

    source = "hors ligne"
    if not args.offline:
        try:
            git(repo, "fetch", "--quiet", "origin")
            source = "git fetch origin OK"
        except subprocess.CalledProcessError:
            source = "git fetch origin ÉCHEC (refs locales seules)"

    proofs, traces, max_attempt = mission_evidence(read_commits(repo), args.key)
    branches = ref_branches(repo)
    expected = [s["branch"] for s in mission["steps"] if s.get("branch")]
    prs = None if (args.offline or args.no_gh) else github_prs(repo, expected)
    gh_state = "hors ligne" if args.offline or args.no_gh else ("NOT_TESTED (gh en échec)" if prs is None else "OK")

    report = evaluate(mission, proofs, traces, max_attempt, branches, prs)
    print(render(mission, report, source, gh_state))
    if args.new_attempt:
        mission["attempt"] = report["next_attempt"]
        path = repo / "missions" / f"{args.key}.state.json"
        path.write_text(json.dumps(mission, ensure_ascii=False, indent=2) + "\n")
        print(f"ÉCRIT : attempt={report['next_attempt']} dans {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
