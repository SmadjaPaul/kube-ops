#!/usr/bin/env python3
"""Tests du contrat platform.smadja.dev/v1 Application et du chart platform-app.

Executable en local et en CI :  python3 -m unittest discover -s tests/platform -p 'test_*.py'
Niveau de preuve : STATIC (schema, rendu Helm, golden) ; pas de cluster.
Mettre UPDATE_GOLDEN=1 pour regenerer les golden files (a relire dans le diff).
"""
import copy
import difflib
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHART = ROOT / "k8s" / "charts" / "platform-app"
FIXTURES = ROOT / "tests" / "platform" / "fixtures"
GOLDEN = ROOT / "tests" / "platform" / "golden"
APPS = ROOT / "k8s" / "apps-generated"

HELM = shutil.which("helm") or "/opt/homebrew/bin/helm"

DB_MSG = "capability database unavailable: pg-shared-homelab not reconciled (AppProject infrastructure lacks databases)"


def helm_template(app_doc, release="platform-test"):
    """Rend le chart avec un app.yaml (dict). Retourne (code, stdout, stderr)."""
    with tempfile.TemporaryDirectory() as tmp:
        values = pathlib.Path(tmp) / "app.yaml"
        values.write_text(yaml.safe_dump(app_doc, sort_keys=False), encoding="utf-8")
        proc = subprocess.run(
            [HELM, "template", release, str(CHART), "-f", str(values)],
            capture_output=True, text=True,
        )
        return proc.returncode, proc.stdout, proc.stderr


def norm(text):
    """Golden compare modulo lignes vides : Helm 4.x (patch) ajoute une ligne vide avant `---`
    selon la version ; le contenu rendu est identique. Les autres differences restent bloquantes."""
    return "\n".join(line.rstrip() for line in text.splitlines() if line.strip()) + "\n"


def render_file(path):
    doc = yaml.safe_load(pathlib.Path(path).read_text(encoding="utf-8"))
    code, out, err = helm_template(doc)
    if code != 0:
        raise AssertionError(f"rendu refuse pour {path}:\n{err}")
    return out


def valid_base():
    return yaml.safe_load((FIXTURES / "web-valid.yaml").read_text(encoding="utf-8"))


class RenderDeterminism(unittest.TestCase):
    def test_two_renders_are_byte_identical(self):
        first = render_file(FIXTURES / "web-valid.yaml")
        second = render_file(FIXTURES / "web-valid.yaml")
        self.assertEqual(first, second)

    def test_golden_file_matches(self):
        rendered = render_file(FIXTURES / "web-valid.yaml")
        golden = GOLDEN / "web-valid.yaml"
        if os.environ.get("UPDATE_GOLDEN") == "1":
            golden.write_text(norm(rendered), encoding="utf-8")
        self.assertTrue(golden.exists(), "golden absent : lancer avec UPDATE_GOLDEN=1")
        self.assertEqual(norm(golden.read_text(encoding="utf-8")), norm(rendered))

    def test_only_namespace_is_cluster_scoped(self):
        rendered = render_file(FIXTURES / "web-valid.yaml")
        docs = [d for d in yaml.safe_load_all(rendered) if d]
        cluster_scoped = [d["kind"] for d in docs if d["kind"] in {"Namespace", "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition"}]
        self.assertEqual(cluster_scoped, ["Namespace"])

    def test_no_secret_and_no_namespace_outside_svc_prefix(self):
        rendered = render_file(FIXTURES / "web-valid.yaml")
        docs = [d for d in yaml.safe_load_all(rendered) if d]
        self.assertNotIn("Secret", {d["kind"] for d in docs})
        for d in docs:
            ns = d.get("metadata", {}).get("namespace")
            if ns is not None:
                self.assertEqual(ns, "svc-demo-web")

    def test_security_baseline_on_pod(self):
        rendered = render_file(FIXTURES / "web-valid.yaml")
        dep = next(d for d in yaml.safe_load_all(rendered) if d and d["kind"] == "Deployment")
        pod = dep["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertTrue(pod["securityContext"]["runAsNonRoot"])
        c = pod["containers"][0]
        self.assertTrue(c["securityContext"]["readOnlyRootFilesystem"])
        self.assertFalse(c["securityContext"]["allowPrivilegeEscalation"])
        self.assertEqual(c["securityContext"]["capabilities"]["drop"], ["ALL"])
        self.assertTrue(c["image"].count("@sha256:") == 1)


class NegativeContract(unittest.TestCase):
    """Chaque mutation doit etre refusee, avec un message attendu."""

    CASES = {
        "invalid-name-uppercase": (lambda d: d["metadata"].update(name="Bad_Name"), "/metadata/name"),
        "name-too-long": (lambda d: d["metadata"].update(name="a" * 21), "/metadata/name"),
        "namespace-forced": (lambda d: d["metadata"].update(namespace="kube-system"), "namespace"),
        "image-without-digest": (lambda d: d["spec"]["source"].update(image="ghcr.io/example/demo-web:1.0.0"), "/spec/source/image"),
        "unknown-field": (lambda d: d["spec"].update(foo="bar"), "foo"),
        "size-free-value": (lambda d: d["spec"]["runtime"].update(size="xl"), "/spec/runtime/size"),
        "replicas-too-high": (lambda d: d["spec"]["runtime"].update(replicas=4), "/spec/runtime/replicas"),
        "replicas-zero": (lambda d: d["spec"]["runtime"].update(replicas=0), "/spec/runtime/replicas"),
        "env-lowercase-key": (lambda d: d["spec"]["runtime"].update(env={"log_level": "info"}), "invalid propertyName"),
        "env-with-cpu-limit": (lambda d: d["spec"]["runtime"].update(cpu="2"), "cpu"),
        "public-exposure": (lambda d: d["spec"]["exposure"].update(mode="public"), "exposure.mode=public unavailable"),
        "authentik-auth": (lambda d: d["spec"]["exposure"].update(auth="authentik"), "exposure.auth=authentik unavailable"),
        "storage-capability": (lambda d: d["spec"].update(storage={"size": "10Gi"}), "capability storage unavailable"),
        "database-on-web-profile": (lambda d: d["spec"].update(database={"engine": "postgres"}), DB_MSG),
        "web-postgres-profile": (lambda d: d["spec"].update(profile="web-postgres"), DB_MSG),
        "bad-owner": (lambda d: d["metadata"].update(owner="team-x"), "/metadata/owner"),
        # Contrat 0.2.0 : secrets, config, egress (garde-fous)
        "secret-wrong-prefix": (lambda d: d["spec"].update(secrets=["OTHER_TOKEN"]), "doit commencer par DEMO_WEB_"),
        "secret-lowercase": (lambda d: d["spec"].update(secrets=["demo_web_token"]), "/spec/secrets/0"),
        "secret-too-many": (lambda d: d["spec"].update(secrets=[f"DEMO_WEB_K{i}" for i in range(17)]), "/spec/secrets"),
        "config-private-key": (lambda d: d["spec"].update(config={"key.pem": "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----"}), "contient une cle privee"),
        "config-bad-filename": (lambda d: d["spec"].update(config={"../escape": "x"}), "invalid propertyName"),
        "egress-ip-address": (lambda d: d["spec"].update(egress={"https": ["10.0.0.1"]}), "pas d'adresse IP"),
        "egress-wildcard": (lambda d: d["spec"].update(egress={"https": ["*.github.com"]}), "/spec/egress/https/0"),
        "egress-cluster-local": (lambda d: d["spec"].update(egress={"https": ["kubernetes.default.svc"]}), "domaine interne"),
        "egress-empty-list": (lambda d: d["spec"].update(egress={"https": []}), "/spec/egress/https"),
        "egress-other-port-field": (lambda d: d["spec"].update(egress={"https": ["api.github.com"], "port": 80}), "port"),
    }

    def test_mutations_are_rejected(self):
        for label, (mutate, expected) in self.CASES.items():
            with self.subTest(case=label):
                doc = copy.deepcopy(valid_base())
                mutate(doc)
                code, _out, err = helm_template(doc)
                self.assertNotEqual(code, 0, f"{label}: aurait dû être refusé")
                self.assertIn(expected, err, f"{label}: message attendu absent\n{err}")


class MinifluxReprise(unittest.TestCase):
    """Reprise de Miniflux en rendu seul (base PostgreSQL, profil web-postgres) : doit etre rejetee proprement."""

    def test_miniflux_is_rejected_with_database_message(self):
        doc = yaml.safe_load((FIXTURES / "miniflux-reprise.yaml").read_text(encoding="utf-8"))
        code, _out, err = helm_template(doc)
        self.assertNotEqual(code, 0)
        self.assertIn(DB_MSG, err)
        self.assertNotIn("Deployment", _out)


class UpdateDiff(unittest.TestCase):
    """Un UPDATE (size, tag/digest) ne change que les champs attendus du rendu."""

    def test_size_and_digest_update(self):
        base = valid_base()
        updated = copy.deepcopy(base)
        updated["spec"]["runtime"]["size"] = "medium"
        updated["spec"]["source"]["image"] = "ghcr.io/example/demo-web:1.0.1@sha256:" + "0" * 63 + "2"

        code_a, before, _ = helm_template(base)
        code_b, after, err_b = helm_template(updated)
        self.assertEqual((code_a, code_b), (0, 0), err_b)

        diff = [l for l in difflib.unified_diff(before.splitlines(), after.splitlines(), lineterm="", n=0)
                if (l.startswith("+") or l.startswith("-")) and not l.startswith(("+++", "---"))]
        print("\n--- diff rendu (size medium + tag/digest) ---")
        print("\n".join(diff))
        allowed = ("cpu", "memory", "image:")
        self.assertTrue(diff, "le rendu doit changer")
        for line in diff:
            self.assertTrue(any(k in line for k in allowed), f"ligne inattendue dans le diff : {line}")
        self.assertLessEqual(len(diff), 12, "diff de rendu anormalement large")

    def test_app_yaml_update_is_one_or_two_lines(self):
        base = (FIXTURES / "web-valid.yaml").read_text(encoding="utf-8")
        updated = base.replace("size: small", "size: medium").replace(
            "@sha256:0000000000000000000000000000000000000000000000000000000000000001",
            "@sha256:0000000000000000000000000000000000000000000000000000000000000002")
        changed = [l for l in difflib.ndiff(base.splitlines(), updated.splitlines()) if l[:1] in "+-"]
        self.assertEqual(len(changed), 4)  # 2 lignes retirées + 2 ajoutées (une ligne modifiée = -/+)


class PolicyAndCluster(unittest.TestCase):
    """Verifications statiques : regles Kyverno du depot (miroir, CLI non executee) et kubeconform."""

    def _pod_spec(self, rendered):
        dep = next(d for d in yaml.safe_load_all(rendered) if d and d["kind"] == "Deployment")
        return dep["spec"]["template"]["spec"]

    def test_kyverno_hardening_rules_mirror(self):
        # Miroir de k8s/infrastructure/security/policies/kyverno-policies.yaml (Audit) sur le Pod template.
        rendered = render_file(FIXTURES / "web-valid.yaml")
        pod = self._pod_spec(rendered)
        self.assertIs(pod["securityContext"]["runAsNonRoot"], True)
        for c in pod["containers"] + pod.get("initContainers", []):
            self.assertEqual(c["securityContext"]["capabilities"]["drop"], ["ALL"])
            self.assertIs(c["securityContext"]["readOnlyRootFilesystem"], True)
            self.assertIsNot(c["securityContext"].get("privileged"), True)
        for key in ("hostPID", "hostIPC", "hostNetwork"):
            self.assertIsNot(pod.get(key), True, key)

    def test_apps_generated_render_and_catalog_info(self):
        apps = sorted(APPS.glob("*/app.yaml"))
        for app_path in apps:
            with self.subTest(app=app_path.parent.name):
                rendered = render_file(app_path)
                app = yaml.safe_load(app_path.read_text(encoding="utf-8"))
                self.assertEqual(app["metadata"]["name"], app_path.parent.name, "dossier != metadata.name")
                catalog = app_path.parent / "catalog-info.yaml"
                self.assertTrue(catalog.exists(), "catalog-info.yaml manquant")
                sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
                from catalog_info import render_catalog_info
                self.assertEqual(catalog.read_text(encoding="utf-8"), render_catalog_info(app))
                # Une app generee ne porte AUCUN fichier en plus de app.yaml/catalog-info
                # (zero edition manuelle) : pas de golden par app, mais determinisme exige.
                self.assertEqual(rendered, render_file(app_path), "rendu non deterministe")
        if not apps:
            print("\n[info] aucune app dans k8s/apps-generated : test applicatif vide (attendu avant la premiere app)")

    @unittest.skipIf(shutil.which("kubeconform") is None, "kubeconform absent (CI l'installe)")
    def test_kubeconform_on_rendered_fixture(self):
        rendered = render_file(FIXTURES / "web-valid.yaml")
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
            f.write(rendered)
        try:
            proc = subprocess.run(
                ["kubeconform", "-strict", "-summary", "-ignore-missing-schemas", "-kubernetes-version", "1.33.0", f.name],
                capture_output=True, text=True,
            )
        finally:
            os.unlink(f.name)
        print("\n[kubeconform]", proc.stdout.strip().splitlines()[-1] if proc.stdout.strip() else proc.stderr.strip())
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


class ExtendedContract(unittest.TestCase):
    """Contrat 0.2.0 : secrets (ExternalSecret), config (ConfigMap), egress (toFQDNs), sonde a point."""

    def _render(self, **spec):
        doc = copy.deepcopy(valid_base())
        doc["spec"].update(spec)
        doc["spec"]["runtime"]["healthPath"] = "/.backstage/health/v1/liveness"
        code, out, err = helm_template(doc)
        self.assertEqual(code, 0, err)
        return out, [d for d in yaml.safe_load_all(out) if d]

    def test_secrets_render_externalsecret_and_envfrom_only(self):
        out, docs = self._render(secrets=["DEMO_WEB_TOKEN", "DEMO_WEB_KEY_PEM"])
        es = next(d for d in docs if d["kind"] == "ExternalSecret")
        self.assertEqual(es["apiVersion"], "external-secrets.io/v1")
        self.assertEqual(es["metadata"]["namespace"], "svc-demo-web")
        self.assertEqual(es["spec"]["secretStoreRef"], {"name": "doppler-cluster", "kind": "ClusterSecretStore"})
        self.assertEqual(es["spec"]["refreshInterval"], "1h")
        self.assertEqual([d["secretKey"] for d in es["spec"]["data"]], ["DEMO_WEB_TOKEN", "DEMO_WEB_KEY_PEM"])
        self.assertEqual([d["remoteRef"]["key"] for d in es["spec"]["data"]], ["DEMO_WEB_TOKEN", "DEMO_WEB_KEY_PEM"])
        self.assertNotIn("Secret", {d["kind"] for d in docs}, "aucun Secret rendu par le chart")
        dep = next(d for d in docs if d["kind"] == "Deployment")
        self.assertEqual(dep["spec"]["template"]["spec"]["containers"][0]["envFrom"], [{"secretRef": {"name": "demo-web-env"}}])

    def test_config_is_configmap_mounted_readonly(self):
        _out, docs = self._render(config={"app.extra.yaml": "app:\n  title: demo\n"})
        cm = next(d for d in docs if d["kind"] == "ConfigMap")
        self.assertEqual(cm["data"], {"app.extra.yaml": "app:\n  title: demo\n"})
        pod = next(d for d in docs if d["kind"] == "Deployment")["spec"]["template"]["spec"]
        mount = next(m for m in pod["containers"][0]["volumeMounts"] if m["name"] == "config")
        self.assertEqual((mount["mountPath"], mount["readOnly"]), ("/etc/platform-config", True))
        self.assertEqual(next(v for v in pod["volumes"] if v["name"] == "config")["configMap"]["name"], "demo-web-config")

    def test_egress_renders_fqdn_443_and_dns_visibility(self):
        _out, docs = self._render(egress={"https": ["api.github.com", "github.com"]})
        cnp = next(d for d in docs if d["kind"] == "CiliumNetworkPolicy")
        fqdn = next(r for r in cnp["spec"]["egress"] if "toFQDNs" in r)
        self.assertEqual(fqdn["toFQDNs"], [{"matchName": "api.github.com"}, {"matchName": "github.com"}])
        self.assertEqual(fqdn["toPorts"], [{"ports": [{"port": "443", "protocol": "TCP"}]}])
        dns = next(r for r in cnp["spec"]["egress"] if "toEndpoints" in r)
        self.assertEqual(dns["toPorts"][0]["rules"]["dns"], [{"matchName": "api.github.com"}, {"matchName": "github.com"}])

    def test_no_new_fields_means_no_new_resources(self):
        _out, docs = self._render()
        kinds = {d["kind"] for d in docs}
        self.assertFalse({"ExternalSecret", "ConfigMap"} & kinds)
        cnp = next(d for d in docs if d["kind"] == "CiliumNetworkPolicy")
        self.assertFalse(any("toFQDNs" in r for r in cnp["spec"]["egress"]))

    def test_private_key_in_config_is_not_rendered(self):
        doc = copy.deepcopy(valid_base())
        doc["spec"]["config"] = {"k.pem": "-----BEGIN PRIVATE KEY-----"}
        code, out, err = helm_template(doc)
        self.assertNotEqual(code, 0)
        self.assertNotIn("BEGIN PRIVATE KEY", out)


if __name__ == "__main__":
    unittest.main()
