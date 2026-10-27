# Project-bound Valkey lifecycle

## Feature playbook

1. `how` over the affected subsystem. **Done.** Rechecked planner, Core observations, activation/deactivation, claim storage, and package-backed lifecycle modules against current source.
2. `architect` for parallel design exploration. **Done.** Two candidate shapes and one cross-judge are recorded in `.audit/project-valkey-binding/`; the final synthesis is in `architecture.md`.
3. Write the throughput checkpoint as four todo items:
   - **Blocking first steps.** Exact Valkey 9.1.2 identity and runtime behavior were implemented against the existing local package archive and private-Core fixtures.
   - **Independent workstreams.** Planner disposition, Core observation and mutation, claims, and private-Core acceptance share one binding and instance identity; keep them under one implementation owner.
   - **Shared mutable state.** The project claim repository and service process evidence are shared. Preflight exact records, compare them again with fresh observations, and keep ownership reads, stop verification, and claim writes synchronous inside the dispatcher actor.
   - **Smallest safe decomposition.** One Luna implementation owner is the smallest safe unit because planner, dispatcher, durable claims, and the built-`val` fixture must agree on the same exact instance.
4. Delegate code-writing to a subagent using your configured feature model with a specific scope and success criteria. **Done.** The assigned implementation owner added exact Valkey project up/down support and preserved PostgreSQL ordering and unsupported legacy service behavior. No commit was created.
5. Verify on the matching surface. **Done.** `Scripts/test.sh --filter 'ProjectReconciliationTests|PostgreSQLServiceLifecycleEndToEndTests|ValkeyServiceLifecycleEndToEndTests'`, `Scripts/tests/valkey-service-lifecycle-test.sh`, `Scripts/tests/val-service-lifecycle-test.sh`, and `git diff --check` passed. Both package-backed fixtures used existing local archives. Parent review remains pending.
6. Rebase into small, ordered commits. **Skipped.** The canonical checkout contains unrelated existing changes, and this slice has no commit request. Do not stage or commit the broader dirty state.
7. If the design is contested, `interrogate` before shipping. **Skipped.** The two candidates were compared and resolved by a read-only cross-judge; the selected behavior is recorded in `architecture.md`.
8. Run `Opening a PR`. **Skipped.** This is a local product slice; no PR was requested.

## Implementation checklist

- [x] Add a closed typed definition for supported project-managed service identity and adapt PostgreSQL/Valkey runtime modules without changing persistence or IPC shapes.
- [x] Extend planner and Core observation/activation/deactivation for exact Valkey bindings, grouping retirement by instance and preserving final-owner claims on failure.
- [x] Extend the real private-Core `val` fixture and script to use the locally generated Valkey archive; keep the PostgreSQL assertions intact. The existing Valkey fixture script already extracts and injects the exact local archive, so no script change was needed.
- [x] Update the project lifecycle verification recipe and audit trail with focused verification evidence.

## Current-state flow

- `ProjectReconciliationPlanner` turns each V2 `ProjectServiceBinding` into `service.<alias>` operations. The closed `ProjectManagedServiceKind` accepts PostgreSQL and exact `valkey-9.1.2` bindings, and checks package, endpoint key, loopback port, and data directory.
- `CoreRequestDispatcher.projectEnvironmentReport` reads the catalog record and PostgreSQL or Valkey runtime health, then produces the unchanged `ProjectServiceBindingObservation` shape.
- `activate` preflights all desired managed bindings and retired final-owner instances, groups retirement by `ServiceInstanceID`, replaces the project claim set transactionally, then executes planned operations against fresh catalog and module state. It starts only `.start` operations.
- `deactivate` leaves a managed instance running when a manual or other-project owner remains. For the final project owner it stops and verifies PostgreSQL or Valkey before atomically releasing this project's claims. Identity, stop, and claim-write failures retain the durable claims. Unsupported legacy kinds retain release-without-stop behavior.
- `ValkeyServiceModule` owns `valkey-9.1.2` instances and verifies PID start time, executable path, live Valkey `process_id`, version, port, bind, and data directory before reporting healthy or stopping.
- `ValkeyServiceLifecycleEndToEndTests` now drives `val project up/down` through private Core with the existing local Valkey archive. It checks stopped unclaimed startup, repeated up/down, alias rename, shared manual ownership, final-owner stop, data retention, and identity-failure claim retention. The PostgreSQL lifecycle fixture remains intact and passed.

## Data shape and invariants

The project declaration uses `ProjectServiceBinding { alias, kind, instance, version }`. The catalog uses `ServiceInstanceRecord { id: (kind, name), packageIdentifier, endpoint, dataDirectory }` plus `ServiceInstanceClaim`. Project status is `ProjectServiceBindingObservation { binding, packageIdentifier, endpoint, dataDirectory, health, claimed }`.

Support the exact `valkey-9.1.2` package and `valkey` loopback endpoint. Never claim a missing, mismatched, or identity-unverified instance. `up` must start and verify the exact instance before succeeding. `down` releases only this project's ownership, and stops Valkey only after the exact process is verified and no manual or other project owner remains. Stop or identity failure retains the last project claim and data. Repeated up/down and alias changes converge safely.

## Design comparison

- Candidate A: extend the existing typed per-kind switches and share only exact service identity/status helpers.
- Candidate B: introduce a project-managed service lifecycle registry/adapter that owns package identity, endpoint key, status, start, and stop for each supported kind.

Rubric: exact process/data safety; one source of truth for supported package and endpoint identity; no behavior change for existing PostgreSQL and legacy MySQL/Mailpit; clear transactional claim semantics; short caller path for adding future MySQL/Mailpit managed lifecycles.

## Completion evidence

- Planner tests cover healthy/stopped claimed and unclaimed Valkey, wrong package/version/endpoint, and identity-unverified health.
- Private-Core `val` fixture covers Valkey project up/down/up, default and shared ownership, exact claim set, health, and failure retaining claims.
- Existing PostgreSQL project lifecycle and legacy service tests still pass.
- One fresh read-only Sol reviewer found the duplicate-alias start regression. A fresh Luna fix round resolved it, and the same reviewer confirmed the correction with no new findings.
- No source download or package installation occurred. The reviewed files were selectively integrated into the canonical dirty checkout after verification; unrelated changes and artifacts remain preserved.

## Review fix round

- [x] Make an actionable start converge if another alias has already started the same exact instance. Add each exact claim, skip duplicate start, and verify healthy status.
- [x] Release this project's grouped claims before runtime verification when another owner remains. Preserve final-owner verification and claim retention on failure.
- [x] Cover two aliases for one stopped Valkey instance and shared-owner release with identity-unverified runtime state.
- [x] Generalize the planner's unhealthy identity reason to name the binding's service kind.
- [x] Run focused tests and both package-backed lifecycle fixtures; record results here.

Verification for this round: `Scripts/test.sh --filter 'ProjectReconciliationTests|PostgreSQLServiceLifecycleEndToEndTests|ValkeyServiceLifecycleEndToEndTests'`, `Scripts/tests/valkey-service-lifecycle-test.sh`, `Scripts/tests/val-service-lifecycle-test.sh`, and `git diff --check` passed. The Valkey fixture and focused suite were rerun after the final edits.
