#!/usr/bin/env python3
"""Génère les cas `kyverno test` (un dossier par règle) de platform-baseline et repo-contract.

Usage : python3 -I tests/policies/gen-tests.py [--check]
Écrit (ou, avec --check, compare sans écrire) tests/policies/<règle>/{resources,kyverno-test}.yaml.
Chaque règle a au moins un cas fail et un cas pass (ou skip quand la règle refuse tout) ; les cas skip vérifient l'exclusion des
namespaces système. Les ressources sont dérivées d'un objet propre : un cas = une mutation.
"""
import copy
import os
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = "../../../k8s/infrastructure/security/policies/platform-baseline.yaml"
STATIC = "../../../policy/static/repo-contract.yaml"
ADMISSION = "../../../k8s/infrastructure/security/policies/eso-k8s-store-guard.yaml"
PREVIEW = "../../../k8s/infrastructure/previews/admission-policy.yaml"
DIGEST = "sha256:" + "a" * 64


def pod(ns="app"):
    return {
        "apiVersion": "v1", "kind": "Pod", "metadata": {"name": "x", "namespace": ns},
        "spec": {
            "securityContext": {"runAsNonRoot": True, "runAsUser": 1000},
            "containers": [{
                "name": "main", "image": "registry.example/app:1.2.3",
                "securityContext": {
                    "allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                    "capabilities": {"drop": ["ALL"]},
                },
                "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}},
            }],
            "volumes": [{"name": "tmp", "emptyDir": {"sizeLimit": "64Mi"}}],
        },
    }


def with_init(p):
    init = copy.deepcopy(p["spec"]["containers"][0])
    init["name"] = "init"
    p["spec"]["initContainers"] = [init]
    return init


def c0(p):
    return p["spec"]["containers"][0]


def deployment(p):
    return {
        "apiVersion": "apps/v1", "kind": "Deployment",
        "metadata": {"name": "x", "namespace": p["metadata"]["namespace"]},
        "spec": {"selector": {"matchLabels": {"a": "b"}}, "template": {"metadata": {"labels": {"a": "b"}}, "spec": p["spec"]}},
    }


def pod_case(fn=None, ns="app", init=False, wrap=None):
    p = pod(ns)
    if init:
        i = with_init(p)
        if fn:
            fn(p, i)
    elif fn:
        fn(p, c0(p))
    return deployment(p) if wrap == "deployment" else p


def setp(**kw):
    def f(p, c):
        for k, v in kw.items():
            p["spec"][k] = v
    return f


def setc(key, val):
    def f(p, c):
        c["securityContext"][key] = val
    return f


def delc(*path):
    def f(p, c):
        d = c
        for k in path[:-1]:
            d = d[k]
        del d[path[-1]]
    return f


def both(*fns):
    def f(p, c):
        for fn in fns:
            fn(p, c)
    return f


def svc(t=None):
    s = {"apiVersion": "v1", "kind": "Service", "metadata": {"name": "x", "namespace": "app"},
         "spec": {"ports": [{"port": 80}], "selector": {"a": "b"}}}
    if t:
        s["spec"]["type"] = t
    return s


def svc_in(t, ns, name):
    s = svc(t)
    s["metadata"] = {"name": name, "namespace": ns}
    return s


def svc_deleting(t):
    s = svc(t)
    s["metadata"]["deletionTimestamp"] = "2026-01-01T00:00:00Z"
    return s


def pvc(sc=None):
    o = {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": {"name": "x", "namespace": "app"},
         "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}}
    if sc:
        o["spec"]["storageClassName"] = sc
    return o


def es(api="external-secrets.io/v1", store="doppler-cluster", kind="ClusterSecretStore", refresh="1h"):
    s = {"apiVersion": api, "kind": "ExternalSecret", "metadata": {"name": "x", "namespace": "app"},
         "spec": {"secretStoreRef": {"name": store, "kind": kind},
                  "target": {"name": "x"}, "data": [{"secretKey": "A", "remoteRef": {"key": "A"}}]}}
    if refresh:
        s["spec"]["refreshInterval"] = refresh
    return s


def es_k8s(store="k8s-auth", kind="ClusterSecretStore", keys=("oidc-app",), ns="app", refresh="1h", **extra):
    """Copie lue dans un store k8s-* (formes B) : une cle `remoteRef.key` par element de `keys`."""
    s = es(store=store, kind=kind, refresh=refresh)
    s["metadata"]["namespace"] = ns
    s["spec"]["data"] = [{"secretKey": f"K{i}", "remoteRef": {"key": k, "property": "P"}} for i, k in enumerate(keys)]
    s["spec"].update(extra)
    return s


def es_gen(**over):
    """Source generee (forme C) conforme ; `over` ecrase ou, avec la valeur None, supprime un champ de spec."""
    s = {"apiVersion": "external-secrets.io/v1", "kind": "ExternalSecret", "metadata": {"name": "x", "namespace": "auth"},
         "spec": {"refreshPolicy": "CreatedOnce", "target": {"name": "x", "creationPolicy": "Orphan"},
                  "dataFrom": [{"sourceRef": {"generatorRef": {"apiVersion": "generators.external-secrets.io/v1alpha1",
                                                                "kind": "Password", "name": "x"}}}]}}
    for k, v in over.items():
        if v is None:
            s["spec"].pop(k, None)
        else:
            s["spec"][k] = v
    return s


def schedule(fs, opt_out=None):
    s = {"apiVersion": "velero.io/v1", "kind": "Schedule", "metadata": {"name": "x", "namespace": "velero"},
         "spec": {"schedule": "0 3 * * *", "template": {"includedNamespaces": ["app"]}}}
    if fs is not None:
        s["spec"]["template"]["defaultVolumesToFsBackup"] = fs
    if opt_out is not None:
        s["metadata"]["annotations"] = {"kube-ops.io/fs-backup-opt-out": opt_out}
    return s


def env(name, **kw):
    def f(p, c):
        c["env"] = [dict(name=name, **kw)]
    return f


REF = {"valueFrom": {"secretKeyRef": {"name": "s", "key": "k"}}}


# règle -> (fichier de politique, préfixe de politique, kind, [(cas, attendu, objet)])
P, F, S = "pass", "fail", "skip"

# Lecture croisee (secrets-migration-spec 4.5) : memes cas pour la regle statique et pour l'admission.
OWN_NS_CASES = [
    ("oidc-own-namespace", P, es_k8s("k8s-auth", keys=("oidc-app",))),
    ("oidc-own-namespace-usage", P, es_k8s("k8s-auth", keys=("oidc-app--mas", "oidc-app"))),
    ("pg-own-namespace", P, es_k8s("k8s-databases", keys=("pg-app",))),
    ("pg-own-namespace-usage", P, es_k8s("k8s-databases", keys=("pg-app--ro",))),
    ("llm-own-namespace", P, es_k8s("k8s-agentgateway", keys=("llm-app",))),
    ("llm-other-namespace", F, es_k8s("k8s-agentgateway", keys=("llm-autre",))),
    ("oidc-key-on-agentgateway-store", F, es_k8s("k8s-agentgateway", keys=("oidc-app",))),
    ("oidc-other-namespace", F, es_k8s("k8s-auth", keys=("oidc-autre",))),
    ("oidc-one-key-other-namespace", F, es_k8s("k8s-auth", keys=("oidc-app", "oidc-autre"))),
    ("oidc-prefix-collision", F, es_k8s("k8s-auth", keys=("oidc-app-pilot",))),
    ("oidc-namespace-substring", F, es_k8s("k8s-auth", keys=("oidc-app--x", "oidc-appx"))),
    ("pg-key-on-auth-store", F, es_k8s("k8s-auth", keys=("pg-app",))),
    ("oidc-key-on-databases-store", F, es_k8s("k8s-databases", keys=("oidc-app",))),
    ("authentik-core-secrets", F, es_k8s("k8s-auth", keys=("authentik-core-secrets",))),
    ("datafrom-extract", F, es_k8s("k8s-auth", keys=("oidc-app",), dataFrom=[{"extract": {"key": "oidc-app"}}])),
    ("datafrom-find", F, es_k8s("k8s-databases", keys=(), dataFrom=[{"find": {"name": {"regexp": ".*"}}}])),
    ("data-sourceref", F, es_k8s("k8s-auth", keys=("oidc-app",), data=[{"secretKey": "A", "sourceRef": {"storeRef": {"name": "k8s-auth"}},
                                                                       "remoteRef": {"key": "oidc-app"}}])),
    ("secretstore-kind", F, es_k8s("k8s-auth", kind="SecretStore", keys=("oidc-app",))),
    ("doppler-store-not-concerned", S, es(store="doppler-cluster")),
]

RULES = {
    "non-root-containers": [
        ("clean", P, pod_case()),
        ("container-overrides-pod", P, pod_case(both(setp(securityContext={"runAsNonRoot": False}), setc("runAsNonRoot", True)))),
        ("pod-run-as-non-root-false", F, pod_case(setp(securityContext={"runAsNonRoot": False, "runAsUser": 1000}))),
        ("uid-0-container", F, pod_case(setc("runAsUser", 0))),
        ("uid-0-pod", F, pod_case(setp(securityContext={"runAsNonRoot": True, "runAsUser": 0}))),
        ("no-non-root-anywhere", F, pod_case(setp(securityContext={}))),
        ("init-root", F, pod_case(setc("runAsUser", 0), init=True)),
        ("deployment-root", F, pod_case(setp(securityContext={"runAsNonRoot": False}), wrap="deployment")),
        ("system-namespace-root", S, pod_case(setp(securityContext={}), ns="kube-system")),
    ],
    "no-privileged": [
        ("clean", P, pod_case()),
        ("privileged-false", P, pod_case(setc("privileged", False))),
        ("privileged", F, pod_case(setc("privileged", True))),
        ("init-privileged", F, pod_case(setc("privileged", True), init=True)),
        ("deployment-privileged", F, pod_case(setc("privileged", True), wrap="deployment")),
        ("system-namespace-privileged", S, pod_case(setc("privileged", True), ns="monitoring")),
        ("exception-longhorn-system", S, pod_case(setc("privileged", True), ns="longhorn-system")),
        ("exception-csi-proxmox", S, pod_case(setc("privileged", True), ns="csi-proxmox")),
    ],
    "no-privilege-escalation": [
        ("clean", P, pod_case()),
        ("escalation-true", F, pod_case(setc("allowPrivilegeEscalation", True))),
        ("escalation-missing", F, pod_case(delc("securityContext", "allowPrivilegeEscalation"))),
        ("init-escalation", F, pod_case(setc("allowPrivilegeEscalation", True), init=True)),
        ("system-namespace", S, pod_case(setc("allowPrivilegeEscalation", True), ns="kube-system")),
    ],
    "drop-all-capabilities": [
        ("clean", P, pod_case()),
        ("drop-other", F, pod_case(setc("capabilities", {"drop": ["NET_RAW"]}))),
        ("no-capabilities", F, pod_case(delc("securityContext", "capabilities"))),
        ("no-security-context", F, pod_case(delc("securityContext"))),
        ("init-no-drop", F, pod_case(setc("capabilities", {"add": ["CHOWN"]}), init=True)),
        ("system-namespace", S, pod_case(delc("securityContext"), ns="kube-system")),
    ],
    "no-added-capabilities": [
        ("clean", P, pod_case()),
        ("add-net-bind-service", P, pod_case(setc("capabilities", {"drop": ["ALL"], "add": ["NET_BIND_SERVICE"]}))),
        ("add-net-admin", F, pod_case(setc("capabilities", {"drop": ["ALL"], "add": ["NET_ADMIN"]}))),
        ("add-sys-admin-init", F, pod_case(setc("capabilities", {"drop": ["ALL"], "add": ["SYS_ADMIN"]}), init=True)),
        ("system-namespace", S, pod_case(setc("capabilities", {"add": ["NET_ADMIN"]}), ns="kube-system")),
    ],
    "read-only-root-filesystem": [
        ("clean", P, pod_case()),
        ("writable", F, pod_case(setc("readOnlyRootFilesystem", False))),
        ("missing", F, pod_case(delc("securityContext", "readOnlyRootFilesystem"))),
        ("init-writable", F, pod_case(setc("readOnlyRootFilesystem", False), init=True)),
        ("system-namespace", S, pod_case(setc("readOnlyRootFilesystem", False), ns="kube-system")),
    ],
    "no-host-namespaces": [
        ("clean", P, pod_case()),
        ("explicit-false", P, pod_case(setp(hostNetwork=False, hostPID=False, hostIPC=False))),
        ("host-network", F, pod_case(setp(hostNetwork=True))),
        ("host-pid", F, pod_case(setp(hostPID=True))),
        ("host-ipc", F, pod_case(setp(hostIPC=True))),
        ("system-namespace", S, pod_case(setp(hostNetwork=True), ns="kube-system")),
    ],
    "no-hostpath-volume": [
        ("clean", P, pod_case()),
        ("hostpath", F, pod_case(setp(volumes=[{"name": "h", "hostPath": {"path": "/var/run"}}]))),
        ("no-volumes", P, pod_case(setp(volumes=[]))),
        ("system-namespace", S, pod_case(setp(volumes=[{"name": "h", "hostPath": {"path": "/"}}]), ns="kube-system")),
    ],
    "require-resources": [
        ("clean", P, pod_case()),
        ("no-resources", F, pod_case(delc("resources"))),
        ("no-memory-limit", F, pod_case(lambda p, c: c["resources"]["limits"].pop("memory"))),
        ("no-cpu-request", F, pod_case(lambda p, c: c["resources"]["requests"].pop("cpu"))),
        ("init-no-resources", F, pod_case(delc("resources"), init=True)),
        ("system-namespace", S, pod_case(delc("resources"), ns="kube-system")),
    ],
    "emptydir-size-limit": [
        ("clean", P, pod_case()),
        ("no-volumes", P, pod_case(setp(volumes=[]))),
        ("unbounded", F, pod_case(setp(volumes=[{"name": "t", "emptyDir": {}}]))),
        ("memory-unbounded", F, pod_case(setp(volumes=[{"name": "t", "emptyDir": {"medium": "Memory"}}]))),
        ("system-namespace", S, pod_case(setp(volumes=[{"name": "t", "emptyDir": {}}]), ns="kube-system")),
    ],
    "no-latest-tag": [
        ("pinned-tag", P, pod_case()),
        ("digest-only", P, pod_case(lambda p, c: c.update(image=f"registry.example/app@{DIGEST}"))),
        ("registry-port-tag", P, pod_case(lambda p, c: c.update(image="registry.example:5000/team/app:v2"))),
        ("latest", F, pod_case(lambda p, c: c.update(image="registry.example/app:latest"))),
        ("no-tag", F, pod_case(lambda p, c: c.update(image="registry.example/app"))),
        ("main-tag", F, pod_case(lambda p, c: c.update(image="registry.example/app:main"))),
        ("init-latest", F, pod_case(lambda p, c: c.update(image="busybox:latest"), init=True)),
        ("system-namespace", S, pod_case(lambda p, c: c.update(image="x:latest"), ns="kube-system")),
    ],
    "no-nodeport": [
        ("cluster-ip", P, svc()),
        ("explicit-cluster-ip", P, svc("ClusterIP")),
        ("load-balancer", P, svc("LoadBalancer")),
        ("node-port", F, svc("NodePort")),
    ],
    "no-loadbalancer": [
        ("cluster-ip", P, svc()),
        ("node-port", P, svc("NodePort")),
        ("load-balancer", F, svc("LoadBalancer")),
        ("load-balancer-other-gateway-name", F, svc_in("LoadBalancer", "gateway", "my-lb")),
        ("cilium-gateway-external", S, svc_in("LoadBalancer", "gateway", "cilium-gateway-external")),
        ("dns-exact-resolver", S, svc_in("LoadBalancer", "dns-exact-resolver", "dns-exact-resolver")),
        ("system-namespace", S, svc_in("LoadBalancer", "kube-system", "x")),
        # Without an unchanged oldObject, a deletionTimestamp must not bypass the ban.
        ("deletion-timestamp-no-old-object", F, svc_deleting("LoadBalancer")),
    ],
    "storage-class-allowed": [
        ("longhorn-fast", P, pvc("longhorn-fast")),
        ("longhorn-bulk", P, pvc("longhorn-bulk")),
        ("longhorn-bulk-scratch", P, pvc("longhorn-bulk-scratch")),
        ("oci-bv", P, pvc("oci-bv")),
        ("nfs-client", F, pvc("nfs-client")),
        ("proxmox-csi", F, pvc("proxmox-csi")),
        ("default-class-implicit", F, pvc()),
    ],
    "env-secret-via-secretkeyref": [
        ("no-env", P, pod_case()),
        ("env-null", P, pod_case(lambda p, c: c.update(env=None))),
        ("secretkeyref", P, pod_case(env("DB_PASSWORD", **REF))),
        ("plain-env", P, pod_case(env("LOG_LEVEL", value="debug"))),
        ("password-file-path", P, pod_case(env("DB_PASSWORD_FILE", value="/run/secrets/db"))),
        ("empty-value", P, pod_case(env("API_TOKEN", value=""))),
        ("literal-password", F, pod_case(env("DB_PASSWORD", value="not-a-real-value"))),
        ("literal-token", F, pod_case(env("API_TOKEN", value="not-a-real-value"))),
        ("secret-named-numeric-value", F, pod_case(env("TOKEN_VALIDITY", value=3600))),
        ("literal-client-secret", F, pod_case(env("OIDC_CLIENT_SECRET", value="not-a-real-value"))),
        ("init-literal-password", F, pod_case(env("DB_PASSWORD", value="not-a-real-value"), init=True)),
        ("system-namespace", S, pod_case(env("DB_PASSWORD", value="not-a-real-value"), ns="kube-system")),
    ],
}
STATIC_RULES = {
    "no-networkpolicy": [
        ("standard-networkpolicy", F, {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
                                       "metadata": {"name": "x", "namespace": "app"}, "spec": {"podSelector": {}}}),
        ("system-namespace", S, {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
                                 "metadata": {"name": "x", "namespace": "kube-system"}, "spec": {"podSelector": {}}}),
    ],
    "no-rendered-secret": [
        ("literal-secret", F, {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "x", "namespace": "app"},
                               "type": "Opaque", "stringData": {"k": "placeholder"}}),
        ("system-namespace", S, {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "x", "namespace": "kube-system"},
                                 "type": "Opaque", "stringData": {"k": "placeholder"}}),
    ],
    "externalsecret-contract": [
        ("compliant", P, es()),
        ("v1beta1", F, es(api="external-secrets.io/v1beta1")),
        ("other-store", F, es(store="other-store")),
        ("namespaced-secretstore", F, es(kind="SecretStore")),
        ("refresh-720h", F, es(refresh="720h")),
        ("refresh-missing", F, es(refresh=None)),
        # (B) copie lue dans k8s-auth / k8s-databases
        ("k8s-auth-copy", P, es_k8s("k8s-auth")),
        ("k8s-databases-copy", P, es_k8s("k8s-databases", keys=("pg-app",))),
        ("k8s-auth-namespaced-store", F, es_k8s("k8s-auth", kind="SecretStore")),
        ("k8s-auth-refresh-720h", F, es_k8s("k8s-auth", refresh="720h")),
        ("k8s-auth-refresh-missing", F, es_k8s("k8s-auth", refresh=None)),
        ("k8s-unknown-store", F, es_k8s("k8s-other")),
        # (C) source generee
        ("generated-source", P, es_gen()),
        ("generated-without-createdonce", F, es_gen(refreshPolicy=None)),
        ("generated-refresh-periodic", F, es_gen(refreshPolicy="Periodic")),
        ("generated-owner", F, es_gen(target={"name": "x", "creationPolicy": "Owner"})),
        ("generated-creation-policy-missing", F, es_gen(target={"name": "x"})),
        ("generated-mixed-with-data", F, es_gen(data=[{"secretKey": "A", "remoteRef": {"key": "A"}}])),
        ("generated-with-store", F, es_gen(secretStoreRef={"name": "doppler-cluster", "kind": "ClusterSecretStore"})),
        ("generated-datafrom-extract", F, es_gen(dataFrom=[{"extract": {"key": "A"}}])),
        ("generated-datafrom-mixed", F, es_gen(dataFrom=[es_gen()["spec"]["dataFrom"][0], {"extract": {"key": "A"}}])),
        ("generated-datafrom-empty", F, es_gen(dataFrom=[])),
        ("generated-system-namespace", S, {**es_gen(refreshPolicy=None), "metadata": {"name": "x", "namespace": "monitoring"}}),
    ],
    "eso-k8s-store-own-namespace": OWN_NS_CASES,
    "velero-fs-backup": [
        ("fs-backup-true", P, schedule(True)),
        ("fs-backup-false", F, schedule(False)),
        ("fs-backup-missing", F, schedule(None)),
        ("fs-backup-false-opt-out", P, schedule(False, "donnees couvertes par barman")),
        ("fs-backup-false-empty-opt-out", F, schedule(False, "")),
    ],
}


ADMISSION_RULES = {"k8s-store-guard": OWN_NS_CASES}


def prev(obj, ns="pr-7-demo"):
    o = copy.deepcopy(obj)
    o["metadata"]["namespace"] = ns
    return o


def prev_pod(**kw):
    p = pod("pr-7-demo")
    p["spec"]["priorityClassName"] = "preview-low"
    p["spec"].update(kw)
    return p


def store_obj(kind, ns=None):
    o = {"apiVersion": "external-secrets.io/v1", "kind": kind, "metadata": {"name": "x"},
         "spec": {"provider": {"doppler": {"auth": {"secretRef": {"dopplerToken": {"key": "token", "name": "t"}}}}}}}
    if ns:
        o["metadata"]["namespace"] = ns
    return o


PREVIEW_CASES = [
    # form C: the only admitted ExternalSecret
    ("generated-form-c", P, prev(es_gen())),
    ("generated-form-c-outside-preview-ns-is-skipped", S, es_k8s("k8s-auth", ns="auth")),
    # the three production stores, and any other store
    ("store-doppler-cluster", F, prev(es())),
    ("store-k8s-auth", F, prev(es_k8s("k8s-auth", keys=("oidc-pr-7-demo",)))),
    ("store-k8s-databases", F, prev(es_k8s("k8s-databases", keys=("pg-pr-7-demo",)))),
    ("store-other-doppler", F, prev(es(store="doppler-other"))),
    ("store-namespaced-secretstore", F, prev(es(kind="SecretStore", store="own"))),
    ("generated-with-store", F, prev(es_gen(secretStoreRef={"name": "doppler-cluster", "kind": "ClusterSecretStore"}))),
    ("generated-mixed-with-data", F, prev(es_gen(data=[{"secretKey": "A", "remoteRef": {"key": "A"}}]))),
    ("generated-datafrom-extract", F, prev(es_gen(dataFrom=[{"extract": {"key": "A"}}]))),
    ("generated-without-createdonce", F, prev(es_gen(refreshPolicy=None))),
    ("generated-non-password-generator", F, prev(es_gen(dataFrom=[{"sourceRef": {"generatorRef": {
        "apiVersion": "generators.external-secrets.io/v1alpha1", "kind": "Webhook", "name": "x"}}}]))),
    ("generated-datafrom-store-ref", F, prev(es_gen(dataFrom=[{"sourceRef": {"storeRef": {"name": "doppler-cluster", "kind": "ClusterSecretStore"}}}]))),
    # no store of its own, no shared database
    ("secretstore-in-preview", F, store_obj("SecretStore", "pr-7-demo")),
    ("database-in-preview", F, {"apiVersion": "postgresql.cnpg.io/v1", "kind": "Database",
                                "metadata": {"name": "x", "namespace": "pr-7-demo"},
                                "spec": {"name": "demo", "owner": "demo", "cluster": {"name": "pg-shared-homelab"}}}),
    ("database-outside-preview-is-skipped", S, {"apiVersion": "postgresql.cnpg.io/v1", "kind": "Database",
                                                "metadata": {"name": "x", "namespace": "databases"},
                                                "spec": {"name": "demo", "owner": "demo", "cluster": {"name": "pg-shared-homelab"}}}),
    # priority and exposure
    ("pod-low-priority", P, prev_pod()),
    ("pod-default-priority", F, {**prev_pod(), "spec": {k: v for k, v in prev_pod()["spec"].items() if k != "priorityClassName"}}),
    ("service-loadbalancer", F, prev(svc("LoadBalancer"))),
    ("service-clusterip", P, prev(svc("ClusterIP"))),
]

PREVIEW_RULES = {"namespace-guard": PREVIEW_CASES}


def render(rule, cases, policy_file, prefix):
    pol = f"{prefix}-{rule}"
    res, results = [], []
    for cid, expected, obj in cases:
        o = copy.deepcopy(obj)
        o["metadata"]["name"] = cid
        res.append(o)
        results.append({"policy": pol, "isValidatingPolicy": True, "kind": o["kind"], "resources": [cid], "result": expected})
    test = {"apiVersion": "cli.kyverno.io/v1alpha1", "kind": "Test", "metadata": {"name": pol},
            "policies": [policy_file], "resources": ["resources.yaml"], "results": results}
    if prefix == "preview":
        # The policy is bounded by a namespaceSelector (PLT-395): without these labels the CLI
        # excludes every resource and a `fail` case passes vacuously.
        test["values"] = {"namespaceSelector": [{"name": "pr-7-demo", "labels": {"smadja.dev/preview": "true"}}]}
    hdr = "# Généré par tests/policies/gen-tests.py : ne pas éditer à la main.\n"
    return {
        "resources.yaml": hdr + yaml.safe_dump_all(res, sort_keys=True, allow_unicode=True),
        "kyverno-test.yaml": hdr + yaml.safe_dump(test, sort_keys=True, allow_unicode=True),
    }


def main():
    check = "--check" in sys.argv
    stale = []
    for table, pf, prefix in ((RULES, BASELINE, "platform-baseline"), (STATIC_RULES, STATIC, "repo-contract"), (ADMISSION_RULES, ADMISSION, "eso"), (PREVIEW_RULES, PREVIEW, "preview")):
        for rule, cases in table.items():
            got = {c[1] for c in cases}
            assert F in got and (P in got or S in got), f"{rule}: il faut un cas fail et un cas pass ou skip"
            d = os.path.join(HERE, rule)
            for name, content in render(rule, cases, pf, prefix).items():
                path = os.path.join(d, name)
                if check:
                    if not os.path.exists(path) or open(path, encoding="utf-8").read() != content:
                        stale.append(path)
                else:
                    os.makedirs(d, exist_ok=True)
                    open(path, "w", encoding="utf-8").write(content)
    if stale:
        print("Cas de test périmés (relancer gen-tests.py) :\n  " + "\n  ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
