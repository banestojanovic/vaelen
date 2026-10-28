# Candidate A. Reviewed byte patch with a protected before-image

## Problem

A developer with a ready database receipt needs to review six conventional Laravel connection assignments and approve one exact edit. Existing provisioning owns database creation and Keychain credentials. Adoption owns only manifest creation. Neither operation gains an implicit environment write. This candidate owns one existing `.env`, preserves every byte outside approved assignment value spans and appended missing assignments, and retains a protected original until explicit restore or discard.

**Verdict.** Recommend this small product shape with a bounded concurrency guarantee. Core rejects all stale evidence observed through the final descriptor and pathname check, serializes its own transactions, and publishes complete bytes atomically. An uncoordinated external write between the final check and rename remains possible. The same limit applies to restore. This meets ordinary editor-conflict detection, but does not prove the strict arbitrary-writer interpretation of the rubric.

## Usage (caller's view)

The CLI flow is proposed as follows. The review displays the project, receipt, five literal connection values, and `DB_PASSWORD=<managed password, hidden>`. It identifies each field as replaced or appended. It never displays the old password or a raw file diff.

```text
val project db connection review --operation <receipt-id>
val project db connection apply --confirmation <review-id>
val project db connection status
val project db connection restore review --recovery <recovery-id>
val project db connection restore apply --confirmation <review-id>
val project db connection discard --recovery <recovery-id>
```

A review expires after 30 seconds and is single use. CLI apply is an explicit action. No plaintext credential is accepted as an argument. The existing separate password reveal operation remains separate. This interprets preview of the password as preview of its source and replacement action, because the scope forbids password values in preview results.

The Core dispatcher resolves raw selectors and identifiers at its existing boundary. The feature receives domain evidence, never IPC request types.

```swift
let target = try await validateConnectionTarget(project: project, operationID: operationID)
let review = try connectionSetup.review(target: target)
return ConnectionReviewWire(review)
```

Settings owns only transient display state per project path. It shows a compact review sheet, disables Apply after expiry, clears the confirmation on project changes, and refreshes environment inspection after success. Core remains authoritative if the UI's clock or selected project is stale.

```swift
let review = try await core.projectConnectionReview(project, operationID: receiptID)
connectionReview[project.rootPath] = review
// The user selects Apply in the sheet.
let outcome = try await core.projectConnectionApply(project, confirmation: review.confirmation)
connectionReview[project.rootPath] = nil
```

Explicit restore gets a fresh review, which binds the current installed file evidence and exact before-image. It never means "force restore".

```swift
let review = try connectionSetup.reviewRestore(target: projectIdentity, recoveryID: recoveryID)
let outcome = try connectionSetup.apply(confirmation: review.confirmation, current: currentEvidence)
```

## Shape

`ProjectConnectionSetup` is the sole owner of in-memory approvals, byte patch rules, protected before-images, recovery records, and file mutation. The dispatcher owns current project, receipt, and service validation because it already owns that knowledge. It passes newly observed evidence to the owner on apply. No caller coordinates prepare, backup, replace, and record operations. This interface concentrates the transaction complexity behind review, apply, status, and discard.

The domain shape is `ConnectionReview` and `ConnectionRecoveryState`, per Model the Domain. A fixed `ConnectionKey` enum derives iteration order, preview field order, duplicate detection, and generation. There are no independently maintained six-key lists in CLI or Settings. Raw external data becomes typed evidence at the dispatcher and file boundary, per Boundary Discipline. Recovery derives state from durable records and file evidence rather than replaying a remembered intention, per Make Operations Idempotent.

The public Core sketch lives in `types.swift`. It has no implementations. Storage headers, raw file bytes, digests, and secret values are internal and never Codable IPC payloads. Each confirmation refers to one opaque in-memory plan. Callers cannot submit replacement values after review.

### Byte grammar and edit plan

Read a bounded UTF-8 byte buffer through a no-follow file descriptor. Reject invalid UTF-8, NUL, excessive size, mixed LF and CRLF, lone CR, and unsupported syntax. Preserve the original BOM if present. Identify logical assignments with a byte lexer that tracks quoted value state across physical lines. A line inside a multiline value cannot become an assignment. Do not reuse `ProjectEnvironmentInspector.parseDotenv`, which is line based and last-wins.

Recognize optional horizontal whitespace, optional `export` plus whitespace, an exact ASCII identifier, optional whitespace, `=`, and the value. Recognize quoted values, unquoted values, and outside-quote comments according to the project's supported phpdotenv fixtures. Before that compatibility suite exists, accept only the proven single-line subset and reject any document whose structure cannot be classified. Unsupported multiline constructs anywhere in the document cause review rejection instead of a guess. Unrelated valid lines remain unchanged. An apparent malformed target declaration is a rejection, even when a simple parser would ignore it. Duplicates are counted after normalizing only the supported `export` form. A second occurrence of a target key always rejects.

The patch replaces each existing target's complete value span and preserves its prefix, trailing whitespace, comment, and original newline. Missing keys append in enum order. The review explicitly discloses append operations and any required separator newline when the original lacks a final newline. Build a result from ordered non-overlapping byte ranges, never by serializing a dictionary.

Emit literal values only. Current generated passwords use a URL-safe base64 alphabet in `KeychainProjectDatabasePasswordStore.create`. Validate that alphabet when loading, rather than assuming every Keychain value has it. Names and endpoint values must also pass the literal encoder's proven alphabet. Reject unsupported values instead of introducing an untested quoting escape scheme. Map MySQL to `mysql` and PostgreSQL to `pgsql`. Resolve host and port from the exact validated service endpoint, not from mutable defaults or CLI guesses. No environment interpolation is emitted.

The preview contains proposed nonsecret literals and a typed managed-password marker. Diagnostics contain fixed reason codes and line numbers, never source lines, parser fragments, raw errors, or file contents. An active connection URL or socket override is a blocking compatibility diagnostic if the conventional six-key edit would be ineffective. The implementation must establish the supported Laravel config convention in fixtures. A cached configuration is a visible warning with no automatic cache deletion or command execution. This feature promises the approved `.env` bytes, not successful application authentication through arbitrary custom PHP configuration.

### Approval binding

The private plan retains exact original bytes, full-file SHA-256, file device and inode, size, nanosecond modification and change times, owner, group, mode, and security metadata. It also retains parent-directory identity, linked-project ID and root, ready receipt identity and immutable content, binding, service record identity, endpoint, and a digest of proposed bytes. The password is loaded only inside Core and incorporated into private proposal bytes. Review serialization cannot traverse the private plan. A service record change invalidates approval even if the replacement text would be identical.

Apply removes the confirmation from the session map before any await. The dispatcher then resolves and validates all current project, receipt, and service evidence again. The owner compares the evidence against the retained plan. One active recovery record is allowed per project. An unfinished or retained operation prevents another apply until restore or explicit discard, so there is one original to restore and no silent recovery history pruning.

Hold the feature's synchronous file transaction after the last await. Actor isolation does not prevent races during dispatcher reentrancy, nor edits from outside Core. Recheck directory identity and file descriptor metadata before and after reading bytes. Recheck the named `.env` immediately before publication. These checks detect observed staleness but do not close the final race.

### Filesystem boundary

Reject an absent file, a symbolic link at `.env` or an untrusted root component, a nonregular file, multiple hard links, a foreign owner, special mode bits, immutable flags, extended ACLs, unsupported security metadata, or group/other write or read permissions. A conservative first slice supports owner-only readable files, such as mode `0600`, and preserves mode, owner, and group. It does not silently chmod a typical `0644` file before putting a password there. Review gives an actionable fixed diagnostic. Supporting `0640` later requires an explicit audience policy.

Reject group/other-writable containing directories. Resolve from pinned directory descriptors with `openat` and no-follow behavior. Verify that the linked project root path still names the pinned root. Reject unsupported or network filesystems until their rename and durability behavior has been verified. Do not treat a canonicalized string path as file identity.

Create an operation directory on the same filesystem under an owner-only, no-follow `.vaelen` recovery directory. Validate any existing directory's owner, mode, ACLs, and link behavior. Operation directories are `0700`; original bytes, replacement bytes, and headers are `0600`. Random opaque names contain no project labels or values. These are deliberate protected recovery artifacts inside the project, not generic temporary files. The UI warns that filesystem backups and same-user tools can still read them. This permission boundary does not promise secrecy against the account owner or root.

Store the before-image as a copy, never a hard link to the live `.env`. Otherwise an in-place editor could modify the supposed recovery copy. The original backup copy remains `0600` even when restoring a supported less restrictive original mode becomes possible later. Copy original ownership and supported metadata onto the replacement before publication. Reject metadata that cannot be preserved, rather than quietly dropping it.

### Transaction and recovery

There is no SQLite transaction for file contents. A versioned header in the protected operation directory contains opaque IDs, before and after digests, identities, original nonsecret metadata, and state. It contains neither old values nor proposed values. SQLite and logs may contain at most opaque operation identifiers and fixed status codes. The protected before-image is the intentional exception for preserving user secrets.

| Durable evidence | Reconciliation |
| --- | --- |
| No complete header, partial artifacts | The operation never reached publication. Remove only validated private partial files. Do not touch `.env`. |
| Complete before-image and prepared header, live file matches before evidence | Mark not applied. Keep the before-image until explicit discard. Never resume applying a proposal after restart. |
| Prepared header, live file matches after identity and digest | Mark applied. Keep the original for explicit restore. |
| Prepared header, live file matches neither | Mark conflict. Preserve recovery artifacts. Never alter `.env`. |
| Applied header, live file still matches installed identity and digest | Restore is eligible for a fresh explicit review. |
| Applied header, live file changed or replaced | Restore is blocked. Preserve the original. |
| Restore prepared, live file matches restored identity and original digest | Mark restored. A repeated restore reports restored. |
| Restore prepared, live file matches neither known side | Mark conflict. Never guess based on modification time. |
| Discard tombstone | Complete deletion of the validated private operation directory. Do not touch `.env`. |

The intended write ordering is before-image copy, file synchronization, atomic prepared-header creation, header and directory synchronization, protected replacement write and synchronization, final evidence check, atomic publication, containing-directory synchronization, then atomic applied-header update and synchronization. A failure after publication must report an operation with reconciliation required, not "nothing changed". A crash after header update cannot make the operation silently disappear. Test actual durability behavior on the supported macOS filesystem; the sketch does not equate `Data.write(.atomic)` with durable publication.

Restore uses the same transaction owner and publication rule as apply. It retains the installed file as a second protected recovery image until restore is reconciled. Before-image retention has no automatic age limit in this slice. Explicit discard first persists a tombstone, then removes only the operation's validated files and directory. It is idempotent across crashes. Deletion on APFS is not a guarantee of physical erasure. Unlink does not erase snapshots or external backups.

### The unresolved compare-and-replace requirement

The local `rename(2)` manual documents replacement, `RENAME_SWAP`, `RENAME_EXCL`, and no-follow options. It supplies no flag that means "replace only if this inode and these bytes still match". An adversarial schedule is enough to falsify a check-then-rename guarantee.

1. Core hashes inode A and approves the final check.
2. An editor replaces `.env` with inode B, or writes new bytes into A.
3. Core renames the prepared file over `.env`.
4. The editor's work is overwritten even though the confirmation was stale.

`flock`, `O_EXLOCK`, and `NSFileCoordinator` cannot protect against a process that does not participate. Directory permissions cannot prevent another process with the same UID from restoring permissions. An atomic exchange retains the displaced file but first makes stale proposal bytes live. A later rollback needs another compare-and-replace and can overwrite a second edit. It does not satisfy "reject stale confirmations without overwriting edits". A hard link to the original inode protects neither in-place writes nor path replacement.

The proposed internal signature is therefore `publishAfterRevalidation`, not `publishIfUnchanged`. It checks all known evidence immediately before atomic rename and refuses every observed mismatch. Its contract excludes an uncoordinated writer in the final syscall gap. This is an explicit limit for synthesis to judge against the original completion predicate. A journal improves recoverability, but does not manufacture conditional replacement. If the strict arbitrary-writer interpretation is mandatory, this candidate is insufficient and mutation cannot ship under that claim.

## Module map

- `Sources/VaelenCore/ProjectConnectionSetup.swift` owns domain review and recovery types, sessions, parser, patch plan, and operation policy. File transaction details may live in one internal `ProjectConnectionFile.swift` companion if needed. Callers cannot import those internals.
- `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift` validates linked project, ready receipt, and exact service record using existing resolution logic. It owns IPC method dispatch and maps fixed feature errors.
- `Sources/VaelenIPC/Protocol/ProtocolModels.swift` defines explicitly tagged connection review, apply, restore-review, status, and discard wire payloads. Existing custom shape-based decoding needs regression tests, because both adoption and connection requests can contain `confirmation`.
- `Sources/VaelenIPC/Client/VaelenCoreClient.swift` adapts typed wire operations. It owns no patch or recovery policy.
- `Sources/VaelenCLI/main.swift` and `CLIDocumentation.swift` parse explicit subcommands and render redacted field actions.
- `App/Vaelen/Vaelen/AppModel.swift` owns transient review state by project path. `VaelenApp.swift` shows review, result, and recovery controls.
- `Tests/VaelenCoreTests/ProjectConnectionSetupTests.swift` owns behavioral parser, byte preservation, approval, recovery, and failure-injection cases. IPC tests cover typed transport and secret nonappearance. Existing fixture recipes drive actual CLI and Settings acceptance.

The dominant path is dispatcher, `ProjectConnectionSetup`, and its internal file boundary. CLI and Settings consume the same reviewed field array and reason codes. No provisioning engine, service start path, `project up`, migration command, manifest writer, or Laravel bootstrap changes.

## Synthesis decision

Candidate-local recommendation is this small domain owner and conservative byte patch. The parent must fill this section after comparing the independently produced journal candidate. This candidate rejects ordinary atomic replacement as sufficient for the rubric's strict concurrency wording.

## Tradeoffs accepted

- We accept rejecting unfamiliar dotenv syntax in exchange for never guessing which bytes are assignments.
- We accept requiring owner-only file permissions in exchange for not expanding who can read a generated database password.
- We accept one retained recovery operation per project in exchange for a clear, explicit restore and discard model.
- We accept protected copies of the original environment in exchange for recoverability. The application discloses retention and never auto-prunes them.
- We accept the explicitly bounded check-before-publish guarantee in exchange for a conventional, small file transaction. Strict protection against an arbitrary external writer in the final syscall gap remains unmet.

## Alternatives considered

- A generated include file hides file patching, but exposes Laravel bootstrap and load-order changes to every project. It loses on scope and interface depth for this slice.
- A generic two-phase SQLite and filesystem journal exposes a broader recovery framework without solving final compare-and-replace. The one-operation protected directory hides enough complexity with fewer consistency boundaries.
- Parse and reserialize `.env` hides syntax handling but changes unrelated whitespace, comments, quoting, and duplicate behavior. It fails the byte requirement.
- Atomic exchange hides the displaced-file capture mechanism but exposes conflict resolution and transient stale installation to users. It improves forensic recovery without meeting strict stale-write rejection.
- In-place descriptor writes avoid a rename race against a different path inode, but leave readers with partial files, retain races against writes to the same inode, and risk overwriting renamed-away files. They lose on both crash behavior and expected-path semantics.

## Open questions and risks

- Is the explicitly bounded check-before-publish guarantee acceptable for this feature, or must the original completion predicate require a different workflow?
- Does the supported Laravel fixture matrix include `export`, multiline strings, inline comments, empty assignments, interpolation, URL overrides, and socket overrides, with actual phpdotenv evaluation of emitted values?
- Should owner-only permission requirements be relaxed for deliberate group access in a later slice, with an explicit audience policy?

These are design risks. The candidate has not run product tests or implemented a transaction.

## Next implementation step

First build a deterministic adversarial file-boundary experiment that injects an external path replacement and an in-place edit between final validation and publication, then reject any proposed publication mechanism that loses either edit.

## Rubric self-assessment

| Axis | Score | Evidence |
| --- | --- | --- |
| Byte and dotenv correctness | 4 | Offset patch, conservative full-document lexer, explicit missing-key behavior, fixture compatibility gate. No full phpdotenv compatibility claim. |
| Stale-write and concurrency safety | 3 | Exact approval evidence, one Core writer, final revalidation, and atomic publication detect observed conflicts. An uncoordinated write in the final syscall gap remains excluded. |
| Crash recovery and restore | 3 | Before-image and digest reconciliation cover publication windows, but live restore has the same unresolved conditional-write gate. |
| Secret containment | 4 | Private bytes, secret marker, protected copies, fixed diagnostics, no SQLite payload. Same-user access and filesystem snapshots remain outside the protection boundary. |
| Interface depth and fit | 5 | One Core owner, shared typed review, existing receipt validation, no provisioning expansion. |
