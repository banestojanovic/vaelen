# Vaelen

Vaelen is a native macOS developer control center for local projects and their
development services. Projects are the primary user abstraction; the menu-bar
popover is for quick operations, and the native Settings window contains the
deeper project and service controls.

## Current development state

The active `dev` checkout is current product development, **not a declared
release or architectural freeze**. The current product version is
`0.0.14-dev`. Recent integrated work includes the Settings window and compact
menu-bar experience, service-specific settings, and safer MySQL package
management (including removal of package debug-only binaries). The signed app
and embedded Core were updated and validated against the existing schema-v7
installation; reuse the accepted runtime evidence unless product source
changes.

Compatibility versions: SQLite `user_version` **7**; IPC compatibility schema
**6**; IPC protocol **v1**.

Historical records remain historical: M12 (`v0.0.13-m12`) is the frozen
milestone documented in [`docs/m12-acceptance.md`](docs/m12-acceptance.md) and
ADR-0012. `v0.0.14-m13-golden` is the established runtime regression baseline.
Neither record describes the current `dev` checkout or declares a new freeze.
Earlier acceptance records are preserved in `docs/`.

## Requirements and local build

- macOS 14 or newer.
- Swift 6 or newer for package builds and tests.
- Python 3 for preparing the descriptor-pinned bundled PHP resources.
- Full Xcode is required to build/sign the native app and for the supported
  XCTest toolchain.

```bash
./Scripts/prepare-bundled-php
swift build
swift test
xcodebuild -project App/Vaelen/Vaelen.xcodeproj -scheme Vaelen \
  -configuration Debug build
```

The preparation command materializes the exact reviewed PHP CLI/FPM resources
from pinned archives; it does not compile PHP or refresh the catalog. Verified
resources are reused immediately. Use `./Scripts/prepare-bundled-php --offline`
when the resources or pinned archives are already cached. Xcode's Core embed
phase invokes preparation automatically. See
[`Distribution/PHP/README.md`](Distribution/PHP/README.md) for fresh-checkout
and offline-build details.

The app is a native menu-bar app (`dev.vaelen.app`) that bundles its matching
`vaelend` Core. Core owns the managed runtime state; GUI and CLI are interfaces
to the same Core and typed IPC. The app reuses a compatible running Core,
starts its embedded Core when needed, and stops only a Core process it started
when the app quits. Durable state lives under
`~/Library/Application Support/Vaelen/`; tests should use isolated temporary
state and ports rather than the installed runtime.

## Development install and runtime checks

On `dev`, use the signed app updater only when an installed-app update is
explicitly needed and the exclusive installed-operation slot is available:

```bash
./Scripts/vaelen-dev-update
```

It replaces only `/Applications/Vaelen.app`, requires the configured signing
identity and normal authorization, and checks the live schema-v7 database,
route inventory, and enabled-service readiness. It does not replace the support
root or reset the database.

For a CLI-only installation/update, use the guarded installer:

```bash
./Scripts/install-cli.sh
```

It installs the owned Release `val` beside Vaelen's PHP resolver and points
`~/.local/bin/val` to it; it does not replace the app or start/stop services.
Installed CLI use shares the exclusive installed-operation slot. Do not use
`Scripts/install-dev-cli.sh` as the current installed CLI path.

Repository harness commands are available for development when runtime work
is authorized:

```bash
./Scripts/vaelen-dev restart
./Scripts/vaelen-dev smoke
```

`reset-runtime` is destructive to runtime state and requires explicit need.
`clean-install` is not a `dev` update path: its exact guard permits only branch
`restored-m13-product` at commit
`328e2f1efc74dab9c41f411e914afe015a22d009`. Do not relax that guard.

## Historical full-suite result

`swift test` completed on 2026-09-30 against that historical source: **472 tests
reported across the IPC, DNS, Core, and CLI test bundles; 0 failures; 4 skipped**.
The skips are
environment-gated acceptance tests, not failures:

- `CaddyModuleTests.testOfficialDistributionWithDevelopmentCosign` — requires
  `VAELEN_COSIGN_PATH` and network access to Caddy's signed release assets.
- `MySQLRuntimeLifecycleTests.testConfiguredInstanceMigratesTo3306WithoutReinitializingData`
  — requires the installed managed MySQL package and canonical port 3306 free.
- `MySQLRuntimeLifecycleTests.testManagedMySQLIsolatedLifecyclePreservesUnrelatedSameBinaryServer`
  — requires canonical ports and `mysqld` inactive.
- `PHPFPMRuntimeLifecycleTests.testPHPFPMIsolationRegressionLeavesNormalRuntimeStoppedAndUnrelatedProcessUntouched`
  — requires normal Vaelen PHP-FPM to begin stopped.

The deterministic Caddy install/provenance and checksum-rejection tests run
without those official-artifact prerequisites. Do not infer a full-suite pass
from a build-only result.

This result predates the current accepted PHP/provider and orchestration
consolidation and is not validation of current source. See
[`docs/current-development.md`](docs/current-development.md) for the current
checkpoint and focused orchestration evidence.
