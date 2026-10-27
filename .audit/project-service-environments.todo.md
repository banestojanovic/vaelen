# Herd replacement workflow: project environments

The user clarified the intended outcome. This is not complete when Vaelen can list two new service types. It is complete when a PHP developer can move a real project from Herd to Vaelen and use Vaelen for the full local development loop without losing project or service data.

## Phase A. Frame

- [x] Read the Principles section of the poteto-mode skill.
- [x] Define a falsifiable completion predicate from the user request and current product gaps.
- [x] Record scope, rough effort, and blockers from the current implementation.
- [x] Preserve and account for existing dirty work before touching implementation files. The dirty PHP test, app-verification recipe, development note, Finder metadata, and verification artifacts remain untouched.

## Phase B. Design the workflow

- [x] Map current service lifecycle, project configuration, activation, IPC, CLI, and UI.
- [ ] Turn the successful PostgreSQL/ICU and Valkey arm64 build spikes into a reproducible, license-audited packaging lane and release checksummed manifest. The pinned-source builder, notices, checksum manifest, relocation/runtime verifier, and exact archive-root checks are implemented. Valkey repeats byte-for-byte; PostgreSQL repeatability, full license review, authenticated source provenance, signing/notarization, macOS 14 execution, and package/update lifecycle remain open. See `.audit/project-service-package-lane.todo.md`.
- [x] Compare service instance and project-binding data shapes against existing persistence and callers.
- [x] Write the final architecture decision and phased implementation plan before product-code changes.

## Phase C. Build in verified units

- [x] Add a portable, versioned project environment declaration covering PHP, Node, routing/TLS, and named service bindings while retaining readable version-1 files.
- [x] Baseline and verify the manifest slice before starting catalog/lifecycle implementation.
- [x] Add a read-only project adoption preview that inventories bounded project metadata, redacted `.env` facts, and Vaelen route/TLS evidence without mutation.
- [x] Add review and explicit confirmation for adoption choices, then apply only supported project declarations and service claims without rewriting `.env` or silently taking ownership of routes/data. Core issues a short-lived confirmation bound to project, route, discovery, and catalog evidence; it creates only a new V2 `vaelen.yml`, records explicit service claims, and leaves route ownership association for project activation.
- [x] Add the shared typed service instance model, SQLite schema-9 persistence, migration, deterministic inventory, and manual/project claim ownership without moving existing user data.
- [ ] Add independent PostgreSQL and explicitly named Redis-compatible package lanes and isolated instance lifecycles. PostgreSQL 18.6 and Valkey 9.1.2 named lifecycles are implemented. Package repeatability, full licensing review, authenticated provenance, signing/notarization, macOS 14, and distribution gates remain open.
- [ ] Expose exact instance inventory, setup, health, connection information, and safe lifecycle through Core IPC and `val`.
  - [x] List cataloged instances, package identities, endpoints, data paths, and ownership claims through `val service instances [--json]`.
  - [x] Create, inspect health for, and safely start/stop/remove exact named PostgreSQL instances through Core IPC and `val`.
  - [x] Add the same lifecycle for explicitly named Valkey instances, including default-port idempotency, process identity checks, stale-process recovery, write-failure cleanup, and real AOF value recovery across stop/start.
- [ ] Complete one project `up`/`down` reconciliation path for PHP, Node, site routing/TLS, and exact database/cache/mail instances.
  - [x] Add CLI `project up` (with `activate` compatibility alias) and `project down` over Core IPC.
  - [x] Select exact PHP patches or an eligible patch in a declared PHP family; select an eligible exact Node package.
  - [x] Associate a unique unchanged legacy route only after rechecking host, target, document root, TLS, and duplicate-host state.
  - [x] Reconcile exact PostgreSQL project claims, start stopped instances, verify health, release retired claims safely, and support down/up recovery.
  - [x] Create and converge project routes from explicit reviewed V2 intent; require healthy router, `.test` host, DNS, and standard ports, plus an already trusted Local CA for HTTPS.
  - [x] Support project bindings for the existing default MySQL and Mailpit singleton instances; project down releases claims and leaves both runtimes running.
  - [x] Support exact named PostgreSQL and Valkey 9.1.2 bindings. Project `up/down` converges multiple aliases, preserves shared owners, and retains final-owner claims when identity or stop verification fails.
- [ ] Complete ownership guarantees for every supported service; project down must leave instances running while another project or manual owner needs them.
  - [x] PostgreSQL and catalog claim behavior is covered for manual ownership, other project claims, failed identity/stop checks, and repeat up/down.
  - [x] Valkey project ownership is covered for multiple aliases, a shared manual owner, final-owner stop, and identity-unverified shared/final-owner behavior.
  - [x] Verify MySQL/Mailpit project claims, alias reuse, release-only behavior, removal exclusion, and process identity through focused tests and the real app/Core path.
  - [x] Implement Core startup recovery from durable project claims for MySQL, Mailpit, PostgreSQL, and Valkey. Controlled runtime tests cover exact identity, alias deduplication, healthy-state idempotence, unclaimed exclusion, mismatch refusal, failure isolation, stale-issue cleanup, and shutdown/mutation races.
  - [x] Verify package-backed project-service recovery using the installed Mailpit package through private Core and the actual `val project up/status/down` child. Both aliases recovered healthy with claims intact while global Mailpit intent stayed disabled.
  - [x] Reconstruct a Core dispatcher over persisted project claims and verify startup recovery with a controlled Mailpit runtime.
  - [x] Reopen SQLite claims under a fresh Core dispatcher and verify package-backed MySQL 8.4.11, PostgreSQL 18.6, and Valkey 9.1.2 recovery with changed healthy PIDs, intact claims, global MySQL intent off, and confirmed cleanup. Evidence: `/private/tmp/vaelen-core-project-recovery-evidence.puOW5Q/` (three service records, zero skips).
  - [ ] Restart the Core process executable and verify recovery through a new actual `val` child; the package-backed dispatcher reconstruction does not cover process launch, IPC reconnect, or app restart/update.
- [x] Add native Settings adoption review/apply and compact project controls that surface the same project state without creating persistent windows for every project.
  - [x] Add Core-backed project start-plan review, exact service binding display and recheck, explicit start confirmation, and ownership-scoped service-claim release with verified results.
  - [x] Add Core-token-backed adoption preview/review/apply with explicit PHP, Node, route, TLS, and PostgreSQL/Valkey choices; fail closed on incomplete discovery and consume the confirmation after any apply attempt.
  - [x] Build and inspect the populated adoption Settings fixture; controls stay disabled and cannot call Core in fixture mode.
  - [x] Verify project start/release controls against live isolated Core state, including refreshed status and ownership-scoped release. Mailpit remained healthy as PID 55591 after release; evidence is `artifacts/verification/project-mysql-mailpit-settings-20261027/result.txt`.
  - [x] Exercise adoption apply, stale-review rejection, persisted V2 state and exact claims, refreshed project state, unchanged `.env`, and isolated cleanup against a disposable live Core project. Evidence: `artifacts/verification/native-project-adoption-live-core-20261026-r3/` and commit `10b980a`.
- [ ] Add install, update, backup/recovery, diagnostics, and removal behavior sufficient to preserve data through normal product maintenance.
- [ ] Verify the complete adoption-to-working-site workflow on an isolated fixture and the installed Vaelen app.
  - [x] Core-level PostgreSQL project lifecycle sequence passes on isolated state; built `val` child passes the named PostgreSQL lifecycle fixture.
  - [x] Invoke built `val project adopt`, `up`, and `down` children through private Core; create HTTP and HTTPS routes from separate reviewed manifests and verify real Caddy/PHP-FPM responses, `.env` byte preservation, route retention, and repeated `up/down/up`.
  - [x] Verify the populated Projects Settings fixture visibly presents Start and Release Project Services controls, keeps them disabled in fixture mode, and preserves the compact single-window layout.
  - [x] Verify the populated project-adoption Settings fixture shows redacted project and service facts, explicit choices, and disabled fixture controls.
  - [ ] Repeat the adoption-to-working-site journey in the installed Vaelen app; verify native state agreement and user-trusted HTTPS.

## Phase D. Keep the audit trail

- [x] Append decisions and evidence to `.audit/project-service-environments.tsv` as each unit lands.
- [x] Review the trail against the actual changes and verification artifacts for the completed project lifecycle slice.

## Phase E. Verify and hand back

- [ ] Audit the completion predicate against Core, CLI, UI, persisted data, and runtime behavior.
- [ ] Complete an independent read-only review of the entire Herd-to-working-project goal and resolve its findings.
- [ ] Report verified behavior, open gaps, and the next remaining phase.

## Completion predicate

The goal is complete when a developer can move one real PHP project from Herd to Vaelen and use Vaelen for the normal daily local workflow. Vaelen must inspect the project and available existing state, present an adoption plan, and let the user review it before any ownership or configuration change. A portable project declaration must capture supported PHP and Node requirements, the local site and TLS intent, and exact database/cache/mail instances. One project-level `up` operation must install or activate only what the reviewed plan requests, report truthful readiness, and expose usable secret-safe connection information. The native app and CLI must agree on project state. `down`, app restart, update, recovery, and uninstall/package removal must preserve user project and service data, and shared services must remain running while another owner needs them. Vaelen must not silently rewrite `.env`, import credentials, change routes, kill external processes, select substitute versions or services, or delete data. Existing v1 project files and MySQL/Mailpit behavior remain usable. The complete Herd-to-working-project path is directly verified with isolated data and the installed app. This predicate excludes AI tools, public tunnels, deployment, and copying Herd Studio.

## Scope and risk

This is a multi-slice product effort across project discovery, package acquisition, long-lived service processes, project state, IPC, CLI, routing, and SwiftUI. The highest risks are accurately importing existing user intent, choosing maintainable arm64 artifacts, preserving durable instance data, preventing service shutdown while another project uses an instance, and keeping existing configuration readable. Package availability and licensing are open until checked against primary sources.

The goal does not include public tunnels, parallel branch workspaces, AI tooling, automatic `.env` edits, destructive data deletion, Herd Studio, or adding every service Herd supports. If the full workflow identifies these as an explicit blocker for the first target users, revise scope based on evidence rather than assuming feature parity is necessary.

## Current worktree

The implementation baseline is commit `5d071c4` on branch `dev`. The worktree has pre-existing changes in `PHPProviderDiscoveryTests.swift`, `docs/current-development.md`, the app verification recipe, Finder metadata, and untracked audit and verification artifacts; these remain preserved. The manifest foundation is integrated in the main worktree in `ProjectEnvironment.swift`, `ProjectReconciliation.swift`, and their focused tests. It adds typed V1/V2 specs and strict V2 parsing, blocks requirements the current planner cannot verify, and only reports secure routing when route-specific evidence is complete. Multiple static/proxy route TLS remains conservatively blocked because the current observation model cannot enumerate that full set.

## Current continuation

The completion predicate was broadened to one complete Herd-to-Vaelen project workflow after the user clarified that adding a service family alone is too small. The selected architecture is recorded in `architecture.md`. The first isolated implementation slice is integrated from `/private/tmp/vaelen-herd-manifest-foundation` (`codex/herd-project-manifest-foundation`) and was reviewed with one fresh read-only Sol reviewer after two fix rounds. Parent verification passed `Scripts/test.sh --filter ProjectEnvironmentTests`, `Scripts/test.sh --filter ProjectReconciliationTests`, and `git diff --check`. It does not yet activate V2 PHP/Node/web/service requirements; the planner explicitly blocks those until orchestration supports them.

The read-only adoption preview, explicit CLI review/apply, durable instance catalog/claims, and PostgreSQL named-instance lifecycle are integrated and independently reviewed. Apply creates only a new V2 `vaelen.yml`, preserves `.env`, revalidates short-lived review evidence, and claims only exact existing catalog services. Route selection is recorded in the declaration; route ownership association is applied only after fresh evidence. Focused adoption, CLI parsing, environment, reconciliation, catalog, inventory, and PostgreSQL lifecycle checks pass, as does the real built-`val` private-Core service lifecycle fixture. Adoption has not yet been driven through a private Core socket, and native Settings acceptance remains open.

Project `up/down` now supports PHP exact/family selection, eligible Node selection, safe legacy route association, reviewed route creation/TLS convergence, and exact PostgreSQL, Valkey, MySQL, and Mailpit project claims. Shared owners remain running, and final-owner claims remain when identity or stop checks fail. A live Debug app/Core journey reviewed and started Mailpit, then released only the project claim; the same process stayed healthy and fixture cleanup confirmed app, Core, process, and ports were stopped (`artifacts/verification/project-mysql-mailpit-settings-20261027/`). Core startup recovers exact project-claimed MySQL, Mailpit, PostgreSQL, and Valkey independently of global singleton intent, rechecks runtime/package identity, deduplicates aliases, isolates per-instance failures, and preserves claims. Controlled-runtime tests cover all four kinds and mutation/shutdown races. The installed Mailpit private-Core fixture exercises actual `val project up/status/down` children after stopping Mailpit, but recovery is triggered inside the already running Core. Package-backed recovery after dispatcher reconstruction passed for MySQL 8.4.11, PostgreSQL 18.6, and Valkey 9.1.2 using reopened SQLite claims and fresh service modules; three records show changed healthy PIDs, one preserved claim each, global MySQL intent off, confirmed stop/cleanup, and zero skips. Evidence: `/private/tmp/vaelen-core-project-recovery-evidence.puOW5Q/`. A newly launched Core executable and reconnecting actual `val` child, app restart/update recovery, installed-app acceptance, and package release gates remain open. The recovery runner, focused project suites, and Mailpit private-Core fixture passed; one fresh read-only Sol follow-up review found no actionable issues in the production recovery implementation. The unfiltered test run still fails on unavailable/mismatched PHP provider cache fixtures and a release expectation, so no whole-suite pass is claimed. Package output remains blocked on PostgreSQL repeatability, license review, authenticated provenance, signing/notarization, macOS 14 execution, and acquisition/update/distribution.

Native Settings now includes project start-plan review, exact V2 declaration/service-binding display, a spec-and-plan recheck before explicit activation, release of this project's service claims, operation verification, refreshed status, and Core-token-backed adoption review/apply. Adoption requires explicit PHP/Node selectors, one reviewed route, no route, or a fully declared new route, and exact PostgreSQL/Valkey instance bindings. It displays redacted endpoint facts and blocks incomplete discovery, unsupported HTTP routes, invalid aliases, fixture mutations, and reuse of a consumed confirmation. One read-only Sol review found and drove fixes for exact target confirmation, stale refresh overlap, mutation serialization, honest stop scope, TLS picker values, unsupported route representation, explicit document roots, and confirmation reuse. Official fixture builds, doctor, CUA inspection, cleanup, and offline PHP preflight passed for both lifecycle and adoption Settings fixtures. The focused adoption filter passed the exact PostgreSQL and Valkey package identifier case but also hit the unrelated existing `testProjectDownRetainsManualOwnerAndReleasesOnlyProjectClaim` failure at `Tests/VaelenIPCTests/ProjectAdoptionApplyTests.swift:127`. The isolated unfiltered `Scripts/test.sh` run still fails on DNS, project adoption, release, and unavailable/mismatched PHP provider fixtures; do not treat it as a passing suite. Live Core lifecycle acceptance, live adoption/token acceptance, and installed-app acceptance remain open.

Throughput checkpoint: typed manifest foundation, read-only adoption preview, explicit CLI adoption apply, durable catalog/claims, read-only instance inventory, PostgreSQL and Valkey named lifecycles, project-level PostgreSQL/Valkey/MySQL/Mailpit ownership, HTTP/HTTPS route CLI acceptance, native Settings lifecycle plus adoption review/apply, and Core startup recovery for all four claimed service kinds are implemented. Package-backed fresh-dispatcher recovery now covers MySQL, PostgreSQL, and Valkey; installed Mailpit recovery covers the actual `val` project journey with startup recovery triggered in private Core. A new Core process exercised through a restarted actual `val` client, app restart/update recovery, installed-app acceptance, and package release gates remain open.

## Named Valkey service lifecycle

Valkey 9.1.2 supports exact named create/status/start/stop/remove through Core IPC and `val`. The actual child fixture passed against the already generated checksummed local archive without downloading sources or installing a package. It verifies omitted-port idempotency, manual claim, nonempty data refusal, exact process/package/version/loopback-port/data health, cross-instance PID-spoof refusal, dead-process stop/start recovery, evidence-write cleanup, AOF value recovery across stop/start, running-remove refusal, and data retention after manual-claim release. RDB snapshot policy is configured but RDB file recovery is not directly tested. Evidence and commands are in `.agents/skills/verify-vaelen/features/service-instance-lifecycle.md` and the final rows of `.audit/project-service-environments.tsv`.

The next product goal is data-safe maintenance and recovery for an adopted project: verify Core restart recovery for project claims and service processes, define backup/restore behavior without touching project data by default, and verify the installed signed app's complete adoption-to-working-site journey. Package acquisition, licensing, provenance, signing, repeatability, and macOS 14 execution remain release gates.
