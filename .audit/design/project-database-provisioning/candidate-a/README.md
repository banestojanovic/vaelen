# Project database provisioning candidate A

This is a proposed design, grounded at `d66ccfab87c4e09c5ce89eb5fd1ce45a37a5ddcc`. No implementation or engine proof is claimed. The accompanying [type sketch](shape.swift.md) and [recovery and proof plan](recovery-and-proof.md) define the candidate.

## Problem

A project needs a new database and its own application account on its exact claimed MySQL default instance or named PostgreSQL instance. `ProjectServiceBinding`, `ServiceInstanceID`, the service catalog, and the runtime evidence must agree before Core sends SQL. Existing database or account names must cause refusal. MySQL and PostgreSQL both need durable operation records because database creation cannot be grouped atomically with every account operation. Secrets belong in Keychain before any engine mutation.

## Usage

The proposed CLI creates metadata and keeps the generated password hidden.

```text
val project database create --service database --database shop_dev --user shop_app
Created shop_dev on postgresql/dev. User shop_app. Password saved in Keychain.
Project files were not changed.

val project database status --service database
shop_dev  shop_app  postgresql/dev  ready

val project database password --service database --reveal
<password appears only for this explicit command>

val project database password --service database --copy
Password copied.
```

`--service` is the project binding alias. It is required when several eligible bindings exist. Selection never falls back to a default PostgreSQL instance or to the first service using the same port. JSON create and status output contain metadata only. Password commands require exactly one of `--reveal` or `--copy`, reject `--json`, and are separate from create. Copy never launches `pbcopy` with a secret argument. The UI and CLI use a native pasteboard adapter.

In selected-project Settings, show a compact Database section for each eligible binding. Before creation, show database and application user fields with editable safe suggestions and a **Create database** button. The button states the selected service kind and instance. A successful result shows the endpoint, database, username, and separate **Reveal password** and **Copy password** buttons. Loading the project, expanding the section, creating the database, and opening TablePlus do not retrieve the password. A partial result shows created and uncertain resources, with no destructive repair button. This stays inside the current selected-project details.

The caller creates one operation ID per explicit create action and retains it until the operation settles.

```swift
// CLI boundary. Resolve the linked project and exact binding from Core data.
let request = try DatabaseProvisionRequest(
	id: DatabaseProvisionID(UUID()), target: selectedDatabaseTarget,
	database: DatabaseName(databaseArgument), user: DatabaseUserName(userArgument))
let outcome = try await client.provisionProjectDatabase(request)
print(databaseOutcomeText(outcome))
```

```swift
// Settings. A repeated submit after a transport timeout reuses pendingRequest.id.
let outcome = try await core.provisionProjectDatabase(pendingRequest)
selectedProjectDatabase = outcome
// No password field exists in DatabaseProvisionOutcome.
```

```swift
// A dedicated reveal action is the only caller that receives secret bytes.
let disclosed = try await core.discloseProjectDatabasePassword(
	.init(provisionID: ready.id, intent: .copy))
try pasteboard.copy(disclosed.password)
```

These snippets describe proposed API names. They are not existing calls.

## Shape

One `ProjectDatabaseProvisioner` owns the durable attempt and all credential policy. Its public methods are provision, list status for a project, and explicit disclosure. CLI, Settings, the dispatcher, and the IPC client do not coordinate engine stages. This is a deep interface because a single create call hides target validation, reservations, Keychain access, engine differences, and durable failure reporting.

Per Model the Domain, `DatabaseProvisionState` represents confirmed progress and unresolved side effects explicitly. Per Boundary Discipline, Core resolves and validates the current full binding, claim, service record, and runtime identity at its boundary. Wire DTOs and SQL stay outside the public domain types. Per Make Operations Idempotent, an operation ID always identifies one immutable request. Repeating a finished request returns its prior metadata, while repeating an interrupted engine request returns a stable attention result without repeating uncertain DDL. A prepared attempt has not authorized DDL and can continue after fresh identity and collision checks.

Persist an append-only operation row plus the latest typed state in SQLite. Unique reservations cover `(service identity, database)` and `(service identity, username)` across all project aliases. Engine username collision checks are broader than those local reservations. MySQL checks every host entry for that username. PostgreSQL checks cluster-wide roles. Failed attempts remain visible and reserve possibly created resources. SQLite stores the Keychain item reference, never the secret or a connection URI containing it.

The Core dispatcher is the only mutation owner. Provisioning remains synchronous within its actor turn in the first slice, including Keychain and subprocess interaction, so an actor suspension cannot permit project unlink, service replacement, or a concurrent create halfway through the operation. A bounded engine timeout limits blocking. An asynchronous implementation later needs an explicit lifecycle lease honored by claim release, stop, remove, and package-switch paths. An actor alone would not provide that lease across `await`.

Keychain generic-password items use a Vaelen-specific service and an account containing the installation ID and provision ID. Creation uses add-only semantics and device-local accessibility. User-presence policy must match the app's existing signing and Core process identity. Keychain failure stops before engine mutation. A separate injected password-store protocol permits deterministic missing, locked, denied, and duplicate-item tests.

## Module map

| File | Knowledge owned |
| --- | --- |
| New `Sources/VaelenCore/ProjectDatabaseProvisioning.swift` | Domain types, target guard, operation transition policy, provisioning and explicit disclosure. |
| New `Sources/VaelenCore/ProjectDatabasePersistence.swift` | SQLite attempt encoding, name reservations, immutable request matching, and durable transition writes. |
| New `Sources/VaelenCore/ProjectDatabasePasswordStore.swift` | Generic-password Keychain attributes and test seam. No TLS private-key reuse. |
| Existing `Sources/VaelenCore/MySQLModule.swift` | Exact managed socket and package validation, secure MySQL admin session, MySQL catalog parsing, and DDL. |
| Existing `Sources/VaelenCore/PostgreSQLServiceModule.swift` | Named-instance admin session, PostgreSQL catalog parsing, role and database DDL. |
| Existing `Sources/VaelenCore/ProjectServiceBindings.swift` | Narrow exact-claim and runtime authorization query. Provisioning does not call adopt or replace claims. |
| Existing SQLite schema owner | One forward schema migration for nonsecret attempt rows and indexes. |
| Existing `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift` | Typed request adaptation and the sole serialized mutation boundary. |
| Existing `Sources/VaelenIPC/Protocol/ProtocolModels.swift` and `Client/VaelenCoreClient.swift` | Create, status, and explicit-disclosure messages. Separate response variants prevent accidental disclosure. |
| Existing `Sources/VaelenCLI/main.swift` and a database command/output file | Argument parsing and metadata presentation. |
| Existing `App/Vaelen/Vaelen/AppModel.swift` and `ProjectsViews.swift` | Selected-project state and compact setup controls. |

The main trace is caller, dispatcher, provisioner. The selected engine module is a private terminal adapter. There is no public generic SQL runner and no separate layer per execution stage. The existing database viewer action remains read-only and credential-free.

## Synthesis decision

Pending the parent architect's comparison. Candidate A recommends an attempt journal with conservative, read-only recovery. Its central choice is to expose uncertainty honestly rather than infer ownership from a matching database name.

## Tradeoffs accepted

- We accept a retained partial account or database in exchange for never dropping data as compensation.
- We accept a needs-attention result after an ambiguous crash in exchange for never taking over an existing object.
- We accept serialized bounded operations in the initial implementation in exchange for preserving current project claim ownership without inventing an incomplete lease system.
- We accept narrower ASCII identifiers in exchange for the same predictable rules across both engines.
- We accept a retained Keychain item for a partial attempt in exchange for preserving the only recoverable credential for a possibly created account.

## Alternatives considered

A declarative resource controller could store desired database and account state and reconcile continuously. That shape hides retries from callers and can resume more crashes. It requires durable engine-side ownership markers for every independently committed object, plus a controller, lifecycle integration, and a stronger catalog identity model. A MySQL database does not provide the same owner field as a PostgreSQL database. A dedicated marker table would change application schema, and creating it would introduce another crash window. This alternative loses here because name matching alone cannot authorize repair and the extra ownership protocol exceeds a bounded provisioning feature.

A CLI-only shell script is structurally different but shallow. It exposes service resolution, Keychain policy, retry semantics, and errors to each caller. It cannot give Settings the same Core operation and would create two writers. Reject it.

## Open questions and risks

- Can the shipped MySQL client accept an inherited pipe as a defaults file for authenticated proof, or does that require a native client-library adapter? Resolve this with the first implementation spike before selecting a transport.
- Which PostgreSQL app connection policy should the product advertise while current managed clusters use trust authentication? Report this honestly as trust, and prove password authentication separately against an isolated SCRAM fixture.
- Can the supported engine packages suppress all statement and error paths that would include generated password SQL? Require actual captured-log proof before enabling the feature for that package.
- Does the production signing identity let Core and the explicit disclosure path read the same generic-password items without a surprise prompt? Verify with a real signed Core instance and temporary Keychain namespace.

## Next implementation step

Build a bounded engine-input and logging proof with injected Keychain storage and an isolated MySQL service before wiring UI, then implement one create-to-status path with a durable pending-step row and crash injection.

## Red flag screen

The caller does not coordinate stages. SQL, Keychain attributes, and SQLite encodings remain internal. One provisioner writes the journal and one password store writes Keychain. Engine adapters own dialect differences rather than mirroring two workflows in CLI and Settings. No enum of service kinds is copied into both callers. Supported targets derive from Core's eligible binding projection. The journal is not a desired-state record, so a subsequent start does not trigger more SQL.
