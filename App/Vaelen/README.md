# Vaelen.app

This directory contains Vaelen's native SwiftUI macOS menu-bar application.
Build and sign it with the Xcode project and `Vaelen` scheme; the target
requires macOS 14 or newer and embeds the matching `vaelend` Core. Use
[`../../README.md`](../../README.md) for build commands, current compatibility
versions, development install paths, harness boundaries, and the latest test
result.

The Core embed phase runs `Scripts/prepare-bundled-php` before its Swift build,
materializing the exact pinned PHP resources on a fresh checkout. Direct package
builds/tests require running that preparation command first from the repository
root. With verified resources or archives cached, pass `--offline` to prepare
without network access. No PHP compilation or catalog refresh occurs.

The compact popover provides quick project and service operations. Deeper
project and service configuration belongs in the native Settings window. The
app does not own managed runtime state: Core is authoritative, and the app and
CLI use its typed IPC (protocol v1, compatibility schema 6; SQLite schema 7).

At launch, the app reuses a compatible running Core or starts its embedded
Core when IPC is unavailable. On quit it stops only the Core process it
started; it does not stop a Core owned by another launcher. Project and service
state remains in Vaelen's per-user support directory across app updates.

On current `dev`, an installed signed app update uses `./Scripts/vaelen-dev-update`
from the repository root; a CLI-only update uses `./Scripts/install-cli.sh`.
These are distinct from the historical golden-checkout-only
`./Scripts/vaelen-dev clean-install` path. The M12 acceptance record and the
`v0.0.14-m13-golden` runtime baseline remain historical evidence, not a
declaration that current `dev` is frozen.
