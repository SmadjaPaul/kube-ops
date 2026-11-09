import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import manage_tenants as mod


class TenantContractTest(unittest.TestCase):
    def test_secret_ref_is_deterministic(self):
        self.assertEqual(mod.secret_key("t-a1234"), "APP_HERMES_T_A1234_LLM_KEY")

    def test_registry_rejects_bad_ids_and_unexpected_personal_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "tenants.json"
            with patch.object(mod, "REGISTRY", p):
                for rows in (
                    [{"id": "alice@example.com", "secret_key": "x"}],
                    [{"id": "t-a1234", "secret_key": mod.secret_key("t-a1234"), "email": "private"}],
                    [{"id": "t-a1234", "secret_key": "wrong"}],
                ):
                    p.write_text(json.dumps(rows))
                    with self.assertRaises(ValueError):
                        mod.load_registry()

    def test_empty_registry_does_not_deploy_any_agent(self):
        doc = json.loads(mod.TEMPLATE.read_text())
        self.assertEqual(doc["spec"]["generators"][0]["list"]["elements"], [])
        self.assertEqual(doc["spec"]["template"]["spec"]["source"]["helm"]["valuesObject"]["replicaCount"], 1)
        self.assertEqual(doc["spec"]["template"]["spec"]["source"]["helm"]["valuesObject"]["strategy"]["type"], "Recreate")
        self.assertFalse(doc["spec"]["template"]["spec"]["source"]["helm"]["valuesObject"]["apiServer"]["enabled"])


if __name__ == "__main__":
    unittest.main()
