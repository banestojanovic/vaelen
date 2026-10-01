# PHP update-feed release readiness

The product now uses the stable HTTPS catalog location by default, and the
trusted workflow prepares a catalog only from CLI/FPM pairs whose published
bytes match their release manifests. Manual and automatic checks surface the
catalog-specific cause while retaining the last valid cache.

Hosted discovery and update installation remain blocked until the release
assets below are built by the trusted workflow and explicitly published. Do
not advertise the prepared local build as a trusted release. See
`RELEASE-PREPARATION.md` for current official PHP versions, proposed immutable
tags/assets, and the approval boundary. The stable catalog asset is
`php-catalog.json` at the `php-catalog` release tag.
