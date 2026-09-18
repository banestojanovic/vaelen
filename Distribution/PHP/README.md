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
