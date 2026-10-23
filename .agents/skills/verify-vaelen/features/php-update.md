# Update PHP

A user updates a PHP runtime and expects default selection, running state, settings, and project pins to remain coherent.

## Sub-features

- `php.update.lifecycle` reports accepted, in-progress, and completed update results through IPC.
- `php.update.convergence` preserves default and running intent, carries settings, and retires the superseded runtime.
- `php.update.refusal` reports pinned projects, orphan routes, invalid sources, and partial convergence failures.

## How to get to it (user POV)

Run `val php update` for the intended runtime or use PHP update controls in Settings. These recipes exercise the lower Core paths; they do not drive those CLI or GUI controls.

## Driving it with Swift XCTest

Preconditions: inspect `Tests/VaelenIPCTests/PHPUpdateLifecycleTests.swift` and `PHPUpdateConvergenceTests.swift` before execution. Both need the already verified provider-cache pair PHP 8.4.23 and 8.4.24. Do not refresh or download it under this skill. Confirm all processes and roots belong to the new test run.

```bash
swift test --skip-build --filter PHPUpdateLifecycleTests
swift test --skip-build --filter PHPUpdateConvergenceTests
```

These are optional focused recipes, not part of the initial executed proof. Record discovery, passed tests, and skips separately. Require the expected update payloads, preserved default/settings, and specific partial-failure outcomes. Read each test's owned FPM teardown results. A skip from a missing cache leaves the journey unverified.

### Real PHP 8.4.24 → 8.4.27 acceptance

For a current provider update, place these four macOS arm64 archives in a disposable directory supplied by the caller:

- `php-8.4.24-cli-macos-aarch64.tar.gz`
- `php-8.4.24-fpm-macos-aarch64.tar.gz`
- `php-8.4.27-cli-macos-aarch64.tar.gz`
- `php-8.4.27-fpm-macos-aarch64.tar.gz`

Acquire them only from the provider's HTTPS origin and its approved object-storage redirect host (`dl.static-php.dev` and `static-php-cli.fra1.digitaloceanspaces.com`). The test itself does not access the network or the live app. It computes a local digest manifest from the supplied bytes, then exercises real CLI/FPM installs through isolated Core state. Since the provider does not publish signed checksums, this proves the update lifecycle and package behavior for those downloaded bytes, not independent artifact authenticity.

```bash
VAELEN_PHP_ACCEPTANCE_ARTIFACT_DIR=/absolute/path/to/archives \
  Scripts/test.sh --filter 'PHPUpdateConvergenceTests.testRealPHP8424To8427Acceptance'
```

The test checks reported CLI versions, refuses an update while a project pins the source version, then verifies successful update convergence, running/default state, carried settings, and cleanup of the superseded runtime. Without the environment variable or any required archive, the test skips and the real-package journey remains unverified.

## Gotchas

The cached artifacts are real PHP and some cases start isolated FPM. Dispatcher/socket paths use private filesystem roots, and router behavior uses doubles. This does not prove installed-app update behavior. `IsolatedPHPFixture.swift` is an existing supporting pattern that references installed executable paths read-only and owns disposable FPM state; it is not an independent user journey or evidence of GUI interaction.
