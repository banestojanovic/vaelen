# macOS service build spike

Date: 2026-10-26

This spike tests whether the selected source lanes produce usable native Apple Silicon runtimes without Homebrew in the build path. It is feasibility evidence only. The outputs are under `/private/tmp/vaelen-project-service-build-spike` and are not product packages.

## Pinned inputs

| Component | Source pin | SHA-256 or revision |
|---|---|---|
| PostgreSQL | Official 18.6 source archive | `983ee554ec53dbeb9b70797bef9fcf4e67e117e7e48ca1463cc80b3ff8e8ff3f` |
| ICU | Official 78.3 source archive | `3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0` |
| Valkey | Official 9.1.2 release commit | `7f1dffedff6de73058b2c2a389422b6ecd56c8fb` |

The PostgreSQL and ICU archive hashes matched the upstream-published values recorded during acquisition. The Valkey source was checked out at the exact release commit. Local `git verify-commit` could not run because `gpg` is not installed, so local signature verification remains open.

## Build and runtime evidence

- Builds ran with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and Xcode's macOS SDK. No Homebrew path or package was used.
- ICU 78.3 built as static libraries with static data packaging. Its license file is retained in the upstream source tree.
- PostgreSQL 18.6 built with `--with-icu`, using the locally built ICU static libraries and the macOS `libc++` runtime. The initial link failed because that C++ runtime was missing; adding `-lc++` resolved it.
- `initdb` initialized a fresh UTF-8 database with the ICU locale provider. An ICU `en` collation sorted `a`, `ä`, `z`; the query passed over both the local socket and TCP. PostgreSQL shut down cleanly.
- PostgreSQL `postgres` is arm64. `otool -L` reports only `/usr/lib/libz.1.dylib`, `/usr/lib/libSystem.B.dylib`, and `/usr/lib/libc++.1.dylib`. No ICU or Homebrew dynamic library is required by the executable.
- Valkey 9.1.2 built with `MALLOC=libc`. A fresh isolated instance returned `PONG`, `OK`, and `persisted`, then shut down. `valkey-server` is arm64 and `otool -L` reports only `/usr/lib/libSystem.B.dylib`.
- The manual spike binaries report `LC_BUILD_VERSION minos 27.0`. They do not prove compatibility with Vaelen's macOS 14 minimum. The repeatable recipe must set the deployment target in compile and link flags and inspect every packaged Mach-O load command.
- PostgreSQL executable SHA-256: `0518d80ca4fa9e74144600c523fe073a2dec1afce29be81cba100ed3408a3877`.
- Valkey executable SHA-256: `793f046518d46bf834446700a3edf6a82a0b2405b7edbdfb29a771552e64c9ff`.

## Relocation evidence

- Copying the PostgreSQL install tree to a new directory and hiding the original prefix failed immediately. `initdb` linked to `libpq.5.dylib` by its absolute build-prefix path.
- Rewriting PostgreSQL's internal library IDs and references to `@rpath/libpq.5.dylib`, then adding `@loader_path/../lib` to the affected executables, allowed a copied install to run while the original prefix was hidden.
- The relocated copy initialized a UTF-8 ICU database, sorted `a`, `ä`, and `z` with its default ICU collation, loaded PL/pgSQL, and shut down cleanly.
- The first ICU retry used the earlier SQL_ASCII fixture and was rejected by PostgreSQL. Reinitializing with `--encoding=UTF8 --locale-provider=icu --icu-locale=en` passed.
- Copying the Valkey install tree also passed `PING`, `SET`, and `GET` with its original prefix hidden, then shut down cleanly.
- PostgreSQL's official installation guide documents `--disable-rpath` for relocatable installs and says the build must provide another way to locate shared libraries. The reproducible build should combine that option with package-relative Mach-O library IDs and loader paths, then rerun the relocation check.

The official Valkey 9.1.2 release tarball was downloaded from the release tag and matched the Valkey project's published checksum: `19c23908e7d57e8d91ef85b41f5646307582f10f4f0fb999bbf89ed24ec9c983`. This is a better reproducible build input than relying on a local Git checkout whose commit signature could not be verified because `gpg` was unavailable.

## Initial license inventory

The Valkey 9.1.2 source Makefile links `libvalkey`, `hdr_histogram`, and `fpconv` into the server. Its CLI also links `libvalkey`, `linenoise`, and `fpconv`. The server build uses `MALLOC=libc`, so it does not link jemalloc. The build includes Lua sources and the Lua module. The source tree identifies these notices:

| Component | Source notice found | Follow-up |
|---|---|---|
| Valkey | `COPYING`, BSD-3-Clause notices | Keep the full notice in the product package. |
| libvalkey | `deps/libvalkey/COPYING`, BSD-3-Clause notices | Review all notices in the file and include them. |
| linenoise | BSD-3-Clause notice in `deps/linenoise/linenoise.c` | Include the copyright and conditions for the distributed CLI. |
| Lua | `deps/lua/COPYRIGHT`, MIT | Include the notice for the server and Lua module. |
| fast_float | `deps/fast_float/ffc.h` contains MIT, Apache-2.0, and Boost license text | Confirm the applicable grant and include the needed notices. |
| fpconv | `deps/fpconv/LICENSE.txt`, Boost, CC0, and BSD-2-Clause terms | Confirm applicable terms and include notices. |
| hdr_histogram | `deps/hdr_histogram/COPYING.txt` and `LICENSE.txt`, CC0 and BSD-2-Clause terms | Confirm applicable terms and include notices. |
| ICU | `LICENSE`, ICU license | Include with PostgreSQL if shipped separately or as a notice bundle. |
| PostgreSQL | `COPYRIGHT`, PostgreSQL license | Include with PostgreSQL. |

This is an inventory of files and build links, not a completed redistribution review. Valkey TLS was not enabled in this spike. The local source tree did not verify the signed Valkey commit because `git verify-commit` could not find `gpg`.

## Still required before shipping

- Turn the manual commands into a reproducible, reviewed build and packaging pipeline.
- Complete a license and notice audit for every linked or distributed upstream component, including Valkey's bundled dependencies and the exact PostgreSQL/ICU package contents.
- Verify upstream source authenticity with available signature tooling and define the release provenance policy.
- Produce a versioned package manifest with source pins, build options, artifact hashes, architecture, and license notices. The executable hashes above are local spike evidence, not release manifest entries.
- Test install, update, rollback, and uninstall while proving package removal never removes instance data.
- Sign/notarize the product-distributed artifacts and verify them through the normal updater path.

## Logs

The spike retains configure, build, install, initdb, server, query, and shutdown logs in the named temporary directory. The PostgreSQL ICU configure log includes `USE_ICU`; its `pg_config --configure` output records the exact ICU paths and flags.
