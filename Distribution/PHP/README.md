# Vaelen PHP Distribution

This directory contains versioned inputs for Vaelen-controlled PHP builds. It
does not contain PHP binaries.

The build uses a pinned `static-php-cli` source commit on an Apple Silicon
machine. `Scripts/build-php.sh` owns the build, validation, packaging, and
manifest steps; both local development and GitHub Actions invoke that script.

For M2 development, a successful local run is accepted as the bootstrap trust
root when CI is unavailable. This does not authorize public distribution:
`PUBLIC PHP DISTRIBUTION BLOCKED UNTIL CI PROVEN`. A CI-built artifact remains a
required future release gate.

The manifest's SHA-256 values verify artifact integrity against the selected
Vaelen trust root. SHA-256 alone is not an authenticity mechanism. Local M2
manifests identify `bootstrap-local-machine` as their trust root and are not
public-release authenticators. CI manifests identify the reviewed Vaelen
workflow and published release. A future signature or provenance layer can be
added without changing the package model.

The package build intentionally uses the static-php-cli build mechanism rather
than republishing its hosted unsigned PHP archives.

## Curated Runtime Catalog

Each supported PHP version has a checked-in build configuration such as
`php-8.4.23.json`. The configuration pins the static-php-cli source revision,
the exact PHP source version, extensions, and Vaelen's `cli`/`fpm` artifact
names. `Scripts/build-php.sh` emits a manifest containing the artifact URLs and
SHA-256 values after validating both executables.

When multiple Vaelen manifests are available, create the catalog shipped beside
the primary manifest with:

```text
Scripts/create-php-catalog.sh php-catalog.json \
  release/vaelen-php-manifest-8.4.23.json \
  release/vaelen-php-manifest-8.3.29.json
```

The catalog contains only complete macOS arm64 PHP manifests. Vaelen reads the
local catalog immediately and keeps installed runtime truth independent of its
availability. Release publication should upload the catalog beside the
versioned artifacts; no PHP version is advertised until its manifest and both
validated artifacts are published.

## Local M2 Bootstrap

Build and configure the local development distribution from the repository
root:

```text
Scripts/build-php.sh
Scripts/configure-local-php-distribution.sh
swift run vaelend
```

The second command independently checks the local manifest's bootstrap trust
mode and both artifact SHA-256 values, then writes a small configuration file
under `~/Library/Application Support/Vaelen/config`. The daemon reads that
Vaelen-owned configuration through the existing manifest-location abstraction.
No PHP binaries are copied into the repository, and no environment override is
required for normal `swift run vaelend` development.

`VAELEN_PHP_MANIFEST` and `VAELEN_PHP_ARTIFACT_BASE` remain explicit override
variables for isolated development/testing. Missing configuration continues to
produce an honest PHP distribution error.
