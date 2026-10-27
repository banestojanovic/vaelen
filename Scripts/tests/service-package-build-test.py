#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from pathlib import Path

DRIVER = Path(__file__).resolve().parents[1] / "build-service-packages.py"
SPEC = importlib.util.spec_from_file_location("service_packages", DRIVER)
service_packages = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = service_packages
SPEC.loader.exec_module(service_packages)


class PackageDriverTests(unittest.TestCase):
    def test_release_build_disables_variable_debug_metadata(self):
        self.assertIn("--prefix=/vaelen-build/pg-install", service_packages.LOCK_DATA["recipes"]["postgresql"])
        self.assertIn("DESTDIR=$BUILD_ROOT/pg-dest", service_packages.LOCK_DATA["recipes"]["postgresql"])
        self.assertIn("--disable-debug", service_packages.LOCK_DATA["recipes"]["postgresql"])
        self.assertIn("DEBUG=", service_packages.LOCK_DATA["recipes"]["valkey"])
        self.assertIn("-ffile-prefix-map=$BUILD_ROOT=/vaelen-build", service_packages.LOCK_DATA["recipes"]["postgresql"])
        self.assertIn("-ffile-prefix-map=$BUILD_ROOT=/vaelen-build", service_packages.LOCK_DATA["recipes"]["valkey"])
        self.assertIn("-ffile-prefix-map=$BUILD_ROOT_REAL=/vaelen-build", service_packages.LOCK_DATA["recipes"]["postgresql"])
        self.assertIn("-ffile-prefix-map=$BUILD_ROOT_REAL=/vaelen-build", service_packages.LOCK_DATA["recipes"]["valkey"])
        self.assertIn("-Wl,-oso_prefix,$BUILD_ROOT_REAL", service_packages.LOCK_DATA["recipes"]["postgresql"])
        self.assertIn("-Wl,-oso_prefix,$BUILD_ROOT_REAL", service_packages.LOCK_DATA["recipes"]["valkey"])
        self.assertEqual("1", service_packages.clean_environment("/sdk", Path("/tmp/build"))["ZERO_AR_DATE"])
        env = service_packages.clean_environment("/sdk", Path("/tmp/unique-build-root"))
        self.assertIn("-ffile-prefix-map=/tmp/unique-build-root=/vaelen-build", env["CFLAGS"])
        stable_flags = service_packages.normalize_build_paths(env["CFLAGS"], Path("/tmp/unique-build-root"))
        self.assertNotIn("/tmp/unique-build-root", stable_flags)
        self.assertIn("$BUILD_ROOT_REAL", stable_flags)

    def test_postgresql_runtime_allowlist_excludes_pg_config(self):
        self.assertNotIn("pg_config", service_packages.POSTGRES_BINARIES)

    def test_source_cache_rechecks_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            pin = service_packages.PINS["valkey"]
            path = cache / pin.sha256
            path.write_bytes(b"corrupt")
            with self.assertRaisesRegex(ValueError, "digest"):
                service_packages.acquire_source(pin, cache, offline=True)

    def test_command_failure_retains_a_unique_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "build.log"
            log.write_text("failure details")
            retained = Path(temporary) / "failure-unique.log"

            def create_retained_file(**_):
                return os.open(retained, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), str(retained)

            with patch.object(service_packages.tempfile, "mkstemp", side_effect=create_retained_file), patch.object(
                service_packages.subprocess, "run", return_value=SimpleNamespace(returncode=1)
            ), self.assertRaisesRegex(RuntimeError, "full log") as failure:
                service_packages.run(["failing-command"], temporary, {}, log)
            self.assertIn(str(retained), str(failure.exception))
            self.assertEqual("failure details", retained.read_text())

    def test_postgresql_socket_directory_is_removed_when_initdb_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "package"
            (package / "bin").mkdir(parents=True)
            scratch = root / "scratch"
            scratch.mkdir()
            socket_dir = root / "socket"
            socket_dir.mkdir()
            with patch.object(service_packages.tempfile, "mkdtemp", return_value=str(socket_dir)), patch.object(
                service_packages, "run", side_effect=RuntimeError("initdb failed")
            ), self.assertRaisesRegex(RuntimeError, "initdb failed"):
                service_packages.smoke_package(package, "postgresql-18.6", scratch, {}, root / "smoke.log")
            self.assertFalse(socket_dir.exists())

    def test_extraction_rejects_traversal_and_escaping_links(self):
        for name, kind, link in [("../escape", tarfile.REGTYPE, ""), ("root/link", tarfile.SYMTYPE, "../../escape")]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                archive = Path(temporary) / "hostile.tar"
                with tarfile.open(archive, "w") as tar:
                    item = tarfile.TarInfo(name)
                    item.type = kind
                    item.linkname = link
                    item.size = 1 if kind == tarfile.REGTYPE else 0
                    tar.addfile(item, io.BytesIO(b"x") if item.size else None)
                with self.assertRaises(ValueError):
                    service_packages.extract_archive(archive, Path(temporary) / "out")

    def test_archive_encoding_is_deterministic(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "payload"
            root.mkdir()
            (root / "bin").mkdir()
            (root / "bin/tool").write_bytes(b"hello")
            one, two = Path(temporary) / "one.tar.gz", Path(temporary) / "two.tar.gz"
            records = service_packages.inventory_tree(root)
            service_packages.write_archive(root, one, "example", 0)
            service_packages.write_archive(root, two, "example", 0)
            self.assertEqual(one.read_bytes(), two.read_bytes())
            self.assertEqual(records, service_packages.inventory_tree(root))

    def test_manifest_verification_rejects_archive_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "package"
            package.mkdir()
            (package / "bin").mkdir()
            (package / "bin/tool").write_bytes(b"hello")
            archive = root / "package.tar.gz"
            service_packages.write_archive(package, archive, "example", 0)
            second = root / "second.tar.gz"
            second_payload = root / "second"
            second_payload.mkdir()
            (second_payload / "bin").mkdir()
            (second_payload / "bin/tool").write_bytes(b"world")
            service_packages.write_archive(second_payload, second, "valkey-9.1.2", 0)
            service_packages.write_archive(package, archive, "postgresql-18.6", 0)
            manifest = service_packages.make_manifest([
                service_packages.package_record("postgresql-18.6", archive, package, {}),
                service_packages.package_record("valkey-9.1.2", second, second_payload, {}),
            ])
            manifest["packages"][0]["archive"] = "postgresql-18.6-macos14-arm64.tar.gz"
            manifest["packages"][1]["archive"] = "valkey-9.1.2-macos14-arm64.tar.gz"
            manifest["packages"][0]["files"] = service_packages.inventory_tree(package)
            archive.rename(root / manifest["packages"][0]["archive"])
            second.rename(root / manifest["packages"][1]["archive"])
            archive = root / manifest["packages"][0]["archive"]
            (root / "manifest.json").write_text(json.dumps(manifest))
            with patch.object(service_packages, "smoke_package"):
                service_packages.verify_directory(root)
            archive.write_bytes(archive.read_bytes() + b"x")
            with self.assertRaises(ValueError):
                with patch.object(service_packages, "smoke_package"):
                    service_packages.verify_directory(root)

    def test_verifier_rejects_archive_members_outside_expected_package_root(self):
        for extra_name, extra_type in [("stray.txt", tarfile.REGTYPE), ("second-package", tarfile.DIRTYPE)]:
            with self.subTest(extra_name=extra_name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                package = root / "postgresql-18.6"
                package.mkdir()
                (package / "bin").mkdir()
                (package / "bin/tool").write_bytes(b"hello")
                archive = root / "postgresql.tar.gz"
                with tarfile.open(archive, "w:gz") as tar:
                    tar.add(package, arcname="postgresql-18.6")
                    extra = tarfile.TarInfo(extra_name)
                    extra.type = extra_type
                    if extra_type == tarfile.REGTYPE:
                        extra.size = 1
                        tar.addfile(extra, io.BytesIO(b"x"))
                    else:
                        tar.addfile(extra)

                second = root / "valkey-9.1.2"
                second.mkdir()
                (second / "bin").mkdir()
                (second / "bin/tool").write_bytes(b"world")
                second_archive = root / "valkey.tar.gz"
                service_packages.write_archive(second, second_archive, "valkey-9.1.2", 0)
                manifest = service_packages.make_manifest([
                    service_packages.package_record("postgresql-18.6", archive, package, {}),
                    service_packages.package_record("valkey-9.1.2", second_archive, second, {}),
                ])
                manifest["packages"][0]["archive"] = archive.name
                manifest["packages"][1]["archive"] = second_archive.name
                (root / "manifest.json").write_text(json.dumps(manifest))
                with self.assertRaisesRegex(ValueError, "archive contains member outside expected package root"):
                    with patch.object(service_packages, "smoke_package"):
                        service_packages.verify_directory(root)

    def test_manifest_records_per_package_repeatability_state(self):
        manifest = service_packages.make_manifest([])
        self.assertEqual({"postgresql": "open", "valkey": "verified"}, manifest["same_host_repeatability"])

    def test_verifier_rejects_symlink_manifest_and_duplicate_packages(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            external = root / "external.json"
            external.write_text("{}")
            (root / "manifest.json").symlink_to(external)
            with self.assertRaisesRegex(ValueError, "regular file"):
                service_packages.verify_directory(root)
            (root / "manifest.json").unlink()
            manifest = {"schema_version": 1, "packages": [{"id": "postgresql-18.6"}, {"id": "postgresql-18.6"}]}
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "incomplete"):
                service_packages.verify_directory(root)

    def test_verifier_rejects_symlink_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "external.tar.gz"
            target.write_bytes(b"archive")
            archive = root / "postgresql-18.6-macos14-arm64.tar.gz"
            archive.symlink_to(target)
            (root / "manifest.json").write_text(json.dumps({
                "schema_version": 1,
                "packages": [
                    {"id": "postgresql-18.6", "archive": archive.name, "archive_sha256": "0" * 64, "archive_size": 7},
                    {"id": "valkey-9.1.2", "archive": "valkey-9.1.2-macos14-arm64.tar.gz", "archive_sha256": "0" * 64, "archive_size": 0},
                ],
            }))
            with self.assertRaisesRegex(ValueError, "digest or size mismatch"):
                service_packages.verify_directory(root)


if __name__ == "__main__":
    unittest.main()
