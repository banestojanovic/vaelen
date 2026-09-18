# M5 MySQL Investigation

Date: 2026-09-18

Status: Investigation and M5 Slice 1 acceptance complete.

## Executive Decision

Proceed with a Vaelen-owned MySQL module based on the official MySQL 8.4 LTS generic macOS ARM64 archive. The archive is relocatable enough for Vaelen when `basedir` and all runtime paths are explicit, but the package must not rely on MySQL's compiled `/usr/local/mysql` defaults.

This investigation does not require a new ADR before implementation. The implementation must follow ADRs 0001, 0003, 0004, 0007, and 0008. A module-specific ADR is warranted only if implementation introduces behavior that cannot be expressed by those existing decisions.

## Findings

1. **Representative artifact:** `mysql-8.4.11-macos15-arm64.tar.gz`, downloaded from the official MySQL download redirect and CDN.
2. **Artifact size:** 167,977,240 bytes; SHA-256 `b96e00493bc3499b9ffd7f08d65c5d64933af0383a8287d9873b64f94c2d6009`.
3. **Archive format:** gzip-compressed tar archive with a single versioned top-level directory.
4. **CPU architecture:** `mysqld`, `mysql`, and the tested binaries are native Mach-O arm64. Rosetta is not required on Apple Silicon.
5. **Apple signing:** `mysqld`, `mysql`, and bundled OpenSSL libraries have valid Developer ID signatures from Oracle America, Inc., team `VB5E2TV963`, chained to Apple. `spctl` rejects the standalone executable only because it is not an app bundle, not because its code signature is invalid.
6. **GnuPG verification:** MySQL publishes an `.asc` signature for this exact archive and documents build key `B7B3B788A8D3785C`. The host used for testing has no `gpg`, so cryptographic GPG verification remains a packaging-pipeline requirement rather than an executed test result.
7. **Dynamic dependencies:** `mysqld` uses system CoreServices, CoreFoundation, libc++, and libSystem plus bundled `libssl`, `libcrypto`, and protobuf through `@loader_path`. No Homebrew or MacPorts dependency was observed.
8. **Relocatability:** The archive ran successfully from a temporary path outside `/usr/local`. Runtime flags must still set `--basedir`, `--datadir`, socket, pid, log, and port explicitly.
9. **Compiled defaults:** Binary strings contain `/usr/local/mysql/data`, `/usr/local/mysql/etc`, and related paths. These are fallback defaults and must not be allowed to define Vaelen state ownership.
10. **Package contents:** The archive includes `mysqld`, client tools, `mysqldump`, `mysqld_safe`, libraries, plugins, character sets, TLS material generated during initialization, documentation, and `support-files/mysql.server`.
11. **Data separation:** The extracted package and persistent data directory are separable. Package files belong under Vaelen's immutable package root; the data directory belongs under Vaelen's persistent application-support data root.
12. **Initialization:** `--initialize` completed successfully and generated a temporary root password. `--initialize-insecure` creates an empty root password and is unsuitable for normal Vaelen initialization.
13. **Initialization idempotence:** Re-running initialization against a non-empty data directory aborts rather than silently replacing data. Core must track initialized state and never use initialization as a start operation.
14. **Authentication:** The generated temporary root password must be consumed through a controlled first-run flow using `--connect-expired-password`, then replaced with a generated Vaelen-managed credential or an explicit user setup.
15. **Readiness:** `mysqladmin ping` over the Unix socket became successful after startup. Readiness must be based on an authenticated or otherwise deliberately scoped probe, not only process existence.
16. **Networking:** The server successfully listened on loopback TCP port `13307` and accepted a TCP client. The production default should be a Vaelen-selected port with collision detection, while retaining an explicit socket path for local clients.
17. **Loopback policy:** Bind explicitly to loopback and disable unused MySQL X Protocol (`--mysqlx=OFF` in the test). Do not expose MySQL on external interfaces by default.
18. **Shutdown:** Authenticated `mysqladmin shutdown` produced a clean shutdown and process exit. Core should prefer a controlled administrative shutdown, then apply bounded escalation only if the child remains alive.
19. **Version coexistence:** Multiple MySQL versions can be represented by independent package roots, data roots, sockets, pid files, logs, and ports. A data directory must be bound to one compatible major/version policy and never shared concurrently.
20. **Upgrade and downgrade:** MySQL data upgrades are not a generic package replacement. Vaelen must preserve the existing data directory, make upgrade intent explicit, require a backup or recovery point, and refuse unsupported downgrade attempts.

## Recommended Runtime Shape

Core should own one supervised `mysqld` child per selected MySQL instance. The desired-state record should include package version, executable path, data directory, socket path, loopback port, pid path, log path, and initialization state. CLI and GUI should consume Core's observed state rather than independently probing or launching MySQL.

The first implementation should use a generated option file or explicit argument list owned by Core. It must set at least `basedir`, `datadir`, `socket`, `port`, `bind-address`, `pid-file`, `log-error`, and disable X Protocol unless a later requirement needs it. Credentials must not be placed in process arguments or ordinary logs.

## Packaging Requirements

- Pin the exact archive and record its SHA-256 and official GPG signature metadata in the distribution manifest.
- Verify the GPG signature in CI and distribution tooling using the documented MySQL build key.
- Preserve Oracle's signed Mach-O files without rewriting them after extraction.
- Keep package installation immutable and keep data, logs, sockets, pid files, and generated credentials outside the package.
- Add an artifact acceptance test for arm64 architecture, Apple code-signature validity, absence of external package-manager dependencies, and explicit `basedir` startup.

## Open Decisions Before Implementation

- Select the stable Vaelen MySQL port policy: prefer an allocated Vaelen port over assuming `3306` is available.
- Define the credential handoff and storage policy in Core without exposing passwords through argv, logs, or unprotected IPC.
- Define the supported upgrade matrix for the first shipped MySQL version. Do not claim arbitrary 8.0/8.4/9.x data-directory compatibility.
- Add or use a CI environment with GnuPG so the published MySQL signature is verified as part of the artifact pipeline.

## Test Record

The archive was extracted and executed only under the external temporary workspace. A fresh data directory was initialized, started on loopback port `13307`, queried over both Unix socket and TCP, and shut down cleanly. The repository remained at the frozen M4 state during this historical investigation.

## M5 Final Acceptance Addendum

M5 Slice 1 implemented and accepted a Vaelen-owned MySQL 8.4.11 ARM64 module. Final acceptance covered installation, initialization, generated credential handoff, loopback TCP `127.0.0.1:13306`, the Vaelen Unix socket, package/data separation, persistence across MySQL and Core restarts, surviving-process reconciliation, external termination detection, external port collision preservation, Laravel database write/read acceptance, and the browser-facing Laravel path.

Two final development-stack defects were found and fixed narrowly during browser verification:

1. FastCGI routes rewrote every request to `/index.php`, causing existing production assets under the document root to return Laravel 404 responses and leaving the Inertia page blank. Caddy now matches and serves existing document-root files before the FastCGI fallback. Non-existing application routes still use `/index.php`, and the file matcher remains rooted at the route document root.
2. DNS responder reconciliation derived `vaelendns` only from the active Core executable's sibling path. SwiftPM development outputs can place a valid responder in another directory within the same trusted `.build` tree. Discovery now accepts that controlled path drift while requiring the responder executable name, current user, expected port argument, and trusted Vaelen build root.

The static-file routing regression and DNS build-path reconciliation regression are covered by tests. Final browser verification served the Inertia HTML, production JavaScript, and production CSS without a Vite development server. No ADR changed.
