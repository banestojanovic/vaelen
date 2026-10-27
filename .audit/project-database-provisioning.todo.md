# Project database provisioning

## Phase A. Frame

- [x] Read the Principles section of the poteto-mode skill.
- [x] Define the falsifiable completion predicate.
- [x] Record scope, rough effort, and blockers from the current implementation.
- [x] Preserve and account for existing dirty work before implementation.

## Phase B. Design the workflow

- [x] Ground the MySQL, PostgreSQL, Keychain, Core IPC, CLI, and Settings paths.
- [x] Compare two distinct architecture candidates and have one independent judge select a base.
- [x] Capture the selected type sketch, usage, tradeoffs, and first implementation slice.
- [x] Capture baseline focused test and package-fixture availability.
- [x] Record the phase list and throughput checkpoint below.

## Phase C. Implement in verified units

- [x] Add the typed provisioning request/result, Keychain seam, receipt journal, and engine behavior tests.
- [x] Implement the production MySQL adapter and bind it to exact Core project/service identity.
- [x] Prove safe MySQL provisioning and app authentication through production Core.
- [x] Implement safe PostgreSQL provisioning and secret storage behind Core.
- [x] Wire exact project service bindings through IPC and `val project db`.
- [x] Add a compact project Settings setup and explicit reveal/copy action.
- [x] Update CLI and Settings verification recipes.
- [x] Run actual MySQL and PostgreSQL fixtures, migration, restart, and file-preservation checks.

## Phase D. Keep the audit trail

- [x] Log each decision and verified unit in `.audit/project-database-provisioning.tsv`.
- [x] Review the full diff with one fresh, read-only Sol reviewer.
- [x] Fix actionable findings through fresh implementation delegates.
- [x] Run deslop and inspect the final diff.

## Phase E. Verify and hand back

- [x] Check every completion predicate against live fixture evidence and native Settings interaction.
- [x] Confirm no project `.env`, existing database, or service claim changed unexpectedly.
- [x] Write a detailed handoff with remaining release gates and next feature.
- [x] Report the branch and verification evidence. Commit after acceptance under the user's earlier explicit instruction; do not push without authorization.

## Completion predicate

A developer can provision a new database and dedicated application user on the exact managed MySQL or PostgreSQL instance bound to a project. The operation refuses an existing database or user, keeps generated credentials in macOS Keychain, and reveals or copies them only after an explicit request. `val` and compact native Settings use the same Core operation. Neither entry point edits `.env` automatically. Actual MySQL and PostgreSQL fixtures accept a Laravel migration, retain its data through service restart, and leave project files, existing databases, and service claims intact.

The feature does not add database deletion, overwrite, migration rollback, or automatic `.env` edits.

## Scope and blockers

The work crosses about ten source areas: domain/Core, both database modules, Keychain storage, IPC models and dispatch, CLI, AppModel, project Settings, tests, and verification recipes. Expected effort is one focused multi-hour coding run plus actual engine acceptance. The principal risk is safe recovery after MySQL's non-transactional DDL partially succeeds. The current tree already has MySQL and PostgreSQL lifecycle modules, a project service claim catalog, a local Core IPC dispatcher, CLI project commands, and a selected-project Settings detail. The current committed baseline has no per-project database/user provisioning or generic secret Keychain store. Local package fixtures are present at `/Users/banes/.codex/worktrees/vaelen/service-data-backup-recovery-fixtures/{packages,extracted}`. macOS Keychain behavior and the native Settings interaction still need live verification.

## Throughput checkpoint

At the first implementation checkpoint, the branch must have one domain request/result, one Core-owned provisioning path, no secret in SQLite or process arguments, and tests for refusal on collisions plus DDL partial failure. Stop before UI wiring if those invariants cannot be demonstrated. At the second checkpoint, actual MySQL and PostgreSQL fixtures must provision, accept a Laravel migration, and retain data after restart. Only then wire the compact Settings flow and complete CLI output and explicit reveal behavior.

## Phase list

1. Ground existing ownership, auth, IPC, user flows, and fixture availability.
2. Compare two candidate designs. Select the smallest design that handles collision refusal, MySQL partial DDL, Keychain writes, and explicit secret reveal.
3. Build a focused Core harness and test the state transition and secret boundary.
4. Implement and verify each engine independently against its exact service instance.
5. Add the CLI and Settings entry points over the same typed Core operation.
6. Run live fixture acceptance and inspect `.env`, service claims, and existing data before and after.
7. Run one independent review, fix findings, check the decision trail, and write the handoff.
