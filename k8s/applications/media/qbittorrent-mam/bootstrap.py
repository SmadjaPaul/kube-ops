#!/usr/bin/env python3
"""Validate the shared media mount and seed qBittorrent's private WebUI auth."""

import base64
import hashlib
import os
import secrets
import stat
import tempfile
from pathlib import Path


CONFIG = Path("/config/qBittorrent/config/qBittorrent.conf")
PASSWORD = Path("/run/qbittorrent-auth/WEBUI_PASSWORD")
DOWNLOADS = Path("/data/torrents/books")
IMPORT_PATHS = (Path("/data/book-dock"), Path("/data/media/books"))


def check_storage_contract() -> None:
    if os.getuid() != 2501 or os.getgid() != 2501:
        raise RuntimeError("expected process uid/gid 2501")

    for path in (DOWNLOADS, DOWNLOADS / ".incomplete", *IMPORT_PATHS):
        path.mkdir(parents=True, exist_ok=True)

    fd, probe_name = tempfile.mkstemp(prefix=".qbittorrent-mam-probe-", dir=DOWNLOADS)
    probe = Path(probe_name)
    destinations = []
    try:
        os.write(fd, b"qbittorrent-mam-storage-probe")
        os.fsync(fd)
        os.close(fd)
        for directory in IMPORT_PATHS:
            target = directory / f".qbittorrent-mam-probe-{secrets.token_hex(12)}"
            os.link(probe, target)
            destinations.append(target)
            source_stat = probe.stat()
            target_stat = target.stat()
            if (source_stat.st_dev, source_stat.st_ino) != (target_stat.st_dev, target_stat.st_ino):
                raise RuntimeError(f"hardlink contract failed for {directory}")
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        for target in destinations:
            target.unlink(missing_ok=True)
        probe.unlink(missing_ok=True)


def ini_set(text: str, section: str, key: str, value: str) -> str:
    lines = text.splitlines()
    header = f"[{section}]"
    start = next((i for i, line in enumerate(lines) if line.strip() == header), None)
    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend((header, f"{key}={value}"))
        return "\n".join(lines) + "\n"

    end = next((i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith("[")), len(lines))
    for i in range(start + 1, end):
        lhs, separator, _rhs = lines[i].partition("=")
        if separator and lhs.strip() == key:
            lines[i] = f"{key}={value}"
            return "\n".join(lines) + "\n"
    lines.insert(start + 1, f"{key}={value}")
    return "\n".join(lines) + "\n"


def write_config() -> None:
    password = PASSWORD.read_bytes().rstrip(b"\r\n")
    if len(password) < 24:
        raise RuntimeError("WebUI password secret is missing or too short")

    salt = secrets.token_bytes(16)
    derived = hashlib.pbkdf2_hmac("sha512", password, salt, 100_000, dklen=64)
    encoded = f'"@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(derived).decode()})"'

    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    original = CONFIG.read_text() if CONFIG.exists() else ""
    settings = (
        ("BitTorrent", r"Session\DefaultSavePath", str(DOWNLOADS)),
        ("BitTorrent", r"Session\TempPath", str(DOWNLOADS / ".incomplete")),
        ("BitTorrent", r"Session\TempPathEnabled", "true"),
        ("BitTorrent", r"Session\Port", "51413"),
        ("BitTorrent", r"Session\GlobalMaxRatio", "-1"),
        ("BitTorrent", r"Session\GlobalMaxSeedingMinutes", "-1"),
        # A queued torrent does not seed, which would break MAM's 72 h seeding rule.
        ("BitTorrent", r"Session\QueueingSystemEnabled", "false"),
        ("Preferences", r"WebUI\Username", "admin"),
        ("Preferences", r"WebUI\Password_PBKDF2", encoded),
        ("Preferences", r"WebUI\Port", "8080"),
        ("Preferences", r"WebUI\Address", "*"),
        ("Preferences", r"WebUI\ServerDomains", "qbittorrent-mam.media.svc.cluster.local"),
        ("Preferences", r"WebUI\CSRFProtection", "true"),
        ("Preferences", r"WebUI\ClickjackingProtection", "true"),
        ("Preferences", r"WebUI\HostHeaderValidation", "true"),
        ("Core", "AutoDeleteAddedTorrentFile", "Never"),
    )
    for section, key, value in settings:
        original = ini_set(original, section, key, value)

    fd, temp_name = tempfile.mkstemp(prefix=".qBittorrent.conf-", dir=CONFIG.parent)
    try:
        os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(fd, "w") as handle:
            handle.write(original)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, CONFIG)
    finally:
        Path(temp_name).unlink(missing_ok=True)


def main() -> None:
    check_storage_contract()
    write_config()
    print("STORAGE_CONTRACT=PASS uid=2501 hardlinks=2")


if __name__ == "__main__":
    main()
