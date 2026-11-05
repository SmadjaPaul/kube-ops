"""Base-only admission gate unit tests; no GitHub API or cluster interaction."""
import datetime as dt
import json
import unittest
import verify as gate

NOW = dt.datetime(2026, 11, 5, 13, 0, tzinfo=dt.timezone.utc)


def example(**changes):
    row = {
        "repository": gate.REPOSITORY, "pr": 949, "headSha": "a" * 40,
        "paths": ["tests/harness/backup-audit-contract-test.sh"],
        "reason": "PLT-56: validated contract additions",
        "approvedBy": gate.OWNER, "expiresAt": "2026-11-06T13:00:00Z",
    }
    row.update(changes)
    return {"schemaVersion": 1, "admissions": [row]}


class AdmissionContract(unittest.TestCase):
    def test_valid_exact_scope(self):
        self.assertEqual(len(gate.validate_registry(json.dumps(example()), NOW, True)), 1)

    def test_unauthorized_gate_change(self):
        with self.assertRaises(ValueError):
            gate.validate_registry(json.dumps(example(paths=[gate.SELF])), NOW, True)

    def test_reject_wildcards(self):
        with self.assertRaises(ValueError):
            gate.validate_registry(json.dumps(example(paths=["tests/harness/*"])), NOW, True)

    def test_expiry_fail_closed(self):
        with self.assertRaises(ValueError):
            gate.validate_registry(json.dumps(example(expiresAt="2026-11-05T12:00:00Z")), NOW, True)

    def test_reject_wrong_owner(self):
        with self.assertRaises(ValueError):
            gate.validate_registry(json.dumps(example(approvedBy="agent")), NOW, True)

    def test_reject_duplicate_exact_sha(self):
        data = example()
        data["admissions"].append(dict(data["admissions"][0]))
        with self.assertRaises(ValueError):
            gate.validate_registry(json.dumps(data), NOW, True)

    def test_protected_path_matching(self):
        self.assertTrue(gate.protected("tests/harness/backup-audit-contract-test.sh"))
        self.assertTrue(gate.protected(".github/workflows/workflow-integrity.yaml"))
        self.assertFalse(gate.protected("docs/operations/backup-audit.md"))
        self.assertFalse(gate.protected(gate.REGISTRY))


if __name__ == "__main__":
    unittest.main()
