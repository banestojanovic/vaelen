# Central project service lifecycle

Choose a central `ProjectServiceLifecycleCoordinator` with a closed PostgreSQL and Valkey adapter registry. A project user gets exact `valkey-9.1.2` activation and safe ownership release. The next maintainer adds a managed service in one lifecycle module rather than copying identity checks into every project operation.

## Problem and grounding

The current planner, report builder, claim preflight, retirement loop, activation loop, and deactivation loop each know PostgreSQL package or runtime details. `ProjectReconciliation.swift:243` accepts only PostgreSQL. `CoreRequestDispatcher.swift:1762`, `:1885`, `:1933`, `:1945`, and `:2150` repeat the same restriction. Adding Valkey at every point leaves the supported-service list and identity policy spread across those callers.

`ServiceInstanceRepository.replaceProjectClaims` already replaces one project's claims transactionally. `ValkeyServiceModule` already owns process identity, executable and package validation, live `process_id`, loopback port, bind, and data-directory verification. The coordinator must compose these existing owners. It must not duplicate their process inspection or replace their storage.

## Usage first

The dispatcher constructs one coordinator from its existing dependencies. No new daemon wiring or public IPC operation is required.

```swift
let projectServices = ProjectServiceLifecycleCoordinator(
	repository: serviceInstances,
	postgresql: postgresql,
	valkey: valkey
)
```

The report builder asks for observations. Catalog-only legacy services retain their current `unknown` health behavior. A missing supported runtime module produces `unavailable`.

```swift
let bindings = try spec.services.map {
	try projectServices.observe(binding: $0, projectID: project.id)
}
```

Activation retains the existing two-stage contract. First reconcile the desired claim set after lifecycle preflight. Then execute each actionable service operation with a fresh exact check. The coordinator owns the checks and writes in both stages.

```swift
try projectServices.reconcileClaims(projectID: projectID, desired: spec.services)
// The existing planner loop selects the binding and records the result.
let observation = try projectServices.ensureRunning(binding: binding, projectID: projectID)
```

Deactivation asks the coordinator to release claims. It returns an outcome for each alias, so the dispatcher keeps its current succeeded, partial, and failed result aggregation.

```swift
let outcomes = try projectServices.releaseClaims(projectID: projectID)
```

The planner needs no runtime dependency. It uses the same static definition as the coordinator.

```swift
guard let definition = ProjectManagedServiceDefinition.supported(binding.kind),
	definition.accepts(version: binding.version) else { /* unsupported */ }
guard definition.matches(binding: binding, observation: observation) else { /* blocked */ }
// Existing healthy/stopped and claimed/unclaimed disposition table follows.
```

## Types and signatures

The durable and IPC shapes stay unchanged. They remain `ProjectServiceBinding`, `ServiceInstanceRecord`, `ServiceInstanceClaim`, and `ProjectServiceBindingObservation`.

```swift
public enum ProjectManagedServiceDefinition: Sendable {
	case postgresql
	case valkey

	public static func supported(_ kind: ProjectServiceKind) -> Self? {
		fatalError("not implemented")
	}
	public var kind: ProjectServiceKind { fatalError("not implemented") }
	public var packageIdentifier: String { fatalError("not implemented") }
	public var endpointKey: String { fatalError("not implemented") }
	public var displayName: String { fatalError("not implemented") }
	public func accepts(version: String?) -> Bool { fatalError("not implemented") }
	public func matches(binding: ProjectServiceBinding,
		observation: ProjectServiceBindingObservation) -> Bool {
		fatalError("not implemented")
	}
}

public struct ProjectServiceReleaseOutcome: Sendable {
	public let binding: ProjectServiceBinding
	public let result: Result<ProjectServiceReleaseDisposition, ProjectServiceLifecycleFailure>
}

public enum ProjectServiceReleaseDisposition: Sendable {
	case stoppedAndReleased
	case sharedAndReleased
	case unsupportedAndReleased
}

public struct ProjectServiceLifecycleFailure: Error, Sendable {
	public let message: String
}

public final class ProjectServiceLifecycleCoordinator {
	public init(repository: ServiceInstanceRepository,
		postgresql: PostgreSQLServiceModule?, valkey: ValkeyServiceModule?) {
		fatalError("not implemented")
	}
	public func observe(binding: ProjectServiceBinding, projectID: ProjectID?) throws
		-> ProjectServiceBindingObservation { fatalError("not implemented") }
	public func reconcileClaims(projectID: ProjectID, desired: [ProjectServiceBinding]) throws {
		fatalError("not implemented")
	}
	public func ensureRunning(binding: ProjectServiceBinding, projectID: ProjectID) throws
		-> ProjectServiceBindingObservation { fatalError("not implemented") }
	public func releaseClaims(projectID: ProjectID) throws
		-> [ProjectServiceReleaseOutcome] { fatalError("not implemented") }
}
```

The definition uses `PostgreSQLServiceModule.packageIdentifier` or `ValkeyServiceModule.packageIdentifier`. It accepts an omitted version or the full exact package identifier. Its endpoint key is `postgresql` or `valkey`. Its observation matcher requires equal bindings, the exact package, the correct endpoint key, and a data directory.

The coordinator contains a private runtime adapter enum. Its cases hold the existing module objects. An exhaustive switch converts each module's status into one private status shape and forwards `start` and `stop`. This is a closed registry, with no registration API, protocol conformance changes, closure injection, or service discovery.

```swift
private enum RuntimeAdapter {
	case postgresql(PostgreSQLServiceModule)
	case valkey(ValkeyServiceModule)
	var definition: ProjectManagedServiceDefinition { fatalError("not implemented") }
	func status(id: ServiceInstanceID) throws -> RuntimeStatus { fatalError("not implemented") }
	func start(id: ServiceInstanceID) throws { fatalError("not implemented") }
	func stop(id: ServiceInstanceID) throws { fatalError("not implemented") }
}

private struct RuntimeStatus {
	let record: ServiceInstanceRecord?
	let health: String
}

private struct VerifiedInstance {
	let record: ServiceInstanceRecord
	let adapter: RuntimeAdapter
	let state: State
	enum State { case healthy, stopped }
}

// Private to the coordinator. No caller can manufacture a verification result.
private func verify(binding: ProjectServiceBinding) throws -> VerifiedInstance {
	fatalError("not implemented")
}
```

`verify` requires the supported version, a present runtime adapter, an exact catalog package and endpoint kind, and a module status whose complete record equals that catalog record. Only `healthy` and `stopped` produce `VerifiedInstance`. All other health strings fail closed. This token is local to a synchronous operation. Every mutation and its final verification reread live state.

## Ownership transitions

`reconcileClaims` follows these steps:

1. Verify every desired binding before any claim write or retirement stop.
2. Derive desired instance IDs and group retired bindings by instance ID.
3. Skip retirement stops for an instance that remains desired under another alias.
4. For a retired managed instance with no manual or other-project owner, verify it, stop it if healthy, and verify the same complete record is stopped.
5. On any stop or verification failure, keep the existing project claim set and throw.
6. Replace this project's claims with the desired set in the existing SQLite transaction.

Retired unsupported kinds follow existing behavior. Their claims are replaced without a runtime stop. A new desired unsupported binding still fails preflight, as it does today.

`ensureRunning` verifies before writing a claim, idempotently adds the exact alias claim, starts only a stopped instance, then requires exact healthy status. A start or final verification failure retains the claim for retry. This matches existing PostgreSQL ordering. The service module rechecks its own process evidence before start or stop.

`releaseClaims` groups this project's claims by instance ID. If a manual or another-project claim exists, remove only this project's aliases and leave the process running. Otherwise, a managed instance must verify, stop, and verify the same record as stopped before any of this project's aliases are removed. A stop or verification failure retains all this project's claims on that instance. An already stopped exact instance can release successfully. Unsupported kinds retain the existing release-without-stop behavior. No operation deletes instance records or developer data.

These methods remain synchronous inside the existing `CoreRequestDispatcher` actor. Do not add `await` between an ownership read, process transition, and claim write. Direct service requests already run through that actor and module locks. This preserves the current serialization assumption rather than adding a second independent writer.

## Module map

| Module | Responsibility |
| --- | --- |
| New `Sources/VaelenCore/ProjectServiceLifecycle.swift` | Own the static definitions, private adapters, exact verification, and project lifecycle claim policy. |
| `Sources/VaelenCore/ProjectReconciliation.swift` | Use the shared definition and retain its pure disposition table. |
| `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift` | Construct the coordinator, obtain observations, invoke lifecycle methods, and map outcomes into existing operation results. Delete replaced project-specific PostgreSQL checks in the same change. |
| Existing PostgreSQL and Valkey modules | Remain the sole owners of process identity, package validation, runtime start, and runtime stop. |
| `ServiceInstanceCatalog.swift` | Retain catalog and transactional claim storage without a schema change. |
| Planner and private-Core test files | Prove externally visible behavior through the existing report and CLI shapes. |

## Rationale and alternatives

Model the Domain changes the organizing structure from caller-local service switches to one closed definition plus runtime adapter. The definition owns support and package identity. The coordinator owns project claim transitions. Existing modules keep process identity.

Make Operations Idempotent changes retirement and release to group by instance identity rather than alias. A rename changes claims without stopping the same desired runtime. A crash after a successful stop but before claim replacement leaves a stopped claimed instance that the next run can safely verify and release.

Laziness Protocol limits the abstraction to this project flow. There is no generic service plugin framework. PostgreSQL and Valkey modules gain no conformance boilerplate. The public coordinator hides catalog lookup, exact verification, retirement safety, start ordering, and stop-before-release behind four methods.

The minimal typed-dispatch alternative adds Valkey branches to the existing planner, report, preflight, retirement, execution, and deactivation blocks, with small package and endpoint helpers. It has the smaller immediate diff. It loses because the dispatcher still coordinates and repeats the lifecycle claim protocol, and an agent adding the next kind must discover every branch. Its interface hides less policy from its callers.

A generic `ProjectServiceLifecycle` protocol with separately registered providers also loses. It adds open-ended configuration and unavailable-provider states for two fixed modules, while leaving ownership transitions in the dispatcher unless a coordinator is added anyway.

## Risks and limits

- Moving PostgreSQL claim handling is a larger regression area than adding switches. Preserve its ordering and messages where practical, then rerun its real private-Core lifecycle fixture unchanged.
- The existing repository is shared state. A future writer outside the dispatcher actor could race owner checks. This design preserves current serialization and does not claim cross-process transactional stop-and-release safety.
- A stopped module status verifies absence of an owned live process, not installed package availability. `up` still validates the package through the module's `start`; failure retains the exact catalog claim. Do not reinterpret `stopped` as package installation proof.
- A storage failure after a verified stop leaves a stopped claimed instance. This is safe and retryable. A partial release across different instances remains a partial project result, as today.
- Metadata and runtime availability differ deliberately. A supported definition can exist when its runtime module is unavailable. That state blocks mutation and cannot silently fall back to legacy release behavior for a managed final owner.

## Proposed verification

No tests ran for this design candidate. First add planner cases for exact Valkey healthy and stopped instances, claimed and unclaimed, plus wrong package, version, endpoint, missing record, and identity-unverified health. Add coordinator behavior checks for preflight before writes, alias convergence, shared ownership, failed retirement, failed start retention, and final-owner stop failure retention.

Extend `Scripts/tests/val-service-lifecycle-test.sh` to extract both verified archives and inject `VAELEN_TEST_VALKEY_PACKAGE_ROOT`. Extend the real private-Core fixture with a Valkey module and a separate project. Cover `up`, repeated `up`, alias rename, `down`, repeated `down`, `up` again, manual ownership, another-project ownership, corrupt evidence, exact claim sets, and retained data. Run through `Scripts/test.sh`. Keep the existing PostgreSQL assertions and legacy MySQL and Mailpit tests.

The first implementation unit is the shared definition and unchanged planner disposition table. The next unit moves existing PostgreSQL project policy into the coordinator and adds Valkey through its private adapter.

## Synthesis decision

This candidate selects the central coordinator. The parent architecture pass owns the final cross-candidate synthesis.
