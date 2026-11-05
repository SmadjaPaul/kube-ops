#!/usr/bin/env python3
"""Synthetic-only SQLite WAL backup/restore proof for RustiCal v0.18.

Never accepts a real database path. Every file is made in TemporaryDirectory.
This DOES NOT establish a Kubernetes/Velero restore gate.
"""
import json
import shutil
import sqlite3
import tempfile
from pathlib import Path


def rows(connection):
    return connection.execute(
        "SELECT owner, kind, item FROM fixture ORDER BY owner, kind, item"
    ).fetchall()


def drill():
    with tempfile.TemporaryDirectory(prefix="rustical-wal-synthetic-") as tmp:
        root = Path(tmp)
        original = root / "running.sqlite"
        raw_copy = root / "db-only.sqlite"
        consistent = root / "online-backup.sqlite"
        restored = root / "restored.sqlite"

        init = sqlite3.connect(original)
        try:
            init.execute(
                "CREATE TABLE fixture(owner TEXT, kind TEXT, item TEXT, "
                "PRIMARY KEY(owner, kind, item))"
            )
            init.execute("INSERT INTO fixture VALUES ('user-a','calendar','before-wal')")
            init.commit()
        finally:
            init.close()

        writer = sqlite3.connect(original)
        snapshot = None
        try:
            if writer.execute("PRAGMA journal_mode=WAL").fetchone()[0] != "wal":
                raise AssertionError("WAL_NOT_ENABLED")
            writer.execute("PRAGMA wal_autocheckpoint=0")
            writer.execute("INSERT INTO fixture VALUES ('user-a','calendar','after-wal')")
            writer.execute("INSERT INTO fixture VALUES ('user-b','contact','after-wal')")
            writer.commit()

            wal = Path(str(original) + "-wal")
            if not wal.exists() or wal.stat().st_size <= 0:
                raise AssertionError("WAL_WRITE_NOT_OBSERVED")

            expected = rows(writer)
            if len(expected) != 3:
                raise AssertionError("SOURCE_ROWS_MISSING")

            # A deliberately unsafe DB-file-only copy misses live WAL frames.
            # Never use this method to back up a running production RustiCal.
            shutil.copy2(original, raw_copy)
            naive = sqlite3.connect(raw_copy)
            try:
                naive_matches = rows(naive) == expected
            except sqlite3.DatabaseError:
                naive_matches = False
            finally:
                naive.close()
            if naive_matches:
                raise AssertionError("NEGATIVE_CONTROL_DID_NOT_REPRODUCE_WAL_LOSS")

            # SQLite's online backup API creates a transactionally coherent
            # snapshot with concurrent WAL frames still uncheckpointed.
            snapshot = sqlite3.connect(consistent)
            writer.backup(snapshot)
            snapshot.close()
            snapshot = None

            shutil.copy2(consistent, restored)
            recovery = sqlite3.connect(restored)
            try:
                if recovery.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                    raise AssertionError("RESTORED_SQLITE_CORRUPT")
                if rows(recovery) != expected:
                    raise AssertionError("RESTORED_ROWS_DIFFER")
                for owner in ("user-a", "user-b"):
                    own = recovery.execute(
                        "SELECT DISTINCT owner FROM fixture WHERE owner=?", (owner,)
                    ).fetchall()
                    if own != [(owner,)]:
                        raise AssertionError("SYNTHETIC_OWNER_ISOLATION_FAILED")
            finally:
                recovery.close()
        finally:
            if snapshot is not None:
                snapshot.close()
            writer.close()

    print("RUSTICAL_WAL_SYNTHETIC=PASS " + json.dumps({
        "wal_active": True,
        "db_only_copy_incomplete": True,
        "online_snapshot_restored": True,
        "quick_check": "ok",
        "synthetic_users": 2,
        "records": 3,
    }, sort_keys=True))
    print("RUSTICAL_K8S_PVC_RESTORE=NOT_EXECUTED")
    print("RUSTICAL_VELERO_RESTORE=NOT_EXECUTED")


if __name__ == "__main__":
    drill()
