# PHP distribution

Vaelen installs PHP from a provider's prepared macOS packages. **Vaelen does not
compile PHP**, and it does not host PHP binaries of its own.

Provider configuration lives in exactly one file, `provider.json`. The refresh
script reads it, and Core carries the same values in `PHPPackageProvider`. When
the provider changes, update `provider.json` and refresh the catalog.

## Provider

| | |
|---|---|
| Provider | [static-php-cli](https://github.com/crazywhalecc/static-php-cli) |
| Generation | `v3` |
| Channel | `bulk` |
| Base URL | `https://dl.static-php.dev/v3/php-bin/bulk` |
| Update feed | `https://dl.static-php.dev/v3/php-bin/bulk/?format=json` |
| Notices | `https://dl.static-php.dev/v3/php-bin/bulk/license` |
| Platform | macOS arm64, minimum macOS 12.0 |
| Packages | one archive per SAPI: `php-<version>-{cli,fpm}-macos-aarch64.tar.gz` |

### Archived PHP 8.0 and 8.1 packages

The separate, generation-scoped `archive-v2` catalog pins prepared static-php-cli
bulk packages PHP 8.0.30 and 8.1.34 from
`https://dl.static-php.dev/static-php-cli/bulk`. Their exact archive digests,
sizes, deployment targets, required extensions, generation, and PHP license
notice are recorded in `legacy-catalog.json`; cache names include the source
generation so these bytes cannot collide with v3. The archived source is checked
independently from v3: absence of these families in v3 is not treated as a v3
failure. A failure to check either configured source leaves shipped/cached
options usable and reports the check as cached or unconfirmed, not current.

Both packages were tested from their actual macOS arm64 bytes. PHP 8.0.30
requires macOS 14.0; PHP 8.1.34 requires macOS 12.0. Vaelen itself currently
requires macOS 14.0. Both packages meet the full required-extension contract,
have no Homebrew/runtime library dependencies, and retain the provider's PHP
license notice beside the managed install. PHP 7.4 has no matching prepared
arm64 macOS CLI/FPM pair in the inspected provider feeds; it is deliberately
not advertised as installable.

### Why `bulk`

The provider's older `/static-php-cli/bulk/` channel tops out at 8.5.9 and is
months behind. Its `v3` successor `/v3/php-bin/common/` is current — it listed
8.5.11, 8.4.26, 8.3.33 and 8.2.33 built the same day — but the actual macOS
binaries **do not carry `intl`, `mysqli` or `sodium`**, which the product
requires. That is a property of those builds, established by running the real
macOS `php -m`, not by filename or by a Linux build manifest.
`v3/php-bin/bulk/` is the same current generation and satisfies the full
contract, so it is the channel Vaelen uses.

`common` was not adopted because weakening the required extension list to make a
channel pass would be dishonest: real projects depend on those extensions.

### Why not Homebrew bottles

A Homebrew `php` bottle links against ~21 other Homebrew formulae (openssl@3,
icu4c, libzip, sqlite, freetds, net-snmp, unixodbc, libpq, …). Vaelen's PHP would
then depend on packages Vaelen does not own and could collide with the user's own
Homebrew PHP. These packages link only against system libraries, so they are
self-contained and cannot adopt an external runtime.

## Caching

Downloads are cached under `.build/php-provider/<generation>/<channel>/<version>/`,
**scoped by generation and channel**. Artifact filenames are identical across
generations, so a shared cache would let Vaelen pin one generation's bytes under
another generation's version. Tests resolve the same scoped cache.

`VAELEN_PHP_EXTRA_VERSIONS=8.4.23` caches extra published versions without
adding them to the shipped catalog. Update acceptance needs a real same-family
predecessor to update from; the catalog itself only ever carries the newest patch
of each supported family.

## Integrity and trust model

The provider publishes **no checksums and no signatures**. Vaelen therefore
cannot authenticate a digest against a provider signature. What it actually does:

* **Review-pinned versions** — `refresh-php-catalog-from-provider.sh` downloads
  the provider's bytes, records their SHA-256 and exact sizes, and pins them in
  the catalog shipped inside the signed app. Install refuses any archive whose
  digest does not match the pin.
* **Runtime-discovered versions** — a periodic or manual check may find a newer
  patch. Vaelen downloads it over the provider's HTTPS origin (restricted to a
  host allowlist that includes the object-storage host the provider redirects to)
  and records the digest it received, then re-verifies every later transfer and
  reinstall against that record.

That recorded digest is a **local integrity record**, not independent provider
authentication. It proves the install matches what was downloaded and that later
reuse is unmodified. It does not prove the provider signed anything, because the
provider signs nothing. Discovered versions carry
`digestPinnedByReview: false` so this distinction stays visible in the manifest.

This is stated plainly rather than papered over: Vaelen does not fabricate
trusted-checksum metadata it does not have.

## Refresh the catalog

```bash
./Scripts/refresh-php-catalog-from-provider.sh
```

Reads the provider feed, selects the newest patch of each supported family,
downloads both prepared packages, records SHA-256 and exact byte sizes, validates
the extracted binaries exactly as the product does at install time, writes
`Sources/VaelenCore/Resources/php-catalog.json`, and bundles the configured
bundled family.

A version is pinned only if it passes every check:

* both `cli` and `fpm` archives are published for it;
* both binaries are `Mach-O 64-bit executable arm64`;
* neither requires a macOS newer than Vaelen's minimum (12.0);
* neither links to `/opt/homebrew`, `/usr/local`, or Herd;
* `php -v` reports the exact version the catalog claims;
* every extension in `requiredExtensions` is loaded;
* the provider's FPM binds and then releases a private socket.

Optional extensions are reported, never required. On the current channel Imagick
is present and functional (`ImageMagick 7.1.2-29 Q16-HDRI`).

## Bundled runtime

### Build preparation

Git tracks `bundled-runtime.json`, archive and binary SHA-256 pins, and license
notices. The two large raw executables are generated resources and are ignored;
they are not Git or Git LFS payloads.

On a fresh checkout, before a direct Swift package build or test:

```bash
./Scripts/prepare-bundled-php
swift build
```

Xcode's `embed-vaelend.sh` invokes the same preparation before its Core build,
including when the signed app updater builds the app. Preparation requires
Python 3, verifies existing resources without replacing them, otherwise reuses
the digest-verified `.build/php-provider/<generation>/<channel>/<version>`
archives or downloads only the descriptor's exact pinned archives. Newly
downloaded archives are cached by digest beneath `.build/php-provider/archives`.
Both binary digests are checked before publishing resources by atomic file
replacement. Archive paths, links, special files, and unexpected files are
rejected. Nothing compiles PHP, chooses a newer version, or changes the catalog.

For an offline build, retain the verified generated resources or their pinned
archives and run:

```bash
./Scripts/prepare-bundled-php --offline
swift build
```

Offline preparation fails if it cannot obtain a complete verified pair from
resources or pinned cached archives; it never silently omits offline activation.
Deleting `.build` removes cached archives; a fresh checkout with no retained
resources needs one online preparation.
The focused preparation regressions run with
`python3 Scripts/prepare-bundled-php-tests.py` and use only isolated fixtures.

### Runtime payload

The script also writes `Sources/VaelenCore/Resources/PHPBundledRuntime/`
containing the configured `bundledFamily` (currently 8.5): `php`, `php-fpm`, a
`bundled-runtime.json` record with the binaries' digests, and the provider's
notices under `license/`.

First activation needs no download. The bundled pair is digest-verified against
the signed bundle's own record, then installed through the **same** managed
package path a download uses: validation, ownership metadata, per-version INI
files, and notices retained beside the installed package.

**Bundling starts nothing.** Presence of the bundle is not presence of an
installed runtime: no FPM is started, no default changes, and no project is
touched until the user activates PHP.

Notices are the provider's per-component licenses (63 files, including
`php-src_LICENSE.txt`). PHP and every statically linked library carry their own
license; the build tool's MIT license does not cover them.

## How the product uses it

`Sources/VaelenCore/Resources/php-catalog.json` ships inside the signed app and is
the only PHP source an installed Vaelen needs. `PHPModule.bundled()` serves it,
so PHP is available with no distribution configuration, manifest path, or
environment override.

* Install verifies SHA-256 against the pin before extraction, then re-validates
  the extracted binaries — architecture, minimum macOS, isolation, exact version,
  and the required extension set — before publishing the package.
* Archive entries that would escape the staging directory are rejected.
* Remote artifact URLs are validated for HTTPS and an allowlisted host before any
  request.
* **Update discovery.** Periodic and manual checks fetch the provider feed and
  discover newly published compatible patches, recording them so they can be
  installed without a new Vaelen release. A discovered version *is* installable:
  it arrives over the verified HTTPS origin, and Vaelen records the digest it
  received as a local integrity record, then re-verifies every later transfer and
  reinstall against that record. A version the provider advertises but a check has
  not yet recorded is reported separately as *not yet installable*, so it is never
  offered as if it were ready.
* A check that cannot confirm the provider still serves the pinned versions leaves
  availability marked cached with a retryable cause. It is never reported as
  current, and the last usable catalog is preserved.
* Checks share one mechanism and one ~12-hour persisted cadence, deduplicate
  concurrent requests, and run once on startup when overdue without blocking the
  interface.
* A `VAELEN_PHP_MANIFEST` override or `config/php-distribution.json` still takes
  precedence for local development, but only when the configured manifest actually
  exists and is usable — a stale pointer cannot disable the provider.

## Version presentation

The Settings list shows installed runtimes newest first, each with its exact
patch, running state, default role, and project use. Nothing is kept solely for
rollback: a successful update removes the superseded package.

The sidebar update indicator is a **per-family** claim: once the newest patch of a
line is installed, that line no longer needs an update.

## Update behaviour

* An update is requested with an explicit **source runtime**. Core validates it
  before installing anything: it must be installed, in the target's family, older
  than the target, and still present. A stale, missing, or wrong-family source is
  rejected with a specific reason instead of quietly updating another runtime.
* Before any mutation, the update refuses when the source is still required: an
  exact-version project pin names the affected projects, and a persisted route
  no project owns names the stranded hostname. Pins are never silently migrated.
* Updating a running default installs the replacement, hands the default role
  over, starts it, and requires it to become healthy. If it does not, the update
  fails and the previous default is left alone.
* Updating a stopped non-default runtime starts nothing and does not change the
  global default.
* Saved settings follow the replaced runtime to the replacement, and the shared
  defaults are untouched. A reinstall restores the removed version's saved
  settings.
* After verified convergence — replacement healthy, default handed over, routes
  converged — the superseded runtime is stopped through ownership-checked
  lifecycle control, its package and generated runtime artifacts are removed, and
  its start intent is retired. Verified download caches stay for fast
  reinstallation but never count as installed runtimes.
* While the update is incomplete, the working source is preserved and the outcome
  is reported as partial success with a targeted retry rather than as a finished
  update. Cleanup failures are reported specifically; complete success is never
  claimed when cleanup failed.
* Projects with an explicit PHP pin are never migrated by an update; the user
  chooses migration.

## Adding or refreshing a version

1. Run `./Scripts/refresh-php-catalog-from-provider.sh`.
2. Review the diff to `Sources/VaelenCore/Resources/php-catalog.json`.
3. Run `swift test --filter PHPProvider`, which proves the shipped pins still
   match the provider's real bytes and exercises real install, update, and removal.
4. Ship the app. There is no release, tag, or asset publication step.
