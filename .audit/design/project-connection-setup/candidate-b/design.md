# Journaled connection setup

Candidate B. Design only, grounded at `52daafe18af932d4aff33cad2913d1cdd24ea194`.

## Usage

A developer with a ready database receipt runs `val project db connection review --operation <id>`. The CLI displays the project, `.env`, five destination values, and `DB_PASSWORD = managed password, hidden`. No existing value is printed. The review reports whether each key is added or replaced. It warns that Laravel config caching may require the developer to refresh the cache separately. The feature never runs that command.

The CLI prompts in the same process, then sends the confirmation token after approval. A noninteractive workflow can obtain the redacted review and token through JSON output and use `val project db connection apply --confirmation <token>`. A token expires after 30 seconds and is consumed on the first apply attempt. There is no `--yes` that silently creates a fresh review.

Settings adds **Review connection settings** beside a ready database attempt. A sheet shows the same review. **Apply to .env** consumes that review. The sheet never reveals or retains the password. A stale review requires a fresh review and fresh approval.

The public domain API, called behind the existing typed IPC client, has three operations. The context is validated by the dispatcher and contains no IPC types.

```swift
let review = try connectionSetup.review(
	.configure(operationID), context: verifiedContext, now: clock.now)
render(review.presentation)

// After the developer approves this review.
let outcome = try connectionSetup.apply(
	review.confirmation, context: freshVerifiedContext, now: clock.now)
render(outcome)
```

```swift
// Settings refresh, or CLI after a lost apply response.
let status = try connectionSetup.status(context: selectedProjectContext)
if let recovery = status.retainedRecovery {
	showRecovery(recovery)
}
```

```swift
// Restore also requires a fresh review. Its approval is bound to current bytes.
let review = try connectionSetup.review(
	.restore(recoveryID), context: selectedProjectContext, now: clock.now)
render(review.presentation)
let outcome = try connectionSetup.apply(
	review.confirmation, context: freshProjectContext, now: clock.now)
```

`discard(recoveryID)` uses the same review and apply pair. Discard deletes only Core-owned retained artifacts, never `.env`. The developer sees that discard removes the ability to restore. Core refuses discard while the journal may be the only surviving original `.env`.

## Shape

The named data shape is `ConnectionTransaction`. A transaction has one immutable descriptor and owned artifact slots. A journal records the last durable intent. Reconciliation classifies the actual files, rather than trusting that the last recorded intent completed.

Core owns one transaction at a time for one project root. Every transaction uses a unique directory. The one canonical `.env` remains shared because Laravel already reads it. `ProjectConnectionSetup` owns parsing, review sessions, transaction rules, retained copies, and recovery policy. CLI, Settings, and IPC only render or adapt its typed results.

The public API hides byte spans, path opening, security checks, sync barriers, transaction phases, and recovery classification. Callers choose only a project and an intent, render a review, and approve its token. There is no public `backup`, `write`, `rollback`, or journal-phase option. This is a deep module with a short call chain.

The dispatcher already owns linked-project resolution and exact database target validation. It constructs a `ConnectionContext` after fresh validation. For configuration, this context includes the ready receipt, full `VerifiedDatabaseTarget`, exact `vaelen.yml` evidence, canonical project identity, and a private credential loader. For restore and discard, the context requires the same linked project and canonical root, but not a still-running database. Restoring a user's file should remain possible after the database is removed.

`apply` consumes the session before any await or disk write. The dispatcher reserves the project operation before asynchronous project and service validation, so another connection mutation cannot enter during an await. After those awaits, it compares fresh evidence with the review evidence and calls a synchronous Core commit. No actor suspension occurs within the filesystem transaction. Existing project, service, and receipt evidence receives the same exact fresh validation as password reveal. This does not make independent engine changes atomic with filesystem work.

The type sketch is in [Shape.swift](Shape.swift). The public constructors of evidence and secret-bearing types are intentionally absent. Production code must not let a UI construct `VerifiedConnectionDatabase` from wire data.

## Module map

| File | Knowledge owned |
| --- | --- |
| `Sources/VaelenCore/ProjectConnectionSetup.swift` | Domain model, review sessions, one transaction per project, apply and recovery policy. |
| `Sources/VaelenCore/ProjectConnectionDotenv.swift` | Lossless byte document, target recognition, safe output encoding, patch spans. Internal to Core. |
| `Sources/VaelenCore/ProjectConnectionTransaction.swift` | Descriptor-relative filesystem access, journal and artifact ownership, sync barriers, reconciliation. Internal to Core. |
| `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift` | Existing selection and receipt authority, fresh target validation, transport adaptation, per-project reservation. |
| `Sources/VaelenIPC/Protocol/ProtocolModels.swift` | Explicit request and result DTOs for review, apply, and status. |
| `Sources/VaelenIPC/Client/VaelenCoreClient.swift` | Typed transport methods. |
| `Sources/VaelenCLI/main.swift` and `CLIDocumentation.swift` | Argument parsing, prompt, redacted text and JSON rendering. |
| `App/Vaelen/Vaelen/AppModel.swift` | Per-project transient review and outcome state, keyed by canonical path and checked project ID. |
| `App/Vaelen/Vaelen/VaelenApp.swift` | Compact review and recovery sheet. |

The normal call chain is dispatcher, setup owner, then one internal knowledge owner. Parsing and filesystem details are peers hidden by setup. There is no generic file transaction framework and no SQLite migration. The existing read-only inspector stays read-only. Its permissive dictionary parser is never called by this writer.

## Byte document

The input is bounded UTF-8 bytes, with a conservative size limit such as 1 MiB. The scanner records byte offsets and line boundaries, never Swift `String` indices. It preserves a leading UTF-8 BOM, mixed existing line endings, comments, spacing, unrelated assignments, and the absence of a final newline. Existing bytes outside replacement spans are copied exactly.

Recognition uses logical entries, not independent lines. The scanner understands quote and escape state, comment starts outside quotes, optional `export`, and quoted variable names. It normalizes only the name used for recognition. Therefore `DB_HOST=...`, `export DB_HOST=...`, and `"DB_HOST"=...` count as the same target key. Duplicate target entries are rejected even if their values agree. A target declaration without `=` is rejected. Invalid UTF-8, embedded NUL, uncertain entry boundaries, unsupported escaping, malformed names, and unterminated quotations refuse the entire review. Errors contain a fixed code, target key if known, and line number. They never contain a source line or parser-provided error text.

The accepted grammar is deliberately a subset. Valid unusual forms outside that subset receive a refusal, rather than an attempted repair. The implementation must pin tests against a supported phpdotenv version. phpdotenv 5.6.2 explicitly recognizes exported and quoted names in [EntryParser](https://raw.githubusercontent.com/vlucas/phpdotenv/v5.6.2/src/Parser/EntryParser.php). Its [Lines parser](https://raw.githubusercontent.com/vlucas/phpdotenv/v5.6.2/src/Parser/Lines.php) also handles logical multiline entries. Those sources invalidate the existing inspector's line-by-line recognizer as a mutation parser.

The first slice should refuse all multiline logical entries, including unrelated ones, after recognizing them safely. This avoids pretending that a general quote scanner exactly reproduces every Laravel dotenv version. Single-line unrelated valid entries remain opaque byte slices. The fixture corpus must prove that quoted or exported targets and malformed target-looking forms cannot be mistaken for unrelated text.

For a recognized target, only its value span changes. The key spelling, export prefix, quotes around the key, spacing around `=`, trailing comment, and original newline remain. The new value is a single-quoted literal when the value alphabet permits that representation. The generated password must pass the existing provisioning alphabet check and an explicit dotenv-literal encoder. An unexpected quote, control character, or encoding case refuses review rather than escaping it speculatively. The five other values derive solely from the verified receipt and loopback endpoint. No old target value is needed for the presentation.

Missing target keys append in the `ConnectionKey.allCases` order. The plan records any required separator newline. New lines use the first existing line ending, or LF for a file without one. Existing mixed endings are untouched. The review lists additions, so appending is part of the approved proposal.

Target interpolation is replaced as a complete value span. Interpolation in unrelated values is preserved. The feature cannot claim effective Laravel configuration when shell environment variables, `.env.<environment>`, `DB_URL`, or a config cache override the conventional six keys. The review reports a fixed advisory when supported inspection finds those conditions. It does not evaluate PHP or change bootstrap code.

## File ownership and protection

All operations use an opened canonical project directory and descriptor-relative paths. Core verifies that the directory still denotes the linked project root before mutation. `.env` is opened with `O_NOFOLLOW`, checked with `fstat`, and compared with a no-follow lookup of its path. The file must be regular, owned by the effective user, have exactly one hard link, and permit only owner read and write. This slice accepts mode `0600`. It refuses ACLs, unexpected file flags, or metadata it cannot preserve safely. Core never chmods the user's original to make a proposal eligible.

The canonical project directory and transaction directory must be owned by the user and not writable by another principal. Core rejects symlinked transaction roots and files, unexpected hard links, unsupported network or cross-device operations, and a filesystem that cannot provide required exclusive renames and sync operations. Permission and type checks repeat at apply and recovery boundaries.

The transaction directory is `.vaelen-connection-recovery/<transaction-id>` within the canonical project root. Its root and transaction directories have mode `0700`, and its files have mode `0600`. Same-filesystem storage permits capture and exclusive publication by rename. The directory's name and location are a policy owned by the transaction module. Its files are secret-bearing recovery artifacts, even though the journal itself contains no environment values. The review discloses that a protected recovery copy remains in the project. No `.gitignore` edit occurs implicitly. This directory must never be included in diagnostics, export bundles, or logs.

Only fixed basenames are accepted inside a transaction directory. Journal paths cannot direct Core outside that directory. Discovery treats journal bytes as untrusted input. Unknown versions or invalid ownership refuse recovery without deleting anything. A Core-owned registry under its existing state root can index transaction IDs and project roots for startup discovery. It contains no file bytes or credentials. The filesystem journal remains authoritative. An orphaned directory discovered on the next project access is still recoverable if the index write was interrupted.

## Transaction and recovery

This candidate uses two phases and exclusive publication. It never replaces an occupied destination path. This choice changes ordinary atomic replacement into an interval in which `.env` may be absent. That interval is an accepted product cost of retaining the actual file that occupied `.env` at the commit boundary.

The artifact slots are `journal`, `before`, `proposed`, and `withdrawn`. `before` is a synchronized copy of reviewed bytes. `proposed` contains approved output bytes. `withdrawn` receives the actual `.env` inode when Core begins publication. Core never uses a hard link for a retained copy.

The immutable journal descriptor records its version, transaction ID, project identity and root identity, intent, receipt and target identities, review evidence, artifact identities, byte counts, SHA-256 digests, original mode, and creation time. It contains no source values, proposed values, password, rendered diff, parser fragment, or serialized review session. SHA-256 digests are comparison evidence and are never printed. A journal phase is an intent hint, not proof of completion.

The write sequence is:

1. Revalidate the consumed review against project, manifest, ready receipt, full service record, cluster identity, credential bytes, root, file identity, file metadata, and file bytes. Credential equality uses an in-memory session fingerprint or private secret buffer, never a persisted password hash.
2. Create the private transaction directory exclusively. Write `before`, `proposed`, and `prepared` journal through exclusive no-follow opens. Sync files and the directory. Zero or release secret buffers when no longer required. Failure here leaves `.env` unchanged.
3. Read and compare `.env` again. Atomically move `.env` into the empty `withdrawn` slot with `renameatx_np(..., RENAME_EXCL)`. Sync both directories. Read and compare the captured file, including identity, metadata, and bytes, with reviewed evidence. This checks the actual inode removed from the path, not the inode opened earlier.
4. If capture differs, record a conflict. Restore `withdrawn` to an absent `.env` through an exclusive rename if possible. If another writer has created `.env`, leave that file untouched and retain `withdrawn`. Report that manual reconciliation is required.
5. If capture matches, durably record `publishPending`, then publish `proposed` into an absent `.env` with `RENAME_EXCL`. If another writer created `.env`, leave it untouched and retain the transaction as a conflict. Sync the project directory. Read back published identity and bytes. Check `withdrawn` again for late writes. Record `applied` only after the evidence matches.
6. Retain `before` and `withdrawn` until explicit restore or discard. Retaining `withdrawn` protects late writes through pre-existing editor descriptors. Never silently clean it up after a conflict. A new configuration review is blocked while a retained transaction exists, so the first slice has no recovery chain.

Evidence comparison distinguishes external metadata changes from changes caused by Core's own rename. Capture must preserve device, inode, ownership, mode, flags, link count, size, and bytes. A rename-induced change time is recorded afresh rather than compared blindly with the old timestamp. Publication records the actual installed file evidence after the rename. Restore compares against that installed evidence, never the staged file's pre-rename timestamps.

Supported Darwin exclusive-rename flags and descriptor-relative signatures are present in the installed SDK's `usr/include/sys/stdio.h`. Implementation must test the actual filesystem operation and sync behavior. Presence in headers is not a durability test.

### Bounded concurrency guarantee

The guarantee covers stale edits present before the capture rename, editor path replacement, and creation of a new `.env` during the absent-path interval. Core captures the actual occupant, validates it, and never overwrites a newly occupied destination. After a refused or interrupted operation, every captured version remains in a protected artifact or back at `.env`.

The guarantee does not promise atomic content compare-and-swap against an uncooperative process that keeps an old file descriptor open. Such a process can write the withdrawn inode after any final check. That write remains in `withdrawn`, but may not be detected before Core reports success. Reconciliation detects it on the next access and blocks automatic restore or discard. Core advisory locks and `NSFileCoordinator` cannot turn arbitrary editor writes into cooperative writes. This limitation must appear in the implementation's acceptance criteria.

No design using final stat/hash followed by ordinary rename can honestly provide the stronger guarantee either. If the product requires `.env` always present and strict instantaneous rejection of arbitrary open-descriptor writers, this candidate is rejected. A product constraint on cooperating editors or a different filesystem facility would be necessary. This candidate instead guarantees preservation of captured external data and refusal when observable evidence differs.

### Reconciliation table

Core reconciles on startup for indexed projects and before every review, apply, or status. It validates the linked root before touching project files. It never automatically resumes a new credential publication after restart. User approval sessions are gone after restart.

| Observed evidence | Classification and action |
| --- | --- |
| No durable journal, only a partial private directory, and `.env` still matches reviewed evidence | Treat as abandoned preparation. Keep protected artifacts until explicit discard if ownership is provable. |
| `prepared`, `.env` still matches original, and `withdrawn` is absent | Publication did not start. Report `preparedAbandoned`. Do not publish without a fresh review. |
| `.env` absent, `withdrawn` matches original | Restore `withdrawn` exclusively as repair of the interrupted withdrawal. Sync and report `interruptedRestored`. An intervening creator wins and changes this to conflict. |
| `.env` matches proposed identity and bytes, and `withdrawn` matches original | Classify `applied`, including a crash before the journal's applied marker. Retain recovery. |
| `.env` exists with any other identity or bytes | Classify `externalChange`. Do not write `.env`, even if a digest matches an earlier version but identity differs. |
| `withdrawn` differs from original at any access | Classify `externalChange` and retain all versions. This includes a late write through an old descriptor. |
| `.env` is absent and only a verified `before` copy exists | Report `needsAttention`. Require a fresh restore review. Do not invent a new `.env` during automatic recovery. |
| Journal or artifact identities, permissions, types, lengths, or digests are inconsistent | Report `unsafeRecovery`. Do not follow paths, overwrite files, or delete evidence. |

Atomic journal updates use a synchronized temporary journal, rename, and directory sync. Reconciliation accepts either the prior complete journal or the next complete journal. A phase marker never grants permission to overwrite an existing path. For every rename, the directories on both sides must be synchronized before the operation is considered durable. Unsupported sync failures leave a visible `needsAttention` result rather than a success claim.

### Restore and discard

Restore first requires that the current `.env` has the exact identity, metadata, and bytes installed by this transaction, and that `withdrawn` has not changed. Its fresh review binds those facts and the protected `before` artifact. Restore uses the same journaled withdraw-and-exclusive-publish protocol, with a synchronized copy of `before` as its proposal. The current applied file receives a separate fixed restore-capture slot. Original artifacts remain until restoration is durably classified, so a crash cannot destroy the only original.

If restore captures later edits or another `.env` appears before publication, restore refuses and retains the edited file. It never writes over an occupied path. The same open-descriptor limitation applies after capture. A strict guarantee about future writes to an already removed inode is outside this transaction's guarantee.

Discard requires a fresh token bound to the recovery artifact identities and reconciliation result. It is eligible only when `.env` exists and the transaction is known applied, restored, or abandoned without an original trapped in recovery. Conflicts, late writes to `withdrawn`, and unsafe metadata prohibit automatic discard. The user must resolve the conflicting copies outside this slice. Discard unlinks only verified files in the verified transaction directory, syncs, removes the empty directory, and then removes its nonsecret index entry. It does not promise secure erasure from APFS snapshots or backups.

## Secret containment

Review loads the Keychain password only inside Core, builds the exact output in a private buffer, and stores the secret-bearing proposal only in a bounded, expiring session. No secret-bearing type conforms to `Codable`, `CustomStringConvertible`, or a debug printer. Dropping a session releases its buffer. Swift copies mean this is lifetime minimization, not a proof of complete memory zeroization.

Only explicit apply writes the proposed password to the protected staging file and eventual `.env`. The redacted presentation has a closed `managedSecret` case, so renderers cannot accidentally print the password. The source secret never goes through IPC. Restore uses protected file bytes and does not read Keychain. Ordinary exceptions map to fixed diagnostic codes before leaving Core. Test assertion helpers must redact byte buffers on failure.

The original before-image may contain many unrelated secrets. It has the same protection and retention policy as `proposed`, even if no database password was present before. No environment bytes enter SQLite, structured logs, arguments, crash messages, or ordinary JSON output. Existing explicit password reveal remains separate and is not reused for connection review.

## Verification plan

The first implementation unit is a pure lossless document planner and its accepted-grammar corpus. The second is the filesystem transaction with injected stops after every write, sync, and rename. The third wires the Core actor, transport, CLI, and Settings after those contracts pass.

Meaningful tests include:

- Golden byte fixtures for LF, CRLF, mixed endings, BOM, comments, spaces, no final newline, missing keys, and every target key position.
- Duplicate plain, exported, and quoted targets. Missing `=`, malformed target-looking names, invalid UTF-8, NUL, unsupported escapes, and multiline entries must refuse with no bytes written.
- A pinned phpdotenv fixture oracle for accepted input and for the encoded six destination values. The app never shells out to PHP during actual review or apply.
- `.env` symlinks, FIFO, directories, hard links, wrong owner, non-0600 mode, ACL, unsafe directory, renamed root, and symlinked transaction directory.
- Edit and replace `.env` between review, preflight, capture, and publication. Create a new `.env` in the absent interval. Assert preserved bytes and conflict classification.
- Keep a writable descriptor to the original open across capture, write afterward, and assert that reconciliation finds the retained bytes and blocks restore and discard. This test documents the bounded guarantee.
- Crash injection at every durable boundary, including journal-before-rename, rename-before-sync, publish-before-marker, and interrupted restore or discard. Restart twice and assert identical classification and no unsolicited publication.
- Lost apply response, expired token, token replay, two CLI clients, simultaneous Settings apply, changed receipt state, changed manifest, relinked project, same service name with changed cluster, changed port, and replaced Keychain bytes.
- Restore after unrelated edits, same bytes on a different inode, changed permissions, a missing target, and an external creator during restore. No occupied destination is overwritten.
- Secret canaries in old values and the generated password. Search IPC captures, JSON, captured logs, journal/index bytes, and failure diagnostics. Raw values may occur only in protected artifacts and final `.env`.

Run repository tests through `Scripts/test.sh`. Before independent review, the lead follows `.agents/skills/verify-vaelen/SKILL.md` and exercises a real linked Laravel fixture with a ready MySQL or PostgreSQL receipt through `val`. The Settings check uses the app skill and observes review, stale refusal, apply, recovery, and restore. This design artifact has no implementation or runtime verification claim.

## Red-flag screen

No caller coordinates backup and publication. No DTO is imported into the domain owner. Parsing and journal internals stay internal to Core. There is one writer API and one retained recovery transaction per project. The six-key enum generates rows and patch ordering. Journal phases are represented as a sum type and reconciliation is evidence-based. The price is the additional filesystem protocol and the absent `.env` interval. Those are actual costs, not complexity hidden by a short API.

The strongest challenge to this design is that an ordinary durable before-image and atomic replacement has a smaller filesystem protocol and keeps Laravel reads uninterrupted. This candidate earns its extra protocol only if retaining the actual racing path occupant is a product requirement. If the parent accepts a narrower final-check race for atomic replacement, candidate A is likely the better base, with this candidate's evidence-derived reconciliation and explicit concurrency limitation adapted to it.
