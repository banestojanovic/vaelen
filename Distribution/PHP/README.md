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

Each supported PHP patch line has a checked-in build configuration. Current
patches follow PHP's official release announcements: PHP 8.4.26 (released
2026-09-24) and PHP 8.3.33 (released 2026-07-30). Sources:
<https://www.php.net/releases/index.php> and
<https://www.php.net/supported-versions.php>. 8.4 remains actively supported;
8.3 receives security support through 2027-12-31. These are the two existing
Vaelen-supported minor lines; 8.5 is not added to this candidate.

The configurations `php-8.4.26.json` and `php-8.3.33.json` pin the static-php-cli source revision,
the exact PHP source version, extensions, and Vaelen's `cli`/`fpm` artifact
names. `Scripts/build-php.sh` emits a manifest containing the artifact URLs and
SHA-256 values after validating both executables.

The stable production catalog URL is
`https://github.com/banestojanovic/vaelen/releases/download/php-catalog/php-catalog.json`.
The product and local distribution setup use this URL by default; users do not
enter it. The `php-catalog` release asset is updated by the trusted tagged
workflow. Runtime packages remain at immutable `php-v<version>` release URLs.

When multiple validated Vaelen manifests are available, create a catalog with:

```text
Scripts/create-php-catalog.sh php-catalog.json \
  release/vaelen-php-manifest-8.4.26.json \
  release/vaelen-php-manifest-8.3.33.json
```

The catalog generator requires trusted manifests, exact version-derived release
tags, HTTPS asset URLs, and SHA-256 CLI/FPM checksums. The release workflow also
downloads each prior pair and checks its bytes against the manifest before
including that entry. A version is omitted unless its pair is present and
verified. Hosted publication is still subject to explicit approval.

The bundled bootstrap catalog is intentionally empty until those release pairs
exist. It no longer advertises the former localhost or missing-release assets;
installed runtimes remain visible and usable, and update availability is
visibly marked unconfirmed/failed until the HTTPS catalog can be refreshed.

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
