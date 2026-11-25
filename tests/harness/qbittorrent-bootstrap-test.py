#!/usr/bin/env python3
"""Offline tests for the qBittorrent storage and WebUI bootstrap contract."""

import base64
import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "k8s/applications/media/qbittorrent-mam/bootstrap.py"
SPEC = importlib.util.spec_from_file_location("qbittorrent_bootstrap", SOURCE)
BOOTSTRAP = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(BOOTSTRAP)


class QbittorrentBootstrapTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="qbt-bootstrap-test-")
        root = Path(self.tmp.name)
        BOOTSTRAP.CONFIG = root / "config/qBittorrent/config/qBittorrent.conf"
        BOOTSTRAP.PASSWORD = root / "secret/WEBUI_PASSWORD"
        BOOTSTRAP.PASSWORD.parent.mkdir(parents=True)
        BOOTSTRAP.PASSWORD.write_bytes(b"offline-fixture-password-value\n")
        BOOTSTRAP.DOWNLOADS = root / "data/torrents/books"
        BOOTSTRAP.IMPORT_PATHS = (root / "data/book-dock", root / "data/media/books")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_storage_probe_confirms_same_filesystem_hardlinks_and_cleans_only_its_probes(self) -> None:
        with patch.object(BOOTSTRAP.os, "getuid", return_value=2501), patch.object(
            BOOTSTRAP.os, "getgid", return_value=2501
        ):
            BOOTSTRAP.check_storage_contract()

        for directory in (BOOTSTRAP.DOWNLOADS, *BOOTSTRAP.IMPORT_PATHS):
            self.assertTrue(directory.is_dir())
            self.assertEqual(list(directory.glob(".qbittorrent-mam-probe-*")), [])

    def test_wrong_uid_or_gid_refuses_before_writing(self) -> None:
        with patch.object(BOOTSTRAP.os, "getuid", return_value=1000), patch.object(
            BOOTSTRAP.os, "getgid", return_value=1000
        ):
            with self.assertRaisesRegex(RuntimeError, "uid/gid 2501"):
                BOOTSTRAP.check_storage_contract()
        self.assertFalse(BOOTSTRAP.DOWNLOADS.exists())

    def test_config_persists_safe_paths_unlimited_seeding_and_qbittorrent_password_hash(self) -> None:
        BOOTSTRAP.CONFIG.parent.mkdir(parents=True)
        BOOTSTRAP.CONFIG.write_text("[Existing]\nKeepThis=true\n")
        BOOTSTRAP.write_config()
        config = BOOTSTRAP.CONFIG.read_text()
        self.assertIn(f"Session\\DefaultSavePath={BOOTSTRAP.DOWNLOADS}", config)
        self.assertIn("Session\\GlobalMaxRatio=-1", config)
        self.assertIn("Session\\GlobalMaxSeedingMinutes=-1", config)
        self.assertIn("AutoDeleteAddedTorrentFile=Never", config)
        self.assertIn("KeepThis=true", config)
        self.assertNotIn("offline-fixture-password-value", config)

        line = next(line for line in config.splitlines() if line.startswith("WebUI\\Password_PBKDF2="))
        encoded = line.split("=", 1)[1].strip().strip('"')
        payload = encoded[len("@ByteArray(") : -1]
        salt64, derived64 = payload.split(":")
        salt = base64.b64decode(salt64)
        derived = base64.b64decode(derived64)
        expected = hashlib.pbkdf2_hmac("sha512", b"offline-fixture-password-value", salt, 100_000, dklen=64)
        self.assertEqual(derived, expected)
        self.assertEqual(len(salt), 16)
        self.assertEqual(len(derived), 64)


if __name__ == "__main__":
    unittest.main(verbosity=2)
