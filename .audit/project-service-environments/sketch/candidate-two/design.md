# Candidate B. Managed service instance kernel

## Problem

Developers need named PostgreSQL and Redis-compatible instances that remain isolated, survive app restarts, and bind to projects predictably. This candidate puts package, process, endpoint and persistence coordination behind one service domain API. Service drivers retain database-specific knowledge. Project activation requests a durable dependency set instead of invoking singleton modules directly.

### Observed facts

- At base `5d071c4`, `MySQLModule.swift` has an internal instance-name initializer, but its public initializer selects `default`. Its package selection file is still `mysql-default.json`. Generalizing only that initializer would leave shared selection state.
- `MailpitModule.swift` takes custom ports but uses default instance paths. `VaelenDaemon/main.swift:25` constructs one provider of each kind.
- `CoreRequestDispatcher.swift:374` onward handles singleton MySQL and Mailpit operations. Its startup restoration reads literal service keys. `ServiceIntentStore.swift` persists enabled choices separately from observations.
- `ProjectEnvironment.swift:401` reads `vaelen.yml`. Desired MySQL and Mailpit fields are booleans. It already compares both database and mail endpoints. Its `.env` inspection reports secret availability without returning secret values.
- `ProjectReconciliation.swift` marks MySQL start deferred and installed Mailpit start actionable. The dispatcher activates a subset of planned operations and observes again.
- `MySQLModule.remove` removes package material while retaining instance data and credentials. Preserve that distinction.
- Native service settings and project views currently branch on MySQL and Mailpit singleton status. PostgreSQL display aliases do not establish runtime support.

Everything below is a proposal, including command syntax, manifest schema, package delivery and module names. This is an architecture candidate, not implemented behavior.

## Usage (caller's view)

### Developer workflow

```sh
val service available
val service create postgresql shop-db --version <catalog-version>
val service create postgresql tests-db --version <catalog-version>
val service create redis-compatible shop-cache --runtime valkey --version <catalog-version>
val service list
val service status postgresql shop-db
val project up .
val project services .
val project down .
```

`create` installs the explicitly selected verified package when necessary, initializes a new instance, and leaves it stopped. `up` requires existing named instances. It never guesses that an arbitrary listening server is the requested instance. Missing bindings report the exact create command and leave current project claims unchanged. `down` releases this project's recorded claims, including bindings removed from or obscured by a now-invalid manifest. It never removes a database, message store, package, or directory.

```yaml
version: 2
php: '8.4'
services:
  database:
    kind: postgresql
    instance: shop-db
  cache:
    kind: redis-compatible
    runtime: valkey
    instance: shop-cache
  mail:
    kind: mailpit
    instance: default
```

The role names are project-local labels. `(kind, immutable instance name)` selects an exact local instance, never a current default or first available instance. `runtime` is required for Redis-compatible bindings and verified against the resolved instance. Developers recreate those names independently on their machines. The instance owns its exact package pin. This first schema does not claim cross-machine package reproducibility. A future explicit package constraint can check compatibility without silently upgrading a dataset.

The CLI and app show the resolved instance ID, runtime, package version, measured readiness, observation time, actual endpoints, active consumers and retained data location. A proposed row is `database → postgresql/shop-db · ready · 127.0.0.1:15432`. Redis-compatible rows explicitly say `Valkey`. Database credentials are absent from ordinary reports. Copy endpoint copies a secret-free value. Connection configuration remains a developer action. Endpoint mismatch with `.env` is a diagnostic and never rewrites that file.

### Three actual consumer shapes

```swift
// Core request handler, after decoding and validating a create request.
let instance = try await services.create(.postgresql(
    name: requestedName, package: approvedPackage,
    configuration: .localDevelopment(port: .automatic)))
return ServiceInstanceReply(instance)

// Project activation, after parsing the whole manifest.
let change = ProjectServiceDemand.running(project: project.id,
    bindings: desired.serviceBindings, manifestDigest: digest)
let result = try await services.apply(.project(change))
// The result contains resolved bindings and a fresh observation for every dependency.

// Native app Stop action, sent through IPC and decoded in Core.
let result = try await services.apply(.manual(instance: instanceID, running: false))
// If another consumer remains, result explains why the instance continues running.
```

Project down calls `apply(.project(.released(project: project.id)))`. It does not reconstruct the old dependency set from the manifest. CLI renderers and SwiftUI consume the same snapshot contract. They do not inspect PID files, calculate effective intent, allocate ports or invoke drivers.

## Shape

### Domain structures first

```swift
public enum ServiceKind: String, Sendable {
    case postgresql, redisCompatible, mysql, mailpit
}
public struct ServiceInstanceID: Hashable, Sendable { /* private UUID */ }
public struct ServiceInstanceName: Hashable, Sendable {
    public init(parsing text: String) throws { fatalError("not implemented") }
    // Canonical lower-case ASCII slug. No slash, traversal, or ambiguous normalization.
}
public struct ServiceSelector: Hashable, Sendable {
    public let kind: ServiceKind
    public let name: ServiceInstanceName
}
public struct ServiceBinding: Equatable, Sendable {
    public let role: ProjectServiceRole
    public let selector: ServiceSelector
    public let requiredRuntime: RedisCompatibleRuntime?
    // Parser admits a runtime requirement only for a Redis-compatible binding.
}
public enum NewServiceInstance: Sendable {
    case postgresql(name: ServiceInstanceName, package: PostgreSQLPackageID,
                    configuration: PostgreSQLConfiguration)
    case redisCompatible(name: ServiceInstanceName, package: RedisCompatiblePackageID,
                         configuration: RedisCompatibleConfiguration)
    case mysql(name: ServiceInstanceName, package: MySQLPackageID,
               configuration: MySQLConfiguration)
    case mailpit(name: ServiceInstanceName, package: MailpitPackageID,
                 configuration: MailpitConfiguration)
}
public enum ProjectServiceDemand: Sendable {
    case running(project: ProjectID, bindings: [ServiceBinding], manifestDigest: ManifestDigest)
    case released(project: ProjectID)
}
public enum ServiceDemandChange: Sendable {
    case project(ProjectServiceDemand)
    case manual(instance: ServiceInstanceID, running: Bool)
}
public enum ServiceObservation: Sendable {
    case stopped(lastExit: ExitSummary?)
    case starting(OwnedProcessEvidence)
    case ready(OwnedProcessEvidence, ServiceReadinessEvidence)
    case unhealthy(OwnedProcessEvidence, ServiceFailure)
    case conflict(ServiceConflict)
    case unavailable(ServiceFailure)
}
public enum ServiceDetails: Sendable {
    case postgresql(PostgreSQLDetails)
    case redisCompatible(RedisCompatibleDetails)
    case mysql(MySQLDetails)
    case mailpit(MailpitDetails)
}
public struct ServiceInstanceSnapshot: Sendable {
    public let id: ServiceInstanceID
    public let selector: ServiceSelector
    public let package: ServicePackageSummary
    public let endpoints: [ServiceEndpoint]
    public let consumers: Set<ServiceConsumer>
    public let observation: ServiceObservation
    public let observedAt: Date
    public let details: ServiceDetails
}
```

`ServiceEndpoint` distinguishes PostgreSQL, MySQL, RESP, SMTP, HTTP and private Unix endpoints. A configured endpoint is labeled configured until readiness is verified. `ServiceReadinessEvidence` contains the protocol and probe timestamp. A running PID alone cannot construct it. `ServiceDetails` preserves database catalogs and Mailpit UI information without turning every driver-specific property into an optional common field. Use a tagged binding requirement internally instead of the sketch's optional runtime field if Swift validation cannot make construction private.

```swift
public actor ManagedServices {
    public func catalog(_ query: ServiceCatalogQuery = .all) async throws -> ServiceCatalog {
        fatalError("not implemented")
    }
    public func create(_ request: NewServiceInstance) async throws -> ServiceInstanceSnapshot {
        fatalError("not implemented")
    }
    public func apply(_ change: ServiceDemandChange) async throws -> ServiceDemandResult {
        fatalError("not implemented")
    }
    public func package(_ change: ServicePackageChange) async throws -> ServiceCatalog {
        fatalError("not implemented")
    }
    // Startup recovery and Core quit are internal daemon lifecycle hooks.
}
```

`catalog` returns approved releases, installed packages and fresh instance snapshots, with explicit unknown observations if a probe fails. `package` supports install and remove for compatibility with existing package workflows. Package removal is blocked while any instance pins it, even when stopped. There is no generic data destroy, rename, arbitrary executable, shell-command, or automatic major-upgrade operation. Typed package IDs originate from the approved catalog. Internal storage and IPC DTOs are absent from this API.

These four operations hide artifact staging, verification, initialization, path assignment, endpoint reservations, durable intent, process ownership and protocol observation. Callers supply domain intent and render outcomes. That is the interface-depth gain. Avoid separate caller-visible `install → use → initialize → launch → saveIntent` operations. The existing CLI compatibility commands can still express their historical stage, but only one kernel implementation performs it.

### Durable structure and dominant access patterns

The daemon holds an exclusive filesystem ownership lock before opening a new `managed-services.sqlite`. One private `ManagedServices` owner writes the catalog. Projects and manual controls publish separate consumer rows instead of editing a shared enabled boolean. This follows Separate Before Serializing Shared State. Serialization remains necessary for actual shared resources such as an endpoint or package.

| Relation | Key and invariant | Dominant read |
| --- | --- | --- |
| Instances | UUID primary key, unique `(kind, canonicalName)`, immutable package pin and storage reference | Selector lookup from manifest, ID lookup from UI |
| Packages | Content-derived package ID, exact product/version/platform/architecture/provenance | Package reuse and eligible version inventory |
| Claims | Unique `(consumer, instanceID)`, with project manifest generation | Consumers for an instance, recorded dependencies for project down |
| Endpoint reservations | Unique `(transport, address, port)` and unique `(instanceID, purpose)` | Stable endpoints across restarts and conflict checks |
| Operations | Operation UUID, target instance, request digest, initialization/launch phase | Retry and recovery after interrupted creation or launch |

Indexes on `(kind, canonicalName)`, claim `instanceID`, and claim `consumer` are part of the initial schema. Names do not change and are not reused by a later destroy feature without an explicit identity policy. New data paths derive from UUIDs, not caller text. Existing default paths are adopted as a verified legacy storage reference without moving data. All four instance kinds have a private data directory, generated config, credentials, process record, socket namespace and logs. Package directories are immutable and shared independently of data directories.

Port allocation reserves stable loopback ports transactionally. New instances use configurable nonprivileged ports. Adoption preserves existing default ports. The reservation is not proof that the OS endpoint is free. Start checks the OS and fails with a conflict if an unrelated process took it. It never silently changes an existing endpoint, kills a conflicting process, or adopts a server merely because its protocol responds.

### Typed drivers and module map

The kernel uses a closed internal driver registry, not public plugins. Typed drivers accept typed persisted records and verified package handles. A single exhaustive dispatch point converts the closed service sum type to its driver. CLI, project planning and UI receive descriptors from the kernel instead of maintaining independent service lists.

```swift
// Private within the managed-services implementation target.
protocol ServiceDriver {
    associatedtype Configuration
    associatedtype DataFormat
    func initialize(_ context: InitializationContext<Configuration>) throws -> DataFormat
    func launch(_ context: LaunchContext<Configuration, DataFormat>) throws -> LaunchRecipe
    func probe(_ context: ProbeContext<DataFormat>) throws -> ServiceReadinessEvidence
    func shutdown(_ context: VerifiedProcessContext<DataFormat>) throws -> ShutdownRecipe
}
```

The driver defines binary roles, initialization, generated configuration, supported data format, readiness, and graceful shutdown. The kernel executes recipes with bounded timeouts and private file permissions. Drivers cannot write catalog claims or choose arbitrary root paths. PostgreSQL knows `initdb`, cluster major compatibility, authenticated local readiness and server shutdown. The Redis-compatible driver knows the selected implementation, RESP readiness, persistence configuration and shutdown semantics. MySQL keeps its initialization/authentication/catalog behavior. Mailpit keeps its SMTP and HTTP readiness and message database configuration.

| Module/file | Knowledge owned |
| --- | --- |
| `VaelenCore/ManagedServices.swift` and domain types | Only public service API and pure demand reduction |
| New internal `VaelenManagedServices` target | Catalog SQL, artifact verification, instance paths, process evidence and driver execution; public factory exposes only the domain API |
| `VaelenManagedServices/Drivers/{PostgreSQL,RedisCompatible,MySQL,Mailpit}Driver.swift` | Typed service-specific behavior |
| `VaelenCore/ProjectEnvironment.swift` | Versioned manifest parsing and `.env` observation, including database/mail/cache comparison |
| `VaelenCore/ProjectReconciliation.swift` | Project plan combines service results with existing PHP, web, DNS and TLS work |
| `VaelenDaemonSupport/CoreRequestDispatcher.swift` | Domain request decoding, authorization already present in the project flow, response adaptation |
| `VaelenIPC/Protocol/ServiceModels.swift` | Versioned wire DTOs and explicit domain conversion |
| CLI output and native app service/project views | Shared snapshot presentation, user actions and error display |

The new internal target needs a small `VaelenServiceDomain` dependency if importing VaelenCore would form a cycle. Put public service types there and re-export only those types through Core. Do not create both a public kernel protocol and a same-shaped forwarding facade. The composition root creates the concrete kernel and injects its domain interface. A service action traces through dispatcher, kernel, driver. Persistence and process helpers are implementation details of that middle boundary.

### Boundary pseudocode and recovery

```text
create(request)
  validate approved package, typed name/configuration and path ownership
  if selector exists with the same completed specification, return fresh snapshot
  if selector exists with a different specification, fail without mutation
  reserve UUID, endpoints and create operation in one catalog transaction
  acquire/verify immutable package in unique staging, publish atomically
  initialize only an empty, operation-owned data directory
  persist a verified data-format marker and completed instance record
  return stopped snapshot

apply(project running)
  resolve every selector and runtime requirement before changing any claims
  transactionally replace only this project's claim set and generation
  derive effective run intent from all durable consumer rows
  reconcile affected instances, in deterministic instance-ID order
  return per-binding fresh observations and partial/failure details

apply(project released)
  read this project's persisted claims, delete only those rows transactionally
  stop affected instances only if their complete remaining consumer set is empty
  return stopped or retained-with-consumers observations

reconcile(instance)
  re-read current intent after every asynchronous boundary
  verify recorded PID, executable, start time, launch token and instance/config identity
  if ownership cannot be proved, expose conflict and send no signal
  if running is desired and no owned process exists, persist prepared launch then spawn
  launch a foreground process with an instance launch marker, then persist PID evidence
  verify protocol readiness against this exact endpoint and process
  if stopped is desired, request graceful shutdown of verified owned process only
  on timeout retain visible unhealthy state and data; do not auto-force-kill databases

startup
  recover interrupted operations before accepting new mutations
  scan prepared launches using executable + instance argument/config + launch marker
  adopt only fully verified descendants; ambiguous evidence becomes conflict
  never reinitialize a nonempty or uncertain directory
  reconcile persisted claims and probe every observed process again
```

Swift actors reenter while awaiting I/O. Each instance has one reconciliation task and a generation counter. A pending operation re-reads the generation before spawn and after readiness. Concurrent up/down updates collapse into the latest durable desired state. Catalog transactions never span downloads or process waits. A daemon lock prevents a second process from bypassing that ownership model.

Project activation retains accepted claims if one dependency fails to start. Its result is partial and identifies every failure. It does not roll back by stopping a service another consumer may have acquired. Retrying the same request converges. This follows Make Operations Idempotent. A newer manifest replaces the project's claims atomically, then reconciles removed dependencies. The request digest makes a lost IPC reply safe to retry.

Core quit stops verified owned processes but preserves claims. Startup restores them. Closing a project view or losing a CLI connection does not release a claim. Project down is explicit. Removing a registered project must first release its recorded claims. Claims do not expire on a timer, so an interrupted developer session cannot stop a still-used database. Manual stop removes only the manual claim and reports remaining project consumers. Ordinary force stop is outside this design.

New PostgreSQL and MySQL instances initialize once and record a data-format compatibility identity. A package pin cannot be changed through an ordinary start. New Redis-compatible instances explicitly enable durable persistence in their private data directory and expose its durability mode in details. They never run flush/reset commands. Files surviving a failed initialization remain visible as `initializationIncomplete`, with recovery instructions. They are never treated as empty because metadata is missing. Default Mailpit adoption retains the existing message store.

### Project and compatibility migration

Version 1 `services.mysql: true` and `services.mailpit: true` normalize into bindings to the corresponding `default` instance. False means no dependency claim. It does not mean stop a manually started service. Version 2 accepts only typed bindings and rejects mixed boolean/binding ambiguity, duplicate roles and unknown kinds. An invalid manifest creates no new claims. Down still uses persisted claims.

Import existing verified default instances and selected packages into the catalog idempotently. Keep original paths and credentials. Map old enabled keys to manual claims once. The import marker and imported records commit together before legacy intent writes are disabled. Existing data with unclear ownership produces an adoption diagnostic rather than fresh initialization. Do not import healthy state from disk.

Keep existing MySQL/Mailpit IPC methods and CLI syntax as boundary adapters targeting the imported `default` instance. Their response conversion preserves established fields. Move daemon, CLI and app internal callers to the generic API in the same delivery unit, then remove the singleton lifecycle writers. The compatibility adapter is a wire-contract cost, not a second implementation. Existing package remove remains data-preserving; the new all-instance pin check may require an actionable `package in use` error. Legacy package selection changes are accepted only when the existing instance's data-format check permits them.

The app retains package inventory but adds a real instance list, Create flow and instance details. Project details show each role and resolved instance, with Activate dependencies and Down actions. Existing PHP, routing and privileged capability controls remain separate from this service kernel. Boundary Discipline puts raw YAML/IPC validation at adapters. Model the Domain puts instance state, claims and readiness in one typed structure. Minimize Reader Load keeps process policy out of CLI and SwiftUI.

### Package provenance and licensing

Observed upstream facts are separate from the delivery proposal. PostgreSQL publishes source archives and links macOS binaries, and its macOS page describes an EDB binary archive intended for embedding. PostgreSQL's own license permits distribution with required notices. This does not verify an EDB or Postgres.app artifact's full dependency license set. [PostgreSQL downloads](https://www.postgresql.org/download/), [macOS packages](https://www.postgresql.org/download/macosx/), [license](https://www.postgresql.org/about/licence/).

Valkey's installation documentation offers official source releases. Its COPYING file uses BSD-3-Clause terms. Its documentation's macOS package-manager paths do not establish a standalone redistributable macOS archive. [Valkey installation](https://valkey.io/topics/installation/), [COPYING](https://github.com/valkey-io/valkey/blob/unstable/COPYING).

Redis 8 and later offer AGPLv3, RSALv2 or SSPLv1 choices. Therefore a newer redis-server package needs an explicit license and delivery decision. This candidate proposes Valkey as the named Redis-compatible runtime and requires explicit `--runtime valkey`. It does not advertise Valkey as redis-server or promise Redis module parity. [Redis licensing](https://redis.io/legal/licenses/).

The proposed launch lane is Vaelen-built PostgreSQL and Valkey archives from pinned official source tags, built on clean macOS CI for each supported architecture. Build dependencies are pinned and bundled where required. End-user installation needs neither Homebrew nor a compiler. A signed Vaelen catalog records upstream source URL and hash, build recipe revision, exact runtime implementation/version, platform/minimum OS/architecture, binary archive hash, license expression, notices, bundled dependency SBOM and signing identity. The downloader verifies the catalog signature and archive hash. Extraction rejects path traversal and escaping symlinks. Eligibility verifies executable architecture/version, signatures according to the selected package policy, and linked libraries. It rejects `/opt/homebrew`, `/usr/local` package-manager dependencies and unbundled non-system libraries, including transitive dependencies.

Use existing verified MySQL and Mailpit package lanes as driver inputs, without claiming their existing checks are sufficient for the new catalog. Retain their current source, hash and license metadata. Shipping each catalog entry requires inspecting its concrete artifact and notices. Package provenance is a release gate, not an assumption hidden in a service driver. No download URL or hash is invented by this design.

## Synthesis decision

Pending parent synthesis. Candidate B's base is the managed instance kernel and typed drivers. The intended winning property is one owner for package/data/process coordination across all four services. Do not graft a second path in which project activation invokes singleton modules directly.

## Tradeoffs accepted

- We accept an up-front MySQL/Mailpit extraction in exchange for one lifecycle policy that later service additions cannot bypass.
- We accept an opaque local ID plus immutable human selector in exchange for safe paths, portable manifests and stable UI identity.
- We accept explicit instance creation before project up in exchange for preventing accidental dataset creation under a mistyped binding.
- We accept durable claims that require explicit down in exchange for never stopping a shared instance because a client disappeared.
- We accept a build-and-publish responsibility for standalone artifacts in exchange for independent installation and verifiable runtime provenance.
- We accept a closed driver registry in exchange for exhaustive typing and fewer extension points than an unproven plugin system.

## Alternatives considered

- Four standalone service managers behind a thin instance inventory would preserve current module code. It loses on interface depth because project activation and package removal still coordinate multiple lifecycle authorities and repeat consumer policy.
- A container engine adapter hides server binaries but exposes engine installation, image provenance, network mapping and volume lifecycle to developers. That is a larger runtime dependency and a weaker native local workflow for this scope.
- A universal untyped service descriptor with executable paths and command arrays hides launch mechanics but leaks initialization, readiness and data-format invariants into metadata. Typed drivers earn their complexity by protecting those differences.

## Open questions and risks

- Does the product require the Redis implementation specifically, or is an explicitly labeled Valkey runtime sufficient for this milestone? The proposed default is explicit Valkey; supporting redis-server adds a separate package lane without changing instance identity.
- Which macOS architectures and minimum OS versions will the standalone build catalog promise? The first release should advertise only combinations validated on clean hosts.
- Can the package build pipeline produce reproducible, relocatable PostgreSQL binaries and all required notices within the milestone? Prototype that artifact before committing the UI scope.
- Which exact lifecycle behavior do existing MySQL package-selection clients require? Compatibility tests must make any new pin protection explicit before rollout.
- How will a developer retire unused named instances without data deletion? This scope intentionally retains data; a future archive/forget workflow must preserve selector identity and never become implicit down behavior.

## Candidate score

Scores are design judgments on a five-point scale, not measured implementation outcomes.

| Criterion | Score | Reason |
| --- | --- | --- |
| End-user project workflow | 5/5 | Exact named bindings, explicit creation, shared CLI/app snapshots and endpoint diagnostics form a complete path |
| Durable data/process safety | 5/5 | Separate immutable package pins, durable claims, verified process identity, recoverable operation phases and no destroy path |
| Backward compatibility | 4/5 | Default instances, legacy paths and wire adapters survive; internal module extraction and package pin restrictions need focused regression work |
| Duplication/interface depth across Core/IPC/CLI/UI | 5/5 | Four domain operations own coordination; typed details and one descriptor source replace per-service orchestration |
| Safe project start/down with shared instances | 5/5 | Transactional per-consumer claims and generation-aware reconciliation prevent one project stopping another's service |
| Package provenance and licensing | 4/5 | Explicit implementation and catalog contract are strong; clean-host artifact production remains unproven |

The principal risk is migration size. A kernel that leaves old singleton writers active earns none of the ownership benefits and should be rejected at review.

## Next implementation step

Build a disposable PostgreSQL/Valkey package eligibility spike and a claim-reconciliation harness covering two projects sharing one instance, lost replies, interrupted initialization, spawn-record crashes, manifest changes and down, then implement the catalog and driver extraction against those observed boundaries.

Verification for the eventual implementation must include `Scripts/test.sh` compatibility suites for MySQL/Mailpit, isolated real server fixtures for persistence and protocol readiness, CLI up/down with two live projects, Core restart with retained data, external port/PID conflicts, and native app instance/create/project flows. This candidate writes only this architecture artifact and makes no claim that those lanes have passed.
