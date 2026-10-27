# Catalog-backed singleton project bindings

## Usage (caller's view)

An already installed, initialized MySQL and an installed Mailpit can be selected explicitly:

```yaml
version: 2
services:
  database:
    kind: mysql
    instance: default
    version: mysql-8.4.11
  mail:
    kind: mailpit
    instance: default
    version: mailpit-1.31.1
```

`val project plan` reports the exact package, loopback endpoints, existing data location, health, and whether the project owns a claim. `val project up` claims and starts these existing singletons. It never installs or initializes MySQL. Mailpit's existing start may create its default message store. `val project down` releases both claims and leaves both services running. `val mysql stop` and `val mailpit stop` remain explicit global service actions. Package removal reports the claiming projects before changing service intent or stopping anything.

Native adoption lists `mysql/default` and `mailpit/default` with exact package, endpoints, path, health, and owners beside the existing PostgreSQL/Valkey choices. Unsupported/nondefault declarations remain visible as blocked; the UI cannot create a named MySQL or Mailpit instance. A missing declaration version can resolve only from a currently verified catalog record. Adoption writes the exact selected package identifier into its new V2 declaration.

The three integration call sites are deliberately small; names below are proposed signatures rather than current APIs:

```swift
// CoreRequestDispatcher.projectEnvironmentReport and service.instances:
try refreshSingletonCatalog() // metadata reconciliation only; never start/install/initialize
let inventory = try serviceInstances.inventorySnapshot()
let observation = try observeProjectService(binding, inventory: inventory)

// Existing project activation, after a fresh declaration read and lifecycle preflight:
let prepared = try prepareProjectServices(spec.services, projectID: projectID)
try serviceInstances.replaceProjectClaims(prepared.bindings, for: projectID)
for binding in prepared.bindings { try activateProjectService(binding) }

// Existing deactivation: one policy switch, before accessing a driver:
switch ProjectServiceSupport(binding: binding)?.releaseBehavior {
case .releaseOnly:
    try serviceInstances.removeProjectClaims(bindingsForInstance, for: projectID)
case .stopWhenUnclaimed:
    // Existing exact PostgreSQL/Valkey final-owner stop/verify/release path.
default:
    // Existing unsupported legacy-claim release path; never call a runtime stop.
}
```

## Problem

V2 claims already require schema-9 catalog rows, while MySQLModule and MailpitModule own production singleton `default` runtimes and established paths. Adding them as ordinary named lifecycle instances would invent ownership they do not have. Keeping them as global V1 observations would lose exact catalog identity and durable removal protection. The design makes the singleton a catalog identity while keeping its lifecycle in its existing module. V1 booleans and global service intents retain their existing behavior; `.env` remains evidence only.

## Shape

### Data structures first

Reuse `ServiceInstanceID`, `ServiceInstanceRecord`, `ServiceInstanceEndpoint`, `ProjectServiceBinding`, and `ServiceInstanceClaim` unchanged on disk. A singleton catalog row means “this exact installed local singleton identity,” not a newly provisioned instance. `ServiceInstanceRecord.dataDirectory` carries MySQL's datadir and Mailpit's **message database file path**; document that existing column's broader location meaning instead of taking Mailpit's parent directory and losing identity.

Add the following domain types in `Sources/VaelenCore/ProjectReconciliation.swift`, adjacent to the existing closed service-support policy. These are domain values, never IPC or SQLite objects:

```swift
public enum ProjectServiceReleaseBehavior: Sendable {
    case stopWhenUnclaimed
    case releaseOnly
}

// Replaces ProjectManagedServiceKind; no registry or extension protocol.
public enum ProjectServiceSupport: Equatable, Sendable {
    case postgresql, valkey, mysqlDefault, mailpitDefault
    public init?(binding: ProjectServiceBinding) { /* not implemented */ }
    public var releaseBehavior: ProjectServiceReleaseBehavior { /* not implemented */ }
    // mysqlDefault/mailpitDefault require instance.value == "default" here.
    // Static package checks remain for PG/Valkey; singleton packages come from modules.
}

public enum ProjectServiceReadiness: Equatable, Sendable {
    case healthy
    case startable
    case blocked(reason: String)
}

public struct ProjectServiceRuntimeObservation: Equatable, Sendable {
    public let record: ServiceInstanceRecord? // nil if no verified installed package
    public let readiness: ProjectServiceReadiness
    public let health: String                // existing public diagnostic vocabulary
    public init(record: ServiceInstanceRecord?, readiness: ProjectServiceReadiness, health: String)
    // Observation is evidence, never authority to mutate; exact-start always revalidates.
}

extension MySQLModule {
    public func projectServiceObservation() -> ProjectServiceRuntimeObservation {
        fatalError("not implemented")
    }
    public func startProjectService(expected: ServiceInstanceRecord) throws {
        fatalError("not implemented")
    }
}
extension MailpitModule {
    public func projectServiceObservation() -> ProjectServiceRuntimeObservation {
        fatalError("not implemented")
    }
    public func startProjectService(expected: ServiceInstanceRecord) throws {
        fatalError("not implemented")
    }
}
```

Observation and exact-start live **in each module's source file**, with access to package validation, configuration, instance metadata, and process identity. `startProjectService(expected:)` is a policy-bearing adapter, not a same-shape pass-through: validate default identity, exact package/endpoint/path and startability immediately before existing `start()`, call it, then require the same record and healthy readiness. It has no instance-ID argument and cannot initialize a service. The old `start()/stop()` APIs remain the global service interface. Share their existing internals rather than implement a second process launcher.

`ProjectServiceSupport` is the single exhaustive policy list. Its failable initializer rejects nondefault singleton names. Do not make generic `ProjectServiceBinding.init` reject these names: the manifest parser should still represent unsupported declarations and report them clearly. Exact matching requires binding ID equality, declared version absent or byte-for-byte equal to the catalog package, and `runtime.record == catalogRecord`. No suffix matching for singleton versions, no port-only or absolute-path-only approximation. An absent version cannot supply identity when the record or verified installed package is missing.

### Module-owned identity rules

MySQL constructs `mysql-<verified installed package.version>` from `selectedPackage()`/validated installed inventory, requires its configured singleton really is `default`, validates the package executable and existing module identity checks, and uses the exact status datadir and TCP endpoint. Reject port 0/socket-only configurations as unsupported for V2 TCP bindings. `.installed` / `not-initialized` always blocks. `.stopped` is startable only when instance metadata says initialized **and the next start's configured TCP port and data location equal the snapshot**. This matters because current `start()` may rewrite metadata to its configured port. Never mutate metadata in order to make identity match. Healthy requires current `.running` and `healthy`, retaining executable/PID/start identity/readiness checks. Unhealthy/conflict/starting is blocked.

Mailpit constructs `mailpit-<verified package.version>`, exact SMTP and HTTP ports, and `instanceDatabasePath()`; both endpoints participate in equality. `.installed` with verified package and available configured ports is startable, as is `.stopped`. Healthy retains owned-child, executable, arguments, process identity, SMTP and HTTP readiness requirements. A process discovered only by listening port is never adopted. After Core restarts, an old Mailpit process record without the current module's owned child remains `identity-unverified`; neither catalog refresh nor project up reconstructs owned-child authority from disk. Observed process ports or DB location differing from configured launch identity blocks activation instead of rewriting a record to conceal drift.

Both modules can supply a verified installed identity with blocked readiness, so inventory can show uninitialized/unhealthy services with reasons. Invalid package material supplies no usable new record. Existing claimed catalog records remain available as evidence even when live identity disappears.

### Catalog ownership and repository signatures

`Sources/VaelenCore/ServiceInstanceCatalog.swift` remains the only owner of catalog and claim SQL. Add:

```swift
extension ServiceInstanceRepository {
    /// Only mysql/default or mailpit/default. Insert if absent; no-op if equal.
    /// Replace a different record only when BOTH manual and project claims are empty.
    /// One SQLite transaction performs compare, owner check, and replacement.
    public func reconcileSingletonRecord(_ observed: ServiceInstanceRecord) throws {
        fatalError("not implemented")
    }

    /// Throw with claiming projects if any project claim exists for this singleton.
    /// Removal safety is intentionally independent of current runtime health/version.
    public func requireSingletonUnclaimed(_ id: ServiceInstanceID) throws {
        fatalError("not implemented")
    }
}
```

Keep existing immutable `saveInstance` for isolated instances. `reconcileSingletonRecord` is a constrained domain operation, not a general upsert escape hatch. On a conflicting claimed record, keep it and return a typed identity-conflict error; report/plan translates that to blocked without failing unrelated services. On a missing live package, do not delete a claimed record or synthesize a package. Repeated reconciliation is idempotent. Persisted records carry no health, initialized flag, PID, or copied ownership state; all derive at the read boundary.

The dispatcher invokes metadata refresh on `service.instances`, project report, adoption preview/apply, and after successful global install/initialize/start/use. This ensures existing installations become discoverable without requiring a manual start. Refresh only reconciles a module-produced verified record; it cannot create a datadir, message database, intent, claim, or process. If an unclaimed row becomes stale because the package disappeared, inventory may retain it as unavailable evidence, and adoption must disable it. On successful package removal, call existing `removeStoppedInstance` to drop its now-unclaimed catalog record. Crash between package deletion and row deletion is safe: subsequent exact live observation blocks the stale row, and metadata cleanup/reinstall can recover.

### Daemon integration and signatures

Keep the closed runtime adapter private in `CoreRequestDispatcher.swift`; rename it to `ProjectServiceDriver` and add `.mysql(MySQLModule)` / `.mailpit(MailpitModule)`. Its methods are policy-bearing adaptations:

```swift
private enum ProjectServiceDriver {
    // Existing isolated cases plus singleton cases.
    func observe(id: ServiceInstanceID) throws -> ProjectServiceRuntimeObservation
    func start(expected: ServiceInstanceRecord) throws
    // Existing isolated stop dispatch remains private; singleton cases throw unsupported.
    // Project release consults support.releaseBehavior first, so singleton stop is unreachable.
}

// All private, synchronous and actor-isolated; no public staged lifecycle API.
private func refreshSingletonCatalog() throws
private func observeProjectService(_ binding: ProjectServiceBinding,
    inventory: ServiceInstanceInventorySnapshot) throws -> ProjectServiceBindingObservation
private func prepareProjectServices(_ bindings: [ProjectServiceBinding],
    projectID: ProjectID) throws -> PreparedProjectServices
private func activateProjectService(_ binding: ProjectServiceBinding) throws
```

`PreparedProjectServices` is a private immutable value containing bindings and exact validated records for the current non-suspending mutation segment. It is not persisted or sent over IPC. Activation reobserves before start, so this value is not a long-lived authority token.

Extend the existing report observation with typed readiness internally, preserving `health` for CLI/IPC diagnostics. Make readiness an additive optional wire field if it must cross IPC; old decoding remains valid. Planner logic acts on `.startable`, not string rewriting that would conflate installed MySQL and installed Mailpit. V2 reporting obtains the expected application endpoints from selected exact binding records, including Mailpit SMTP, rather than assuming global defaults; `.env` mismatch remains a review blocker and never triggers application-file changes. V1 desired booleans still use the existing global MySQL/Mailpit planner branches.

Interface depth: callers obtain an observation or request an exact start; package selection, initialization gating, path provenance, launch-port drift and process ownership stay inside the module. The repository owns atomic metadata rules. The daemon owns project membership and request ordering. Typical path is planner → dispatcher → service module; SQL operations are a separate ownership boundary, not another orchestration layer.

## Lifecycle, failures, and retries

1. **Plan/report:** inspect without runtime mutation; reconcile discoverable catalog metadata; compare declaration to exact catalog and live module record. Wrong version/nondefault ID/missing package/identity drift/uninitialized MySQL blocks. A fresh installed Mailpit can be startable without a DB file. Plan never claims.
2. **Up:** after every awaited project/report collection, enter one synchronous CoreRequestDispatcher actor segment. Fresh-read records, module observations and claims; validate every desired binding before replacing claims. Existing retirement logic stops only isolated final-owner instances; singleton retirement only releases membership. Atomically replace desired claims using existing repository transaction. Start each eligible stopped singleton through exact-start. Claim precedes runtime mutation, so package removal is prevented during failure/retry. Failure retains the claim and reports actual health; retry observes again and either idempotently succeeds or remains blocked. No compensating singleton stop on another binding's failure.
3. **Down:** load persisted claims, group by full `(kind,name)` identity, and release singleton groups transactionally without querying health or requesting a driver. Even a broken/missing package cannot prevent this release. Repeated down succeeds with no claims. A failed SQL release retains ownership. Other projects/manual global intents do not change this behavior. Existing isolated final-owner semantics remain.
4. **Removal:** for both mysqlRemove and mailpitRemove, require unclaimed `kind/default` before changing service intent, calling stop or removing files. Fail closed if repository/claim lookup is unavailable. Any singleton project claim blocks removal, even if version/live health has drifted; down is the recovery path. Then preserve current ownership-verified stop and package removal; remove catalog metadata last. Manual stop remains allowed with claims and leaves them for future up.
5. **Concurrent requests:** CoreRequestDispatcher is an actor. Claim preflight/write/start and removal guard/intent/stop/remove/metadata deletion are synchronous actor-isolated segments with no `await` between guard and mutation; after any suspension revalidate. Repository transactions protect compare/claim changes; never hold a SQLite transaction while starting/stopping a process. Global mutation requests pass through the same actor. No new lock/lease system or second metadata writer is introduced. External on-disk tampering is detected by package/record/process verification and produces blocked/failed output, not adoption.
6. **Intent/restart:** V2 up must not set the global service-intent flag merely to represent a project claim; that would make an ordinary global intent a second ownership ledger. Preserve existing global intent/recovery behavior. Project claims remain durable and explicit up retries the binding; this feature does not add claim-driven boot startup.

## Native adoption and module map

| Path | Responsibility/change |
| --- | --- |
| `Sources/VaelenCore/ProjectReconciliation.swift` | Closed support/release policy and typed readiness; V2 planner handles singleton exact bindings; V1 branches preserved. |
| `Sources/VaelenCore/MySQLModule.swift` | Exact singleton observation/start adapter using existing private package, metadata and process checks. |
| `Sources/VaelenCore/MailpitModule.swift` | Exact singleton observation/start adapter using existing default store and owned child checks. |
| `Sources/VaelenCore/ServiceInstanceCatalog.swift` | Only SQL writer; constrained reconciliation and claim-removal guard. |
| `Sources/VaelenCore/ProjectEnvironment.swift` | Observation domain/wire-compatible fields and selected-binding endpoint derivation; no file mutation. |
| `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift` | Catalog refresh, driver integration, atomic actor segments, up/down/retirement/removal guards, adoption fresh-evidence validation. |
| `Sources/VaelenIPC/Protocol/ProtocolModels.swift` | Additive readiness/capability projections if required; no new generic lifecycle commands. |
| `App/Vaelen/Vaelen/AppModel.swift` | Fetch global MySQL/Mailpit status for singleton inventory rows, rather than sending unsupported service.instance.lifecycle requests; maintain full `kind:name` UI keys. |
| `App/Vaelen/Vaelen/VaelenApp.swift` | Offer four supported kinds, show/disable unavailable singleton choices, label release semantics, use `(kind,name)` row identity (both singletons are named default). |
| `Sources/VaelenCore/ProjectAdoptionApply.swift` | Retain existing create-only V2 manifest writer; no .env changes or data relocation. |

Native UI offers candidates only from refreshed inventory and current exact module observation; a catalog row alone is insufficient. Use `ProjectServiceSupport` as the source for supported-kind projections, eliminating duplicated PostgreSQL/Valkey filters. Adoption apply rechecks session inventory AND live module observations after its awaits; exact snapshot drift expires review. The current apply suffix version check is replaced for singleton bindings by exact identifier equality. Server validation must enforce name/default and readiness even if a malicious or older client submits a choice hidden by the UI. The UI may display uninitialized MySQL, but cannot select it as activatable.

Adoption retains the existing file-write/claim-write rollback boundary: create manifest, transactionally write claims, remove only the just-created matching bytes on failure. Crash after manifest creation but before claims is recoverable by `project up`; the file is not an active claim and does not itself prohibit package removal. Crash after claims commits is recoverable by idempotent up/down. Do not promise an atomic transaction spanning filesystem and SQLite.

## One-way doors and migration

No schema bump and no bulk V1 conversion. Schema 9 already supports typed mysql/mailpit endpoint rows and project foreign keys. First inventory/report access discovers existing verified singleton identity; no data moves or path normalization migration occurs. Persist exact canonical locations supplied by the module; compare the same representation on subsequent reads.

The durable decision is that MySQL/Mailpit `default` refers to the established legacy store, and claims are real catalog claims despite release-only lifecycle policy. Future named isolated modules must add explicit capability/case support; they must not silently reinterpret or move `default`. Exact package updates require all claims released before reconciliation can replace identity. A future upgrader must make that transition explicit rather than weakening equality.

Downgrading to current code keeps schema readable, but current old binaries lack singleton package-removal guards and cannot honor the new protection. This is an operational compatibility limit, not a database migration failure. Do not encode fake manual claims as a downgrade workaround.

## Tradeoffs accepted

- We accept metadata writes during inventory/report reconciliation in exchange for one durable catalog used by reports, adoption, claims and removal guards; these writes never provision services.
- We accept a constrained singleton reconciliation operation alongside immutable isolated save in exchange for upgrading an unclaimed legacy singleton without inventing an instance recreation API.
- We accept adding two exact-start module adapters in exchange for keeping module-private path/configuration/process rules out of orchestration.
- We accept explicit global stops interrupting project connectivity in exchange for preserving the existing global service controls and meaningful durable project claims.
- We accept releasing claims before an exact package change in exchange for refusing silent retargeting of active projects.

## Alternatives considered

**Distinct V2-only legacy observations:** let V2 mysql/mailpit bindings read global statuses directly and bypass the catalog while leaving PostgreSQL/Valkey on catalog claims. This looks smaller at the planner boundary, but schema 9 prevents such claims. Making the approach viable requires a second durable ownership table or relaxing the catalog FK, plus separate inventory/adoption/removal logic. Its public binding shape appears uniform while callers must learn two sources of identity and claim semantics. It hides less complexity and splits the most important invariant: which package an active project protects. Reject it.

**Generic lifecycle registry/protocol:** wrap all services in a create/start/stop/remove registry with capability flags. This forces singleton modules to pretend to accept instance IDs and pushes capability checks into each caller. Four closed cases with one explicit release policy hide more complexity with less exposed surface. Reject it.

## Rationale and red-flag screen

Boundary discipline: module observations validate external package/process/filesystem evidence once and expose domain records. Encode lessons in structure: singleton support admits only default and release-only policy; typed readiness prevents installed MySQL from sharing Mailpit's startable branch; exact-start always revalidates observations. Single source of truth: repository owns claims, modules own runtime identity, catalog never stores duplicate health or initialization flags. Idempotent operations: reconcile, claims replacement, healthy start, and empty down all tolerate retry.

| Red flag | Result |
| --- | --- |
| Shallow module | Exact-start adapter hides package/config/path/process policy; no public staged prepare/commit API. |
| Information leakage | Dispatcher never assembles legacy data paths or package IDs; module snapshot supplies them. Wire projections stay at IPC boundary. |
| Temporal decomposition | No separate loader/validator/writer service stack; module owns identity at observation and mutation. |
| Pass-through methods | Exact-start performs pre/post invariants; no same-argument forwarding API added to the modules. |
| Split ownership | Only repository writes catalog/claims; no global-intent mirror of claims. |
| Two ways to do one task | V2 always uses catalog claims; V1 global observation is retained as a versioned compatibility contract, not an alternate V2 branch. |
| Importable internals | Driver, prepared values and orchestration helpers private; observations are inert domain values and never authorize start without module revalidation. |
| Hand-synced list | Exhaustive ProjectServiceSupport switch drives support/release/UI projections; module cases supply identity, with exhaustive tests guarding projections. |

## Synthesis decision

Candidate A selects catalog-backed singleton records and real project claims as its base. Keep this candidate's constrained metadata reconciliation, module-owned launch-identity verification, release-only policy, and no-await removal segment together: dropping one weakens the others. Parent arena synthesis records its final selection separately.

## Open questions and risks

- Should a future product feature restart claimed singleton services automatically on Core boot? This design deliberately preserves current global intent recovery and requires explicit project up for project-driven retries.
- Should a future manifest version support socket-only MySQL? This V2 feature requires a real TCP endpoint and blocks port-zero configurations.
- Is automatic upgrade of an active singleton desirable? It requires a separate reviewed release/rebind operation; this design blocks it.

None of these questions blocks the specified feature.

## Verification contract and next implementation step

Write repository/planner regression tests first, then module adapters, then dispatcher/native integration. Extend `Tests/VaelenCoreTests/ServiceInstanceCatalogTests.swift`, `ProjectReconciliationTests.swift`, `MySQLModuleTests.swift`, `MailpitModuleTests.swift`, `ProjectEnvironmentTests.swift`; add/extend `Tests/VaelenIPCTests/ProjectAdoptionApplyTests.swift`, `ServiceInstanceInventoryTests.swift`, and a bounded singleton project lifecycle test file.

Required cases: both default discoveries; nondefault rejection; explicit/missing/wrong exact version; Mailpit both-port/path mismatch; uninitialized MySQL never initialize/start; configured-port drift blocks before MySQL metadata changes; missing/invalid package; unhealthy/external process remains untouched; installed Mailpit starts using the current DB path; healthy up idempotence; start failure retains claim; down releases while running/unhealthy/package missing; mixed singleton/isolated retirement; another project and multiple aliases; removal blocked before intent/stop/files on active claims; removal available after down; claim lookup unavailable fails closed; unclaimed stale record replace vs claimed mismatch; adoption live drift expires; two default UI rows retain unique identity; V1 planner/global intent behavior unchanged; no `.env` byte changes or data movement.

Run focused suites with `Scripts/test.sh --filter <Suite>` and follow `.agents/skills/verify-vaelen/SKILL.md` for actual CLI/Core evidence before independent review. Use `.agents/skills/verify-vaelen-app/SKILL.md` for native adoption; inspect both singleton choices and down's leave-running result. This design-only artifact has not run tests or changed source.

Phase status: Ground complete from supplied grounding plus authoritative source inspection; Sketch complete in this file; Agree delegated to parent synthesis; Implement and Scrap out of scope for this design-only runner.
