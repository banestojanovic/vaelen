# Core restart recovery for project service claims

## Definition of done

After Core restarts, every exact service instance with a durable project claim is observed by its owning runtime module and brought to healthy state if stopped. Duplicate aliases start the instance once. Unclaimed instances are not started. Identity, package, or health mismatches do not trigger a signal or substitute. Recovery failure for one instance does not prevent recovery of other claimed instances. The project-claim rows and service data remain intact.

## Throughput checkpoint

- **Blocking first steps.** Confirm the inventory claim shape and existing service identity checks. Add focused behavioral tests before implementation.
- **Independent workstreams.** Not applicable. Service selection, exact identity validation, and Core startup ordering share one recovery contract.
- **Shared mutable state.** One owner changes `ProjectServiceBindings` and Core startup wiring. No parallel writers touch the catalog or dispatcher.
- **Smallest safe decomposition.** One Luna implementation delegate owns the focused code and tests because all service kinds converge through the same claim inventory and recovery pathway. The parent reviews, verifies the full diff, and runs the private-Core acceptance.

## Phases

- [x] Ground current service claims and Core startup behavior.
- [x] Choose existing `ServiceInstanceInventoryEntry` and its `.project` claims as recovery input. Do not add a second desired-state store or schema.
- [x] Write tests for exact claimed recovery across MySQL, Mailpit, PostgreSQL, and Valkey, alias deduplication, unclaimed exclusion, idempotent healthy state, and failure isolation.
- [x] Implement and connect startup recovery after saved singleton intents and before routing recovery.
- [x] Run focused catalog/dispatcher tests and the real package-backed private-Core recovery acceptance; the installed Mailpit package was copied into a disposable support root, healthy recovery preserved two claims with global intent disabled, and the fixture was cleaned after Core and Mailpit shutdown were confirmed.
- [x] Resolve review finding 1 with a Core startup recovery barrier for ownership and service lifecycle mutations.
- [x] Resolve review finding 2 by clearing project-service failures whose claims no longer exist, with restart regression coverage.
- [x] Add and run deterministic blocked-startup mutation coverage for finding 1; project unlink remains blocked until startup recovery releases its barrier, then removes the claim.
- [x] One fresh read-only Sol review; resolved the shutdown and project PHP mutation barrier findings with deterministic regressions, reran the focused suite and installed-package private-Core journey, and received a clean fresh follow-up review.
- [x] Update the goal tracker and handoff with package-backed fresh-dispatcher recovery for MySQL, PostgreSQL, and Valkey; a new Core process through actual `val`, installed-app acceptance, maintenance/recovery, and package release gates remain open.

## Verified handoff

- Core startup recovers exact project-claimed MySQL, Mailpit, PostgreSQL, and Valkey records independently of global MySQL/Mailpit intent. Recovery checks persisted package and runtime identity, starts only stopped instances (plus installed Mailpit), confirms healthy state, deduplicates aliases, and records per-instance failures without releasing project claims.
- Startup recovery is serialized against project link/unlink/adoption/apply/up/down, project PHP selection mutations, singleton MySQL/Mailpit lifecycle, and named service-instance lifecycle. Waiting mutations recheck shutdown state before dispatching.
- Focused tests passed with `Scripts/test.sh --scratch-path /private/tmp/vaelen-project-claim-recovery-parent-review-fix-20261027 --parallel --num-workers 1 --filter 'ServiceInstanceCatalogTests|DispatcherTests|ProjectServiceBindingsEndToEndTests'`.
- The package-backed private-Core journey passed via `Scripts/tests/val-project-service-bindings-test.sh`; evidence and installed package hashes are in `artifacts/verification/project-service-bindings-20261027T071219Z-1086/`. It verified project service recovery using the installed Mailpit binary, actual `val project up/status/down`, two aliases, stable claims, disabled global Mailpit intent, and confirmed fixture cleanup. The harness triggers the startup recovery method in the running private Core; it does not restart the Core process. A separate dispatcher reconstruction test uses a controlled Mailpit runtime to verify recovery after Core object recreation.
- One fresh read-only Sol follow-up review found no actionable issues.
- Package-backed dispatcher reconstruction: `Scripts/tests/core-project-service-restart-recovery-test.sh` passed offline against the installed MySQL 8.4.11 package and verified local PostgreSQL 18.6 / Valkey 9.1.2 archives. Each service used a reopened SQLite store and a fresh dispatcher/module, recovered under a changed healthy PID, preserved its exact record and project claim with global MySQL intent disabled, then stopped and cleaned with confirmation. Evidence: `/private/tmp/vaelen-core-project-recovery-evidence.puOW5Q/` (three service records, no skips). This proves dispatcher reconstruction and package-backed module startup; it does not prove launching a new Core executable or reconnecting through a newly started `val` child.
- Remaining recovery evidence: launch a new Core process and invoke recovered services through a newly connected actual `val` child. Package-backed MySQL/PostgreSQL/Valkey dispatcher reconstruction is verified, and installed Mailpit recovery is verified through `val` while recovery is triggered inside private Core. The broader Herd-to-Vaelen goal also still needs app restart/update and data-safe maintenance/backup/removal behavior, signed installed-app adoption-to-working-site acceptance, package repeatability/licensing/provenance/signing/notarization/macOS 14/distribution gates.
