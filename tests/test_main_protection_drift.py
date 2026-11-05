import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "scripts" / "verify-main-protection.py"
SPEC = importlib.util.spec_from_file_location("verify_main_protection", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def protection(**status):
    result = {
        "required_status_checks": {
            "strict": True,
            "contexts": ["v1-contract", "docs-required", "workflow-integrity"],
        },
        "enforce_admins": {"enabled": True},
        "allow_force_pushes": {"enabled": False},
        "allow_deletions": {"enabled": False},
    }
    result["required_status_checks"].update(status)
    return result


class MainProtectionContractTest(unittest.TestCase):
    def test_current_contract_passes(self):
        self.assertEqual(MODULE.validate(protection()), [])

    def test_missing_check_is_drift(self):
        errors = MODULE.validate(protection(contexts=["v1-contract", "docs-required"]))
        self.assertIn("missing required checks: workflow-integrity", errors)

    def test_non_strict_protection_is_drift(self):
        errors = MODULE.validate(protection(strict=False))
        self.assertIn("required_status_checks.strict must be true", errors)

    def test_force_push_or_deletion_is_drift(self):
        candidate = protection()
        candidate["allow_force_pushes"]["enabled"] = True
        candidate["allow_deletions"]["enabled"] = True
        errors = MODULE.validate(candidate)
        self.assertIn("force-pushes must be disabled", errors)
        self.assertIn("branch deletion must be disabled", errors)


if __name__ == "__main__":
    unittest.main()
