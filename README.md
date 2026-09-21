# Vaelen

Vaelen is a native macOS developer control center. The current frozen release
is M13, Core-Authoritative Local TLS Trust Operations, with an authoritative
per-user `vaelend` Core daemon, structured UNIX-socket IPC, project
registration, and managed local development infrastructure. M14 lifecycle
implementation is active but not accepted or frozen.

## Release Status

- **M13:** frozen and complete
- **M14:** active implementation; production acceptance remains incomplete
- **Version:** `0.0.14-dev`
- **Build identity:** `m14-core-daemon-lifecycle-schema-7`
- **SQLite schema:** `7`
- **IPC schema:** `5`
- **Architecture decision:** `docs/adr/ADR-0013-core-authoritative-local-tls-trust-operations.md`

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

## Development CLI

For local dogfooding, install a user-owned symlink to the built CLI:

```bash
Scripts/install-dev-cli.sh
export PATH="$HOME/.local/bin:$PATH"
val status
```

The installer builds `val` first and refuses to replace an unrelated existing
`val` executable or symlink. For zsh, it adds one marked, idempotent PATH block
to `~/.zshrc`; it does not modify unrelated shell configuration. Remove only
the symlink owned by this checkout and any PATH block added by this installer
with:

```bash
Scripts/uninstall-dev-cli.sh
```

This is a development convenience, not the final Vaelen installation or
distribution mechanism.

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

Development runs may still use manual daemon startup. The Xcode app package
contains the signed daemon and its LaunchAgent resource. Lifecycle observation
is passive; registration, bootstrap, and socket activation are explicit
app-controlled operations, not implicit side effects of ordinary CLI commands.

## App

Open the Xcode project under `App/Vaelen` when full Xcode is installed. The
app is a first-class Core client and does not start or inspect the daemon
directly.

## Scope

M12 includes managed PHP runtime selection, Caddy routing, DNS/TLS, standard
ports, project reconciliation, durable PHP route-target convergence, and the
associated ownership and privileged-helper boundaries. The controlled PHP
distribution build inputs and CI workflow live under `Distribution/PHP` and
`.github/workflows/build-php.yml`; no PHP binaries are stored in the
repository. Future milestone scope remains outside this release.
