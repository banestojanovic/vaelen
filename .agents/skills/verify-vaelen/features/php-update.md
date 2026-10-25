# Update PHP

A user updates a PHP runtime and expects default selection, running state, settings, and project pins to remain coherent.

## Sub-features

- `php.update.lifecycle` reports accepted, in-progress, and completed update results through IPC.
- `php.update.convergence` preserves default and running intent, carries settings, and retires the superseded runtime.
- `php.update.refusal` reports pinned projects, orphan routes, invalid sources, and partial convergence failures.

## How to get to it (user POV)

Run `val php update` for the intended runtime or use PHP update controls in Settings. These recipes exercise the lower Core paths; they do not drive those CLI or GUI controls.

## Driving it with Swift XCTest

These provider-backed recipes are opt-in. The default suite runs the pure wire-format tests in `PHPUpdateLifecycleTests` and skips tests that consume provider PHP bytes. Cache-backed recipes require PHP 8.4.23 and 8.4.24 to already exist in the verified local provider cache. Set `VAELEN_PHP_PROVIDER_ACCEPTANCE=1` to opt in. This flag never refreshes the provider catalog or downloads artifacts. Confirm all processes and roots belong to the new test run.

```bash
VAELEN_PHP_PROVIDER_ACCEPTANCE=1 Scripts/test.sh --skip-build --filter PHPUpdateLifecycleTests
VAELEN_PHP_PROVIDER_ACCEPTANCE=1 Scripts/test.sh --skip-build --filter PHPUpdateConvergenceTests
```

These are optional focused recipes, not part of the initial executed proof. Record discovery, passed tests, and skips separately. Require the expected update payloads, preserved default/settings, and specific partial-failure outcomes. Read each test's owned FPM teardown results. A skip from a missing cache leaves the journey unverified.

Run provider install/update acceptance from the existing local cache with this command:

```bash
VAELEN_PHP_PROVIDER_ACCEPTANCE=1 Scripts/test.sh --filter PHPProviderInstallUpdateTests
```

The one test that downloads the latest stable package also requires the separate network opt-in:

```bash
VAELEN_PHP_PROVIDER_ACCEPTANCE=1 VAELEN_PHP_NETWORK_ACCEPTANCE=1 \
  Scripts/test.sh --filter PHPProviderInstallUpdateTests.testLatestStableInstallsFromProviderActivatesAndBecomesDefault
```

This test contacts the live provider and is distinct from acceptance using locally cached bytes. Never set the network flag as part of the ordinary suite.

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
