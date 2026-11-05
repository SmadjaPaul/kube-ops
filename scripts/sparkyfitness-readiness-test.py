import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("preflight", ROOT / "scripts" / "sparkyfitness-readiness.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

class PreflightTests(unittest.TestCase):
    def test_static_source_is_only_a_contract(self):
        result = m.static_checks(ROOT)
        self.assertEqual(result["dormant"], "PASS")
        self.assertEqual(set(result), set(m.CHECKS) | {"dormant"})

    def test_runtime_only_uses_get_of_allowlisted_metadata(self):
        calls = []
        def fake(cmd, **kwargs):
            calls.append(cmd)
            self.assertEqual(cmd[0], "kubectl")
            self.assertEqual(cmd[3], "get")
            self.assertNotIn("secret", cmd[4].lower())
            obj={"status":{"conditions":[{"type":"Ready","status":"True"}],
                           "sync":{"status":"Synced"},"health":{"status":"Healthy"}}}
            return subprocess.CompletedProcess(cmd,0,json.dumps(obj),"")
        with patch.object(m.subprocess,"run",side_effect=fake):
            result=m.runtime_checks()
        self.assertTrue(calls)
        self.assertEqual(result["application/argocd/personal-sparkyfitness"],"PASS")
        self.assertEqual(result["scheduledbackup/wellness/sparkyfitness-postgresql-weekly"],"PRESENT_NOT_PROVEN")
        self.assertFalse(any("secret" in call[4].lower() for call in calls))

    def test_missing_permission_fails_closed(self):
        with patch.object(m.subprocess,"run",return_value=subprocess.CompletedProcess([],1,"","forbidden")):
            self.assertEqual(m.kubectl_status("cluster","wellness","sparkyfitness-db"),"BLOCKED")

    def test_default_cli_is_offline_and_non_mutating(self):
        result = subprocess.run([sys.executable,str(ROOT/"scripts/sparkyfitness-readiness.py")],
                                capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        data=json.loads(result.stdout)
        self.assertEqual(data["admission"],"BLOCKED")
        self.assertEqual(data["runtime_resource_status"],"NOT_EXECUTED")
        self.assertEqual(data["gates"]["USER_READY"],"NOT_EXECUTED")

if __name__ == "__main__":
    unittest.main()
