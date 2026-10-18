# M2 Phase B Local Development

> Superseded for PHP distribution. `Scripts/build-php.sh` and
> `Scripts/configure-local-php-distribution.sh` were removed when Vaelen stopped
> compiling PHP. PHP now comes from the provider catalog shipped inside the app;
> see `Distribution/PHP/README.md`. This document is kept as the M2 record.

Phase B consumes the Phase A bootstrap manifest through a manifest-location
abstraction. The normal local bootstrap procedure is:

```text
Scripts/build-php.sh
Scripts/configure-local-php-distribution.sh
swift run vaelend
```

The configure command verifies the generated local manifest and artifacts, then
writes the Vaelen-owned local pointer under Application Support. Development
runs may also use explicit overrides for isolated testing:

```text
VAELEN_PHP_MANIFEST=/path/to/vaelen-php-manifest.json
VAELEN_PHP_ARTIFACT_BASE=/path/to/release
```

The artifact base is a development override only. Production must use the
Vaelen release manifest and release artifact source; no local build path is
part of the runtime architecture.

PHP packages are installed at:

```text
~/Library/Application Support/Vaelen/packages/php/<exact-version>/
```

Downloads and staging use the centralized Vaelen cache paths. Both CLI and FPM
archives are SHA-256 verified against the manifest, extracted into staging,
validated, and atomically published. Installed package metadata records the
source, exact version, architecture, checksums, and installation time.

The Phase A local bootstrap remains accepted for development and architecture
validation only. Its local-machine trust root does not provide independent
cryptographic authenticity.

**PUBLIC PHP DISTRIBUTION BLOCKED UNTIL CI PROVEN**

M2 does not implement Caddy, routing, DNS/TLS, project-aware PHP selection,
Composer management, framework drivers, or a global shell shim.
