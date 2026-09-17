# Vaelen

Vaelen is a native macOS developer control center. Milestone 0 contains the
authoritative per-user `vaelend` Core daemon, the `val` CLI, structured JSON
UNIX-socket IPC, and the initial SwiftUI menu-bar app.

## Requirements

- macOS 14 or newer
- Swift 6.0 or newer
- Full Xcode is required to build and launch `Vaelen.app`

## Build And Test

```bash
swift build
swift test
```

`swift test` requires a working full-Xcode XCTest toolchain. The reusable
targets and executables can still be compiled with `swift build` when only
Command Line Tools are active.

## Run Core And CLI

Start the per-user daemon in one terminal:

```bash
swift run vaelend
```

Then, in another terminal:

```bash
swift run val status
swift run val status --json
```

The daemon owns the socket at:

```text
~/Library/Application Support/Vaelen/runtime/sockets/core.sock
```

Milestone 0 uses manual daemon startup. LaunchAgent installation and
socket-activation are intentionally deferred.

## App

Open the Xcode project under `App/Vaelen` when full Xcode is installed. The
app is a first-class Core client and does not start or inspect the daemon
directly.

## Scope

PHP, Caddy, routing, DNS/TLS, project management, modules, reconciliation,
privileged helpers, Docker, Electron, and Homebrew-managed infrastructure are
not part of Milestone 0.
