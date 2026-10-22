# Node release provenance

The first Node catalog contains macOS arm64 releases 24.22.1 and 26.12.1. Version aliases and x64 packages are unsupported.

The release manifests, signatures, and signing public key are retained in `Sources/VaelenCore/Resources/NodeProvenance`. The catalog pins archive SHA-256 values from the signed manifest. Installation verifies that digest before decompression, extraction, or executable probing.

## Authentication evidence

On 2026-10-22, the official [Node README release-key list](https://github.com/nodejs/node#release-keys) listed fingerprint `5BE8A3F6C8A5C01D106C0AD820B1A390B168D356` as an active release key for Antoine du Hamel. The public key came from the [Node release-keys repository](https://github.com/nodejs/release-keys/blob/main/keys/5BE8A3F6C8A5C01D106C0AD820B1A390B168D356.asc).

PGPy verified each cleartext manifest signature against that exact fingerprint. This verifies the manifest signature cryptographically. PGPy reports that its self-signature, revocation, and key-flag checks are incomplete. Authorization of the pinned primary key was checked against the current official key list. No runtime OpenPGP validation is claimed.

| Version | Signed manifest | SHA-256 of retained signed manifest | Archive SHA-256 | Bundled npm |
| --- | --- | --- | --- | --- |
| 24.22.1 | [Official signed manifest](https://nodejs.org/dist/v24.22.1/SHASUMS256.txt.asc) | `458c81e98060760ddadc152cd6d2a06e1d5b8cc8018863758e9f64fe72abc809` | `89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7` | 11.19.1 |
| 26.12.1 | [Official signed manifest](https://nodejs.org/dist/v26.12.1/SHASUMS256.txt.asc) | `59a22122b4b3c9c7348764af25a94eda1c9f1de2274ad635b402daa3a4a253a9` | `1901d539912c02afa10d1cc126943a8855a7eedebe830119463470db5e6c59e8` | 11.20.0 |

The downloaded arm64 archives matched these signed digests. The official 24.22.1 archive contains 4,797 regular files, 1,088 directories, and three symlinks. The 26.12.1 archive contains 4,743 regular files, 1,083 directories, and two symlinks. Both use ustar entries without PAX extensions. The installer supports those entry types and rejects hard links, special files, extensions, duplicate paths, traversal, escaping links, and entries under symlink parents.

The catalog also binds each receipt to the full authenticated archive contents. Compute each regular-file SHA-256 and retain each symlink target. Sort paths separately for files and links. Hash the UTF-8 concatenation of `F\0PATH\0DIGEST\n` for files followed by `L\0PATH\0TARGET\n` for links. These manifest digests are `9d88d435cc73b19ad457e9e0d938458bd85a242c1ec222b2b7d1e24d09f60a90` for 24.22.1 and `56bc8b5d2fb81060b8ed5b3bfbcd64dc33d76dc038b2a74babc66c876f875f00` for 26.12.1. Resolution rejects changed receipt hashes and extra package files or links.

## Reproduce signature verification

With GnuPG available, use the retained files in a disposable keyring. The expected primary fingerprint must match before verification.

```bash
gpg --no-default-keyring --keyring /tmp/vaelen-node-review.gpg --import Sources/VaelenCore/Resources/NodeProvenance/release-key.asc
gpg --no-default-keyring --keyring /tmp/vaelen-node-review.gpg --fingerprint
gpg --no-default-keyring --keyring /tmp/vaelen-node-review.gpg --verify Sources/VaelenCore/Resources/NodeProvenance/24.22.1-SHASUMS256.txt.asc
gpg --no-default-keyring --keyring /tmp/vaelen-node-review.gpg --verify Sources/VaelenCore/Resources/NodeProvenance/26.12.1-SHASUMS256.txt.asc
```

GnuPG was unavailable in the implementation environment. The recorded implementation check used PGPy in a disposable Python environment, loaded the retained key with `PGPKey.from_blob`, asserted its fingerprint, loaded each manifest with `PGPMessage.from_blob`, and required `key.verify(message)` to succeed.

## Installation and resolution limits

The downloader permits only the fixed HTTPS Node origin and refuses redirects. Downloads are bounded to 100 MiB and 90 seconds. Decompression is bounded to 512 MiB and 30 seconds. Each archive entry is bounded to 256 MiB, and archives are limited to 20,000 entries.

Packages are built under a private stage within the destination filesystem. Publication uses `renamex_np` with `RENAME_EXCL`, so an existing destination is never replaced. The ownership receipt records the release identity and each regular-file digest and symlink target. Existing packages require a valid receipt and matching contents. The installer probes exact Node version, Darwin platform, host architecture, npm version, and npm entry point before publication.

The offline reader accepts only SQLite schema 8 in rollback-journal format. WAL state and sidecars are rejected before opening SQLite. It opens with `SQLITE_OPEN_READONLY`, checks integrity, and selects project identity and Node pins. It does not instantiate `SQLiteStateStore`, prepare directories, migrate, repair, set journal mode, or contact Core.

The Node IPC additions use distinct `nodeRequest` and `nodeResult` wrappers. IPC compatibility remains 7 because existing request and result shapes, including PHP resolver requests used by the copied PHP shell binary, are unchanged. SQLite schema compatibility is independently checked by the offline Node reader. Older state produces an explicit error until Core upgrades it.

The Projects Settings selector can pin an exact Node release to a linked project. `val node exec -- COMMAND...` and the opt-in zsh `node`/`npm` wrappers apply that pin when invoked from the project. Without shell integration, ordinary shell commands continue to use the invocation `PATH`. Installed-app acceptance is not claimed by this slice.
