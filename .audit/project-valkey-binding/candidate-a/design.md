# Candidate A. Closed typed service dispatch.

Choose a small closed enum for supported project service kinds. Keep project claim reconciliation in `CoreRequestDispatcher`. Reuse each existing service module for process identity, start, stop, and health. Do not introduce a lifecycle registry, protocol hierarchy, or second claim owner.

This extends exact `valkey-9.1.2` project up/down support. It preserves the current storage and wire shapes.

## Grounding

The existing planner in `Sources/VaelenCore/ProjectReconciliation.swift:241` computes `service.<alias>` operations from manifest bindings and observations. Its PostgreSQL policy is package equality, endpoint-key presence, data-directory presence, binding equality, health, and claim state. It performs no process mutation.

`Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift:1759` constructs binding observations. Its activation path at line 1917 preflights every desired binding, safely stops retired final-owner instances, replaces project claims transactionally, then executes service operations. Its deactivation path at line 1867 stops and verifies a final-owner PostgreSQL instance before removing the claim. Claims are durable repository state rather than lifecycle-module state.

`Sources/VaelenCore/ValkeyServiceModule.swift:94` reports exact process health. Healthy includes executable/start identity, live `process_id`, exact 9.1.2 version, port/bind, and data directory. `stop` at line 174 refuses to signal an unverified live process. A stopped result is absence evidence rather than a live identity assertion. `ServiceInstanceRepository` stores immutable exact instance records and transactional project claim sets.

The private-Core acceptance fixture is `Tests/VaelenIPCTests/PostgreSQLServiceLifecycleEndToEndTests.swift`. It launches a real CLI child with an injected PostgreSQL module. Extend that same fixture pattern to inject Valkey. Do not substitute unit mocks for the process acceptance lane.

## Data shape and type sketch

Keep `ProjectServiceBinding`, `ServiceInstanceRecord`, `ServiceInstanceClaim`, and `ProjectServiceBindingObservation` unchanged.

```swift
// VaelenCore. Internal domain descriptor, visible to daemon support as needed.
enum ProjectManagedServiceKind: Sendable {
    case postgresql
    case valkey

    init?(kind: ProjectServiceKind) // Closed supported-kind conversion.
    var kind: ProjectServiceKind { get }
    var packageIdentifier: String { get } // Existing module constants.
    var endpointKey: String { get } // postgresql or valkey.
    func supports(_ binding: ProjectServiceBinding) -> Bool
    func matches(_ binding: ProjectServiceBinding,
                 observation: ProjectServiceBindingObservation) -> Bool
    func matches(_ binding: ProjectServiceBinding,
                 record: ServiceInstanceRecord) -> Bool
}

// Private to CoreRequestDispatcher. No public lifecycle protocol.
private enum ProjectServiceDriver {
    case postgresql(PostgreSQLServiceModule)
    case valkey(ValkeyServiceModule)

    var descriptor: ProjectManagedServiceKind { get }
    func status(id: ServiceInstanceID) throws -> ProjectServiceStatus
    func start(id: ServiceInstanceID) throws
    func stop(id: ServiceInstanceID) throws
}

private struct ProjectServiceStatus {
    let record: ServiceInstanceRecord?
    let health: String
}

private func projectServiceDriver(
    for kind: ProjectManagedServiceKind
) throws -> ProjectServiceDriver

private func verifiedProjectServiceRecord(
    _ binding: ProjectServiceBinding
) throws -> (driver: ProjectServiceDriver, record: ServiceInstanceRecord)

private func stopAndVerifyProjectService(
    driver: ProjectServiceDriver, record: ServiceInstanceRecord
) throws
```

Sketch methods have no product implementation in this artifact. `ProjectManagedServiceKind` owns the exact supported package and endpoint policy. Its `matches` requires full binding equality for observations; exact ID, kind, package, endpoint kind/key, and data-directory presence for records. Nil manifest version retains current PostgreSQL semantics and selects the single exact supported package. Explicit version must equal the complete package identifier, including `valkey-9.1.2`.

`verifiedProjectServiceRecord` reads the repository record, resolves an injected driver, enforces the descriptor, and compares fresh driver status record equality against that entire record. It accepts only `healthy` or `stopped`. It throws before claims change on missing module, missing record, mismatched record, unknown health, unavailable health, or identity-unverified health. It does not cache a permanent verification token.

`stopAndVerifyProjectService` rereads status, compares its record to the expected exact record, accepts `healthy` or `stopped`, stops only healthy, then requires a fresh stopped status with the same exact record. Driver methods normalize only the status shape. The modules retain process safety policy.

## Module map

| Location | Responsibility |
| --- | --- |
| New `Sources/VaelenCore/ProjectManagedServiceKind.swift` | Closed support descriptor and package/binding/record matching. |
| `ProjectReconciliation.swift` | Use descriptor to plan both PostgreSQL and Valkey with the existing health/claim decision table. |
| `CoreRequestDispatcher.swift` private declarations | Typed driver enum and normalization. No new state store. |
| Dispatcher report, activation, deactivation | Use the same descriptor and verification helpers at all project service lifecycle edges. |
| Existing PostgreSQL and Valkey modules | Remain the only process owners and identity authorities. |
| `ServiceInstanceCatalog.swift` | Unchanged durable ownership and transaction semantics. |
| Existing planner, dispatcher, private-Core tests and fixture script | Add exact Valkey cases and archive injection. |

## Caller usage and ordering

Planner pseudocode.

```swift
guard let kind = ProjectManagedServiceKind(kind: binding.kind),
      kind.supports(binding), let observation = observationForAlias else {
    emitUnsupported()
    continue
}
guard kind.matches(binding, observation: observation) else {
    emitBlockedMismatch()
    continue
}
planUsingExistingHealthAndClaimDecisionTable(observation)
```

Observation construction resolves the driver only for supported project-managed kinds. A missing injected driver or thrown status becomes `unavailable`, never `stopped`. It still reports the catalog record and exact project claim. Unsupported kinds keep existing report behavior.

Activation ordering.

1. Verify every desired binding with `verifiedProjectServiceRecord` before changing any claims. Keep the original set unchanged if any check fails.
2. Compute desired instance IDs separately from aliases. For each retired binding whose instance is absent from the desired set, inspect remaining manual and other-project owners. Stop and verify only a supported final-owner instance. A rename to the same instance must never stop it.
3. Replace the project claim set with the exact desired bindings in the existing repository transaction. A stop or verification failure exits before replacement, retaining old claims.
4. Before executing each start/associate operation, freshly verify the exact catalog and driver status, including matching the expected observed record. Add the claim idempotently as today, start only if the operation requires it, and require fresh healthy status with full record equality. Failure retains the claim for retry.
5. Construct the final plan from fresh observations. Success requires the requested exact services to be healthy and claimed.

Deactivation ordering.

1. Iterate the durable project claims, rather than relying on the current manifest.
2. If manual or other-project ownership exists, remove only this project's binding claim and leave the runtime running.
3. For a supported service with no outside owner, verify its exact catalog record and status, stop and verify if healthy, then remove this binding claim. Any missing record, driver, identity, or stop verification failure retains the final project claim.
4. For unsupported legacy kinds preserve existing release-without-stop behavior. This change does not adopt MySQL, Redis, or Mailpit into project-managed lifecycle.
5. Multiple aliases for one instance remain safe. Removing an alias after a verified stop leaves the next alias to observe stopped; repeated down sees no claims. Repeated up sees healthy+claimed. A crash after stop and before claim release leaves a stopped instance with durable retry ownership.

## Alternatives and rationale

The centralized registry alternative would expose a project lifecycle adapter per kind with descriptor, status, start, and stop capabilities and potentially move claim reconciliation into a service coordinator. That can hide a deeper subsystem, but this slice has two concrete injected modules with almost identical signatures and one existing claim owner. A registry adds registration and availability questions while the existing Core caller still coordinates project operations and transactional claim replacement. Moving that policy now would broaden PostgreSQL behavior risk.

Choose the closed enum. It consolidates the supported package and endpoint decisions, statically requires handling both supported kinds, and keeps the current project orchestration readable in place. It intentionally does not provide generic plugins, mutable registration, closures, or per-kind claim implementations. Adding a future managed kind requires one descriptor case, one typed driver case, and focused acceptance coverage. The compiler identifies missing enum handling.

`Model the Domain` shaped the closed supported-kind enum and exact record checks. `Laziness Protocol` shaped the rejection of a new lifecycle subsystem. `Make Operations Idempotent` shaped the stop-before-release ordering, alias-to-instance distinction, and retention of claims after failures. The leaf skill instructions for all three were read for this candidate.

## Red-flag screen and risks

- Information leakage is bounded. Exact package and endpoint policy lives in one descriptor, not repeated across planner/preflight/down/start switches. Process identity remains in existing modules.
- The driver is a narrow adaptation boundary that removes PostgreSQL and Valkey status-type differences. It holds no claims, caches, registry, or duplicate process evidence.
- The repository remains the only claim writer. The dispatcher remains the only project lifecycle coordinator. Legacy direct service lifecycle operations keep existing modules and manual-claim semantics.
- Verification cannot be treated as permanently true. Refresh status before start/stop and verify after mutation. Retain the current serialization assumptions; inspect dispatcher request scheduling before adding any awaits inside claim decisions.
- The existing activation flow can stop one retired service and then fail on a later retired service. All old claims remain, so retry converges, but a prior instance may already be stopped. This proposal preserves that safe partial behavior.
- Status `stopped` can be reported without validating an installed package. The invariant here is verified absence before claiming or releasing. Start still validates the exact package and must pass live identity checks before success. A missing package can therefore retain a newly reconciled claim after failed start, matching current retry behavior.
- Acceptance must cover mixed PostgreSQL+Valkey desired sets, manual and other-project owners, same-instance alias rename, retired final owner, wrong explicit version/package/endpoint, missing instance/module, identity-unverified status, start failure retaining claims, stop failure retaining claims, and repeated up/down/up. Preserve PostgreSQL and legacy service regression coverage.
- No tests were started. This candidate is a design artifact only.
