"""Offline tests for the cluster-access preflight (PLT-239).

No network, no kubectl, no Doppler: Linear is a fake and the preflight is simulated.
"""

import io
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import dispatch  # noqa: E402
from test_selection import FakeLinear, load  # noqa: E402

NOW = datetime(2026, 11, 14, 12, 0, tzinfo=timezone.utc)


def iso(delta):
    return (NOW - delta).strftime("%Y-%m-%dT%H:%M:%S.000Z")


class IncidentLinear(FakeLinear):
    def __init__(self, queue, comments=(), fail_recent=False):
        super().__init__(queue)
        self.incident_comments = list(comments)
        self.fail_recent = fail_recent
        self.since = None

    def in_progress(self):
        return []

    def recent_comments(self, ident, since):
        if self.fail_recent:
            raise dispatch.DispatchError("Linear HTTP 500")
        self.since = since
        return f"uuid-{ident}", self.incident_comments


def args(**kw):
    base = dict(lane="local", dry_run=False, snapshot=None, skip=[], expect=None,
                require_kube_access=True, incident="PLT-283")
    base.update(kw)
    return dispatch.argparse.Namespace(**base)


class PreflightGateTests(unittest.TestCase):
    def setUp(self):
        self.queue = load("queue.json")["queue"]

    def _run(self, a, fake, preflight):
        out = io.StringIO()
        with mock.patch.object(dispatch.sel, "utcnow", return_value=NOW), \
                mock.patch.object(dispatch.subprocess, "run", side_effect=AssertionError("no claude")), \
                mock.patch.object(dispatch.urllib.request, "urlopen", side_effect=AssertionError("no net")), \
                redirect_stdout(out), redirect_stderr(io.StringIO()):
            code = dispatch.run(a, linear=fake, preflight=preflight)
        return code, out.getvalue()

    def test_blocked_skips_without_lock_or_ticket(self):
        fake = IncidentLinear(self.queue)
        code, out = self._run(args(), fake, lambda: (False, "api_unreachable"))
        self.assertEqual(code, 0)
        self.assertIn("DISPATCH_SKIPPED=kube_access_blocked", out.splitlines())
        self.assertEqual(fake.labels, {})
        self.assertEqual(fake.states, {})
        self.assertNotIn("choisi", out)

    def test_blocked_posts_one_incident_comment(self):
        fake = IncidentLinear(self.queue)
        self._run(args(), fake, lambda: (False, "api_unreachable"))
        self.assertEqual(len(fake.comments), 1)
        issue_id, body = fake.comments[0]
        self.assertEqual(issue_id, "uuid-PLT-283")
        self.assertTrue(body.startswith("Exécutant local bloqué :"))
        self.assertIn("REASON=api_unreachable", body)
        self.assertEqual(fake.since, iso(timedelta(hours=3)))

    def test_recent_dispatcher_comment_prevents_a_new_one(self):
        recent = [{"createdAt": iso(timedelta(hours=1)), "body": "Exécutant local bloqué : déjà"}]
        fake = IncidentLinear(self.queue, comments=recent)
        _, out = self._run(args(), fake, lambda: (False, "api_unreachable"))
        self.assertEqual(fake.comments, [])
        self.assertIn("DISPATCH_SKIPPED=kube_access_blocked", out)

    def test_human_comment_does_not_count_as_dispatcher_comment(self):
        human = [{"createdAt": iso(timedelta(minutes=10)), "body": "netbird up fait ?"}]
        fake = IncidentLinear(self.queue, comments=human)
        self._run(args(), fake, lambda: (False, "api_unreachable"))
        self.assertEqual(len(fake.comments), 1)

    def test_old_dispatcher_comment_does_not_block(self):
        old = [{"createdAt": iso(timedelta(hours=3, minutes=1)), "body": "Exécutant local bloqué : vieux"}]
        fake = IncidentLinear(self.queue, comments=old)
        self._run(args(), fake, lambda: (False, "api_unreachable"))
        self.assertEqual(len(fake.comments), 1)

    def test_no_incident_option_means_no_comment(self):
        fake = IncidentLinear(self.queue)
        code, out = self._run(args(incident=None), fake, lambda: (False, "api_unreachable"))
        self.assertEqual((code, fake.comments), (0, []))
        self.assertIn("DISPATCH_SKIPPED=kube_access_blocked", out)

    def test_dry_run_never_comments(self):
        fake = IncidentLinear(self.queue)
        code, out = self._run(args(dry_run=True), fake, lambda: (False, "api_unreachable"))
        self.assertEqual((code, fake.comments), (0, []))
        self.assertIn("DISPATCH_SKIPPED=kube_access_blocked", out)

    def test_linear_failure_keeps_exit_zero(self):
        fake = IncidentLinear(self.queue, fail_recent=True)
        code, out = self._run(args(), fake, lambda: (False, "api_unreachable"))
        self.assertEqual(code, 0)
        self.assertIn("DISPATCH_SKIPPED=kube_access_blocked", out)

    def test_pass_continues_to_the_existing_flow(self):
        fake = IncidentLinear(self.queue)
        code, out = self._run(args(dry_run=True, incident=None), fake, lambda: (True, "ok"))
        self.assertEqual(code, 0)
        self.assertNotIn("DISPATCH_SKIPPED", out)
        self.assertIn("choisi : PLT-5", out)

    def test_option_off_never_calls_the_preflight(self):
        fake = IncidentLinear(self.queue)
        boom = mock.Mock(side_effect=AssertionError("preflight called"))
        code, out = self._run(args(dry_run=True, require_kube_access=False), fake, boom)
        self.assertEqual(code, 0)
        boom.assert_not_called()


class KubeAccessCheckTests(unittest.TestCase):
    def _check(self, rc, out="", err="", exc=None):
        proc = mock.Mock(returncode=rc, stdout=out, stderr=err)
        with mock.patch.object(dispatch.subprocess, "run", return_value=proc, side_effect=exc) as sp:
            return dispatch.kube_access_check(), sp

    def test_runs_the_canonical_function_from_repo_root(self):
        (res, sp) = self._check(0, "KUBE_ACCESS=PASS\nAPI_REACHABLE=yes\n")
        self.assertEqual(res, (True, "ok"))
        cmd = sp.call_args[0][0]
        self.assertIn("source scripts/lib/kube-preflight.sh; require_kube_access", cmd[-1])
        self.assertEqual(sp.call_args[1]["cwd"], dispatch.REPO_ROOT)
        self.assertTrue((dispatch.REPO_ROOT / "scripts/lib/kube-preflight.sh").is_file())

    def test_blocked_reads_only_the_reason_token(self):
        err = "KUBE_ACCESS=BLOCKED\nREASON=api_unreachable\nNEXT_ACTION=X\ntoken=SECRET\n"
        (res, _) = self._check(2, "", err)
        self.assertEqual(res, (False, "api_unreachable"))

    def test_exit_zero_without_pass_line_is_blocked(self):
        (res, _) = self._check(0, "nothing\n")
        self.assertEqual(res, (False, "unknown"))

    def test_timeout_is_blocked(self):
        exc = dispatch.subprocess.TimeoutExpired("bash", 1)
        (res, _) = self._check(0, exc=exc)
        self.assertEqual(res, (False, "preflight_timeout"))


if __name__ == "__main__":
    unittest.main()
