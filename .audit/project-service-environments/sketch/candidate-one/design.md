# Candidate A. Explicit service managers and a shared instance catalog

## Problem

Proposal. A developer creates independent PostgreSQL and Redis-compatible instances, names exact dependencies in `vaelen.yml`, activates them, and sees verified health and connection coordinates in both clients. Each service manager owns its engine's package, initialization, persistence, authentication, probing, and shutdown rules. A small catalog owns identity, project claims, and manual run intent. No extensible plugin runtime is introduced. Maintainers get one place for cross-service ownership policy and concrete engine code where engine differences belong.

Facts. The supplied [grounding](../../grounding.md) and direct inspection of `Sources/VaelenCore/MySQLModule.swift`, `MailpitModule.swift`, `ServiceIntentStore.swift`, `ProjectEnvironment.swift`, `ProjectReconciliation.swift`, and `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift` establish the following constraints. MySQL already has internal named paths but production exposes one default module. Mailpit hardcodes default paths. Project YAML version 1 contains MySQL and Mailpit booleans. Project inspection observes `.env` and compares both database and mail endpoints. Activation does not edit `.env`. MySQL process verification already protects shutdown from stale PID and socket ownership. The existing string intent store also serves other infrastructure, so only database and mail intent keys migrate. None of these facts establishes a PostgreSQL or Redis runtime implementation today.

## Usage (caller's view)

All commands, manifest fields, and signatures below are proposals. Exact package patch identifiers come from the signed available-package catalog. The major selectors in this example resolve once during instance creation and persist the resulting exact package identity.

```sh
val postgres install 18
val postgres create orders-db --version 18
val postgres create analytics-db --version 18
val redis install 8
val redis create orders-cache --version 8
val redis create jobs-cache --version 8
val project plan
val project activate
val project inspect --json
val project down
val postgres status orders-db
```

```yaml
version: 2
php: "8.4"
services:
  database:
    kind: postgres
    instance: orders-db
  cache:
    kind: redis
    instance: orders-cache
```

`database` and `cache` are project-local binding aliases, not instance identities. YAML version 2 accepts a mapping of validated aliases to `{kind, instance}`. It also supports `kind: mysql` and `kind: mailpit`. All entries are required dependencies. No optional dependency or implicit latest-instance rule exists. Multiple aliases may reference one instance and collapse to one claim. A missing instance blocks activation and suggests the corresponding create command. Activation never silently creates it, chooses another instance, installs a package, or upgrades data. A teammate creates the same `(kind, name)` locally. This gives exact machine-local selection with a portable manifest and independent local data. A different engine under the same name does not satisfy the binding.

The first create allocates stable loopback ports, initializes engine data, and leaves the instance stopped. `--port` permits an explicit selection. A healthy instance report includes engine, name, exact version, loopback endpoint, socket where applicable, persistence mode, health timestamp, consumers, and secret-free connection examples. A stopped instance shows configured coordinates separately from reachable endpoints. PostgreSQL initially exposes its bootstrap database and account. Additional SQL database/user administration is separate from activating the instance. Redis-compatible instances are separate processes and data roots, not logical Redis database numbers.

Real call sites, with domain values rather than IPC DTOs:

```swift
// CLI creation. The parser validates engine-specific input at the edge.
let created = try await postgres.create(
    PostgresCreate(name: name, package: installedPackage, port: .automatic))
print(PostgresOutput.instance(created))

// Project activation. One call resolves bindings and persists run claims.
let result = try await projects.activate(projectID)
print(ProjectOutput.activation(result))

// Native project view. It renders the same resolved report as the CLI.
let report = try await projects.inspect(projectID)
for binding in report.services {
    show(binding.alias, binding.instance, binding.observation, binding.diagnostics)
}
```

The Services pane groups engine-specific instance rows and offers create, start, release manual start, status, and connection details. PostgreSQL and Redis creation sheets expose their meaningful options. The Project pane shows each alias and exact instance with observed health, endpoint, consumer count, and missing-instance remediation. The project activation result distinguishes a healthy dependency from application configuration mismatch. Healthy PostgreSQL does not prove the app connects to it. Copy Connection copies secret-free examples. Credentials require a distinct explicit reveal action and are excluded from snapshots, logs, and ordinary IPC reports.

## Shape

The named data shape is `InstanceCatalogState`. It contains immutable instance identities plus durable run ownership. Runtime health is always an observation, never inferred from a persisted claim. Model the Domain changes the old service booleans into typed instance references and a set of run owners. Boundary Discipline keeps YAML, storage JSON, and wire DTOs outside the domain API. Make Operations Idempotent makes activation and recovery reconcile persisted claims with observed engines rather than replay a sequence blindly.

### Core types and signatures

Swift below is a type sketch, not compile-ready implementation. Each operational body is deliberately omitted.

```swift
enum ServiceKind: String, CaseIterable, Sendable {
    case postgres, redis, mysql, mailpit
}
struct InstanceName: Hashable, Sendable {
    // Private initializer. Boundary parser accepts lowercase ASCII names,
    // 1...48 characters, beginning with a letter, then letters/digits/hyphens.
    let rawValue: String
}
struct InstanceID: Hashable, Sendable {
    let kind: ServiceKind
    let name: InstanceName
}
struct BindingAlias: Hashable, Sendable { let rawValue: String }
struct ProjectServiceBinding: Equatable, Sendable {
    let alias: BindingAlias
    let instance: InstanceID
}
enum RunOwner: Hashable, Sendable {
    case manual
    case project(ProjectID)
}
struct InstanceCatalogState: Sendable {
    let revision: CatalogRevision
    let instances: [InstanceID: CatalogEntry]
    let projectClaims: [ProjectID: Set<InstanceID>]
    let manualClaims: Set<InstanceID>
}
enum CatalogEntry: Sendable {
    case postgres(PostgresDescriptor)
    case redis(RedisDescriptor)
    case mysql(MySQLDescriptor)
    case mailpit(MailpitDescriptor)
}
// Each descriptor has an InstanceID of the matching kind, an exact package
// identity, persistent endpoint allocation, and engine-specific configuration.
// Private constructors prevent a MySQL descriptor containing a postgres ID.
enum InstanceObservation: Sendable {
    case postgres(PostgresObservation)
    case redis(RedisObservation)
    case mysql(MySQLObservation)
    case mailpit(MailpitObservation)
}
enum ObservedHealth: Sendable {
    case stopped
    case starting
    case healthy(VerifiedEndpoint, observedAt: Date)
    case unhealthy(InstanceDiagnostic, observedAt: Date)
    case ownershipConflict(InstanceDiagnostic)
    case packageUnavailable(InstanceDiagnostic)
}
struct BoundServiceObservation: Sendable {
    let alias: BindingAlias
    let instance: InstanceID
    let observation: InstanceObservation? // Nil only with missing-instance diagnostic.
    let diagnostics: [ProjectDiagnostic]
}

actor InstanceCatalog {
    func snapshot() throws -> InstanceCatalogState { fatalError("not implemented") }
    func register(_ entry: CatalogEntry, request: CreateRequestID) throws -> CatalogEntry {
        fatalError("not implemented")
    }
    func replaceClaims(project: ProjectID, instances: Set<InstanceID>) throws -> ClaimChange {
        fatalError("not implemented")
    }
    func setManualClaim(_ id: InstanceID, enabled: Bool) throws -> ClaimChange {
        fatalError("not implemented")
    }
    func requiredOwners(of id: InstanceID) throws -> Set<RunOwner> {
        fatalError("not implemented")
    }
}

actor PostgresManager {
    func install(_ release: PostgresReleaseID) async throws -> PostgresPackage {
        fatalError("not implemented")
    }
    func create(_ request: PostgresCreate) async throws -> PostgresObservation {
        fatalError("not implemented")
    }
    func observe(_ descriptor: PostgresDescriptor) async -> PostgresObservation {
        fatalError("not implemented")
    }
    func reconcile(_ descriptor: PostgresDescriptor, goal: RunGoal) async -> PostgresObservation {
        fatalError("not implemented")
    }
}
actor RedisManager {
    // Equivalent operations with RedisReleaseID/Create/Descriptor/Observation.
    // Implementation choice is explicit metadata, never inferred from a binary name.
}
// MySQLManager and MailpitManager adapt their existing concrete modules.
// They have the same four operation concepts with their own domain types.
enum RunGoal: Sendable { case running, stopped }

actor ProjectServices {
    func inspect(_ project: ProjectID) async throws -> ProjectEnvironmentReport {
        fatalError("not implemented")
    }
    func plan(_ project: ProjectID) async throws -> ProjectReconciliationPlan {
        fatalError("not implemented")
    }
    func activate(_ project: ProjectID) async throws -> ProjectReconciliationExecutionResult {
        fatalError("not implemented")
    }
    func down(_ project: ProjectID) async throws -> ProjectServiceReleaseResult {
        fatalError("not implemented")
    }
}
```

`InstanceID` is `(kind, immutable name)`, not a UUID plus mutable label. Instance rename and data deletion are outside this feature. Creation of an existing name returns existing state only for an identical create request; incompatible configuration reports a conflict. Requests carry an idempotency ID so a lost response does not initialize twice. Engine selectors and create IDs are parsed at boundaries. Project identity uses the existing registry's durable project identity, never a UI display name or an uncanonicalized working directory.

The catalog reads by instance ID in O(1), reads a project's exact active claim set directly, and computes an instance's consumers by unioning the manual claim and scanning project claim sets. That scan is acceptable for a local developer catalog and avoids a second persisted consumer index. Project inspection resolves each binding through `instances[id]`. Service inventory sorts dictionary values for display. There is no later hidden indexing requirement.

### Module map and interface depth

| Module or file | Knowledge owned |
| --- | --- |
| `VaelenCore/ServiceInstances.swift` | Closed identity, binding, owner, observation domain types. |
| `VaelenCore/InstanceCatalog.swift` | Catalog schema, atomic claim transactions, migration, stable endpoint reservations. |
| `VaelenCore/PostgresManager.swift` | PostgreSQL package validation, create staging, cluster compatibility, credentials, probes, ownership, shutdown. |
| `VaelenCore/RedisManager.swift` | Explicit Redis implementation metadata, persistence, ACL, Redis probes, ownership, shutdown. |
| Existing MySQL and Mailpit modules | Engine lifecycle and existing default-path compatibility, adapted to named descriptors. |
| Existing project inspector/reconciler | YAML binding resolution, application diagnostics, activate/down policy and report construction. |
| Daemon dispatcher and IPC client | Exhaustive engine dispatch, DTO conversion and compatibility aliases. No process policy. |
| CLI output and native app models/views | Rendering domain reports and engine-specific creation forms. No port selection or claim arithmetic. |

There is one closed `CatalogEntry` switch at the Core project orchestration boundary to invoke each concrete manager. Transport conversion necessarily switches on the domain sum at its own boundary. Neither switch is a runtime registration table. No protocol with dozens of optional engine capabilities is added. The project interface hides resolution, ownership, recovery, and engine invocation behind inspect/plan/activate/down. Engine interfaces hide actual package and process work behind create/observe/reconcile. Callers retain meaningful engine configuration rather than a dictionary of arbitrary arguments.

The expected call chain is client domain method, daemon domain coordinator, concrete manager. The catalog is a collaborator for durable ownership, not another forwarding layer. Existing manager file sizes are a warning to keep engine implementations cohesive with private helpers, not permission to build a separate service framework. Shared low-level ownership evidence and safe archive validation utilities may be extracted only where the existing implementations actually share a mechanism.

### State and process boundaries

The daemon is the sole catalog writer and holds the existing Core endpoint lock before mutation. Catalog storage uses a private schema with atomic replacement and revision numbers. Clients cannot write catalog files. One catalog transaction atomically replaces a project's claim set. Per-instance managers own separate runtime records, logs, and data. A single process cannot concurrently mutate one instance. The project coordinator serializes claim mutation with run-goal dispatch; after suspension it rechecks the current desired state before issuing an opposite transition. This avoids an actor-reentrancy race where down stops a newly claimed instance. Per-instance reconciliation queues coalesce to the newest goal. Managers do not infer desired state from a stale operation plan.

```text
activate(project):
  parse current manifest at boundary; resolve every exact InstanceID
  preflight package presence, compatible data format, and ownership conflicts
  if any preflight blocker exists, return blocked without changing claims
  atomically replace this project's old claim set with resolved IDs
  enqueue reconcile for union(old IDs, new IDs), using current owner sets
  observe each dependency after bounded startup; return per-instance results
  retain claims after partial failure so retry/startup recovery has a stable goal

down(project):
  read persisted project claim set, even if manifest is missing or changed
  atomically replace that set with empty
  reconcile every released ID using current remaining owners
  report stopped, kept for other owners, or could not safely stop
  never initialize, uninstall, change app files, or remove data

startup:
  parse catalog strictly; corruption blocks mutation and retains bytes
  migrate legacy mysql/mailpit intent once if new schema is absent
  inspect existing records; verified existing process may be observed/adopted
  reconcile every catalog instance to the current durable owner set
  publish actual observations and restoration failures separately from claims
```

A manual start adds `.manual`. Manual stop releases `.manual` and refuses to imply the process is stopped while projects still claim it. It reports remaining owners. Explicit override-stop is outside the initial API. Repeating down is harmless. Editing bindings while active takes effect on the next activate; old claims remain visible until that transaction. Project removal releases its claims through the same coordinator, including a report if shutdown fails. An absent project directory does not silently drop claims during startup. The user can explicitly down that registered project.

Catalog and engine storage are not a cross-file transaction. A create request first reserves an immutable catalog entry in a `creating` phase with its request ID and allocated endpoints. The manager stages initialization beside the final data directory. It validates readiness markers and atomically promotes the directory before marking the entry ready. A crash after promotion is recognized by the matching instance/request marker and reconciles ready. Partial staging is retained as failed initialization evidence or safely discarded only when it is provably staging owned by that create request. Existing nonempty unmarked final data is an ownership conflict. No automatic reinitialization occurs. A creating or failed entry cannot acquire a running goal.

Packages live under immutable engine/version/platform roots. Instance data lives under `data/<engine>/instances/<name>`, runtime records under `runtime/...`, and secret files under the instance's private directory with owner-only access. MySQL and Mailpit default instances retain their exact existing paths. Never move default data merely to normalize the layout. Port reservations are stable catalog allocations. A free-port check is advisory until bind succeeds. External collision reports conflict rather than killing a listener or silently changing a known endpoint.

PostgreSQL creation runs `initdb` as the current user into staging, writes loopback-only configuration and authentication, and records cluster major, exact initialized package, locale, encoding, and credential references. PostgreSQL documents that initdb creates the cluster and refuses root execution. [PostgreSQL initdb](https://www.postgresql.org/docs/current/app-initdb.html). The manager launches `postgres` as its owned child and verifies readiness by a bounded authenticated query against the exact endpoint plus process identity. It records PID, start identity, executable, arguments, instance data path, and relevant socket/PID file ownership. A TCP response or `pg_isready` alone is insufficient to prove process ownership. Shutdown signals only the reverified process with bounded PostgreSQL graceful/fast policy; no automatic immediate mode or SIGKILL fallback. PostgreSQL's tooling distinguishes shutdown modes. [PostgreSQL pg_ctl](https://www.postgresql.org/docs/current/app-pg-ctl.html).

Redis creation writes a private ACL, loopback-only configuration, per-instance append-only persistence and snapshot paths, and a no-eviction default suitable for durable developer data. Reports state persistence and durability limits. Reconcile verifies owned process identity and bounded authenticated PING/INFO, including implementation/version and expected persistence settings. Normal shutdown requests a saving shutdown only after identity verification, waits boundedly, and reports failure without deleting persistence files. Avoid sending SHUTDOWN merely because the port responds. Restarts never clear keys. Neither manager automatically upgrades a data format, runs database migrations, rotates credentials, or drops databases. Package removal is blocked when any descriptor references it, including stopped instances.

### Compatibility and transport

YAML version 1 remains byte-for-byte valid. `mysql: true` resolves to `mysql/default` and `mailpit: true` to `mailpit/default`. False or absent values create no claim. Version 2 deliberately uses structured bindings and rejects mixed booleans, unknown kinds, invalid names, duplicate YAML keys, and unsupported versions. It does not rewrite a version 1 manifest.

Legacy `val mysql start/status`, `val mailpit start/status`, existing IPC singleton methods, and existing wire fields remain aliases to the catalog's default entries. They cannot launch separate providers. On the first successful migration, each enabled legacy intent becomes a manual default claim. Catalog schema records migration completion before the legacy database/mail keys cease being read. Other infrastructure intents remain in `ServiceIntentStore`. A corrupt legacy file fails visibly instead of becoming an empty claim set. Old default credentials and process records are preserved and verified before reuse. No new package selection applies retroactively to existing data.

Add instance-aware request DTOs for engine commands and an additive `services` binding list in project reports and service inventory. Default MySQL/Mailpit report fields remain projections of the same observations for old clients. Engine-specific creation DTOs avoid string option bags. The client exposes domain operations after DTO parsing. Negotiate daemon capability for instance APIs; an older daemon produces a clear unsupported-feature error rather than silently acting on default. The same observation drives CLI and app status. Package versions, names, owner counts, health and endpoints have no second UI-owned state source.

### Package provenance and licensing

Facts. PostgreSQL uses its permissive PostgreSQL License. [PostgreSQL license](https://www.postgresql.org/about/licence/). Redis 8 offers a choice of AGPLv3, RSALv2 or SSPLv1. [Redis licensing](https://redis.io/legal/licenses/). The official Valkey download page inspected for this candidate lists Linux binary artifacts; those are not evidence of a usable macOS artifact. [Valkey download](https://valkey.io/download/). The grounding's Postgres.app observation identifies a candidate distribution only. It does not prove that extracting it gives a relocatable self-contained Vaelen runtime.

Proposal. Ship Vaelen-built, pinned macOS runtime archives from official PostgreSQL and Redis source releases. Build infrastructure, not the user's machine, compiles them. Redis remains labeled Redis. Valkey may later be a separately named implementation with its own explicit create selector, package identity and compatibility tests; no automatic substitution occurs. Choose Redis 8's AGPLv3 lane for this candidate, retain corresponding source, build scripts, notices and modifications, and complete distribution review before enabling download. This is a proposed distribution choice, not a legal conclusion about Vaelen's obligations.

Each signed package manifest records upstream release/source digest, complete dependency source identities and licenses, build recipe and toolchain, deployment target, architecture, archive digest, executable/dylib allowlist and hashes, signature policy, and corresponding-source URL. Bundle required non-system dylibs with relocatable install names. Installation rejects absolute/path-traversal archive entries and escaping symlinks, validates executable architecture and dependency closure, verifies signatures/digests, probes version, and atomically promotes a staging root. Runtime dependency checks reject Homebrew paths. The installer never shells out to brew and requires no local compiler. End-to-end CI must launch on a clean machine without `/opt/homebrew` or `/usr/local` runtime libraries before the package is marked supported. Existing MySQL/Mailpit package manifests and provenance remain unchanged unless separately audited.

## Synthesis decision

Pending parent synthesis. Candidate A recommends concrete engine managers plus a small shared catalog. It has not compared itself to or selected the other runner's design. The parent should retain this shape if engine differences dominate and the catalog sufficiently removes repeated ownership policy. A generic executable plugin contract is intentionally rejected here.

## Tradeoffs accepted

- We accept four concrete lifecycle implementations in exchange for preserving engine-specific initialization, compatibility, health and shutdown rules.
- We accept an exhaustive Core engine dispatch and explicit wire conversion in exchange for no hidden plugin registration or arbitrary capability dictionaries.
- We accept immutable instance names in exchange for manifest identity without UUID portability or rename aliases.
- We accept persistent project claims after a partial activation in exchange for deterministic recovery and explicit down semantics.
- We accept no automatic package install/create during project activation in exchange for a plan whose declared dependencies are exactly what runs.
- We accept release engineering work for self-contained macOS artifacts in exchange for a workflow independent of Homebrew and developer toolchains.
- We accept additive legacy wire projections in exchange for older clients continuing to inspect the same default instances.

## Alternatives considered

- A generic service-driver protocol and runtime registry hides command dispatch but exposes engine-specific initialization, persistence and package choices as optional capabilities or untyped configuration. It has a larger caller surface and makes a locally plausible lifecycle change unsafe for another engine. This candidate keeps the common domain narrow.
- Fully separate engine implementations with no shared catalog have shorter local code paths but expose shared-instance arithmetic, identity parsing, and intent migration to every IPC/project/UI caller. This loses interface depth at the project boundary.
- Per-project containers hide package and process ownership deeply but require a container runtime, add a new endpoint/network model, and change the native package workflow. They do not meet the intended independently managed local runtime shape.
- Opaque instance UUIDs with editable names hide path identity but require portable aliases and another mapping layer for checked-in project bindings. Immutable `(kind, name)` supplies the required identity with less public machinery for this scope.

## Open questions and risks

- Does the Redis AGPLv3 distribution lane fit the product's distribution model after reviewing the exact source, bundled dependencies, and notices, or should Redis delivery remain unavailable until another explicitly chosen lane is ready?
- Which minimum macOS target and architectures must clean-machine package CI support before either new engine is advertised?
- Should the initial credentials reveal action use an owner-only file or Keychain-backed secret store while preserving unattended local service startup?
- Can existing registry identity survive unregister/re-register at the same canonical project path without creating orphan claims, and which explicit removal behavior should its migration tests lock down?
- Will an observed ownership mismatch after daemon death be recoverable with current process identity facilities for both new engines, or must the report require an explicit user recovery operation while preserving the data?

These questions are implementation gates or product choices, not permission to use unverified packages or silently stop external processes. The first two block shipping the corresponding package lane. Credential storage and registry identity can be resolved by inspecting the existing code before implementation.

## Next implementation step

Build catalog identity, claims and legacy migration with focused behavior tests, then implement one PostgreSQL instance end to end against a verified self-contained fixture before adding Redis and the client surfaces.

## Candidate assessment

Scores are design judgments on a five-point scale, not measured outcomes.

| Criterion | Score | Reason and verification gate |
| --- | --- | --- |
| End-user project workflow | 4/5 | Exact readable bindings, stable coordinates and shared reports. Explicit create is an extra setup step. Demonstrate two projects, two PostgreSQL clusters and two Redis processes with distinct persisted values. |
| Durable data/process safety | 5/5 | Separate package/data, staged initialization, format checks, durable owners, ownership-verified stop. Crash-cut tests and real process-reuse/conflict checks must prove the proposal. |
| Backward compatibility | 4/5 | Version 1 booleans, paths, commands and wire projections persist through one writer. Exercise an existing default MySQL/Mailpit fixture and old-client methods after migration. |
| Duplication and interface depth | 4/5 | Ownership is centralized; engine mechanics stay concrete. The cost is four managers and boundary sum conversion. Review the first two implementations for duplicated policy before expanding. |
| Safe project start/down with shared instances | 5/5 | Claim sets, persisted old binding sets and current-goal serialization avoid counter drift and stale manifest release. Race activate/down, manual ownership and restart in tests. |
| Package provenance and licensing | 3/5 | Concrete source-build and signed manifest plan avoids Homebrew, but no deliverable macOS archive or completed Redis distribution review exists. Clean-machine launch and source/notice audit are release gates. |

Red-flag screen. No public wire DTOs enter the domain, no plugin capability bag exists, and no client coordinates engine stages. One catalog owns desired run state and endpoint reservations. Engine records own observed process evidence. Compatibility methods project the same default instances rather than opening a second control path. The principal remaining risk is accidentally moving engine policy into the catalog during implementation; reject that expansion if the catalog starts knowing initdb flags, Redis ACL syntax, or package extraction layouts.
