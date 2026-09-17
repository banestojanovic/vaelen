# Vaelen

Vaelen is a native macOS developer control center. Milestone 1 contains the
authoritative per-user `vaelend` Core daemon, structured UNIX-socket IPC,
project registration, and shallow parked-directory discovery.

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
swift run val link
swift run val links
swift run val links --json
swift run val park
swift run val paths
swift run val paths --json
```

The daemon owns the socket at:

```text
~/Library/Application Support/Vaelen/runtime/sockets/core.sock
```

Project metadata is stored in:

```text
~/Library/Application Support/Vaelen/state/vaelen.sqlite
```

`val link` and `val park` store canonical absolute paths. Parked roots expose
only immediate child directories; hidden entries, files, symlink children, and
grandchildren are ignored. Explicit links override discovered entries at the
same path. Missing registrations remain visible as unavailable metadata.

Vaelen never owns or modifies project source directories. Link, unlink, park,
and unpark change only Vaelen's registry metadata.

Milestone 0 uses manual daemon startup. LaunchAgent installation and
socket-activation are intentionally deferred.

## App

Open the Xcode project under `App/Vaelen` when full Xcode is installed. The
app is a first-class Core client and does not start or inspect the daemon
directly.

## Scope

PHP, Caddy, routing, DNS/TLS, modules, reconciliation, privileged helpers,
Docker, Electron, and Homebrew-managed infrastructure remain deferred.
