# Laravel acceptance with a committed official application fixture

This design makes the existing MySQL journey prove that Laravel reads the connection written by `val`. The acceptance uses a committed snapshot of the official Laravel application and a committed Composer lock. The shell installs dependencies into a disposable template before it starts XCTest. XCTest copies the template into its own project directory and owns every credential-bearing file.

The named data shape is `LaravelConnectionExpectation`. It is a JSON object whose keys are the six Laravel config paths below and whose values are strings. Swift constructs it from the requested database, requested user, allocated port, and the password revealed into memory. It never derives expected values from the generated `.env` parser.

```json
{
  "database.default": "mysql",
  "database.connections.mysql.host": "127.0.0.1",
  "database.connections.mysql.port": "<allocated port as decimal text>",
  "database.connections.mysql.database": "dbprov_app",
  "database.connections.mysql.username": "dbprov_app_user",
  "database.connections.mysql.password": "<revealed password>"
}
```

Password is a runtime value, never a committed fixture value. The acceptance mode is a separate enum with `uncached` and `cached` cases. Each PHP invocation takes only the expectation file path and mode in its arguments.

## Exact file changes

1. Add `Tests/Fixtures/Laravel13/app/`. Copy the successful official application probe, excluding `vendor`, `.env`, `.git`, runtime cache files, logs, `node_modules`, and `database.sqlite`. Retain its official `artisan`, `bootstrap/app.php`, `bootstrap/providers.php`, `app`, `config`, `routes`, `public`, `storage` directory structure, `composer.json`, `composer.lock`, license, and remaining official skeleton files. Do not simplify `config/database.php` or introduce a substitute bootstrap. Empty runtime directories may use the upstream `.gitignore` files. This adds a versioned test fixture, not an application dependency.
2. Add `Tests/Fixtures/Laravel13/provenance.json`. Record the official `laravel/laravel` source reference and version from the probe's package acquisition, the source archive SHA-256, Laravel framework `13.39.0`, the locked `vlucas/phpdotenv` version, Composer `2.9.8`, and SHA-256 values for `composer.json`, `composer.lock`, `artisan`, `bootstrap/app.php`, and `config/database.php`. Obtain the missing acquisition reference and archive hash before implementation is accepted. Never substitute a guessed source version. If the probe's acquisition reference cannot be recovered, obtain the same official skeleton again at an immutable reference and compare the retained files before recording it.
3. Add `Scripts/tests/fixtures/laravel-connection-probe.php`. This is the only new PHP test logic. It requires the project's real `vendor/autoload.php`, loads its real `bootstrap/app.php`, resolves the console kernel, and calls `bootstrap()`. It checks the runtime, cache state, selected config values, and a database query. It never parses `.env` itself.
4. Update `Scripts/tests/val-project-database-provisioning-test.sh`. Preserve package provenance checks, the val build, evidence output, and the selected XCTest. Add disposable Laravel template creation, locked dependency installation, template validation, and a required `VAELEN_TEST_LARAVEL_TEMPLATE` input to XCTest. Record fixture and lock hashes in `source.txt`.
5. Update `Tests/VaelenIPCTests/ProjectDatabaseProvisioningEndToEndTests.swift`. Copy the prepared template into `root/project` before linking it. Remove the fake artisan and public index creation. Change the initial `.env` comment to valid UTF-8. Insert Laravel assertions immediately after successful final connection apply and before recovery restore. Keep the existing parser assertions and PDO, collision, neighbor, restart, recovery, claim, and Keychain checks.
6. Update `.agents/skills/verify-vaelen/features/project-database-provisioning.md`. State that the MySQL recipe also checks Laravel 13 config before and after caching. Record dependency setup requirements and explain that PostgreSQL and native UI coverage do not change.

The fixture keeps the official Composer requirements, including the root `^13.17` framework constraint seen in the probe. The lock determines the actual framework version. Changing the lock is an explicit fixture refresh. Run Composer with `--no-dev` so the acceptance does not install PHPUnit or development tooling.

## Shell preparation

The shell creates an exact disposable root with `mktemp -d /private/tmp/vaelen-laravel-template.XXXXXX`, then sets `umask 077`. A trap removes that root on success, failure, signal, or interruption and still prints the retained evidence path. The trap removes only the exact root the shell created. Its template has no generated credentials, private Core, or running services.

Copy the committed fixture into `$LARAVEL_ROOT/app`. Put `COMPOSER_HOME` and `COMPOSER_CACHE_DIR` below `$LARAVEL_ROOT`. Run the installed Composer file through `$PHP_PACKAGE/php` directly. Do not execute Composer's shebang. Confirm that the Composer executable is a PHP entrypoint and that it reports the expected version under this interpreter. All Composer child commands use this same PHP. Install with scripts and plugins disabled.

```sh
"$PHP_PACKAGE/php" "$COMPOSER_EXECUTABLE" --version
"$PHP_PACKAGE/php" "$COMPOSER_EXECUTABLE" install --working-dir="$LARAVEL_ROOT/app" --no-dev --prefer-dist --no-interaction --no-progress --no-scripts --no-plugins
"$PHP_PACKAGE/php" "$COMPOSER_EXECUTABLE" check-platform-reqs --working-dir="$LARAVEL_ROOT/app" --no-dev
```

Use a sanitized Composer environment with no inherited Composer authentication or global configuration, and bound installation to 600 seconds through a small Python subprocess runner. Keep Composer output in the retained evidence directory. No database secret exists yet. Treat lock mismatch, platform mismatch, missing vendor files, framework version mismatch, or dependency download failure as recipe failures. Do not update dependencies, ignore platform requirements, fall back to system PHP, or skip the Laravel phase. Record Composer and framework versions and lock hash in evidence.

Set `VAELEN_TEST_LARAVEL_TEMPLATE` to the prepared app and pass the existing package inputs. The normal command remains:

```sh
Scripts/tests/val-project-database-provisioning-test.sh
```

## XCTest sequence

The existing test remains the single owner of private Core, linked project, MySQL data, Keychain namespace, and its unique root. Add the Laravel template path to the required environment guard. The shell recipe always supplies it. A plain Swift suite without installed package inputs continues to skip the package-backed test.

1. Set fixture root mode to `0700`. Copy the prepared template into the existing `project` location. Assert that the copy contains the real artisan, bootstrap, config, and vendor autoloader, with no cached config. Retain the `neighbor` project's existing behavior.
2. Write the initial valid UTF-8 `.env` and continue all existing provisioning and stale-review tests. The existing reviewed CRLF comment and `CUSTOM_VALUE=keep` remain the final pre-apply file. Keep Core unit-test coverage for malformed-byte preservation unchanged.
3. After the real final `val project db connection apply`, retain the actual `appliedEnvironment` bytes. Write `root/laravel-expected.json` with mode `0600` using the independent values above. Do not log the file contents.
4. Launch the installed Vaelen PHP with the committed probe and `uncached`. Use the actual project as cwd. The probe asserts PHP `8.4.27`, Laravel `13.39.0`, the locked phpdotenv version, no cached config, and `CUSTOM_VALUE=keep` loaded by dotenv. It compares every selected config path to the private expectation. It uses Laravel's database manager to execute `SELECT 1`, which must return `1`. Success prints only `LARAVEL_CONNECTION uncached PASS`.
5. Run the actual `php artisan config:cache --no-ansi --no-interaction` using the same PHP, cwd, and sanitized environment. Require exit zero. Require the cache file to exist and record only its existence. Never retain its bytes as evidence because the cache contains the password.
6. Move the actual applied `.env` to `root/applied-env-held`, preserving the bytes. A Swift `defer` restores the file even if the next assertion fails. Start a fresh PHP process with probe mode `cached`. It must see `configurationIsCached() == true`, no project `.env`, and no `CUSTOM_VALUE` in the process environment. It compares all selected config values against the same private expectation and repeats Laravel's `SELECT 1`. Success prints only `LARAVEL_CONNECTION cached PASS`. Removing `.env` makes loading values from cached config falsifiable.
7. Restore `.env`. Assert its bytes equal `appliedEnvironment`. Run `php artisan config:clear` and require the cache file to disappear. Delete the expectation and held `.env` file before the existing recovery restore. The retained transaction therefore sees the same applied bytes it originally produced.
8. Continue the existing recovery restore and discard flow, original PDO migration, denial of access to the neighboring database, MySQL restart, private Core restart, unlink, exact Keychain cleanup, and final root removal. Extend the existing evidence line with `laravel=13.39.0 dotenv=uncached configCache=passed laravelPDO=passed` only after both phases pass and cleanup is confirmed.

## Child process contract

The Laravel process helper is separate from `runVal`, which persists ordinary CLI output. It captures PHP stdout and stderr in memory, checks both for the known revealed password, and only releases an allowlisted success line or a fixed diagnostic such as `Laravel cached config mismatch field=database.connections.mysql.password`. It never forwards raw framework exception text into XCTest output.

Give PHP a fresh allowlisted environment containing only a safe PATH, isolated HOME, `APP_ENV=testing`, `APP_DEBUG=false`, and `LOG_CHANNEL=null`. There are no inherited `DB_*`, `DATABASE_URL`, `APP_CONFIG_CACHE`, `APP_ENV`, or Composer settings. Set HOME below the fixture root. Configuration cache uses the project's default location. The probe catches `Throwable`, emits a field name or a fixed failure category, and exits nonzero without an exception dump. The artisan helper also captures output in memory and reports only its phase and exit status. Existing timeout and forced child-exit handling apply to all PHP processes.

The probe accepts only the two known modes. It reads and validates the expectation shape before bootstrapping. It casts the actual port to decimal text, then uses strict string comparison for all values. It must not print actual or expected values. In `uncached`, it verifies dotenv's unrelated marker to catch a framework boot that bypasses `.env`. In `cached`, it verifies absence of that marker and of `.env`, so environment fallback cannot masquerade as cache loading.

## Cleanup and risks

The shell deletes only the dependency template. XCTest deletes its private expectation, applied env backup, and cached config during normal progress, then applies its existing verified shutdown policy. On a failure it still restores `.env` before Core recovery decisions. If Core or MySQL shutdown cannot be proved, retain the root under the current policy and report its path. Keep that retained root at `0700`. Never copy `.env`, config cache, expectation, or raw PHP output to the retained evidence directory.

A Laravel snapshot adds upstream files and a lock to the repository. That is this design's explicit cost for reproducible, reviewable framework inputs and no runtime skeleton resolution. Downloads can still fail, but a failure is setup failure rather than an acceptance pass. The shell has a 600-second dependency deadline and existing PHP probes retain 30-second deadlines. Copying vendor adds disk work but does not add another database or Core owner.

The generated password alphabet may not cover every dotenv escape rule in one live run. Retain focused connection writer tests for hostile characters. This acceptance establishes compatibility for the actual provisioned credential and actual apply output. It does not claim exhaustive dotenv grammar coverage or PostgreSQL framework integration.

## Falsifiable acceptance

The candidate passes only if the package-backed shell recipe exits zero, emits both allowlisted Laravel phase lines, and writes final cleanup-confirmed evidence. Source evidence must identify PHP `8.4.27`, Laravel `13.39.0`, phpdotenv, Composer `2.9.8`, fixture hashes, and the committed lock hash.

Run focused Core and IPC checks through `Scripts/test.sh`, then run the live recipe. Before review, deliberately alter one expected field in an isolated run and confirm the corresponding phase fails with only its field name. In another isolated run, delete config cache before the cached probe and confirm cached-mode rejection. Restore the fixture afterward. These controls prove the checks can distinguish wrong config and absent cache. A failing Composer setup, missing framework boot, skipped Laravel phase, framework error, or unconfirmed cleanup cannot produce `result=PASS`.
