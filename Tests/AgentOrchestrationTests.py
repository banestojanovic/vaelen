"""Bookkeeping tests use disposable Git repos and a fake CLI, never a model or Vaelen."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / "Scripts/vaelen-agents"
SECTIONS = ("GOAL", "SCOPE", "CONTEXT", "ACCEPTANCE", "VERIFY", "TIMEBOX", "FORBIDDEN", "REPORT", "STANDING")


class AgentOrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vaelen-orchestration-test-")
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Disposable Fixture")
        (self.root / ".gitignore").write_text(".build/\n")
        (self.root / "feature.txt").write_text("before\n")
        for role in ("worker", "reviewer"):
            path = self.root / ".opencode/agents" / ("vaelen-" + role + ".md")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("Fixture only\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture baseline")
        self.base = self.git("rev-parse", "HEAD")
        self.call("init", "--integration-owner", "fixture-integrator", "--window", "1")
        self.brief = Path(self.temp.name) / "brief.md"
        self.brief.write_text("\n".join(section + " fixture requirement" for section in SECTIONS))

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args, root=None):
        return subprocess.check_output(["git", "-C", str(root or self.root), *args], text=True, stderr=subprocess.PIPE).strip()

    def call(self, *args, ok=True, env=None):
        result = subprocess.run(["python3", str(HELPER), "--repo", str(self.root), "--program", "fixture", *args],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def create(self, unit="unit", scope="feature.txt"):
        return json.loads(self.call("create", unit, "--scope", scope, "--brief", str(self.brief)).stdout)

    def change(self, unit):
        worktree = Path(unit["worktree"])
        (worktree / "feature.txt").write_text("after\n")
        self.git("add", "feature.txt", root=worktree)
        self.git("commit", "-qm", "fixture change", root=worktree)
        return self.git("rev-parse", "HEAD", root=worktree)

    def record(self, sha, **kwargs):
        report = Path(self.temp.name) / "report.md"
        report.write_text("Independent fixture reviewer\nHead: " + sha + "\nCheck: fixture\n")
        return self.call("record", "unit", "--head", sha, "--reviewer", "independent-session",
                         "--report", str(report), "--check", "fixture", "--verdict", "unit-test-verified", **kwargs)

    def test_worktree_isolation_scope_and_duplicate_refusal(self):
        unit = self.create()
        (Path(unit["worktree"]) / "feature.txt").write_text("isolated\n")
        self.assertEqual((self.root / "feature.txt").read_text(), "before\n")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)
        self.call("create", "unit", "--scope", "feature.txt", "--brief", str(self.brief), ok=False)
        self.call("create", "overlap", "--scope", "feature.txt", "--brief", str(self.brief), ok=False)
        self.call("create", "escape", "--scope", "../outside", "--brief", str(self.brief), ok=False)

    def test_invalid_brief_creates_no_ref(self):
        self.brief.write_text("GOAL only\n")
        self.call("create", "unit", "--scope", "feature.txt", "--brief", str(self.brief), ok=False)
        self.assertEqual(self.git("branch", "--list", "codex/orch-*"), "")

    def test_glob_scopes_are_rejected_before_creating_worktrees(self):
        for index, scope in enumerate(("Sources/*", "Sources/?.swift", "Sources/[AB].swift", "Sources/]name")):
            with self.subTest(scope=scope):
                self.call("create", "glob-" + str(index), "--scope", scope, "--brief", str(self.brief), ok=False)
        self.assertEqual(self.git("branch", "--list", "codex/orch-*"), "")

    def test_literal_directory_and_descendant_scopes_overlap(self):
        self.create(scope="Sources")
        self.call("create", "descendant", "--scope", "Sources/Core/file.swift", "--brief", str(self.brief), ok=False)

    def test_dirty_and_stale_heads_cannot_be_verified(self):
        unit = self.create()
        (Path(unit["worktree"]) / "feature.txt").write_text("dirty\n")
        self.record(self.base, ok=False)
        sha = self.change(unit)
        self.record(self.base, ok=False)
        self.record(sha)

    def test_scope_violation_rejected_even_when_committed(self):
        unit = self.create()
        worktree = Path(unit["worktree"])
        (worktree / "outside.txt").write_text("wrong owner\n")
        self.git("add", "outside.txt", root=worktree)
        self.git("commit", "-qm", "fixture scope violation", root=worktree)
        self.record(self.git("rev-parse", "HEAD", root=worktree), ok=False)

    def test_verified_head_preview_and_single_owner_integration(self):
        unit = self.create()
        sha = self.change(unit)
        self.record(sha)
        self.call("integrate", "unit", "--owner", "wrong-owner", "--execute", ok=False)
        self.call("integrate", "unit", "--owner", "fixture-integrator")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)
        self.call("integrate", "unit", "--owner", "fixture-integrator", "--execute")
        self.assertEqual(self.git("rev-parse", "HEAD"), sha)
        self.assertEqual(json.loads(self.call("status").stdout)["units"][0]["state"], "integrated")

    def test_new_head_invalidates_prior_verdict(self):
        unit = self.create()
        sha = self.change(unit)
        self.record(sha)
        (Path(unit["worktree"]) / "feature.txt").write_text("second change\n")
        self.git("add", "feature.txt", root=unit["worktree"])
        self.git("commit", "-qm", "second fixture change", root=unit["worktree"])
        self.call("integrate", "unit", "--owner", "fixture-integrator", "--execute", ok=False)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)

    def test_type_check_only_and_dirty_target_cannot_land(self):
        unit = self.create()
        sha = self.change(unit)
        report = Path(self.temp.name) / "typecheck.md"
        report.write_text("Checked source " + sha)
        self.call("record", "unit", "--head", sha, "--reviewer", "separate-review",
                  "--report", str(report), "--check", "typecheck", "--verdict", "type-check-only")
        self.call("integrate", "unit", "--owner", "fixture-integrator", "--execute", ok=False)
        self.record(sha)
        (self.root / "feature.txt").write_text("preserve unrelated target edit\n")
        self.call("integrate", "unit", "--owner", "fixture-integrator", "--execute", ok=False)
        self.assertEqual((self.root / "feature.txt").read_text(), "preserve unrelated target edit\n")

    def test_native_launch_preview_and_completion_use_fake_cli_only(self):
        self.create()
        binary_dir = self.root / ".build/fake-bin"
        binary_dir.mkdir(parents=True)
        marker = self.root / ".build/fake-cli-called"
        fake = binary_dir / "opencode2"
        fake.write_text("#!/bin/sh\nprintf 'fixture native run\\n'\ntouch '" + str(marker) + "'\n")
        fake.chmod(0o755)
        env = dict(os.environ, PATH=str(binary_dir) + os.pathsep + os.environ["PATH"])
        preview = json.loads(self.call("launch", "unit", env=env).stdout)
        self.assertFalse(preview["executes_model"])
        self.assertFalse(marker.exists())
        self.assertNotIn("--model", preview["argv"])
        self.assertNotIn("--auto", preview["argv"])
        self.assertEqual(preview["argv"][1:3], ["run", "--standalone"])
        launch = json.loads(self.call("launch", "unit", "--execute", env=env).stdout)
        for _ in range(100):
            if Path(launch["receipt"]).exists():
                break
            time.sleep(0.02)
        self.assertTrue(Path(launch["receipt"]).exists())
        self.assertTrue(marker.exists())
        collected = json.loads(self.call("collect").stdout)
        self.assertEqual(collected["units"][0]["state"], "needs-review")
        self.call("integrate", "unit", "--owner", "fixture-integrator", "--execute", ok=False)

    def test_abandon_preserves_work_and_handoff(self):
        unit = self.create()
        self.call("abandon", "unit", "--reason", "fixture concluded")
        self.assertTrue(Path(unit["worktree"]).exists())
        handoff = json.loads(self.call("handoff").stdout)
        self.assertEqual(handoff["units"][0]["state"], "abandoned")
        self.assertEqual(handoff["integration_head"], self.base)

    def test_human_status_empty_and_preserves_json_shape(self):
        empty = self.call("status", "--human").stdout
        self.assertIn("Program: fixture", empty)
        self.assertIn("Integration owner: fixture-integrator", empty)
        self.assertIn("Concurrency window: 1", empty)
        self.assertIn("no units yet", empty)
        unit = self.create()
        expected = {"program", "integration_owner", "window", "units"}
        default = json.loads(self.call("status").stdout)
        self.assertEqual(set(default), expected)
        self.assertEqual(set(default["units"][0]), {"id", "state", "branch", "head", "worktree"})
        self.assertEqual(json.loads(self.call("handoff").stdout)["units"][0]["state"], "planned")

    def test_human_status_reports_actual_lifecycle_role_and_unknown_head(self):
        unit = self.create()
        board_path = self.root / ".build/agent-orchestration/fixture/board.json"
        board = json.loads(board_path.read_text())
        for state in ("planned", "running", "needs-review", "failed"):
            board["units"]["unit"]["state"] = state
            board["units"]["unit"]["runs"] = ([{"role": "reviewer"}] if state != "planned" else [])
            board_path.write_text(json.dumps(board))
            rendered = self.call("status", "--human").stdout
            self.assertIn("Unit: unit", rendered)
            self.assertIn("State: " + state, rendered)
            self.assertIn("Latest role: " + ("Not started" if state == "planned" else "reviewer"), rendered)
            self.assertIn("Observed HEAD: " + self.base[:7], rendered)
            self.assertIn("Next action:", rendered)
        board["units"]["unit"]["worktree"] = str(self.root / "missing-worktree")
        board_path.write_text(json.dumps(board))
        self.assertIn("Observed HEAD: Unknown", self.call("status", "--human").stdout)


if __name__ == "__main__":
    unittest.main()
