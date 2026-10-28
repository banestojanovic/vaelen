# Handoff: Laravel connection acceptance

## Status

The implementation and acceptance are complete in `/Users/banes/.codex/worktrees/vaelen/project-laravel-acceptance`, based on `2fad8cc741f229a090e45c7decf3042da240c2c1`. Commit `a4fb244` is pushed. PR creation is pending. Product code under `Sources/` and `App/` was not changed.

## Acceptance implemented

The existing private-Core MySQL XCTest can run with or without Laravel inputs. The standard MySQL recipe still needs no Composer setup. The new `Scripts/tests/val-project-database-connection-laravel-test.sh` checks committed skeleton provenance, installs only `composer.lock` with plugins, scripts, and development dependencies disabled, and runs Composer under installed Vaelen PHP 8.4.27 with isolated Composer home and cache. It terminates and reaps Composer process groups before removing the exact preparation root; it retains that root if teardown cannot be confirmed.

The Laravel lane copies the prepared official app into the linked project before link and apply. Its private expected JSON object contains six config paths and uses the independent request fields plus the in-memory Keychain reveal. A committed PHP probe boots the real console kernel in fresh processes, checks Laravel and phpdotenv versions, compares every field without printing values, proves `CUSTOM_VALUE=keep` came from dotenv in uncached mode, and executes Laravel's MySQL `SELECT 1`. The recipe runs official `artisan config:cache` under umask `077`, chmods and checks the cache as `0600`, renames the actual `.env` inode away, then verifies cached mode with the same config and query. The identical file is restored before Core recovery. Negative controls reject a mismatched expected port and absent config cache.

The PHP child result keeps exit status, redacted output, and credential-output detection as separate fields. Its success predicate requires both a zero exit status and no detected credential. A negative control prints a known credential sentinel from a zero-exit child and confirms the result cannot pass.

The PHP child result keeps exit status, redacted output, and credential-output detection as separate fields. Its success predicate requires both a zero exit status and no detected credential. A negative control prints a known credential sentinel from a zero-exit child and confirms the result cannot pass.

## Verification

- Lead rerun of the focused suite passed: `Scripts/test.sh --skip-update --disable-automatic-resolution --filter 'ProjectDatabaseProvisioningEndToEndTests|ProjectConnectionSetupTests|ProjectDatabaseConnectionProtocolTests|ProjectRelationshipCLIParsingTests|ProjectRegistryTests'`. This includes the zero-exit credential-output regression control.
- Lead rerun of the Laravel package-backed recipe passed: `Scripts/tests/val-project-database-connection-laravel-test.sh`.
- Existing package-backed MySQL recipe passed without Laravel variables: `Scripts/tests/val-project-database-provisioning-test.sh`.
- Syntax checks passed: `sh -n` for both provisioning scripts, embedded Python compilation, and `php -l Scripts/tests/fixtures/laravel-connection-probe.php`. `git diff --check` passes for authored files. The exact upstream Laravel welcome view retains three whitespace-only lines from the verified source archive; the fixture bytes remain unchanged.
- Final Laravel acceptance evidence is at `/private/tmp/vaelen-laravel-connection-evidence.UPgcZY`. It records the final Swift hash `cb553c5547149ff55e7623e1797759528077064cbd538ae5a8f846cf4c2b6228`, PHP 8.4.27, Composer 2.9.8, Laravel v13.39.0, phpdotenv v5.8.0, lock SHA-256 `ee74bd1edcfc94c29b8fd7db48ad19d641ec8071ceaf3a3ac378701e10a783e6`, fixture SHA-256 `fdae46f5242d8c1ec2ae7a6bdfe770f719f31921830cfd58a5f7afdae5601d98`, both boot/query phases, negative controls, and cleanup confirmation. The generated credential is not retained in evidence.
- Existing MySQL recipe evidence is at `/private/tmp/vaelen-project-database-evidence.Bs72Bk`.
- One initial Laravel run failed only because Laravel created the cache file with mode `0700`; the acceptance now explicitly changes it to and verifies `0600`. The corrected full run passed. Its failure log remains at `.audit/test-failures/swift-test.JlOJDz`.

- One fresh read-only Sol review found that credential redaction preserved a zero child exit status. The test now represents credential detection separately and requires a leak-free result for Artisan success. The added negative control and lead reruns passed. The review found no other actionable provenance or comment issues.

## Coverage limits

This proves the locked Laravel 13.39.0 / phpdotenv 5.8.0 MySQL path under PHP 8.4.27. It does not prove Laravel PostgreSQL behavior, custom database config, migrations, PHP-FPM, HTTP serving, signed-app behavior, or Vaelen-managed cache lifecycle. The framework fixture is an acceptance dependency, not a production dependency.

## Next actions

The implementation commit `a4fb244` is pushed to `codex/project-laravel-acceptance-20261028`. Open the PR stacked on `codex/project-connection-setup-fix-20261028` at [the GitHub compare page](https://github.com/banestojanovic/vaelen/compare/codex/project-connection-setup-fix-20261028...codex/project-laravel-acceptance-20261028?expand=1). This session had no `gh` or `origin` CLI and no browser surface, so it could not submit the PR.

The cleanup removed seven measured Swift `.build` trees totaling 9,632,688 KiB, the 30 MiB Vaelen Xcode DerivedData directory, and the 60 KiB `Scripts/__pycache__` directory. Available disk space rose from 39 GiB to 48 GiB. It preserved all source and every Git worktree. The audit could not confirm chat ownership, and it found uncommitted work in `project-connection-setup-impl`, `vaelen-provider-fixture`, and `.worktrees/invalid-instance-remove-fix`.

The read-only `/private/tmp` inventory still shows large Vaelen candidates: `vaelen-recovery-build-20261028` (779 MiB), `vaelen-db-badge-build` (774 MiB), `vaelen-dbprov-settings-build` (766 MiB), and seven `vaelen-dbprov-<UUID>` directories at about 190 MiB each. They remain because an earlier removal attempt was safety-blocked and this session must not retry those paths. The final acceptance evidence remains at `/private/tmp/vaelen-laravel-connection-evidence.UPgcZY`. The initial failure log remains at `.audit/test-failures/swift-test.JlOJDz` as historical evidence and was not staged.
