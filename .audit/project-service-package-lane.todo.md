# Project service package build lane

## Architect phases

- [x] Ground. Read the package spike and build inputs; verify relocation behavior against copied installs.
- [x] Sketch. Compare a single-driver design with a Make-owned immutable artifact graph, then choose one owner for the package contract.
- [x] Agree. Proceed without a checkpoint because the user asked to continue the goal and made no approval gate.
- [x] Implement. Build a pinned arm64 package lane with checksummed output and relocation smoke coverage. PostgreSQL repeatability remains an explicit open gate.
- [ ] Scrap. Revisit the sketch only if implementation shows repeated workarounds or a wrong boundary.

## Throughput checkpoint

- [x] **Blocking first steps.** Confirm source archive pins, macOS target, package layout, and relocation assumptions before implementation.
- [x] **Independent workstreams.** None. PostgreSQL, ICU, Valkey, package output, and its manifest share one build pipeline and should be owned together.
- [x] **Shared mutable state.** Use a private temporary build root and explicit output directory. Do not edit upstream source archives or the canonical checkout during builds.
- [x] **Smallest safe decomposition.** One Luna implementation owner is appropriate because the build script, package manifest, and relocation checks are one coupled deliverable. The lead owns shape, verification, and integration.

## Acceptance

- [x] Download or reuse only the pinned PostgreSQL 18.6, ICU 78.3, and Valkey 9.1.2 source archives after SHA-256 verification.
- [x] Build arm64 packages with the project minimum macOS target and no Homebrew runtime dependency.
- [x] Produce a versioned manifest with source pins, build options, package archive digests, architecture, and included license notices.
- [x] Extract each archive under a different prefix while hiding its build install prefix; initialize and use PostgreSQL with ICU and Valkey, then stop both cleanly.
- [ ] Preserve the full legal/provenance review as an open release gate; this lane does not claim shipping approval.

## Current evidence and remaining gates

- Two independent fixed-prefix builds both pass the standalone verifier, including fresh extraction, PostgreSQL initialization with ICU and PL/pgSQL, Valkey PING/SET/GET, and clean shutdown.
- Valkey is repeatable on this host and toolchain: both archive digests are `c66a00031a445c96474c8a9d95071ea74d5cd6b4d13b55f25b66d1a5f72477a5` with zero payload inventory differences.
- PostgreSQL is not yet repeatable: archive digests are `c80bd521a3270bb0fa29a0f7c0e5af9c70535f445eb84335b8e0b57cfa14d611` and `956e8120bc584fc11fa376c97c9bcdddf2b4f5cd6a62dced84a10726a6225d57`. Only `bin/postgres` differs; its Mach-O UUID and build-root suffixes embedded in configure arguments vary. Do not strip the UUID or rewrite the binary to claim repeatability.
- The emitted manifest records same-host repeatability separately for each package. Its release gates remain open for complete license review, authenticated upstream provenance, signing/notarization, and execution on macOS 14.
- The verifier inventories the exact expected package root and rejects files or additional roots beside it. Focused fixture suite: 12 tests passed. The wrapper test and `Scripts/test.sh --filter ProjectEnvironmentTests` passed in the canonical checkout.
- The independently reviewed archive-root issue is fixed and covered by two negative fixtures. No files or binary outputs are committed by this work.

## Evidence

- Initial PostgreSQL relocation failed because `initdb` linked to `libpq.5.dylib` at the build prefix.
- Rewriting PostgreSQL internal Mach-O references to `@rpath/libpq.5.dylib` and adding loader-relative library search paths allowed the copied package to initialize and run with the original prefix hidden. ICU sorting and PL/pgSQL passed.
- A copied Valkey package ran `PING`, `SET`, and `GET` with its original prefix hidden.
- The Valkey 9.1.2 source tarball matched the Valkey project's published SHA-256 `19c23908e7d57e8d91ef85b41f5646307582f10f4f0fb999bbf89ed24ec9c983`.

## Architecture choice

Use one Python standard-library driver with a closed PostgreSQL and Valkey recipe set, one source lock, immutable checksum-verified source archives, fresh build workspaces, one archive writer, and one output manifest. Publish the complete package directory atomically only after both extracted packages pass inventory, Mach-O, and runtime checks. Keep a separate `verify` command so maintainers can validate received archives without rebuilding them.

The alternative was a Make-owned DAG with immutable receipts for source, ICU, engine install, package tree, and archive stages. That structure can reuse expensive builds and schedule PostgreSQL and Valkey independently, but requires receipt schemas, invalidation, concurrency locking, moved-workspace rules, and recovery when a smoke test hides an install prefix. No measurement shows that avoiding rebuilds or adding parallelism warrants this state for two packages. Keep only source archives in the verified cache. Build artifacts remain private to one invocation.

The two architecture drafts converged on the one-driver design. A separate graph candidate then specified the DAG and receipt design. One read-only Sol cross-check scored both original drafts 22/25 and recommended the driver with atomic directory publication, exact payload inventories, notice checks, and whole-package relocation checks. All design seats used the same model family, so this was independent-context comparison rather than model-diverse review.

The manifest will be an aggregate `manifest.json` for the fixed pair. It records package identities, source and recipe hashes, captured toolchain, platform and deployment target, sorted payload inventories, notice-file digests, archive names and SHA-256 values. It excludes temporary paths and wall-clock values. Canonical archive bytes are expected to repeat for the same prepared payload; bit-for-bit native source builds remain an open question.
