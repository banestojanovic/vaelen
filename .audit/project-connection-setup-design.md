# Reviewed project connection setup

## Problem

Vaelen can inspect a Laravel project's environment and provision a database with a ready receipt, but it cannot connect them. The generated password is held in Keychain and must remain outside SQLite and ordinary IPC. Existing project adoption already demonstrates single-use approval, while its writer only creates a new manifest. This feature edits an existing secret-bearing `.env`, so it needs its own byte-preserving planner, stale-evidence checks, protected recovery, and explicit user approval.

## Usage (caller's view)

```text
val project db connection review --operation <receipt-id>
val project db connection apply --confirmation <review-id>
val project db connection status
val project db connection restore review --recovery <recovery-id>
val project db connection restore apply --confirmation <review-id>
val project db connection discard review --recovery <recovery-id>
val project db connection discard apply --confirmation <review-id>
```

Review shows the linked project, the ready database receipt, six conventional destination values, and `DB_PASSWORD: managed password (hidden)`. It labels each field as add or replace and discloses the permission and recovery-copy behavior. It does not show old values or a raw file diff. Apply requires the opaque, short-lived review token and accepts no credential argument.

```swift
let review = try await core.projectConnectionReview(project, operationID: receiptID)
connectionReview[project.id] = review // redacted rows only
// The user approves the exact rows.
let result = try await core.projectConnectionApply(project, confirmation: review.confirmation)
```

The CLI uses the same Core result:

```swift
let review = try await client.projectConnectionReview(project, operationID: receiptID)
render(review.presentation)
let result = try await client.projectConnectionApply(project, confirmation: review.confirmation)
render(result)
```

Restore and discard each require a fresh reviewed action. Restore is eligible only while the current `.env` still matches the connection file Vaelen installed. Neither action means “force”.

## Shape

Use the candidate B transaction/reconciliation model as a base, with the smaller Core owner and closed presentation types from candidate A. A single `ProjectConnectionSetup` owns the review session, exact patch, recovery evidence, and operation policy. An internal `ProjectConnectionFileTransaction` owns descriptor-relative file inspection, staged files, atomic publication, and recovery classification. The dispatcher validates linked-project identity, receipt readiness, and the exact current service target before calling the owner. CLI and Settings render the same typed review and outcome.

The transaction stages the replacement in a private recovery directory on the same filesystem as `.env`. Before publication, it creates and synchronizes an independent before-image, the proposed bytes, and a metadata-only journal. It revalidates the exact project, manifest, receipt, service, `.env` device/inode/mode/owner/size/digest, then uses Darwin `renameatx_np(..., RENAME_SWAP)` once to atomically exchange the occupied `.env` and staged proposal. The path remains present during publication. The staged path now contains the actual occupant displaced by that syscall. Vaelen retains it under a unique name and compares it with the reviewed snapshot. The journal records the observed result and both affected directories are synchronized before reporting a durable success.

Do **not** automatically perform a second “rollback swap” when the displaced occupant differs. A check followed by compensation has its own race and can displace an even newer edit. Preserve every version and return an explicit `needsAttention` conflict. The UI and CLI must say that a concurrent file change was captured, that the proposed bytes may now be active at `.env`, and that Vaelen did not choose which version to keep. No file is silently removed. This is the defensible limit of a filesystem API without conditional compare-and-swap: an arbitrary uncooperative writer can race the final validation and the single atomic swap. The displaced content remains available for recovery, but stale proposal bytes may be visible briefly or until the user resolves the conflict.

No confirmation session survives a Core restart. Durable recovery is evidence-based and never resumes a credential write. Status reconciles journal, before-image, staged/displaced file, and live `.env`; any ambiguous state becomes `needsAttention` and leaves all artifacts intact. Restore is a new explicit operation using the same snapshot binding and one-swap rule. Discard is explicit and only removes validated artifacts after the operation is no longer the only surviving copy.

The domain sketch in `project-connection-setup-types.swift` keeps secrets, source bytes, offsets, file descriptors, and journal paths out of Codable IPC types. `ConnectionKey.allCases` drives ordering and detection. The public surface hides byte parsing, permission checks, file coordination, journal states, and recovery details. That is a deeper module than asking the CLI or app to coordinate a backup and write. The parser works on bounded UTF-8 bytes and only supports a tested dotenv subset; it preserves unrelated bytes and rejects uncertain or duplicate target entries. See [Laravel's dotenv loader](https://github.com/laravel/framework/blob/13.x/src/Illuminate/Foundation/Bootstrap/LoadEnvironmentVariables.php) and [phpdotenv](https://github.com/vlucas/phpdotenv) for runtime behavior. This feature does not claim to configure custom bootstrap code.

Core consumes each review token before any await, then revalidates every linked-project and managed-service fact. Because dispatcher methods are actor-isolated but can re-enter at awaits, a per-project operation reservation prevents two connection applies from crossing validation. The final file transaction is synchronous and does not suspend. Unlink or another connection mutation for the same project must honor the reservation. External edits remain outside actor isolation and are handled by the one-swap preservation contract above.

The review blocks recognized `DB_URL`, socket, or alternate connection overrides that make the six conventional values ineffective. It warns about `bootstrap/cache/config.php` and other known runtime overrides. Laravel skips loading `.env` while config is cached; Vaelen only reports “file updated” and never clears or rebuilds configuration cache. The feature does not create `.env`, edit files during provisioning or `project up`, import credentials, remove databases, run migrations, start services, or change Laravel bootstrap files.

Recovery copies contain the original `.env`, which can include unrelated secrets. Store them in a validated owner-only `0700` recovery directory outside the repository when the project parent is on the same volume, with `0600` artifacts. Use a protected project-local recovery directory only when a mount boundary requires same-volume storage; disclose the path and ensure it cannot escape the canonical project root. Never alter `.gitignore` or git configuration automatically. The UI exposes the retained copy and explicit discard. Deleting a file does not erase APFS snapshots or external backups.

The accepted filesystem subset is regular, single-link `.env`, owned by the user and mode `0600`, with no symlinked project/recovery path or metadata the writer cannot preserve. A typical `0644` file is refused with a clear message; the first slice does not silently broaden access or change permissions. The replace operation preserves supported original metadata. Unsupported filesystems or a recovery directory on another device are refused.

## Synthesis decision

Candidate B wins on stale-writer data preservation: the actual displaced path occupant must be retained, not overwritten by a prepared proposal. Candidate A contributes its smaller domain owner, `ConnectionKey` enum, fixed redacted password marker, explicit append/separator review, blocking override diagnostics, and cached-config advisory. Candidate B's withdraw-then-publish protocol is rejected because it leaves `.env` absent across synchronization and journal operations, and a crash can extend that interval. Replace it with a single atomic swap that keeps `.env` continuously present, then retain the displaced inode. Do not compensate automatically if it is stale. This preserves data and reports the precise limit without claiming conditional publication.

The independent Sol judge scored A/B (byte correctness 4/4, stale-write safety 2/4, recovery 3/3, secret handling 4/4, interface fit 5/4). It recommended B's occupant capture and evidence-based reconciliation, while flagging the absent-file interval and A's incomplete replacement identity ordering. The one-swap synthesis resolves the absence gap and also avoids unbounded automatic compensation. The judge's follow-up assessment confirmed that one swap retains the displaced version, but cannot prevent the reviewed proposal from appearing when a stale path replacement wins the final race. That limitation is now part of the user-visible conflict state and acceptance predicate.

The Laravel behavior check is grounded in official source: its bootstrap skips `.env` loading when configuration is cached; standard database configuration consumes environment values, but custom project configuration remains outside this feature's guarantee. Local `man 2 rename` and the installed macOS SDK headers document `RENAME_SWAP`; the implementation must still test actual filesystem behavior and sync/recovery boundaries.

## Tradeoffs accepted

- We accept refusing unsupported dotenv syntax in exchange for byte preservation and unambiguous target detection.
- We accept the documented final-writer race in exchange for an atomic, continuously-present file update that retains the displaced version and reports conflicts.
- We accept keeping a protected copy of secret-bearing environment bytes until explicit restore or discard in exchange for recovery.
- We accept refusing `.env` files with broader permissions in exchange for not silently widening access to the generated database password.
- We accept one outstanding recovery operation per project in exchange for keeping restore semantics bounded.
- We accept that deleting a recovery artifact cannot erase snapshots or backups.
- We accept that a changed Laravel config cache may make the updated file inactive until the developer refreshes that cache.

## Alternatives considered

- Candidate A's ordinary replacement is simpler and keeps the file present, but a path replacement in the final check-to-rename gap can be lost. It fails the data-preservation requirement.
- Candidate B's exclusive withdraw/publish protocol preserves the actual occupant, but leaves `.env` absent for a longer period and complicates crash recovery. The atomic swap keeps the useful capture while avoiding the absent path.
- A generated include file avoids editing `.env`, but needs project bootstrap changes and no longer provides standard Laravel connection setup.
- In-place writes avoid path replacement but expose partial bytes and make crash recovery less reliable.
- A second automatic swap to “undo” a detected conflict still races and can displace a newer file. The system preserves artifacts and asks the developer to reconcile instead.

## Open questions and risks

- Should the first version support only `0600`, or should a later version offer an explicit permission-tightening review for common `0644` files?
- Which unusual phpdotenv constructs should the supported parser recognize before refusing a file?
- How much retained recovery storage is acceptable for large `.env` files? First slice should cap file size and allow one retained transaction per project.

## Implementation outcome

The feature is implemented in Core, typed IPC, CLI, and native Settings. The final transaction uses descriptor-pinned directory operations, a lossless targeted dotenv transform, a private same-volume before-image and stage, one Darwin `RENAME_SWAP`, explicit restore/discard review, and a durable resumable discard intent. See `.audit/handoffs/project-connection-setup-2026-10-28.md` for the tested behavior, branch, evidence, and known limits.

## Next implementation step

The implementation goal is complete. The next release work is listed in the handoff: a full Laravel/`phpdotenv` bootstrap acceptance if required, a live PostgreSQL connection-setup journey, and deterministic Core concurrency plus injected fsync-failure coverage. Preserve the documented final check-to-swap race and manual handling for malformed journal evidence.
