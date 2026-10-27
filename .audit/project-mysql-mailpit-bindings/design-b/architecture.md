# Candidate B: a project-binding facade over catalog-backed singleton adapters

## Usage (caller's view)

An initialized, installed MySQL default instance and an installed Mailpit package can be selected explicitly:

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

`val project plan` reports the exact local package, endpoints, storage, claim, and whether the service can be started. `val project up` claims the selected services and starts those that are safely startable. Uninitialized MySQL is blocked with an instruction to initialize it through the existing explicit service action. `val project down` releases these project claims and leaves both runtimes alone, including when this project was their final owner. An explicit global service stop retains its current meaning. Removing a package while a project claims its singleton fails before changing service intent, stopping a process, or removing files.

In native adoption, the developer chooses MySQL/default or Mailpit/default from Core's eligible inventory, assigns an alias, and reviews the exact package and endpoints. Apply writes the V2 manifest through the existing adoption writer and commits its claims; it does not start services. `.env` remains observation only. Neither activation nor adoption moves service data.

The dispatcher has three realistic call sites. These are sketches of the new interface, not compilable implementation:

```swift
// CoreRequestDispatcher.projectEnvironmentReport, after ordinary observation.
let serviceView = try projectBindings.inspect(
    declarations: spec.services, projectID: project.id)
return report.withServiceBindings(serviceView.observations)

// CoreRequestDispatcher.activate; other PHP/Node/route work stays here.
let outcome = try projectBindings.activate(
    declarations: spec.services, projectID: projectID,
    reviewed: freshReport.serviceBindings ?? [])
results.append(contentsOf: outcome.operations)

// The existing mysqlRemove / mailpitRemove IPC handlers.
let packages = try projectBindings.removeSingletonPackage(
    .mysql, version: params.version)
return mysqlVersionsResponse(packages)
```

`deactivate` calls `projectBindings.release(projectID:)`; adoption calls the same facade's `claimForAdoption` inside the existing manifest-create/rollback boundary. Callers cannot select a “stop after release” option.

## Problem

Schema 9 already gives claims a durable, typed catalog parent. PostgreSQL and Valkey have exact instance-ID lifecycle methods, whereas MySQL and Mailpit own production singleton paths and expose no such lifecycle API. Extending the existing uniform start/stop driver to these services would make final-owner stop look valid when it is prohibited. A V2 bypass over global status would make the catalog stop being the ownership authority. The solution must preserve V1 booleans and global service commands, require exact package/endpoint/path identity, refuse implicit MySQL initialization, preserve Mailpit's current process-identity restrictions, and support consistent CLI and native adoption.

## Shape

Choose one deep `ProjectServiceBindings` facade for **V2 project service policy**, backed by the existing repository and a closed private sum of isolated-instance and default-singleton adapters. Move the existing PostgreSQL/Valkey service preflight, claim reconciliation, activation, and release logic into this facade rather than leave a second V2 route in the dispatcher. This is a bounded relocation of existing behavior, not a new lifecycle registry or plugin framework. Leave V1 planning and its global MySQL/Mailpit observations in place.

The facade owns knowledge of how a project claim affects a service. Each service module continues to own package validation, expected paths, process identity, readiness, and safe start/stop. The repository alone owns SQL. These are separate invariants, not synchronized copies of the same state, per single-source-of-truth and boundary-discipline.

The public surface hides exact matching, missing catalog materialization, all-or-nothing claim replacement, singleton release policy, start verification, and removal exclusion. The dispatcher only passes declarations and renders results. Relative to the policy hidden, six domain operations are a deep interface. No public driver, arbitrary closure-based registry, runtime mode flag, or wire type is exposed.

### Data structures first

Existing `ProjectServiceBinding`, `ServiceInstanceID`, `ServiceInstanceEndpoint`, and `ServiceInstanceRecord` remain the durable shapes. A singleton record always has `name == default`. MySQL's `dataDirectory` is the existing default `data` directory. Mailpit's `dataDirectory` is its existing default instance **directory**, never the `messages.db` file. The exact message database path is checked by its adapter against the private expected `instancePaths().database`; it is also carried in the live snapshot below. We neither reinterpret the catalog field nor add a second persisted storage path.

```swift
// Sources/VaelenCore/ProjectServiceBindings.swift (new domain shapes)
public enum DefaultProjectService: String, Codable, CaseIterable, Sendable {
    case mysql, mailpit
    // Derived kind and ServiceInstanceID(default); no arbitrary name input.
}

public enum ProjectBindingReadiness: Equatable, Sendable {
    case healthy
    case startable
    case blocked(ProjectBindingBlocker)
}

public enum ProjectBindingBlocker: Equatable, Sendable {
    case packageMissing
    case unsupportedInstance
    case unsupportedPackage
    case initializationRequired
    case catalogIdentityMismatch
    case runtimeIdentityUnverified
    case endpointConflict
    case unhealthy(String)
    case moduleUnavailable
}

public enum DefaultProjectStorage: Equatable, Sendable {
    case mysql(dataDirectory: String)
    case mailpit(instanceDirectory: String, databasePath: String)
}

/// Minted by the service module after validating its own package and paths.
/// Its initializer is internal to VaelenCore, not a caller-trusted assertion.
public struct DefaultProjectServiceSnapshot: Equatable, Sendable {
    public let service: DefaultProjectService
    public let record: ServiceInstanceRecord?  // nil when installed identity is absent
    public let storage: DefaultProjectStorage
    public let readiness: ProjectBindingReadiness
    public let health: String                 // existing truthful status vocabulary
    // Internal initializer and package/path checks.
}

/// All supported V2 bindings use one assessed observation shape.
public struct ProjectBindingAssessment: Equatable, Sendable {
    public let observation: ProjectServiceBindingObservation
    public let readiness: ProjectBindingReadiness
    public let releasePolicy: ProjectClaimReleasePolicy
    // Internal initializer, produced only after declaration/catalog/live comparison.
}

public enum ProjectClaimReleasePolicy: String, Codable, Sendable {
    case releaseOnly
    case stopFinalOwner
}
```

These live types do not persist readiness, process IDs, or transient health. Every inspection derives them again. A project claim still stores only project ID, alias, kind, instance, and the optional declared version. Omitted version is allowed for a singleton only when the adapter supplies a full, verified exact local record. Explicit version must equal that record's complete package identifier; `8.4`, suffix matching, and the adoption handler's current `hasSuffix("@...")` concession do not validate a MySQL/Mailpit binding.

`ProjectServiceBindingObservation` gains an optional domain assessment field suitable for Codable reports: a small `ProjectBindingAvailability` value containing readiness category and blocker code/reason. It does not carry a private driver or the storage snapshot. Optional decoding preserves older IPC fixtures. For production V2 reports, the facade always supplies the field for all four supported kinds. The pure planner consumes this field instead of independently reconstructing support from package prefixes or endpoint string counts. Old observation fixtures for PostgreSQL/Valkey may use the existing exact matcher until those fixtures are migrated; production has one path. MySQL/Mailpit are never accepted through that fallback.

The enum of supported adapters is private in the facade file:

```swift
private enum ProjectBindingRuntime {
    case postgresql(PostgreSQLServiceModule)
    case valkey(ValkeyServiceModule)
    case singleton(DefaultSingletonRuntime)
}

private enum DefaultSingletonRuntime {
    case mysql(MySQLModule)
    case mailpit(MailpitModule)
    // inspect and startExactly; deliberately no generic stop(id:) member.
}
```

Isolated instance stop code is only reachable from the PostgreSQL/Valkey cases in `release` and retired-claim reconciliation. Singleton cases only delete claims. Adding another runtime makes these switches non-exhaustive, per encode-lessons-in-structure. `ProjectManagedServiceKind` keeps its present PostgreSQL/Valkey meaning as an internal named-instance matcher; it does not become a misleading umbrella type for singleton stop capability.

### Signatures and visible boundaries

```swift
// Inside MySQLModule.swift and MailpitModule.swift; shared return type above.
public func projectDefaultSnapshot() -> DefaultProjectServiceSnapshot {
    fatalError("not implemented")
    // TODO: derive expected record from validated installed package + private paths;
    // compare current status to those exact facts; map readiness without mutating.
}

// Sources/VaelenDaemonSupport/ProjectServiceBindings.swift (new, internal)
// A synchronous object owned exclusively by CoreRequestDispatcher's actor.
// No async methods or detached tasks: claim/removal decisions cannot interleave.
final class ProjectServiceBindings {
    init(repository: ServiceInstanceRepository,
         mysql: MySQLModule?, mailpit: MailpitModule?,
         postgresql: PostgreSQLServiceModule?, valkey: ValkeyServiceModule?,
         intents: ServiceIntentStore) { fatalError("not implemented") }

    func inspect(declarations: [ProjectServiceBinding], projectID: ProjectID?)
        throws -> ProjectServiceBindingView { fatalError("not implemented") }

    func inventory() throws -> ProjectBindingInventory { fatalError("not implemented") }

    func activate(declarations: [ProjectServiceBinding], projectID: ProjectID,
                  reviewed: [ProjectServiceBindingObservation])
        throws -> ProjectBindingExecution { fatalError("not implemented") }

    func release(projectID: ProjectID) throws -> ProjectBindingExecution {
        fatalError("not implemented")
    }

    func claimForAdoption(declarations: [ProjectServiceBinding], projectID: ProjectID,
                          reviewed: ProjectBindingInventory) throws {
        fatalError("not implemented") // no start; existing manifest rollback owns files
    }

    func removeSingletonPackage(_ service: DefaultProjectService, version: String)
        throws -> DefaultServicePackages { fatalError("not implemented") }
}

// Repository additions, domain inputs; all SQL stays in ServiceInstanceCatalog.swift.
public struct ServiceCatalogExpectation: Equatable, Sendable {
    public let id: ServiceInstanceID
    public let expectedRecord: ServiceInstanceRecord?  // nil means expect no row
    public let desiredRecord: ServiceInstanceRecord
}

extension ServiceInstanceRepository {
    public func replaceProjectClaims(
        _ bindings: [ProjectServiceBinding], for projectID: ProjectID,
        materializing records: [ServiceCatalogExpectation]
    ) throws {
        fatalError("not implemented")
        // TODO: one BEGIN IMMEDIATE; verify project and expected catalog rows;
        // insert missing rows; change differing rows only if no claims at all;
        // then replace the project's claims. Private SQL helpers avoid nesting.
    }

    public func removeUnclaimedSingletonPackage<T>(
        id: ServiceInstanceID, packageIdentifier: String,
        removing body: () throws -> T
    ) throws -> T {
        fatalError("not implemented")
        // TODO: BEGIN IMMEDIATE; fail closed if project claims exist;
        // validate any catalog identity; run bounded stop/removal callback;
        // remove obsolete unclaimed row/manual claim only after package removal.
        // Roll back SQL on failure; package deletion is intentionally not reversible.
    }
}
```

`ProjectServiceBindingView` is assessments plus report observations; `ProjectBindingExecution` is existing reconciliation operation results plus aggregate state. `DefaultServicePackages` is a closed `.mysql([MySQLPackage])` / `.mailpit([MailpitPackage])` result, not an IPC payload. `ProjectBindingInventory` contains `ServiceInstanceInventorySnapshot` plus eligibility/readiness per record ID and the exact current records used for review. It is Equatable so existing adoption snapshot freshness checks remain strict. These small result containers need no behavior beyond construction.

No arbitrary public ID-taking MySQL/Mailpit lifecycle method is introduced. `serviceInstanceLifecycle` remains the named-instance API; native adoption stops polling that API to obtain binding readiness. It gets the assessed inventory from Core.

### Catalog materialization without mutating plan

Inspection and plan are read-only. For MySQL/Mailpit, the facade gets a module-validated current record and compares any existing catalog row. If no row exists, it can describe a prospective exact binding and mark it actionable; activation or adoption inserts that row **in the same transaction as its claim**. No background scan, status call, or V1 action needs to write catalog metadata. The inventory returned for binding selection merges existing catalog rows with these module-produced exact singleton records. A prospective entry is a complete current `ServiceInstanceRecord`, with no claims, eligible only when package inventory and live snapshot agree. It is not inferred from `.env` or an open port.

If a catalog row differs from the current singleton, an active claim blocks replacement and activation. An unclaimed row can be replaced by the claim transaction only when its compare-and-swap expectation still matches. No old claim is silently retargeted. A stale catalog row with missing package remains visible as blocked evidence rather than appearing selectable. A record derived from no package cannot become a prospective entry.

The module's expected paths are authoritative. No caller infers them from `dataDirectory`, strips a `messages.db` suffix, or constructs a default port. Mailpit's two ports remain a typed `.mailpit` endpoint. MySQL validates both the observed port and the configured next-start port: persisted metadata reporting a different port cannot authorize a start that would silently change the project's endpoint.

### Dominant access patterns

| Access | Trace through the shape |
| --- | --- |
| Plan/report | Dispatcher → facade.inspect → repository snapshot + module snapshots; pure assessment; planner renders action or blocker. No writes. |
| Inventory/adoption review | Dispatcher → facade.inventory → same snapshots and assessments. Core exposes eligibility; UI derives kind/instance choices from eligible entries. |
| Up | Facade re-inspects, compares reviewed observation, preflights every desired binding, retires previous isolated instances where needed, transactionally materializes records/replaces claims, then starts and verifies exact targets. |
| Down or removed manifest binding | Facade groups stored claims by ID. Singleton case releases transactionally without touching module; isolated cases preserve current final-owner stop semantics. |
| Package removal | Facade → repository exclusion transaction → module stop/remove callback. Project claims fail before the callback and before service intent changes. |

No additional map or cache is needed. Existing `(kind,name)` primary key, `(project_id,alias)` claim key, and SQL queries are enough. Grouping claims by `ServiceInstanceID` is per-operation local data, so two aliases to one singleton start it once and release together.

### Module map for an implementer

Read these paths; no hidden registry or generated catalog list is assumed:

- `Sources/VaelenCore/ProjectServiceBindings.swift` (new): domain readiness/blocker/snapshot shapes. Keep constructors internal where they assert validation. Do not add package-specific path logic here.
- `Sources/VaelenCore/MySQLModule.swift`: `projectDefaultSnapshot`, using `installedVersions`, `selectedPackage`, `instancePaths`, metadata, status, and configured port. Existing initialize/start/stop behavior remains authoritative.
- `Sources/VaelenCore/MailpitModule.swift`: matching snapshot using manifest-validated package, runtime configuration, private instance/database paths, and existing status/readiness. The `ownedChild` requirement remains intact.
- `Sources/VaelenCore/ServiceInstanceCatalog.swift`: transactional record materialization plus claims and removal exclusion. Existing immutable `saveInstance` remains appropriate for ordinary isolated instances.
- `Sources/VaelenDaemonSupport/ProjectServiceBindings.swift` (new): the single V2 policy facade and closed private adapters. Relocate existing named-instance project logic from dispatcher here without changing its semantics.
- `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift`: report, activate, deactivate, service inventory, adoption session/apply, mysqlRemove, mailpitRemove become facade clients. Preserve V1 branches. No singleton raw module stop/remove bypass remains in removal handlers.
- `Sources/VaelenCore/ProjectReconciliation.swift`: keep legacy appendMySQL/appendMailpit unchanged; V2 binding planning reads assessed availability. Keep unsupported Redis blocked.
- `Sources/VaelenCore/ProjectEnvironment.swift`: optional assessed availability on service binding observations, domain Codable mapping and backward fixture decoding.
- `Sources/VaelenIPC/Protocol/ProtocolModels.swift`: encode assessed inventory eligibility/readiness as an additive optional property on inventory entries. No process ownership token crosses IPC. Old clients ignore the addition; new clients fail closed when eligibility is absent.
- `Sources/VaelenCore/ProjectAdoptionApply.swift`: existing atomic manifest creation/rollback behavior remains; no `.env` write.
- `App/Vaelen/Vaelen/AppModel.swift`: read Core's readiness in the inventory response instead of separately invoking generic instance lifecycle status for a hardcoded kind list.
- `App/Vaelen/Vaelen/VaelenApp.swift`: list all eligible entries, derive picker kinds from them, use kind+name identity for rows (two different kinds both named `default` must not collide), pin selected package, and display release-only behavior for singletons.

Understanding a service operation requires the dispatcher call site, the facade, and the corresponding module. Storage SQL is only needed when changing persistence rules; UI never learns private path or package policy.

## Lifecycle and failure/retry behavior

### Inspect and activate

1. Parse V2 declarations normally. The facade rejects MySQL/Mailpit names other than `default`, unsupported packages, unavailable modules, and mismatched aliases/records. Validation is at the boundary; the planner does not repair inputs.
2. Each singleton module derives its current exact descriptor from its validated installed package. `mysql-<validated version>` and `mailpit-<validated version>` are generated in that module, rather than duplicated reviewed-version strings in the planner. Verify expected directory, executable, endpoint, and live status. Mailpit additionally verifies the exact existing/default message DB path. Merely having a healthy listener is insufficient.
3. MySQL `.installed` / `not-initialized` is blocked. Mailpit `.installed` can be startable: its existing `start()` creates only its own default message store. Healthy means the existing module already proved process identity and readiness. Any conflict, unhealthy, or identity-unverified state blocks mutation. In particular, Mailpit after Core restart must remain identity-unverified when its current code cannot prove `ownedChild` ownership.
4. Preflight every desired binding before changing claims. Compare fresh snapshot identity/readiness with the reviewed observation. The review cannot serve as a capability token: inspect again immediately before mutation.
5. Retire previous claims as current project activation does. A singleton retirement never stops the runtime. For final-owner PostgreSQL/Valkey, stop and verify before removing their claims. If that stop fails, retain old claims and abort desired replacement.
6. Commit the desired claims in one `BEGIN IMMEDIATE` transaction with required new singleton rows. Duplicate aliases fail normally. A concurrently changed expected row fails the transaction; the previous claims survive. Two aliases may share the same singleton, and two projects may claim it, because service identity is fixed and exact.
7. Start each safely stopped/startable instance once. The singleton adapter calls its ordinary `start()` with no instance ID and never calls initialize, use, install, or data migration. Verify the returned and freshly read record against the committed descriptor, plus existing readiness. A failure retains the claim for retry and package protection. Do not claim success solely because `start()` returned.
8. Retry recomputes current facts. A healthy, already claimed singleton is a no-op. An already committed row/claim does not duplicate. A failed/unhealthy runtime stays blocked until existing explicit service actions resolve it.

Claims protect availability intent, not a guarantee that a process can never be manually stopped. Global manual stop remains allowed; the next project report truthfully shows stopped, and V2 up can restart only if its exact identity remains valid. Preserve current V1 behavior: V1 MySQL start remains deferred and legacy Mailpit planning follows its existing decisions.

### Release and package removal

Release uses stored claims even if the manifest disappeared or its version changed. Singleton claim deletion does not require a healthy module or even an installed package; a broken runtime must not prevent project down from releasing ownership. Delete only this project's aliases, retain the row and every other owner. A database failure retains the claim; a retry is idempotent.

Removal must be claim-protected through the destructive action, not only through a preflight read. `removeUnclaimedSingletonPackage` runs its claim check, callback, and catalog cleanup inside the repository's existing `BEGIN IMMEDIATE` mechanism. That blocks competing claim writes on other SQLite connections; the dispatcher actor also executes the synchronous operation without suspension. The callback first verifies installed package ownership, then changes the existing global service intent, invokes the current safe stop, and removes the exact package. It never deletes MySQL data, credentials, or Mailpit messages. If stop or package removal fails, preserve the catalog evidence and propagate the existing module failure. SQL rollback cannot undo a successful process stop; report that partial effect truthfully.

On crash after package deletion but before transaction commit, there were no project claims when deletion was authorized. SQLite rolls back catalog cleanup; the next inventory shows a stale, blocked record and a missing package. Reinstalling the same exact package can restore the descriptor; a future claim transaction can replace an unclaimed stale descriptor after exact verification. Never repair an active claimed descriptor automatically.

Current `mysqlUse` only has one reviewed version, but route identity-changing selection through a facade guard as well: a selection equal to the claimed descriptor is allowed; a different package cannot invalidate a claim. This guard does not silently select a requested version during project activation.

Holding the SQLite write transaction across a bounded stop/removal operation is intentional: it closes the check/use window without introducing a durable lock table or reservation migration. Readers continue using SQLite's existing mode; writers can receive a busy error and retry. The module's existing stop timeouts remain bounds. Do not put network installation or arbitrary asynchronous work in this transaction.

## One-way doors and migration implications

Schema 9 already supports these kinds and typed endpoints. This design needs no schema migration, no runtime directory move, and no automatic V1-to-V2 conversion. Existing catalog rows and claims remain readable. No manual ownership claim is manufactured from the mere existence of a global service intent.

Persisting the first singleton row makes its exact package/endpoint/directory a durable ownership identity. A later module configuration cannot rewrite a claimed row; users must release claims before changing it. Supporting named MySQL/Mailpit instances later requires a real module-level instance lifecycle and storage decision. Do not widen `DefaultProjectService` into a string-name wrapper as a shortcut.

The catalog keeps Mailpit's directory meaning, while the message path is a module-owned derived invariant. Moving `messages.db` in a future module change requires an explicit migration, not updating this facade's path comparison.

New report/inventory readiness fields are additive and optional on decode. New native adoption fails closed against an older Core lacking eligibility. It does not infer support from enum raw values. Existing external consumers of generic service instance lifecycle do not gain MySQL/Mailpit lifecycle capability.

The prospective inventory record is a live, verified descriptor, not an ownership claim. Its persisted counterpart is created only with activation/adoption. This preserves plan's read-only behavior and avoids seeding rows at every global service action. Once claimed, the catalog is the authoritative identity against which live descriptors are compared.

## Tradeoffs accepted

- We accept relocating existing PostgreSQL/Valkey V2 policy into one facade in exchange for one project lifecycle path with no dispatcher branches that can bypass singleton release rules.
- We accept prospective exact singleton descriptors in binding inventory in exchange for read-only plans and no global-service catalog synchronization hooks. A catalog row still exists before every committed claim.
- We accept a short SQLite writer exclusion during bounded package removal in exchange for protection against claim/removal races without schema 10 or a reservation state machine.
- We accept refusing adoption/start during identity uncertainty, including Mailpit's current post-restart uncertainty, in exchange for preserving established process-ownership safety.
- We accept additive inventory readiness in IPC in exchange for deriving native choices from Core rather than hand-syncing support filters and separate status polling.

## Alternatives considered

| Shape | Exact identity | V1 compatibility | Transactional claims / removal | Adoption consistency | Interface depth |
| --- | --- | --- | --- | --- | --- |
| **Chosen catalog + facade + singleton adapters** | One full descriptor comparison, module-owned paths | Separate unchanged V1 path | Existing FK + atomic materialization + removal exclusion | Same assessed inventory as CLI | Small facade hides policy; named/singleton difference remains private |
| **V2-only legacy observation**: planner branches on kind/default, reads global status, never catalogs or claims singleton | Must reconstruct exact package/path rules in report, executor and UI | Superficially simple | Cannot insert normal claims without a row; otherwise must scan manifests or add a second ownership table for removal | Requires native special cases outside service inventory | Shallow: every caller learns global status, exact-match and retention rules |
| **Extend uniform `ProjectManagedServiceDriver` with MySQL/Mailpit and a stop boolean** | Achievable with module adapters | Preservable | Achievable, but every release caller must remember the boolean | Achievable | Exposes invalid singleton stop capability; short code today, repeated policy tomorrow |

The V2-only observation alternative loses decisively. Adding catalog rows to rescue its claim/removal safety makes it the chosen catalog design with a second observation implementation. A separate V2 legacy claim table would require a migration and split removal safety across two ownership stores. Manifest scans do not represent active claims, cannot provide the current transaction boundary, and would make package removal depend on project filesystem availability. Its apparently smaller implementation hides less complexity from its callers.

## Red-flag screen

- **Shallow module:** revised by giving the facade complete V2 inspect/claim/activate/release/removal behavior. Callers do not coordinate snapshots, claim writes, and runtime operations.
- **Information leakage:** package validation and default storage calculations remain inside service modules. Report fields are domain availability, not private process records or drivers. SQLite and IPC types do not enter facade APIs.
- **Temporal decomposition:** no load/validate/save modules. Service modules own runtime identity at every phase; the repository owns durable ownership at every phase; facade owns project policy at every phase.
- **Pass-through methods:** module snapshot functions adapt private package/path/process knowledge into a validated descriptor; the facade hides a complete operation. No extra protocol mirrors module start/stop signatures.
- **Split ownership:** one repository owns all SQL. Live descriptors describe current module facts; catalog records describe committed claimed identity. Their disagreement is an explicit blocker, not synchronized mutable state.
- **Two ways to do one task:** relocate existing V2 named-service policy, rather than leaving it beside the facade. V1 intentionally remains its distinct legacy contract. Do not allow singleton bindings through `serviceInstanceLifecycle`.
- **Importable internals:** the runtime enum and its lifecycle adapters are private to the facade file; module-minted snapshots have internal constructors. Public raw status remains observation, not authority to operate.
- **Hand-synced list:** Core inventory eligibility drives the native kind and instance pickers. Package identity is produced from each module's validated package. Exhaustive enum cases encode lifecycle policy; UI removes PostgreSQL/Valkey-only filters.

## Synthesis decision

This is candidate B's proposed base: the common catalog and a complete V2 policy facade, with a singleton-specific adapter capability that cannot accidentally become final-owner stop. The synthesis orchestrator will record any accepted adaptations. This candidate rejects the V2 legacy bypass and the public uniform stop interface.

## Open questions and risks

- Should package-removal busy failures use the existing generic retry message or a specific project-operation-in-progress message? Either preserves the exclusion and does not require a new persistent state.
- Is an additive inventory readiness field acceptable under the current IPC compatibility policy? If a protocol version bump is required, perform that bump; do not fall back to native support inference.
- Can an existing process be identity-unverified after Core restart while a project claim remains active? Yes under current Mailpit behavior; tests must preserve the blocker, with resolution through the established explicit service workflow rather than new adoption logic.

These are implementation/compatibility checks, not reasons to change the chosen ownership shape.

## Next implementation step

Write module-snapshot tests for exact default identity, uninitialized MySQL, Mailpit installed-startable state, both Mailpit ports, exact database path, and identity-unverified behavior, then build the facade's read-only inventory against those validated snapshots.

## Validation contract for implementation

This candidate performs no product edits or runtime mutations. The implementation lead should run tests through `Scripts/test.sh`, starting with the relevant existing suites and new scoped facade tests:

- `Tests/VaelenCoreTests/ServiceInstanceCatalogTests.swift`: materialization plus claim replacement atomicity, exact row compare-and-swap, active/manual claimed row immutability, default ID enforcement, and SQL rollback.
- `Tests/VaelenCoreTests/ProjectReconciliationTests.swift`: V2 MySQL/Mailpit availability and blockers; unchanged V1 booleans, MySQL deferred behavior, and Mailpit decisions.
- `Tests/VaelenCoreTests/ProjectEnvironmentTests.swift`: `.env` remains untouched and mismatch is reported; default singleton reports use exact endpoints and directories.
- MySQL/Mailpit module suites: installed inventory is required; wrong executable/path/port/DB is rejected; MySQL initialize is never called; Mailpit identity checks remain unchanged.
- `Tests/VaelenIPCTests/ServiceInstanceInventoryTests.swift`: prospective exact descriptor, claimed descriptor, stale row blocker, additive eligibility, and package identity round trip.
- `Tests/VaelenIPCTests/ProjectAdoptionApplyTests.swift`: both singleton choices, exact version requirement or catalog-supplied omitted version, stale review rejection, claim/catalog transaction, and existing manifest rollback on claim failure.
- New scoped `ProjectSingletonBindingLifecycleTests` in the IPC test target: two aliases, two owners, repeat up/down, singleton final-owner down makes zero stop calls, failed start retains claim, removal rejected before intent/stop/file side effects, removal/claim exclusion across SQLite connections, removed manifest releases stored claims, and endpoint configuration drift.

After focused tests, follow `.agents/skills/verify-vaelen/SKILL.md` and the affected project/service feature recipes. Run a private-Core CLI journey with installed controlled service fixtures and retained evidence, exercise native adoption with isolated Debug UI fixtures per `.agents/skills/verify-vaelen-app/SKILL.md`, and obtain one fresh read-only Sol review. Do not claim real MySQL readiness from a stub executable, or installed-app coverage from unit tests. Confirm unchanged `.env` bytes and original service data paths in the retained fixture evidence.

Phase record: grounding and sketch complete; agreement/synthesis belongs to the parent; implementation and scrap phases are intentionally not entered for this design-only assignment.
