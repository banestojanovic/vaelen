# M2 Phase A Local Bootstrap

Status: **accepted for M2 development only**

## Provenance

The M2 bootstrap PHP artifacts were produced by the Vaelen-controlled build
pipeline on the developer's local Apple Silicon Mac because GitHub Actions was
unavailable for an external account/billing reason. These artifacts are
accepted for local M2 development and architecture validation only. CI-built
artifacts remain required before Vaelen's PHP distribution mechanism is ready
for public release.

The local machine is the bootstrap trust root. The local manifest's SHA-256
values provide artifact integrity checks against that manifest; they do not
provide independent cryptographic authenticity.

## Build

- Build host: developer Apple Silicon Mac
- macOS: 27.0, build 26A428
- Architecture: arm64
- PHP: 8.4.23
- static-php-cli: 2.8.5
- static-php-cli commit: `4318ef8fa32a02460ec1554746674a7bc42b49fa`
- Build entrypoint: `Scripts/build-php.sh`
- Configuration: `Distribution/PHP/php-8.4.23.json`
- Build result: fresh CLI and FPM binaries built from the pinned source commit

The shared build entrypoint performs source checkout, tool build, source and
library preparation, CLI/FPM compilation, intermediate validation, license
preservation, deterministic packaging, final extraction, final validation, and
manifest generation. GitHub Actions invokes the same entrypoint.

## Artifacts

- `php-8.4.23-cli-macos-arm64.tar.gz`
  - SHA-256: `339c841f264ac7f1482535a8e31592a6dc704d59b8d9b93d9cd9312d38f2e65b`
- `php-8.4.23-fpm-macos-arm64.tar.gz`
  - SHA-256: `035686d5e79c8c651507f34790cc13c4ea33e6f778ab01fa588db338767f80e2`

The artifacts were independently hashed after manifest generation and both
values matched the manifest. The manifest identifies its trust mode as
`bootstrap-local-machine`.

## Validation

- CLI validation: passed; PHP 8.4.23, arm64 Mach-O executable
- FPM validation: passed; PHP-FPM 8.4.23, arm64 Mach-O executable
- Extension validation: passed for the configured required extension set
- Imagick: passed; ImageMagick 7.1.2-31, Q16-HDRI, aarch64
- Dynamic dependencies: passed; only macOS system libraries/frameworks and `libc++`
- FPM UDS: passed; current-user startup created the temporary UNIX socket
- FPM shutdown: passed; clean termination removed the socket
- Packaging: passed; both archives extracted into a clean temporary directory
- Clean extracted execution: passed for `php -v`, `php -m`, and `php-fpm -v`
- Final packaged-artifact validator: passed
- Manifest validation: passed
- Independent SHA-256 verification: passed

`file` reported both binaries as `Mach-O 64-bit executable arm64`. `otool -L`
reported only:

- `/usr/lib/libresolv.9.dylib`
- `/usr/lib/libSystem.B.dylib`
- `CoreFoundation.framework`
- `CoreServices.framework`
- `SystemConfiguration.framework`
- `/usr/lib/libc++.1.dylib`

No Homebrew or Herd runtime dependency was present.

## Repository Checks

- Shell syntax validation: passed
- JSON validation: passed
- `git diff --check`: passed
- `swift test`: passed, 14 tests

## Release Gate

**PUBLIC PHP DISTRIBUTION BLOCKED UNTIL CI PROVEN**

The local bootstrap artifact is sufficient to continue M2 runtime development
and Phase B architecture work. It must not be treated as a public release
artifact. Future public distribution requires the same pinned build and
validation to succeed in Vaelen-controlled CI, followed by the Vaelen release
manifest and installer verification flow.
