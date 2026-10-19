---
name: verify-vaelen
description: Verify bounded Vaelen CLI and Core changes with existing isolated Swift harnesses, a real val links child, retained evidence, and explicit coverage limits. Use before independent review of a Vaelen feature or correction.
---

# Verify Vaelen

Work from an isolated task worktree based on current `dev`. Establish `git rev-parse HEAD dev`, branch, and canonical `git status --porcelain=v1` before creating it. Preserve the canonical checkout, including staged files and untracked metadata. Use Codex's worktree tool or `git worktree add -b codex/<task> <new-path> dev`. Do not reuse historical orchestration or benchmark worktrees.

Read the [feature map](features/README.md), then the affected journey. Implement and correct the bounded change, execute its focused checks, inspect the actual evidence, and obtain a fresh independent review. Continue through correction without asking for routine continuation. This skill supplies verification recipes, not an orchestration adapter. Respect the task's model and delegation instructions.

## Launch

Use macOS, Swift 6.4, and the pinned Yams revision in `Package.resolved`. A local dependency cache is required for a run without downloads. Do not refresh PHP catalogs or prepare bundled runtime bytes for the default links proof. SwiftPM test compilation needs only the tracked resources. A missing dependency cache is a precondition failure, not permission to download.

From the worktree root, execute:

```bash
.agents/skills/verify-vaelen/scripts/prove-links.sh
```

This executable builds only the unsigned `val` product, compiles and lists tests without executing the full suite, then selects exactly three checks. It records every Swift command and exit status. It uses `--skip-update --disable-automatic-resolution` for build and discovery. The harness requires the default `.build/debug/val`; do not override the scratch path or reuse a binary from another worktree.

For the Composer passthrough, execute:

```bash
.agents/skills/verify-vaelen/scripts/prove-composer.sh
```

This builds only `val`, discovers the suite without running it, and selects exactly six locator checks, one parser check, and one private-Core end-to-end journey. That journey compiles two controlled arm64 Mach-O PHP stand-ins with different reported versions, seeds one linked override and one inherited default, then invokes the actual worktree CLI. It also checks an outside-root invocation, PATH lookup errors, unavailable selected PHP with a default still present, unavailable Core, exact argv/cwd/stdin/stdout/stderr/status, support-file snapshots, and bounded cleanup. The stand-ins are not PHP, and the PHP script candidates are fixture stubs; this proves selection and process forwarding, not Composer behavior or package installation.

The drive starts an in-process production `DaemonServer` with a private Unix socket and disposable SQLite registry containing six projects. There is no persistent shared verification server to launch separately. Readiness and teardown occur within each test invocation.

## Doctor

The helper's preflight is read-only after compilation. It records worktree, branch, commit, dirty-source summary, compiler version, binary SHA-256, and exact discovery counts. An empty or ambiguous test selection fails. Ambient test-root variables fail preflight; never export them in your shell.

Inside the links fixture, the doctor handshakes with its private Core and reads status before driving `val`. It checks the expected in-process PID and reports fixture, socket, source, and executable identity. Review those lines in `drive.log`. A socket file alone is not readiness. The SHA identifies the just-built worktree binary; it is not a signed installed-product identity attestation.

## Drive

The default proof runs these tests from `Tests/VaelenIPCTests/LinkedProjectsPerformanceTests.swift`:

- `testHumanLinksEndToEndSixMinimalNoPHPProjects` invokes the actual `val links` child once for warmup and five repeats. Every invocation must exit zero and include all six project names. Provider observation counts have assertions.
- `testHumanLinksDetectsMissingExpectedProject` deliberately requires an absent project in the same real CLI journey. The output checker must reject the missing name and report the actual output. The outer XCTest passes only when it detects that specific disagreement and cleanup succeeds.
- `testSubprocessTimeoutTerminatesOwnedChildWithoutPreservingRoot` checks bounded termination of an owned child and continued liveness of an unrelated child.

The fixture confines `VAELEN_TEST_SUPPORT_ROOT_ENABLED=1` and `VAELEN_TEST_SUPPORT_ROOT` to its CLI child. The test runner and caller do not receive them. No signed app, launch agent, installed package, live database, project, route, defaults, DNS, ports, TLS trust, or Keychain mutation is part of this proof.

## Evidence

The helper prints a unique `/private/tmp/vaelen-verify-evidence.*` directory. Keep it. Inspect `source.txt`, `commands.txt`, `status.txt`, `doctor.log`, and `drive.log`. Require exactly three selected and passed tests, zero skips, the specific controlled mismatch, successful private-Core doctor, CLI output and exit, and cleanup confirmation. Test discovery compiles other tests but does not execute them. Record discovered count separately from selected and passed counts.

The root, socket, and CLI output in `drive.log` establish the action and observed output. The SQLite seed uses the real `ProjectRegistry` and store; this is listing pre-seeded projects, not CLI link creation or persistence across a product restart. Request accounting printed by the historical benchmark is partly inferred. Do not report its elapsed times as installed-product performance.

For Composer, inspect `composer-drive.log` and require all eight exact checks to pass, including the in-process private Core PID, distinct override/default fixture labels, the expected unavailable-PHP and Core errors, exact stream/argument output, unchanged support snapshot, and confirmed cleanup. Its controlled native executables exercise Core's existing package metadata and file validation; they do not emulate PHP parsing, Composer resolution, or dependency installation.

Router, DNS responder, TLS trust, and privileged ports boundaries are disabled or simulated. No real route reconciliation, DNS listener, TLS trust change, or port forwarding is tested. The optional synthetic-PHP companion reuses a local `php -v` executable as both metadata paths and creates synthetic hashes/default metadata. It supplies neither a genuine package nor PHP-FPM coverage. See [links](features/links.md).

## Cleanup

Each fixture owns its server task, CLI children, and unique temporary root. CLI execution is bounded at 30 seconds, followed by TERM and KILL grace windows of two seconds each. Confirmed CLI exits precede normal root removal. Cleanup requests shutdown only over the fixture's private socket and waits for the owned server task. Unconfirmed termination fails verification and preserves output and disposable state for diagnosis. Do not kill by process name or remove a root while termination is uncertain.

A normal run reports the server stopped and fixture root removed. Evidence lives outside that root and remains readable after cleanup. A failed build or discovery leaves logs but creates no fixture server. If drive fails, read the preserved-root diagnostics before any manual cleanup. Never remove the evidence directory as fixture cleanup.

## Maintain the map

When a bounded feature changes, update its entry and run its recipe. Use `pstack:maintain-verification-skill` for a broader map audit. Mark skipped, simulated, manual, and unverified entry points explicitly. Existing installed-app helpers such as `Scripts/vaelen-dev` and `Scripts/vaelen-dev-update` can build, sign, install, or mutate live state. Execute them only under a separate task that authorizes those effects.
