"""Bookkeeping tests use disposable Git repos and a fake CLI, never a model or Vaelen."""
import json
import os
from pathlib import Path
import runpy
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
        self.call("init", "--integration-owner", "fixture-integrator", "--authorization", "commits-forbidden", "--window", "1")
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

    def test_worker_worktree_receives_verified_pinned_playbook(self):
        (self.root / "opencode.json").write_text("{}\n")
        source = self.root / ".build/agent-tools/pstack"
        source.mkdir(parents=True)
        (source / "pstack/skills").mkdir(parents=True)
        (source / "pstack/skills/fixture.md").write_text("pinned fixture\n")
        self.git("init", "-q", root=source)
        self.git("config", "user.email", "fixture@example.invalid", root=source)
        self.git("config", "user.name", "Disposable Fixture", root=source)
        self.git("add", ".", root=source)
        self.git("commit", "-qm", "pinned fixture", root=source)
        pin = self.git("rev-parse", "HEAD", root=source)
        module = runpy.run_path(str(HELPER))
        module["install_worker_playbook"](self.root, Path(self.temp.name) / "worker", expected=pin)
        copied = Path(self.temp.name) / "worker/.build/agent-tools/pstack/pstack/skills/fixture.md"
        self.assertEqual(copied.read_text(), "pinned fixture\n")

    def test_invalid_brief_creates_no_ref(self):
        self.brief.write_text("GOAL only\n")
        self.call("create", "unit", "--scope", "feature.txt", "--brief", str(self.brief), ok=False)
        self.assertEqual(self.git("branch", "--list", "codex/orch-*"), "")

    def test_launch_restores_assignment_and_authorization_after_brief_rewrite(self):
        unit = self.create()
        brief = Path(unit["brief"])
        brief.write_text("rewritten body with required sections\n" + "\n".join(SECTIONS))
        binary_dir = self.root / ".build/fake-bin"
        binary_dir.mkdir(parents=True)
        fake = binary_dir / "opencode2"
        fake.write_text("#!/bin/sh\nexit 0\n")
        fake.chmod(0o755)
        env = dict(os.environ, PATH=str(binary_dir) + os.pathsep + os.environ["PATH"])
        self.call("launch", "unit", env=env)
        rewritten = brief.read_text()
        self.assertIn("Owned paths: feature.txt", rewritten)
        self.assertIn("Commit authorization: commits-forbidden", rewritten)
        self.assertIn("Respect owned paths", rewritten)
        self.assertIn("Pinned upstream: " + str(Path(unit["worktree"]) / ".build/agent-tools/pstack/pstack"), rewritten)
        preview = json.loads(self.call("launch", "unit", env=env).stdout)
        self.assertIn("Do not commit", preview["argv"][-1])

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
        board_path = self.root / ".build/agent-orchestration/fixture/board.json"
        board = json.loads(board_path.read_text())
        board["authorization"] = "task-local-commits-authorized"
        board_path.write_text(json.dumps(board))
        sha = self.change(unit)
        self.record(sha)
        self.call("integrate", "unit", "--owner", "wrong-owner", "--execute", ok=False)
        self.call("integrate", "unit", "--owner", "fixture-integrator")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)
        merged = self.call("integrate", "unit", "--owner", "fixture-integrator", "--execute")
        integrated = json.loads(merged.stdout)
        combined_head = self.git("rev-parse", "HEAD")
        self.assertNotEqual(combined_head, sha)
        self.assertEqual(integrated["state"], "integrated-needs-check")
        report = Path(self.temp.name) / "combined.md"
        report.write_text("Focused combined source check\nHead: " + combined_head + "\n")
        self.call("accept-integration", "--head", combined_head, "--report", str(report), "--check", "combined-fixture")
        self.assertEqual(json.loads(self.call("status").stdout)["units"][0]["state"], "integrated")

    def test_forbidden_task_cannot_create_integration_commit(self):
        unit = self.create()
        sha = self.change(unit)
        self.record(sha)
        self.call("integrate", "unit", "--owner", "fixture-integrator", "--execute", ok=False)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)

    def test_new_head_invalidates_prior_verdict(self):
        unit = self.create()
        sha = self.change(unit)
        self.record(sha)
        (Path(unit["worktree"]) / "feature.txt").write_text("second change\n")
        self.git("add", "feature.txt", root=unit["worktree"])
        self.git("commit", "-qm", "second fixture change", root=unit["worktree"])
        self.call("integrate", "unit", "--owner", "fixture-integrator", "--execute", ok=False)
        status = json.loads(self.call("status").stdout)
        self.assertEqual(status["units"][0]["state"], "needs-review")
        self.assertEqual(len(json.loads((self.root / ".build/agent-orchestration/fixture/board.json").read_text())["units"]["unit"]["ledger"]), 1)
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
        unit = self.create()
        binary_dir = self.root / ".build/fake-bin"
        binary_dir.mkdir(parents=True)
        marker = self.root / ".build/fake-cli-called"
        fake = binary_dir / "opencode2"
        fake.write_text("#!/bin/sh\nprintf 'fixture native run\\n'\nprintf 'accepted fixture\\n' > feature.txt\ngit commit --allow-empty -m forbidden > /dev/null 2>&1; printf '%s' \"$?\" > '" + str(marker) + ".commit'\ntouch '" + str(marker) + "'\n")
        fake.chmod(0o755)
        env = dict(os.environ, PATH=str(binary_dir) + os.pathsep + os.environ["PATH"])
        preview = json.loads(self.call("launch", "unit", env=env).stdout)
        self.assertFalse(preview["executes_model"])
        self.assertFalse(marker.exists())
        self.assertNotIn("--model", preview["argv"])
        self.assertNotIn("--auto", preview["argv"])
        self.assertEqual(preview["argv"][1:3], ["run", "--standalone"])
        launch = json.loads(self.call("launch", "unit", "--execute", env=env).stdout)
        self.call("launch", "unit", "--execute", env=env, ok=False)
        for _ in range(100):
            if Path(launch["receipt"]).exists():
                break
            time.sleep(0.02)
        self.assertTrue(Path(launch["receipt"]).exists())
        self.assertTrue(marker.exists())
        self.assertEqual(Path(str(marker) + ".commit").read_text(), "1")
        self.assertEqual(self.git("rev-parse", "HEAD", root=Path(unit["worktree"])), self.base)
        collected = json.loads(self.call("collect").stdout)
        self.assertEqual(collected["units"][0]["state"], "needs-review")
        self.assertEqual(collected["completions"][0]["role"], "worker")
        self.assertEqual(collected["completions"][0]["result"]["exit_code"], 0)
        self.call("integrate", "unit", "--owner", "fixture-integrator", "--execute", ok=False)

    def test_authorized_worker_can_commit_through_per_run_guard(self):
        unit = self.create()
        board_path = self.root / ".build/agent-orchestration/fixture/board.json"
        board = json.loads(board_path.read_text())
        board["authorization"] = "task-local-commits-authorized"
        board_path.write_text(json.dumps(board))
        binary_dir = self.root / ".build/authorized-bin"
        binary_dir.mkdir(parents=True)
        fake = binary_dir / "opencode2"
        fake.write_text("#!/bin/sh\nprintf 'authorized\\n' > feature.txt\ngit add feature.txt && git commit -m authorized -q\n")
        fake.chmod(0o755)
        env = dict(os.environ, PATH=str(binary_dir) + os.pathsep + os.environ["PATH"])
        launched = json.loads(self.call("launch", "unit", "--execute", env=env).stdout)
        for _ in range(100):
            if Path(launched["receipt"]).exists():
                break
            time.sleep(0.02)
        self.call("collect")
        worktree = Path(unit["worktree"])
        self.assertNotEqual(self.git("rev-parse", "HEAD", root=worktree), self.base)
        self.assertEqual(self.git("status", "--porcelain", root=worktree), "")

    def test_receipt_reconciles_running_board_and_role_retries_are_independent(self):
        unit = self.create()
        board_path = self.root / ".build/agent-orchestration/fixture/board.json"
        board = json.loads(board_path.read_text())
        board["units"]["unit"]["state"] = "running"
        board["units"]["unit"]["runs"] = [{"role": "worker", "receipt": str(Path(self.temp.name) / "already.json")}]
        receipt = Path(self.temp.name) / "already.json"
        receipt.write_text(json.dumps({"status": "returned", "exit_code": 0, "finished": "now"}))
        board_path.write_text(json.dumps(board))
        status = json.loads(self.call("status").stdout)
        self.assertEqual(status["units"][0]["state"], "failed")
        self.assertTrue(json.loads(board_path.read_text())["units"]["unit"]["replan_required"])
        self.call("launch", "unit", ok=False)
        board = json.loads(board_path.read_text())
        board["units"]["unit"]["state"] = "planned"
        board["units"]["unit"].pop("replan_required", None)
        board["units"]["unit"]["attempts"] = {"worker": 3, "reviewer": 0}
        board_path.write_text(json.dumps(board))
        binary_dir = self.root / ".build/fake-bin"
        binary_dir.mkdir(parents=True)
        (binary_dir / "opencode2").write_text("#!/bin/sh\nexit 0\n")
        (binary_dir / "opencode2").chmod(0o755)
        env = dict(os.environ, PATH=str(binary_dir) + os.pathsep + os.environ["PATH"])
        reviewer = self.call("launch", "unit", "--role", "reviewer", "--execute", env=env)
        self.assertEqual(json.loads(reviewer.stdout)["unit"], "unit")
        board = json.loads(board_path.read_text())
        self.assertEqual(board["units"]["unit"]["attempts"], {"worker": 3, "reviewer": 1})

    def test_timeout_kills_only_owned_process_group_and_preserves_return_fact(self):
        sleeper = Path(self.temp.name) / "sleep.sh"
        child_pid = Path(self.temp.name) / "child.pid"
        sleeper.write_text("#!/bin/sh\nsleep 30 &\nchild=$!\nprintf '%s' \"$child\" > '" + str(child_pid) + "'\ntrap 'kill \"$child\" 2>/dev/null; wait \"$child\" 2>/dev/null; exit 124' TERM\nwait \"$child\"\n")
        sleeper.chmod(0o755)
        spec = Path(self.temp.name) / "timeout.spec.json"
        receipt = Path(self.temp.name) / "timeout.json"
        log = Path(self.temp.name) / "timeout.log"
        spec.write_text(json.dumps({"argv": [str(sleeper)], "cwd": str(self.root), "timeout": 1,
                                   "receipt": str(receipt), "log": str(log)}))
        subprocess.run(["python3", str(HELPER), "_run", str(spec)], check=True, timeout=8)
        result = json.loads(receipt.read_text())
        self.assertEqual(result["exit_code"], 124)
        self.assertEqual(result["status"], "failed")
        with self.assertRaises(ProcessLookupError):
            os.kill(int(child_pid.read_text()), 0)

    def test_wait_collects_reviews_and_refills_ready_unit_before_slow_peer(self):
        board_path = self.root / ".build/agent-orchestration/fixture/board.json"
        board = json.loads(board_path.read_text())
        board["window"] = 3
        board["authorization"] = "task-local-commits-authorized"
        board_path.write_text(json.dumps(board))
        for name in ("pilot-alpha", "pilot-beta", "pilot-gamma"):
            brief = Path(self.temp.name) / (name + ".md")
            brief.write_text("\n".join(section + " fixture" for section in SECTIONS))
            self.call("create", name, "--scope", name + ".txt", "--brief", str(brief))
        binary_dir = self.root / ".build/scheduler-bin"
        binary_dir.mkdir(parents=True)
        fake = binary_dir / "opencode2"
        fake.write_text("#!/bin/sh\ncase \"$PWD\" in *pilot-beta) sleep 2;; esac\ncase \"$*\" in *vaelen-worker*) file=\"$PWD/$(basename \"$PWD\").txt\"; printf 'artifact\\n' > \"$file\"; git add \"$file\"; git commit -m 'fixture scoped artifact' -q;; esac\nexit 0\n")
        fake.chmod(0o755)
        env = dict(os.environ, PATH=str(binary_dir) + os.pathsep + os.environ["PATH"])
        self.call("launch", "pilot-alpha", "--execute", env=env)
        self.call("launch", "pilot-beta", "--execute", env=env)
        result = json.loads(self.call("wait", "--timeout", "30", "--schedule", "--run-timeout", "30", env=env).stdout)
        self.assertTrue(result["completions"])
        scheduled = {(item["unit"], item["role"]) for item in result["scheduled"]}
        self.assertIn((result["completions"][0]["unit"], "reviewer"), scheduled, repr(result))
        self.assertIn(("pilot-gamma", "worker"), scheduled)
        board = json.loads(board_path.read_text())
        self.assertEqual(board["units"]["pilot-beta"]["state"], "running")
        self.assertEqual(board["units"]["pilot-gamma"]["state"], "running")
        self.call("wait", "--timeout", "15")
        for name in ("pilot-alpha", "pilot-beta", "pilot-gamma"):
            worktree = board["units"][name]["worktree"]
            self.git("worktree", "remove", "--force", worktree)

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
        expected = {"program", "integration_owner", "authorization", "window", "units"}
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
