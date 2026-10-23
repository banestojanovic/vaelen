#!/usr/bin/env python3
"""Isolated tests for the updater's read-only CLI preflight."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("vaelen-dev-update-cli-preflight.sh")


class CLIPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vaelen-cli-preflight-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cli = self.root / "val"
        self.owner = self.root / ".val.sha256"
        self.link = self.root / "bin" / "val"
        self.calls = self.root / "calls.txt"
        self.cli.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"$VAELEN_PREFLIGHT_CALLS\"\n"
            "printf '%s\\n' \"$VAELEN_PREFLIGHT_DIAGNOSTIC\" >&2\n"
            "exit \"$VAELEN_PREFLIGHT_EXIT\"\n"
        )
        self.cli.chmod(0o755)
        self.owner.write_text(hashlib.sha256(self.cli.read_bytes()).hexdigest() + "\n")
        self.link.parent.mkdir()
        self.link.symlink_to(self.cli)

    def run_preflight(self, exit_code=0, diagnostic=""):
        command = 'source "$1"; vaelen_update_cli_preflight "$2" "$3" "$4"'
        environment = os.environ.copy()
        environment.update({
            "VAELEN_PREFLIGHT_CALLS": str(self.calls),
            "VAELEN_PREFLIGHT_EXIT": str(exit_code),
            "VAELEN_PREFLIGHT_DIAGNOSTIC": diagnostic,
        })
        return subprocess.run(
            ["bash", "-c", command, "preflight-test", str(SCRIPT), str(self.cli), str(self.owner), str(self.link)],
            capture_output=True, text=True, env=environment,
        )

    def assert_status_was_the_only_cli_action(self):
        self.assertEqual(self.calls.read_text().splitlines(), ["status"])

    def test_connection_failure_is_distinct_and_keeps_cli_diagnostic(self):
        result = self.run_preflight(3, "Error: Vaelen Core is not running.")
        self.assertEqual(result.returncode, 3)
        self.assertIn("Vaelen Core is unavailable", result.stderr)
        self.assertIn("Error: Vaelen Core is not running.", result.stderr)
        self.assertIn("has not requested app shutdown", result.stderr)
        self.assertNotIn("current app left running", result.stderr)
        self.assert_status_was_the_only_cli_action()

    def test_protocol_failure_is_distinct_and_keeps_version_diagnostic(self):
        diagnostic = "Client: 2\nCore: 1"
        result = self.run_preflight(4, diagnostic)
        self.assertEqual(result.returncode, 1)
        self.assertIn("protocol compatibility failed", result.stderr)
        self.assertIn(diagnostic, result.stderr)
        self.assert_status_was_the_only_cli_action()

    def test_unclassified_status_failure_keeps_exit_code_and_diagnostic(self):
        result = self.run_preflight(1, "permission denied opening Core socket")
        self.assertEqual(result.returncode, 1)
        self.assertIn("status exited 1", result.stderr)
        self.assertIn("permission denied opening Core socket", result.stderr)
        self.assert_status_was_the_only_cli_action()

    def test_checksum_ownership_failure_stops_before_cli_invocation(self):
        self.owner.write_text("0" * 64 + "\n")
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum does not match its ownership record", result.stderr)
        self.assertFalse(self.calls.exists())

    def test_command_link_ownership_failure_stops_before_cli_invocation(self):
        self.link.unlink()
        self.link.symlink_to(self.root / "other-val")
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("command link points somewhere else", result.stderr)
        self.assertFalse(self.calls.exists())

    def test_missing_ownership_record_is_named_without_starting_or_installing(self):
        self.owner.unlink()
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ownership record is missing", result.stderr)
        self.assertFalse(self.calls.exists())

    def test_success_runs_only_read_only_status(self):
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_status_was_the_only_cli_action()


if __name__ == "__main__":
    unittest.main()
