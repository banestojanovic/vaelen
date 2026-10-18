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

## Gotchas

The cached artifacts are real PHP and some cases start isolated FPM. Dispatcher/socket paths use private filesystem roots, and router behavior uses doubles. This does not prove installed-app update behavior. `IsolatedPHPFixture.swift` is an existing supporting pattern that references installed executable paths read-only and owns disposable FPM state; it is not an independent user journey or evidence of GUI interaction.
