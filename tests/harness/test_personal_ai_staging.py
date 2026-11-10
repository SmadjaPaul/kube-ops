"""Static fail-closed contract for staged personal AI, stdlib only."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / "k8s/optional/personal-ai-2026"

class PersonalAIStagingContract(unittest.TestCase):
    def test_staged_not_imported_from_active_roots(self):
        for root in ("k8s/applications/ai/kustomization.yaml",
                     "k8s/applications/platform/kustomization.yaml"):
            self.assertNotIn("personal-ai-2026", (REPO/root).read_text())

    def test_pinned_versions(self):
        openclaw = (ROOT/"openclaw/deployment.yaml").read_text()
        hindsight = (ROOT/"hindsight/application.yaml").read_text()
        librechat = (ROOT/"librechat/application.yaml").read_text()
        self.assertIn("ghcr.io/openclaw/openclaw:2026.11.2", openclaw)
        self.assertIn("targetRevision: 1.2.0", hindsight)
        self.assertIn("targetRevision: 3.0.0", librechat)
        self.assertIn("tag: v0.8.8", librechat)
        for content in (openclaw,hindsight,librechat):
            self.assertNotRegex(content, r"image:\\s*\\S+:latest\\b")

    def test_no_public_routes_or_admin_tokens(self):
        for f in ROOT.rglob("*.yaml"):
            content = f.read_text()
            self.assertNotIn("kind: HTTPRoute", content, f.as_posix())
            self.assertNotIn("kind: ClusterRoleBinding", content, f.as_posix())
            self.assertNotIn("automountServiceAccountToken: true", content, f.as_posix())
            self.assertNotIn("kind: ClusterRole", content, f.as_posix())
        config = (ROOT/"openclaw/configmap.yaml").read_text()
        self.assertIn('"bind": "loopback"', config)
        self.assertIn('"cron": {"enabled": false}', config)
        self.assertIn('"allow": ["read"]', config)
        self.assertIn("redactSensitive", config)
        self.assertNotIn("kubectl", config)
        self.assertIn("ALLOW_SOCIAL_LOGIN: \"false\"",
                      (ROOT/"librechat/application.yaml").read_text())

    def test_dedicated_helm_project_and_policies(self):
        project = (ROOT/"project.yaml").read_text()
        self.assertIn("personal-ai-pilot", project)
        self.assertIn("ghcr.io/vectorize-io/charts", project)
        self.assertIn("ghcr.io/librechat-ai/librechat-chart", project)
        for name in ("hindsight", "librechat"):
            self.assertIn("networkpolicy.yaml", (ROOT/name/"kustomization.yaml").read_text())
            self.assertIn("endpointSelector: {}", (ROOT/name/"networkpolicy.yaml").read_text())
            self.assertIn("project: personal-ai-pilot", (ROOT/name/"application.yaml").read_text())

    def test_external_secrets_no_value(self):
        for f in ROOT.rglob("externalsecret*.yaml"):
            c=f.read_text()
            self.assertIn("doppler-cluster", c)
            self.assertIn("remoteRef", c)
            self.assertNotIn("stringData:", c)

if __name__ == "__main__":
    unittest.main()
