# Explicit retry of the saved operation

## Usage (caller's view)

A failed attempt keeps its database name, user name, target, credential reference, and operation ID. The user retries that attempt rather than submitting another Create request.

```sh
val project db create app_data app_user demo --json
val project db status <operation-id> demo --json
val project db retry <operation-id> demo --json
```

Create continues to accept database and user names. Retry accepts only an operation ID and project selection. Its output uses the existing attempt result, including the original operation ID. Retry errors and status responses never include a password.

```swift
let attempt = try await client.retryProjectDatabase(
    selector: selector,
    workingDirectory: workingDirectory,
    operationID: DatabaseOperationID(parsedUUID)
)
render(attempt)
```

Settings retains the returned attempt alongside the project path. A `failedBeforeDDL` row shows Retry. It calls the same client method with the displayed operation ID. Editing the database or user fields creates a different request through Create and cannot alter Retry. A timeout keeps the operation ID available for Status. It never enables Create as a substitute for retry.

```swift
let updated = try await client.retryProjectDatabase(
    selector: project.id.rawValue.uuidString,
    workingDirectory: project.path,
    operationID: displayedAttempt.operationID
)
projectDatabaseAttempts[project.path] = updated
```

Core resolves the selected linked project, loads the saved receipt, and verifies that exact saved target before either reporting status or authorizing retry.

```swift
let attempt = try await receiptOperation(
    selection: selection,
    operationID: params.operationID,
    action: .retry
)
return ProjectDatabaseAttemptResult(attempt)
```

## Problem

The receipt transition table permits preparation after `failedBeforeDDL`, but execution does not record that transition. Collision and repeated failure recording also reject the failed state. CLI and Settings currently generate a new operation ID for every Create action, so neither can use the existing reservation. Status compares the project and current service but omits the receipt's saved service record and live cluster identity. PostgreSQL's current three logging settings omit error and sampled statements. The ready Settings fixtures contain no ready attempt metadata. These observations come from the correction grounding and the current provisioner, dispatcher, CLI, and PostgreSQL module.

## Shape

The main data shape remains `DatabaseProvisionAttempt`. Its immutable request and saved target are authoritative. No new resumable flag, duplicate request payload, password field, or replacement receipt is introduced.

The public client gains one method. The protocol gains `project.database.retry` using the existing `ProjectDatabaseOperationRequest` fields. CLI and Settings never receive an engine authorization capability.

```swift
public func retryProjectDatabase(
    selector: String?,
    workingDirectory: String,
    operationID: DatabaseOperationID
) async throws -> ProjectDatabaseAttemptResult

enum ReceiptAction {
    case status
    case retry
}

private func receiptOperation(
    selection: ProjectSelection,
    operationID: DatabaseOperationID,
    action: ReceiptAction
) async throws -> DatabaseProvisionAttempt

struct RetryableDatabaseAttempt {
    let attempt: DatabaseProvisionAttempt
    private init(_ attempt: DatabaseProvisionAttempt)
    static func validate(_ attempt: DatabaseProvisionAttempt) throws -> Self
}

func retry(
    _ attempt: RetryableDatabaseAttempt,
    target: VerifiedDatabaseTarget
) throws -> DatabaseProvisionAttempt
```

`ProjectSelection` represents the dispatcher's resolved selector and working directory input. It is internal, not a second wire model. `RetryableDatabaseAttempt.validate` requires `failedBeforeDDL`, no pending effect, and empty confirmed and uncertain effects. Construction stays inside the provisioner module. A corrupt receipt that combines a failed state with effect evidence is never authorized.

`receiptOperation` owns project selection, receipt ownership, the existing claim/binding validation, and dispatch to the owning engine module. It passes `attempt.target.record` as `expectedRecord`. The selected module holds its lifecycle exclusion while it checks the exact current record and queries the live cluster identity against `attempt.target.clusterIdentity`. It performs the requested operation inside that exclusion. The module does not reconstruct the saved target from today's cluster identity.

```swift
func withVerifiedDatabaseAttempt<T>(
    _ attempt: DatabaseProvisionAttempt,
    record: ServiceInstanceRecord,
    operation: (any ProjectDatabaseProvisioningEngine) throws -> T
) throws -> T
```

Both concrete service modules implement this internal boundary using their existing lifecycle lock and identity mechanism. Status calls it with a closure that returns the saved attempt. Retry calls it with a closure that re-reads the receipt, narrows it to `RetryableDatabaseAttempt`, and executes the provisioner. Reveal uses the same exact-target boundary before Keychain access. This is one ownership check and one module-owned live verification path, not three independently maintained policies.

The request dispatcher remains the Core policy owner. Engine modules own the engine-specific identity proof. CLI and Settings never validate cluster identity themselves. Per Boundary Discipline, wire parsing and project selection occur at the boundary, while typed attempts flow through the domain API.

## State transitions and crash behavior

| Starting receipt | Explicit Retry behavior |
| --- | --- |
| `failedBeforeDDL`, no effect evidence | Verify saved target, then begin preflight and preparation using the same receipt. |
| `ready` | Return the verified ready receipt as an idempotent completed response. No engine writes or Keychain access. |
| `refused` | Return the verified terminal refusal. No engine writes. |
| `reserved` or `prepared` | Reject as not retryable. No engine writes. |
| `pendingEffect` or `needsAttention` | Reject as not retryable. Never attempt reconciliation by repeating DDL. |
| Any state with uncertain evidence | Reject before preflight, credentials, or engine writes. |

Target validation happens even for completed responses. A stale record or cluster returns a fixed target-mismatch error and leaves the receipt unchanged. No status response presents a stale receipt as current.

For an eligible failed receipt, the first durable transition is `failedBeforeDDL -> prepared`. Clear obsolete pre-DDL diagnostics there. `prepared` still means no engine mutation has begun, not that the password already exists. Existing initial creation must use the same definition. Then repeat absence checks and credential acquisition. A collision records `prepared -> refused`. Any preflight or credential failure records `prepared -> failedBeforeDDL`. Do not record failure by attempting `failedBeforeDDL -> failedBeforeDDL` or record refusal directly from the failed state.

Load the existing credential if present. Otherwise create it under the immutable operation-derived Keychain reference. Preserve the current handling for a duplicate Keychain insertion. A failed preflight need not create a credential. A repeated failure preserves the same reservation, receipt ID, request, target, and credential reference.

Before each DDL operation, durably record its pending effect. Once any effect might have been sent, every failure becomes `needsAttention`, even an engine rejection that appears harmless. Never convert that failure to `failedBeforeDDL`. After the last confirmed effect and successful authentication, record `ready` as today.

Per Make Operations Idempotent, duplicate retry after success returns the completed receipt. A duplicate retry after a pre-DDL failure is safe. A crash after recording an effect is permanently ineligible for automatic retry. Module exclusion and receipt re-reading prevent two queued callers from authorizing against the same failed snapshot. Do not retain the lock across an `await`.

Create with an already existing operation ID becomes observation-only after immutable-request equality and exact-target verification. It must not offer a second retry entrance. New Create reserves and executes once. Receipt recovery from an interrupted `reserved` or `prepared` state is outside this correction; those states must not silently receive the new Retry action.

Per Model the Domain, retry authorization is represented by a private typed attempt, rather than independent UI and CLI conditions that authorize writes. The client-visible state only controls presentation; Core rechecks it under exclusion.

## PostgreSQL secret-query boundary

Keep one private password-bearing SQL execution path. It sets and reads back logging controls on the exact same PostgreSQL session that will execute the password-bearing statement. A successful independent probe session is insufficient. Use `psql -X -w` and `ON_ERROR_STOP`, stdin for SQL, and the existing unnamed secret input mechanism for authentication. No SQL, password, or subprocess output enters errors or routine logs.

Before interpolated secret SQL reaches the server, the session must prove the following effective settings.

| Channel | Required effective value |
| --- | --- |
| Statement logging | `log_statement = none` |
| Duration logging | `log_duration = off`, `log_min_duration_statement = -1` |
| Sampled duration logging | `log_min_duration_sample = -1`, `log_statement_sample_rate = 0` |
| Sampled transaction logging | `log_transaction_sample_rate = 0` |
| Error statement logging | `log_min_error_statement = panic` |
| Parameter logging | `log_parameter_max_length = 0`, `log_parameter_max_length_on_error = 0` |
| Auto-explain, if loaded | `auto_explain.log_min_duration = -1`, `auto_explain.sample_rate = 0` |

Zero parameter logging is defense in depth. The password is embedded in SQL, so it cannot substitute for suppressing statement text. `log_destination`, collector, CSV, and JSON destinations consume the same server messages; changing the destination is not a substitute for suppressing those messages.

Use an explicit supported preload/extension policy for the bundled PostgreSQL version. Inspect effective shared, session, and local preload libraries and installed auditing extensions. Refuse pgaudit or other audit hooks that cannot be proven inactive and controlled. Unknown nonempty preload entries fail closed. If auto-explain is allowed, verify its disabling settings in this session. A missing supported setting, failed SET, unexpected readback, active audit mode, or unrecognized hook prevents the secret statement from executing. No best-effort logging configuration.

The psql script performs password-free inspection and SET operations first. It reads a single boolean predicate into a psql variable and gates secret SQL with `\if`. A false predicate exits unsuccessfully before PostgreSQL receives the secret statement. This script has no secret-bearing output and does not echo SQL. The helper captures/discards raw diagnostics and returns a fixed domain error. Logging setup must run for both CREATE ROLE and ALTER ROLE paths. Recheck for each new session.

Built-in controls do not establish safety for arbitrary externally installed hooks. The refusal policy is part of the supported engine boundary. Verify the exact available settings and library names against the bundled PostgreSQL 18.6 runtime during implementation rather than guessing an extension catalog.

## Settings fixtures and evidence

Both synthetic Settings fixtures seed a ready `ProjectDatabaseAttemptResult` in `projectDatabaseAttempts[project.path]`. Use deterministic synthetic IDs, matching linked project/binding metadata, harmless database/user strings, and ready status. This is presentation metadata only. Do not construct engine objects or write a real credential.

Fixture mode disables Create, Retry, Reveal, and Copy in both the view and action handlers. Reveal and Copy remain visible for the seeded ready attempt so screenshots can inspect their labels, placement, and disabled behavior. A fixture is not evidence that credential disclosure works.

Keep launch and cleanup fixture allowlists identical. Prefer the existing common fixture registry if present; otherwise add a direct equality check rather than unrelated restructuring. Launch both fixtures, inspect the real Settings screen, and retain screenshots. Record connection failure as an unverified UI lane, not a passing screenshot check.

For MySQL, remove the existing-user collision claim from fixture output and docs in this correction. Its observed live test covers the database collision only. A separate isolated user-collision fixture can earn that claim later. PostgreSQL retains its independently exercised database and role collision claims.

## Tests and implementation sequence

Start with failing provisioner tests for successful retry, repeated pre-DDL failure, and a database or user appearing before retry. Assert unchanged operation/request/receipt/credential identity, no premature DDL, successful transition to ready, and terminal collision refusal. Verify retry after ready performs zero additional effects.

Add negative tests for pending effects, confirmed-but-not-ready effects, uncertain effects, forged failed receipts with effect evidence, mismatched immutable request, wrong selected project, changed claim, changed exact service record, and changed live cluster identity. Status and Retry must both reject stale identity. Status must perform no credential read and no DDL.

Add concurrent duplicate-retry coverage against the existing serialization boundary. Only one caller may advance a failed attempt into execution. The other observes ready or rejection, never a second DDL sequence. Add IPC method and client round-trip tests, CLI parser/render tests, and a Settings action test proving the displayed ID is reused.

For PostgreSQL, fake subprocess tests assert every guard is checked and secret SQL is unreachable on every guard failure. A disposable live cluster starts with aggressive statement, duration, sampling, and error logging. Run successful password-bearing operations and a deliberately rejected password-bearing statement through the guarded path. Scan every active server log destination for the generated secret without printing it. Test an installed unsupported audit/preload configuration and verify refusal before any secret-bearing statement. Retain only sanitized pass/fail evidence. Process arguments, environment, named files, stdout/stderr, and fixture logs are also checked for secret absence.

Update the canonical provisioning docs and command documentation with the retry contract, immutable ID, pending/uncertain refusal, and exact-target status checks. Mark old candidate sketches as superseded or reconcile their claims. Remove phase-narrating comments from stale sketches while retaining only non-obvious invariant explanations. This candidate contains no narration comments. The implementation delegate owns those edits; this design runner is restricted to its output directory.

Run focused suites through `Scripts/test.sh`. Then follow `verify-vaelen` for real CLI/Core lanes and `verify-vaelen-app` for the changed Settings presentation. Existing live evidence is prior evidence, not a replacement for these regression lanes.

## Synthesis decision

This is candidate A. The parent chooses a base after comparing the independent candidates. This candidate recommends the dedicated Retry RPC and the existing immutable receipt as the sole retry input.

## Tradeoffs accepted

- We accept one additional IPC method in exchange for an explicit operation that cannot override the saved request.
- We accept refusal of unknown PostgreSQL logging hooks in exchange for a bounded secret-safety claim that can be verified.
- We accept conservative refusal of interrupted prepared/reserved receipts in exchange for keeping this correction limited to proven pre-DDL failures.
- We accept metadata-only Settings fixtures in exchange for repeatable presentation checks without secret access.

## Alternatives considered

Reusing Create with the saved operation ID avoids a new method, but callers must preserve and resend the entire immutable creation request. It exposes request-equality and retry eligibility policy to every caller and leaves two meanings behind Create. A dedicated Retry RPC hides receipt loading, immutable request recovery, and eligibility behind one operation-ID call.

A generic resume API that reconciles engine objects would require proving ownership after uncertain writes. It hides more behavior but exceeds the receipt's available evidence and violates the no-uncertain-retry constraint.

## Open questions and risks

Can the disposable bundled PostgreSQL runtime demonstrate complete suppression across its enabled destinations and unsupported-hook refusal? This is an implementation verification gate, not a user preference.

Can both synthetic Settings fixture screens be inspected through the available desktop driver? If not, the UI lane remains explicitly unverified.

## Next implementation step

Write the three failed-before-DDL regression tests, then implement the dedicated Retry operation and shared exact-target receipt verification boundary against this contract.
