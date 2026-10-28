# Review and apply a project database connection

The Core review path derives six conventional Laravel values from a ready receipt bound to the linked project and its current managed service record. `DB_PASSWORD` is always the closed marker in review output. Apply is a one use 30 second confirmation. The file writer accepts an existing owner-owned regular single-link `.env` with mode `0600`, preserves unrelated bytes, stages a protected before-image, and publishes with one Darwin `RENAME_SWAP`.

## Focused checks

Run the focused Core, IPC, CLI, and registry suites in the task worktree:

```bash
Scripts/test.sh --skip-update --disable-automatic-resolution --filter 'ProjectConnectionSetupTests|ProjectDatabaseConnectionProtocolTests|ProjectRelationshipCLIParsingTests|ProjectRegistryTests'
```

The Core suite covers line endings, BOM, comments, quoting, additions and replacements, malformed inputs, UTF-8 and NUL rejection, file ownership/mode/type/link-count refusal, FIFO and ancestor-symlink refusal, supported deny-only ACL and metadata preservation, known system path aliases, same-volume swap preservation, stale path replacement, an injected last-syscall writer, byte-based crash classification, restore, exact discard evidence, interrupted cleanup, and orphan recovery. IPC checks serialize only the closed password marker. CLI checks require an opaque confirmation token. Registry tests cover stale reserved-ID unlink against a replacement registration.

Run the package-backed MySQL and private-Core journey:

```bash
Scripts/tests/val-project-database-provisioning-test.sh
```

Run the opt-in complete Laravel acceptance:

```sh
Scripts/tests/val-project-database-connection-laravel-test.sh
```

This recipe installs the committed Laravel 13.39.0 lock with Composer 2.9.8 under installed Vaelen PHP 8.4.27. It checks the official Laravel skeleton provenance and retained-file hashes, disables Composer plugins, scripts, and development dependencies, and confines Composer home, cache, and vendor output to a disposable preparation root. The standard MySQL recipe remains independent of Composer and Laravel.

The selected live XCTest copies that prepared application into its existing linked project before actual `val project db connection apply`. It boots the real Laravel console kernel against the exact applied `.env` in a fresh PHP process, compares six configuration paths against an owner-only expected map built from the request and in-memory Keychain reveal, and executes `SELECT 1` through Laravel's database manager. It checks that `CUSTOM_VALUE=keep` came through dotenv without calling `getenv()`. Then it runs official `php artisan config:cache` under a restrictive umask, checks the cache file is owner-only, temporarily renames the same `.env` inode, and repeats the checks in cached mode. The original `.env` is restored before Core recovery continues. Negative controls require a wrong expected port and absent cache to fail with only phase/field diagnostics. Framework child output is checked for the generated credential before XCTest assertions can expose it.

It uses the installed MySQL 8.4.11 package and PHP PDO, provisions a disposable project account, then runs actual `val` review/apply through private Core. It checks Keychain changes, non-Laravel refusal, retained-recovery blocking, unlink refusal while recovery exists, restore/discard, successful unlink after discard, generated-value PDO authentication, and exact cleanup. Latest retained pass evidence: `/private/tmp/vaelen-project-database-evidence.hds0kU`.

## Settings fixture

Use the isolated app fixture and inspect the selected project detail with CUA:

```bash
VAELEN_SETTINGS_FIXTURE=project-connection-setup VAELEN_SETTINGS_PAGE=projects \\
  .agents/skills/verify-vaelen-app/scripts/launch-fixture.sh artifacts/verification/connection-setup-ui-<run-id>
```

The `project-connection-setup` fixture presents synthetic values, a cached-config advisory, and an injected conflict explaining that the approved proposal may be active while the displaced edit is retained. It does not contact Core or modify a project. CUA should inspect the reviewed rows, hidden password marker, cache/conflict messages, and discard-review confirmation.

For the restart state, launch `project-connection-recovery` with the same command and a separate evidence directory. This fixture has a linked Laravel project and a synthetic conflict recovery, but no session receipt or connection review. Verify the conflict message, recovery row, and Review discard confirmation remain visible. Cancel the confirmation without executing discard. The fixture handlers are synthetic and do not contact Core or modify a project. Preserve `run.txt`, `launch.log`, `doctor.txt`, `cleanup.txt`, and `result.txt`; Xcode build logs remain on failure. CUA screenshots and accessibility observations are in the session transcript because this host cannot export those image bytes to the evidence directory.

## Coverage limits

The transaction tests exercise actual local same-volume `RENAME_SWAP`; they do not prove protection against an uncooperative writer in the final check-to-syscall interval. The injected case confirms that the displaced file is retained and conflict is returned. Do not claim stale proposal bytes can never be temporarily active. The package-backed MySQL recipe additionally runs actual `val` review/apply through private Core, parses generated `DB_*` values from the isolated `.env`, and uses those values to authenticate PDO queries. The opt-in Laravel recipe additionally boots only the locked Laravel 13.39.0 / phpdotenv 5.8.0 MySQL path under PHP 8.4.27. It does not prove PostgreSQL Laravel behavior, arbitrary user providers, custom `config/database.php` conventions, migrations, PHP-FPM, HTTP serving, signed app behavior, or automatic cache management. Vaelen still does not run `config:cache` for the user.

The writer accepts only an existing owner-owned regular single-link `.env` with mode `0600`; it refuses unsupported file xattrs, unknown directory metadata, ancestor symlinks, unsafe writable parents, and ACL grants. It permits the observed safe deny-only ancestor ACLs, a narrow directory xattr allowlist, and the exact root-owned `/tmp`, `/var`, and `/etc` symlinks to their `/private/...` targets. It preserves the supported `com.apple.provenance` file attribute in evidence and staged/restored files. It does not create `.env`, clear Laravel's config cache, run migrations, or manage the user's cache lifecycle.

Apply/recovery/unlink reserve the project synchronously in the Core actor before their first suspension point and release it with `defer`; exact project-ID unlink prevents a stale reservation from removing a replacement registration. Tests cover replay and changed project/receipt/service/file context. There is no deterministic simultaneous Core unlink/recovery schedule test or injected fsync-failure test. A writer can still race in the final check-to-swap interval: stale proposal bytes may be briefly active, while the displaced occupant is retained and a conflict is reported. Malformed or partially written journal/discard-intent JSON is retained as `needsAttention` for manual inspection; valid preparation orphans and discard intents are recoverable/resumable. Do not claim automatic recovery from malformed metadata or full concurrency timing coverage.
