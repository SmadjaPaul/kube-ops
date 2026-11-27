#!/usr/bin/env bash
# PLT-538 (lot 2a) : les familles cAdvisor et kubernetes_feature_enabled coupees
# n'ont aucun lecteur dans le depot.
#
# Perimetre (PLT-460 lot 2a) :
#   - cAdvisor (endpoint /metrics/cadvisor du ServiceMonitor kubelet) :
#     container_memory_failcnt, container_pressure_{cpu,io}_{stalled,waiting}_seconds_total,
#     container_oom_events_total, container_memory_kernel_usage,
#     container_memory_total_inactive_file_bytes ;
#   - kubernetes_feature_enabled (kubelet /metrics et apiserver).
#
# Contrat verifie (statique, aucun acces cluster, aucun rendu Helm) :
#   1. chaque famille du perimetre est couverte par une relabeling `drop`
#      ancree (Prometheus ancre la regex) sur le bon endpoint :
#      - les familles cAdvisor par kubelet-cardinality-patch.json, dont l'op
#        `test` garantit que l'endpoint 1 est bien /metrics/cadvisor ;
#      - kubernetes_feature_enabled par les values Helm du kubelet ET par
#        kube-apiserver-cardinality-patch.json ;
#   2. aucune de ces familles n'est lue par une regle, une alerte, un tableau
#      de bord, un autoscaler ou un script du depot (docs/operations/telemetry-policy.md,
#      principe 4). Les seules mentions autorisees sont les regles de drop
#      verifiees en 1 et la documentation de la politique de telemetrie.
#
# Les cas negatifs (famille lue, famille non coupee, regex non ancree) doivent
# etre refuses.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

command -v python3 >/dev/null 2>&1 || { echo 'MONITORING_CARDINALITY_DROP=BLOCKED missing_tool=python3' >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo 'MONITORING_CARDINALITY_DROP=BLOCKED missing_tool=git' >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/monitoring-cardinality-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 -I - "$repo_root" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(sys.argv[1])

PROM_ROOT = "k8s/infrastructure/monitoring/prometheus-stack"
KUBELET_PATCH = f"{PROM_ROOT}/kubelet-cardinality-patch.json"
APISERVER_PATCH = f"{PROM_ROOT}/kube-apiserver-cardinality-patch.json"
VALUES = f"{PROM_ROOT}/values.yaml"
KUSTOMIZATION = f"{PROM_ROOT}/kustomization.yaml"
THIS_TEST = "tests/harness/monitoring-cardinality-drop-test.sh"
POLICY_DOC = "docs/operations/telemetry-policy.md"

# --- perimetre PLT-538 lot 2a ------------------------------------------------

CADVISOR_FAMILIES = (
    "container_memory_failcnt",
    "container_pressure_cpu_stalled_seconds_total",
    "container_pressure_cpu_waiting_seconds_total",
    "container_pressure_io_stalled_seconds_total",
    "container_pressure_io_waiting_seconds_total",
    "container_oom_events_total",
    "container_memory_kernel_usage",
    "container_memory_total_inactive_file_bytes",
)
FEATURE_FAMILIES = ("kubernetes_feature_enabled",)
SCOPED_FAMILIES = CADVISOR_FAMILIES + FEATURE_FAMILIES

# Racines ou un lecteur (PromQL) peut vivre.
CORPUS_ROOTS = ("k8s", "scripts", "docs", "website", "tests", "integrations", "policy", ".github")
# Fichiers exclus du corpus de lecteurs : ils portent les regles de drop
# (verifiees par la couverture), ou ils nomment les familles sans les lire.
CORPUS_EXCLUDED = {
    KUBELET_PATCH,
    APISERVER_PATCH,
    POLICY_DOC,
    THIS_TEST,
}
# Cles Helm qui ne portent que des relabelings (metricRelabelings et
# variantes) : leur contenu est une regle de drop, jamais une lecture.
RELABELING_KEYS = (
    "metricRelabelings",
    "cAdvisorMetricRelabelings",
    "probesMetricRelabelings",
    "resourceMetricRelabelings",
    "relabelings",
)

failures = []


def fail(message):
    failures.append(message)


# --- 1. les regles de drop ---------------------------------------------------


def rules_from_ops(ops, endpoint):
    """Regles `drop` ajoutees par un patch JSON sur un endpoint donne.

    Lève ValueError si l'endpoint porte autre chose qu'un drop : une regle de
    relabeling qui n'est pas un drop ne retire pas la série.
    """
    rules = []
    for op in ops:
        if op.get("op") != "add":
            continue
        if op.get("path") != f"/spec/endpoints/{endpoint}/metricRelabelings/-":
            continue
        value = op.get("value") or {}
        if value.get("action") != "drop":
            raise ValueError(f"relabeling non-drop sur l'endpoint {endpoint} : {value}")
        if not value.get("regex"):
            raise ValueError(f"regle drop sans regex sur l'endpoint {endpoint} : {value}")
        rules.append(value["regex"])
    return rules


def patch_drop_rules(path, endpoint):
    ops = json.loads((ROOT / path).read_text())
    return rules_from_ops(ops, endpoint)


def patch_tested_path(path, endpoint):
    """Chemin garanti par un op `test` du patch JSON (None si absent)."""
    for op in json.loads((ROOT / path).read_text()):
        if op.get("op") == "test" and op.get("path") == f"/spec/endpoints/{endpoint}/path":
            return op.get("value")
    return None


def values_drop_rules(dotted_path):
    node = yaml.safe_load((ROOT / VALUES).read_text())
    for part in dotted_path.split("."):
        if not isinstance(node, dict) or part not in node:
            raise ValueError(f"{VALUES}: cle absente : {dotted_path}")
        node = node[part]
    rules = []
    for entry in node or []:
        if entry.get("action") != "drop":
            raise ValueError(f"{VALUES}: relabeling non-drop dans {dotted_path} : {entry}")
        if not entry.get("regex"):
            raise ValueError(f"{VALUES}: regle drop sans regex dans {dotted_path} : {entry}")
        rules.append(entry["regex"])
    return rules


def families_without_drop(rules, families):
    """Familles non couvertes par une regex ancree (Prometheus ancre la regex)."""
    return [f for f in families if not any(re.fullmatch(rule, f) for rule in rules)]


# --- 2. le corpus de lecteurs ------------------------------------------------


def strip_relabelings(node):
    if isinstance(node, dict):
        return {k: strip_relabelings(v) for k, v in node.items() if k not in RELABELING_KEYS}
    if isinstance(node, list):
        return [strip_relabelings(v) for v in node]
    return node


def tracked_files():
    try:
        out = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z"],
            check=True,
            capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ValueError(f"git ls-files impossible : {exc}")
    return [p for p in out.decode().split("\0") if p]


def reader_corpus():
    """Contenu des fichiers du depot ou un lecteur PromQL peut se trouver."""
    corpus = {}
    for path in tracked_files():
        top = path.split("/", 1)[0]
        if top not in CORPUS_ROOTS:
            continue
        if path in CORPUS_EXCLUDED:
            continue
        if path == VALUES:
            # Les valeurs Helm ne portent que des drop : on retire les cles de
            # relabeling avant de chercher un lecteur dans le reste du fichier.
            data = yaml.safe_load((ROOT / path).read_text())
            corpus[path] = yaml.safe_dump(strip_relabelings(data), allow_unicode=True, sort_keys=True)
            continue
        try:
            corpus[path] = (ROOT / path).read_text(errors="ignore")
        except OSError:
            continue
    return corpus


def families_with_reader(corpus, families):
    """Familles citees dans le corpus, avec les fichiers qui les citent."""
    hits = {}
    for family in families:
        paths = sorted(p for p, text in corpus.items() if family in text)
        if paths:
            hits[family] = paths
    return hits


# --- verifications ------------------------------------------------------------

# Le patch kubelet cible bien l'endpoint cAdvisor (sinon les drop tomberaient
# sur le mauvais endpoint : le `test` du patch fait echouer le build).
tested = patch_tested_path(KUBELET_PATCH, 1)
if tested != "/metrics/cadvisor":
    fail(f"{KUBELET_PATCH}: l'endpoint 1 n'est pas /metrics/cadvisor (test = {tested!r})")

# La kustomization cible les deux ServiceMonitor attendus.
kustomization = yaml.safe_load((ROOT / KUSTOMIZATION).read_text())
targets = {
    patch["target"]["name"]: patch["path"]
    for patch in kustomization.get("patches", [])
    if isinstance(patch, dict) and "target" in patch
}
for name, path in (
    ("kube-prometheus-stack-kubelet", KUBELET_PATCH),
    ("kube-prometheus-stack-apiserver", APISERVER_PATCH),
):
    if targets.get(name) != Path(path).name:
        fail(f"{KUSTOMIZATION}: le patch {path} ne cible pas le ServiceMonitor {name}")

try:
    cadvisor_rules = patch_drop_rules(KUBELET_PATCH, 1)
except ValueError as exc:
    fail(f"{KUBELET_PATCH}: {exc}")
    cadvisor_rules = []
try:
    apiserver_rules = patch_drop_rules(APISERVER_PATCH, 0)
except ValueError as exc:
    fail(f"{APISERVER_PATCH}: {exc}")
    apiserver_rules = []
try:
    kubelet_rules = values_drop_rules("kubelet.serviceMonitor.metricRelabelings")
except ValueError as exc:
    fail(f"{VALUES}: {exc}")
    kubelet_rules = []

for family in families_without_drop(cadvisor_rules, CADVISOR_FAMILIES):
    fail(f"famille cAdvisor non coupee : {family}")

for family in families_without_drop(kubelet_rules, FEATURE_FAMILIES):
    fail(f"famille non coupee sur le kubelet /metrics : {family}")

for family in families_without_drop(apiserver_rules, FEATURE_FAMILIES):
    fail(f"famille non coupee sur l'apiserver : {family}")

try:
    corpus = reader_corpus()
except ValueError as exc:
    fail(f"corpus de lecteurs illisible : {exc}")
    corpus = {}
for family, paths in sorted(families_with_reader(corpus, SCOPED_FAMILIES).items()):
    fail(f"famille avec lecteur : {family} ({', '.join(paths)})")

# --- cas negatifs : les garde-fous doivent refuser un cas casse ---------------

if families_without_drop(["container_oom_events"], ["container_oom_events_total"]) != [
    "container_oom_events_total"
]:
    fail("self-test: une regex non ancree a ete acceptee comme couverture")

if families_without_drop(["container_oom_events_total"], ["container_oom_events_total"]) != []:
    fail("self-test: une famille couverte a ete refusee")

if not families_with_reader({"k8s/demo/rule.yaml": "expr: container_oom_events_total > 0"}, ["container_oom_events_total"]):
    fail("self-test: un lecteur de famille a ete accepte")

if families_with_reader({"k8s/demo/rule.yaml": "expr: container_oom_events_total > 0"}, ["container_memory_failcnt"]):
    fail("self-test: une famille non lue a ete signalee comme lue")

try:
    rules_from_ops(
        [
            {
                "op": "add",
                "path": "/spec/endpoints/1/metricRelabelings/-",
                "value": {"action": "keep", "regex": "container_.*"},
            }
        ],
        1,
    )
except ValueError:
    pass
else:
    fail("self-test: une regle non-drop a ete acceptee")

if failures:
    for message in failures:
        print(f"MONITORING_CARDINALITY_DROP=FAIL {message}", file=sys.stderr)
    sys.exit(1)

print("MONITORING_CARDINALITY_DROP=PASS")
PY
