# Candidate B. A create-once operation receipt

End users create an application database and user for a selected project binding. Creation returns connection metadata and a saved-credential indicator. Password access is a separate explicit action. Core owns the entire operation and both callers use that operation.

This candidate deliberately treats an interrupted engine write as a retained partial result. It never infers permission to modify an existing object from its name. It sacrifices automatic completion after ambiguous DDL in exchange for a small, auditable safety boundary.

## Usage, written before the types

Proposed CLI commands follow the existing `val project` family.

```sh
val project database create shop --service db --database shop_dev --user shop_app
# Created shop_dev for shop_app on PostgreSQL local-dev, alias db.
# Password saved in Keychain. Use `val project database password shop --service db --reveal`.
val project database status shop --service db
val project database password shop --service db --copy
```

`create` has no password argument, password stdin option, environment variable input, or reveal flag. A failed request prints a typed, sanitized reason and a receipt ID when retained resources may exist. `--json` contains the same nonsecret metadata. `password --reveal` is the only CLI command allowed to print password bytes. `--copy` writes to the pasteboard and prints only confirmation. Supplying neither intent is a usage error. Names use lowercase ASCII letters, digits and underscore, start with a letter, and are limited to 32 bytes for the first version. This deliberately satisfies both engines without silent truncation or case folding.

The selected-project Settings detail has a compact Database group. It lists exact eligible bindings when there is more than one. The detail identifies engine, instance, endpoint and alias. “Create database” expands two fields and a Create button in place. A successful row shows database, user, host and port with separate Reveal password and Copy password buttons. No secret loads while rendering or refreshing. A partial receipt shows what was confirmed and what is uncertain. There is no retry button when engine effects are uncertain. Users can choose fresh names. Settings leaves `.env` alone and offers nonsecret connection fields to copy individually.

### CLI call site

```swift
let receipt = try await core.createProjectDatabase(
    project: projectID, binding: selectedBinding,
    database: DatabaseName(databaseArgument), user: DatabaseUserName(userArgument),
    operationID: invocationID)
print(DatabaseOutput(receipt))
```

`invocationID` is generated before sending the IPC request and retained during transport retries. A second click with new names creates a new operation. Reusing an operation ID with different inputs is rejected.

### Settings call site

```swift
let receipt = try await core.createProjectDatabase(
    project: selectedProject.id, binding: selectedBinding,
    database: DatabaseName(databaseField), user: DatabaseUserName(userField),
    operationID: submissionID)
model.databaseReceipt = receipt
```

### Explicit credential call site

```swift
let secret = try await core.projectDatabasePassword(
    receipt: receipt.id, intent: .copy)
pasteboard.replaceWithPassword(secret)
```

`SecretPassword` is not `Codable`, printable, or a property on the ordinary receipt. A private IPC wire representation exists only for the explicit password method. The app clears revealed content on selection changes and dismissals. Pasteboard expiry is an app concern and must not erase clipboard content replaced by another app.

## Package contents

- `Shape.swift` sketches domain types, signatures and ownership boundaries. It is not compilable production code.
- `Rationale.md` explains the structural choice and an alternative.
- `Recovery.md` defines preflight, DDL ordering, receipt durability and crash behavior.
- `Verification.md` defines unit seams, fault injection and real-engine acceptance.

## Repository grounding

The worktree is at `d66ccfab87c4e09c5ce89eb5fd1ce45a37a5ddcc`. Grounding was checked against `.audit/project-database-provisioning-grounding.md` and the source paths below.

- `Sources/VaelenCore/ProjectServiceBindings.swift` owns exact catalog and project-claim checks. Provisioning must query it and must not create, replace or release claims.
- `Sources/VaelenCore/ServiceInstanceCatalog.swift` defines `ServiceInstanceID`, records and project claims. A record includes package, endpoint and data directory. Name or port alone is insufficient identity.
- `Sources/VaelenCore/ProjectEnvironment.swift` defines the full `ProjectServiceBinding`, including alias and optional version.
- `Sources/VaelenCore/MySQLModule.swift` uses its managed socket and a root client defaults file. `runClient` currently accepts `-e` SQL in argv and forwards raw client errors. Neither behavior is suitable for this operation.
- `Sources/VaelenCore/PostgreSQLServiceModule.swift` verifies process identity and data directory, owns the named socket path, and currently writes generic command output to temporary logs. Its generic runner must not execute password-bearing SQL.
- `Sources/VaelenCore/SQLiteStateStore.swift` is at schema version 9 and has transactional migration support. Receipt storage adds metadata only.
- `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift` owns the binding resolver and service modules. It is the only production entry to the new Core operation.
- `Sources/VaelenIPC/Protocol/ProtocolModels.swift` and `Sources/VaelenIPC/Client/VaelenCoreClient.swift` carry typed requests and results. New wire envelopes adapt to Core domain types at the dispatcher.
- `App/Vaelen/Vaelen/VaelenApp.swift` renders `ProjectSelectedDetail`. `AppModel.swift` owns async Core calls. `ProjectsViews.swift` already has database viewer actions. Provisioning does not extend the credential-free TablePlus action.
