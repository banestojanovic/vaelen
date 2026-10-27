# Candidate B. Retry the stored operation

## Caller usage

The developer creates a database as usual and keeps the returned operation ID:

```text
val project db create storefront_dev storefront_app storefront
```

If Core returns `failedBeforeDDL`, the developer retries that stored operation:

```text
val project db retry <operation-id> storefront
```

The Settings receipt row shows **Retry** only for `failedBeforeDDL`. The button sends the existing operation ID. Core loads the immutable original request and repeats it after rechecking the project, claim, service record, endpoint, health, package, and cluster identity.

## Domain and module map

The existing `ProjectDatabaseCreation.operationID` remains the idempotency key. No second create request or caller-supplied database and user names are introduced for retries.

```swift
struct ProjectDatabaseRetryRequest: Codable, Sendable {
    let selector: String?
    let workingDirectory: String
    let operationID: DatabaseOperationID
}

extension CoreRequestDispatcher {
    func retryProjectDatabase(_ operationID: DatabaseOperationID,
                              selector: String?,
                              workingDirectory: String) async throws -> DatabaseProvisionAttempt
}

extension VaelenCoreClient {
    func retryProjectDatabase(selector: String?,
                              workingDirectory: String,
                              operationID: DatabaseOperationID) async throws -> ProjectDatabaseAttemptResult
}
```

Core accepts only a stored attempt in `failedBeforeDDL`. It passes the stored `ProjectDatabaseCreation` back through the existing create path. The receipt repository compares the full immutable request before any engine work. The CLI and Settings call the same retry RPC.

Each service module adds an internal `validateDatabaseAttempt` method. It runs under the module's lifecycle lock, checks the current record, health, and package, and compares the live cluster identity with the receipt. Core status passes the stored record as the expected record and rejects a cluster or service replacement.

## Receipt transitions

```text
reserved -> prepared -> pendingEffect -> confirmed effects -> ready
reserved/prepared -> failedBeforeDDL -> prepared -> pendingEffect
failedBeforeDDL -> refused
pendingEffect -> needsAttention
```

The provisioner transitions a retry to `prepared` only after it reloads or creates the same operation's Keychain item. A repeated Keychain failure leaves `failedBeforeDDL` unchanged. A new collision after the first failure changes the receipt to `refused` and releases name reservations. Core rejects retries from every state except `failedBeforeDDL`. A pending or uncertain effect remains read-only.

## PostgreSQL password logging

Before a password-bearing SQL statement, the PostgreSQL adapter sets session logging controls for statement, duration, error-statement, duration-sampling, statement-sampling, and transaction-sampling logs. It reads the current values back and confirms that each control has the required safe value before it sends the password-bearing statement on stdin. It checks active preloaded audit libraries and refuses if the session cannot prevent them from recording SQL. The operation does not change global server settings.

The integration fixture runs the same live provisioning path with verbose log settings enabled. It checks that normal and failure paths do not put the generated password in PostgreSQL logs. It separately proves that a wrong password cannot authenticate.

## Tests and fixtures

- Core tests cover successful retry from `failedBeforeDDL`, repeated Keychain failure, collision refusal after a pre-DDL failure, and refusal to retry pending or uncertain effects.
- Dispatcher tests reject a changed service record and a changed cluster identity while returning receipt status.
- MySQL end-to-end coverage uses the existing sentinel account as the collision target and confirms that neither the new database nor the account changes.
- PostgreSQL end-to-end coverage checks role flags, wrong-password rejection, neighboring database and temporary-object isolation, and password-free server logs.
- The PostgreSQL Settings fixture seeds a synthetic ready metadata receipt so Reveal and Copy controls render. The fixture still disables create, reveal, and copy actions.

## Tradeoffs

This candidate adds one IPC method and one CLI subcommand. It prevents callers from rebuilding the original request and cannot accidentally retry the same operation under changed names. The command can accept the operation ID printed by the first response and does not need a new operation ID flag on the create command.

The Settings app only keeps the latest receipt in memory, so it can retry a failure while that receipt remains loaded. A future receipt history view is outside this fix.
