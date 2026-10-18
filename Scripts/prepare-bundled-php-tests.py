#!/usr/bin/env python3
"""Isolated preparation regressions; no network, build, or live runtime use."""

import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare-bundled-php.py")


def digest(data):
    return hashlib.sha256(data).hexdigest()


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vaelen-bundled-php-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.resources = self.root / "resources"
        self.resources.mkdir()
        self.cache = self.root / "cache"
        self.source_cache = self.cache / "v3/bulk/8.5.9"
        self.source_cache.mkdir(parents=True)
        self.data = {"cli": b"verified CLI fixture\n", "fpm": b"verified FPM fixture\n"}
        self.descriptor = {
            "schemaVersion": 1, "module": "php-bundled-runtime", "phpVersion": "8.5.9",
            "verification": {"algorithm": "sha256"}, "binaries": {},
            "manifest": {
                "phpVersion": "8.5.9", "verification": {"algorithm": "sha256"},
                "platform": "macos", "architecture": "arm64", "artifacts": {},
                "verifiedArtifactSizes": {},
            },
        }
        for kind, name in (("cli", "php"), ("fpm", "php-fpm")):
            self.descriptor["binaries"][kind] = {"file": name, "sha256": digest(self.data[kind])}
            self.write_archive(kind, [(name, self.data[kind])])
        self.write_descriptor()

    def write_archive(self, kind, entries):
        filename = "php-8.5.9-" + kind + "-macos-aarch64.tar.gz"
        path = self.source_cache / filename
        with tarfile.open(path, "w:gz") as archive:
            for name, contents in entries:
                member = tarfile.TarInfo(name)
                member.size = len(contents)
                archive.addfile(member, io.BytesIO(contents))
        self.descriptor["manifest"]["artifacts"][kind] = {
            "file": filename, "sha256": digest(path.read_bytes()),
            "url": "https://provider.example/" + filename,
        }
        self.descriptor["manifest"]["verifiedArtifactSizes"][kind] = path.stat().st_size

    def write_descriptor(self):
        (self.resources / "bundled-runtime.json").write_text(json.dumps(self.descriptor))

    def run_preparation(self, success=True):
        process = subprocess.run(
            [sys.executable, str(SCRIPT), "--offline", "--resources", str(self.resources), "--cache", str(self.cache)],
            capture_output=True, text=True,
        )
        if success:
            self.assertEqual(process.returncode, 0, process.stderr)
        else:
            self.assertNotEqual(process.returncode, 0, process.stdout)
        return process

    def test_verified_resource_cache_hit_needs_no_archives(self):
        for kind, binary in self.descriptor["binaries"].items():
            path = self.resources / binary["file"]
            path.write_bytes(self.data[kind])
            path.chmod(0o755)
        before = {p.name: p.stat().st_mtime_ns for p in self.resources.iterdir()}
        for archive in self.source_cache.iterdir():
            archive.unlink()
        result = self.run_preparation()
        self.assertIn("already verified", result.stdout)
        self.assertEqual(before, {p.name: p.stat().st_mtime_ns for p in self.resources.iterdir()})

    def test_offline_materialization_reuses_generation_scoped_archives(self):
        descriptor_before = (self.resources / "bundled-runtime.json").read_bytes()
        result = self.run_preparation()
        self.assertIn("from pinned archives", result.stdout)
        for kind, binary in self.descriptor["binaries"].items():
            path = self.resources / binary["file"]
            self.assertEqual(path.read_bytes(), self.data[kind])
            self.assertEqual(path.stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.resources / "bundled-runtime.json").read_bytes(), descriptor_before)
        self.assertFalse(list(self.resources.glob(".prepare-*")))

    def test_corrupt_digest_scoped_archive_fails_before_publishing(self):
        artifact = self.descriptor["manifest"]["artifacts"]["fpm"]
        corrupt = self.cache / "archives" / artifact["sha256"] / artifact["file"]
        corrupt.parent.mkdir(parents=True)
        corrupt.write_bytes(b"corrupt cached archive")
        result = self.run_preparation(success=False)
        self.assertIn("Cached archive checksum mismatch", result.stderr)
        self.assertFalse((self.resources / "php").exists())
        self.assertFalse((self.resources / "php-fpm").exists())

    def test_traversal_archive_is_rejected_even_with_matching_archive_digest(self):
        self.write_archive("cli", [("php", self.data["cli"]), ("../escaped", b"bad")])
        self.write_descriptor()
        result = self.run_preparation(success=False)
        self.assertIn("Unsafe archive entry", result.stderr)
        self.assertFalse((self.root / "escaped").exists())
        self.assertFalse((self.resources / "php").exists())

    def test_binary_digest_mismatch_does_not_replace_existing_resources(self):
        (self.resources / "php").write_bytes(b"existing resource")
        self.write_archive("fpm", [("php-fpm", b"wrong extracted bytes")])
        self.write_descriptor()
        result = self.run_preparation(success=False)
        self.assertIn("Extracted binary checksum mismatch", result.stderr)
        self.assertEqual((self.resources / "php").read_bytes(), b"existing resource")
        self.assertFalse((self.resources / "php-fpm").exists())

    def test_missing_offline_archive_fails_without_network(self):
        for archive in self.source_cache.iterdir():
            archive.unlink()
        result = self.run_preparation(success=False)
        self.assertIn("Pinned archive is not cached", result.stderr)

    def test_symbolic_link_archive_member_is_rejected(self):
        kind = "cli"
        artifact = self.descriptor["manifest"]["artifacts"][kind]
        path = self.source_cache / artifact["file"]
        with tarfile.open(path, "w:gz") as archive:
            member = tarfile.TarInfo("php")
            member.type = tarfile.SYMTYPE
            member.linkname = "/bin/sh"
            archive.addfile(member)
        artifact["sha256"] = digest(path.read_bytes())
        self.descriptor["manifest"]["verifiedArtifactSizes"][kind] = path.stat().st_size
        self.write_descriptor()
        result = self.run_preparation(success=False)
        self.assertIn("links and special files", result.stderr)


if __name__ == "__main__":
    unittest.main()
