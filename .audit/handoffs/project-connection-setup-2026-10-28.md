# Handoff: reviewed project database connection setup

## Status

The feature is implemented, locally verified, and committed in the isolated worktree `/Users/banes/.codex/worktrees/vaelen/project-connection-setup-fix` on branch `codex/project-connection-setup-fix-20261028`. The main checkout and its unrelated edits were not modified. Use `git log -1` for the current commit and confirm whether the branch has been published.

The active behavior connects a ready Vaelen database receipt to a linked Laravel project's existing `.env` through an explicit review, one-use approval, and durable recovery. Review never displays the password value. Settings offers the same Core-owned flow and can restore or discard a retained recovery after an app restart without relying on an in-memory receipt.

## User workflow

```text
val project db connection review <operation-id> [project] [--json]
val project db connection apply <operation-id> --confirmation <token> [project] [--json]
val project db connection status [project]
val project db connection review-restore <recovery-id> [project]
val project db connection restore <recovery-id> --confirmation <token> [project]
val project db connection review-discard <recovery-id> [project]
val project db connection discard <recovery-id> --confirmation <token> [project]
```

Review proposes six conventional Laravel values: `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, and `DB_PASSWORD`. PostgreSQL maps to Laravel's `pgsql` driver. The user reviews add/replace rows and warnings before applying. Apply requires a Core-issued token valid for 30 seconds and bound to the project, ready receipt, exact service record, Keychain password bytes, manifest snapshot, and `.env` identity/bytes.

Apply preserves unrelated `.env` bytes and uses one Darwin `RENAME_SWAP`. It retains a protected original and metadata journal. A single outstanding recovery blocks another connection change. Restore is available only while the installed proposal still matches evidence; discard requires a separate explicit review. Conflict discard warns that it may remove the only captured external edit. Nothing clears Laravel's config cache, runs migrations, or edits `.env` during provisioning or project activation.

## Safety boundaries

- Core accepts only a linked, available Laravel project and a ready receipt whose current service target still matches.
- `.env` must already exist as an owner-owned regular single-link file with mode `0600`; no file creation or permission tightening is implicit.
- Paths use pinned directory descriptors. FIFO and arbitrary ancestor symlinks are refused. The exact root-owned `/tmp`, `/var`, and `/etc` aliases to `/private/...` are accepted after target verification. Ancestor ACLs may only deny access; allow ACLs are refused.
- Directory metadata support is allowlisted. The supported `com.apple.provenance` file xattr is included in evidence and preserved; other file xattrs are refused.
- Both the recovery directory and `.env` parent are synchronized after publication/restoration. Discard persists intent, moves each reviewed artifact to an exclusive quarantine name, checks exact evidence, and can resume after interruption.
- Project unlink is refused while any connection recovery artifacts remain. The unlink guard uses the same per-project reservation as apply/restore/discard and targets the exact linked project ID.
- No password is written to receipt metadata, ordinary IPC/UI, CLI review, or logs. The generated password is reloaded from Keychain and byte-compared at apply time.

## Verification performed

- Lead rerun: `Scripts/test.sh --skip-update --disable-automatic-resolution --filter 'ProjectConnectionSetupTests|ProjectDatabaseConnectionProtocolTests|ProjectRelationshipCLIParsingTests|ProjectRegistryTests'` — passed.
- Implementer ran the same focused suite, including system aliases, metadata/ACL, orphan/discard recovery, and stale reserved-ID unlink regressions — passed.
- Package-backed live lane: `Scripts/tests/val-project-database-provisioning-test.sh` — passed using MySQL 8.4.11, private Core, actual `val` review/apply/restore/discard, Keychain-change refusal, non-Laravel refusal, retained-recovery blocking, unlink refusal while recovery is retained, successful unlink after discard, and PHP PDO with generated `.env` values. Evidence: `/private/tmp/vaelen-project-database-evidence.hds0kU` (`result=PASS`).
- Read-only ancestor traversal probe passed on `/Users/banes/Code/apps/vaelen`; metadata evidence is in `.audit/connection-setup-fix/`.
- Native Debug `project-connection-setup` fixture passed. CUA verified six rows, hidden password marker, cached-config advisory, conflict state, and explicit discard warning. Evidence: `artifacts/verification/connection-setup-ui-fix-20261028T074642Z/`.
- Native Debug `project-connection-recovery` fixture passed with no session receipt or connection review. CUA verified the conflict message, recovery row, Review discard action, and loss warning, then cancelled. Evidence: `artifacts/verification/connection-recovery-ui-20261028/`.
- Both fixtures were stopped with the ownership-checking cleanup helper; their temporary DerivedData was removed. Screenshot and accessibility observations remain in the CUA transcript because the host does not export screenshots to disk.
- Independent read-only Sol review found and fixed the missing post-restart recovery UI. The same reviewer rechecked the fix and found no remaining UI issue.
- `git diff --check` passed after the implementation and UI correction.

## Known limits and residual coverage

- The opt-in extension in `/Users/banes/.codex/worktrees/vaelen/project-laravel-acceptance` passed with pinned Laravel 13.39.0 / phpdotenv 5.8.0 boot and query checks before and after config caching. Its evidence and exact commands are in `.audit/handoffs/project-laravel-acceptance-2026-10-28.md`; the extension still needs lead review and integration.
- PostgreSQL mapping is unit-tested; the new connection-setup flow has no separate live PostgreSQL/PDO journey yet.
- There is no injected `fsync` failure test and no deterministic simultaneous Core unlink/recovery schedule test. The Core reservation order, unlink refusal with retained artifacts, successful unlink after discard, and stale-ID registry behavior are covered by inspection and tests.
- An uncooperative writer can change `.env` in the final check-to-swap interval. The approved proposal may briefly become active; the actual displaced occupant is retained and the operation reports conflict. The implementation never claims this race is eliminated.
- Malformed or partially written journal/discard-intent JSON is retained as `needsAttention` for manual inspection. Valid preparation orphans and valid discard intents can be explicitly reviewed and recovered/resumed.
- Unsupported dotenv syntax, unknown ACLs/xattrs, broader `.env` modes, and custom Laravel database configuration are refused or outside the feature contract.
- Earlier failed compile/test logs remain under `.audit/test-failures/`; they are retained as audit evidence, not active processes.

## Next release work

1. Review and integrate the pinned Laravel acceptance from its isolated worktree.
2. Add deterministic Core concurrency scheduling and injected directory-sync failure tests if the test seams can be added without weakening production transaction boundaries.
3. Add a live PostgreSQL connection-setup/PDO journey if PostgreSQL `.env` setup must receive the same integration coverage as MySQL.
4. Decide whether supporting common `0644` `.env` files should be a later, separately reviewed permission-tightening workflow. Current behavior deliberately refuses them.

## Next session startup

1. Check the fix worktree branch, `git status`, and upstream state.
2. Read this handoff and `.agents/skills/verify-vaelen/features/project-connection-setup.md`.
3. Run the focused command above before making follow-up changes.
4. Preserve `.audit/test-failures/`, `.audit/connection-setup-fix/`, and the verification directories until evidence has been copied or the user requests cleanup.
5. The implementation is already committed. Do not reset or remove the feature worktree until the branch is integrated and the user confirms its retained evidence can be cleaned.
