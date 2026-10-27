# Project MySQL and Mailpit bindings

## Phase A. Frame

- [x] Read the pstack Principles and the installed Codex mapping before choosing the workflow.
- [x] Record a falsifiable completion predicate, scope, baseline, effort, and blockers.
- [x] Preserve the existing dirty workspace and use it as the implementation baseline.

## Phase B. Design the workflow

- [x] Ground existing project binding, singleton service, and removal flows.
- [x] Compare two structurally distinct designs for mapping the singleton services to project claims; screen both against the architect red flags.
- [x] Select one design and record the synthesis rationale before implementation.
- [x] Keep the implementation to one owner because catalog identity, project claims, runtime state, and app selection must agree.

## Phase C. Build in verifiable units

- [x] Add planner tests first for exact default MySQL/Mailpit identity, health states, and mismatch blocking.
- [x] Add catalog projection and project claim handling for the existing default singleton instances without moving service data.
- [x] Extend project up/down so it starts only an explicitly bound, supported service, retains claims on failed starts, and never stops the legacy singleton on project down.
- [x] Prevent service package removal while a project claims the singleton.
- [x] Expose MySQL and Mailpit in native adoption selection and project status without exposing secrets.
- [x] Verify V1 project manifests and existing global service controls remain compatible through focused Core/UI model tests.
- [x] Verify focused tests and the disposable built-`val`/private-Core path; `.env`, source package bytes, and service/Core process cleanup pass in `artifacts/verification/project-service-bindings-20261027T055046Z-20630/`.
- [x] Verify the live Debug Settings start/release path against an isolated Core and inspect it with CUA; retain ownership, process, `.env`, and cleanup evidence in `artifacts/verification/project-mysql-mailpit-settings-20261027/`.
- [x] Run one fresh read-only Sol review and resolve accepted findings. The reviewer identified asynchronous stdout drain and fixture cleanup gaps; one Luna fix round addressed both, and the reviewer found no remaining issue after bounded timeout cleanup was added.

### Review regression set

- [x] Two aliases for one stopped singleton both report successful `up`, with only one runtime start.
- [x] Omitted-version singleton binding is blocked before catalog materialization and accepted only after exact catalog identity exists.
- [x] Successful package removal clears the matching unclaimed catalog/manual identity; a project claim blocks before callback effects across two repository connections.
- [x] Singleton release path has no stop capability; PostgreSQL/Valkey retain final-owner stop behavior.
- [x] Native kind choices only include kinds with eligible inventory entries and changing kind selects a valid instance.

## Phase D. Keep the audit trail

- [x] Append implementation and verification decisions to `.audit/project-service-environments.tsv`.
- [x] Update the main Herd-replacement roadmap only with evidence verified in this unit.

## Phase E. Verify and hand back

- [x] Review the scoped diff, rerun focused checks in the canonical dirty checkout, and confirm no unrelated source or artifacts were overwritten. The parent run passed `MailpitModuleTests`, `ProjectServiceBindingsEndToEndTests`, and the multi-alias dispatcher test; `Scripts/tests/val-project-service-bindings-test.sh` also passed in `artifacts/verification/project-service-bindings-20261027T061517Z-64023/`.
- [x] State precisely which MySQL/Mailpit project behavior is verified and which full-goal gates remain open in `.audit/handoffs/mysql-mailpit-bindings-2026-10-26.md`.

## Completion predicate

A V2 project can bind only the existing exact default MySQL or Mailpit instance that Core can identify from its installed package, configured endpoint, data path, and current health. Project status, adoption inventory, and activation use that same identity. `up` records the project's exact claim and starts only the explicitly requested service when the existing module can safely do so. `down` releases only project claims and never stops the legacy MySQL or Mailpit singleton. Package removal is refused while a project claim exists. Existing V1 booleans and global service controls retain their prior behavior. Focused tests and a disposable built-`val`/native Settings acceptance prove those behaviors, secret redaction, `.env` preservation, and cleanup.

This unit does not create a new named MySQL or Mailpit engine, initialize MySQL automatically, create application databases/users, migrate database contents, or close the full Herd-replacement goal.

## Scope and effort

This is one cross-layer feature slice across the service catalog, project planner/dispatcher, adoption inventory, native Settings selection, CLI reporting, and focused verification. The ownership model is higher risk because current MySQL/Mailpit data paths belong to global singleton modules. Estimate one substantial implementation pass plus live acceptance, with further work sessions for database import/setup, package/update recovery, and installed-app acceptance.

The canonical checkout already contains unrelated dirty feature code and artifacts. Do not reset, stage broadly, or replace those files. Use the one implementation delegate and one independent reviewer required by `AGENTS.md`.

## Throughput checkpoint

- **Blocking first steps.** Confirm that MySQL/Mailpit default identity and status can be projected into the existing catalog without changing paths or silently initializing data.
- **Independent workstreams.** None. Planner, catalog, claim mutation, and live service driver must share one identity model.
- **Shared mutable state.** `CoreRequestDispatcher` serializes lifecycle requests. Keep catalog claim changes in `ServiceInstanceRepository`, compare the live status to the exact catalog record before mutation, and never stop these singleton kinds from project down.
- **Smallest safe decomposition.** One Luna implementation owner. The change spans the typed planner, Core observation, adoption inventory, and native choices, so independent implementation owners would duplicate or race on shared invariants.

## Design candidates

1. **Catalog-backed singleton binding.** Project existing MySQL/Mailpit defaults into `ServiceInstanceRecord` entries with name `default`, exact package identity, current loopback endpoints, and the existing data directory. Reuse the typed project-binding and SQLite claim model. A closed lifecycle adapter delegates to the current singleton modules. Project down releases claims without stopping either runtime; package removal checks project owners.
2. **Legacy observation path.** Keep MySQL/Mailpit outside the catalog and special-case V2 bindings through `ProjectObservedEnvironment.mysql/mailpit` and the old desired-state booleans. This avoids catalog projection but splits adoption inventory, project status, and ownership handling, and the existing schema requires a catalog foreign-key target for claims.

The required design runners and judge will compare these against `.audit/project-mysql-mailpit-bindings/grounding.md`. Candidate sketches and synthesis will be written under that directory.
