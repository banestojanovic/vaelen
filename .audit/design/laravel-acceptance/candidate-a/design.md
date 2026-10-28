# Laravel connection acceptance through the existing MySQL journey

The acceptance must fail when Laravel receives a different connection than the account provisioned through `val`. Extend the existing package-backed XCTest rather than introduce a second provisioning journey. Boot a pinned official Laravel application in the linked project that receives the actual connection apply. Run both uncached and cached boot checks with the installed Vaelen PHP 8.4.27 binary.

This is a design proposal. No implementation or successful acceptance run is claimed.

## Data shape

Use one private expected-value document owned by the XCTest root. Swift encodes it from the requested database name, requested user, selected fixture port, fixed connection kind and host, and the revealed Keychain credential. Do not derive expected values from `.env`, `generatedDotenvValues`, Laravel output, or the generated cache.

```json
{
  "database.default": "mysql",
  "database.connections.mysql.host": "127.0.0.1",
  "database.connections.mysql.port": "<fixture port as decimal string>",
  "database.connections.mysql.database": "dbprov_app",
  "database.connections.mysql.username": "dbprov_app_user",
  "database.connections.mysql.password": "<private generated credential>"
}
```

The committed probe contains no credential. Swift writes the actual JSON with mode `0600` under a root created with mode `0700`. Read the JSON from a file path argument. The password never enters process arguments or the child environment. Normalize only the port to a decimal string before comparison. Compare every other selected config value with strict string equality. A mismatch reports only the field name and phase. Never use XCTest equality on the entire expected object or password because its failure printer exposes values.

The probe accepts `app-root`, `expected-path`, and one of `uncached` or `cached`. The phase determines the required state of `$app->configurationIsCached()`. The successful result is a fixed token such as `LARAVEL_CONNECTION_ACCEPTANCE uncached PASS` or `LARAVEL_CONNECTION_ACCEPTANCE cached PASS`. No config values appear in output.

## Exact file changes

1. Add `Tests/Fixtures/LaravelConnection/` as an official `laravel/laravel` v13.11.0 application snapshot with `composer.json`, `composer.lock`, a provenance README, and the PHP application files needed for console bootstrap. Keep the official `artisan`, `bootstrap/app.php`, `bootstrap/providers.php`, `app/Providers/AppServiceProvider.php`, `routes/console.php`, `routes/web.php`, `public/index.php`, and the standard `config/*.php` files. Keep storage and bootstrap cache directory placeholders. Preserve the skeleton's license. Do not commit `vendor`, generated caches, `.env`, keys, SQLite files, frontend output, or credentials. Keep official `config/database.php` unchanged. Pin the root dependency `laravel/framework` to `13.39.0` and commit the resolved lock. The provenance README records the exact official skeleton release or commit, source archive SHA-256, retained-file list, framework version, phpdotenv version, Composer version, and intentional omission of frontend and tutorial files. The successful throwaway probe at `/private/tmp/vaelen-laravel-boot-probe.6cgu9y/app` supplies the starting snapshot and lock. It has framework v13.39.0 and phpdotenv v5.8.0. The implementer records the official skeleton source archive identity before committing the fixture.
2. Add `Tests/Fixtures/LaravelConnectionProbe.php`. This is an external console probe rather than a replacement config file or dotenv loader. It requires the application's real `vendor/autoload.php`, requires its official `bootstrap/app.php`, obtains `Illuminate\Contracts\Console\Kernel`, and calls `bootstrap()`. It asserts the cache mode, checks the six expected fields through Laravel's config repository, and optionally runs `DB::connection()->selectOne('SELECT 1 AS accepted')` as an extra check of the framework's selected connection. Make the SQL check part of the acceptance, since the running private MySQL already exists. Catch `Throwable` and print only a fixed phase failure or a field name. Disable PHP display errors. Do not print exception messages or stack traces.
3. Extend `Scripts/tests/val-project-database-provisioning-test.sh`. Preserve its package provenance preflight, build, selected XCTest, and retained evidence. Resolve the installed Composer PHP entry file and invoke it explicitly as `"$PHP_PACKAGE/php" "$COMPOSER_ENTRY"`. Never invoke Composer's shell launcher through its shebang. Prepare a separate `mktemp` root with mode `0700`, copy the tracked Laravel snapshot into it, and install the lock once before running XCTest. Set `COMPOSER_HOME` and `COMPOSER_CACHE_DIR` inside that root. Run `install --no-interaction --no-progress --prefer-dist --no-scripts --no-plugins --no-dev` under PHP 8.4.27. Do not run `update`, `create-project`, or an unpinned resolver during acceptance. Pass the prepared application path as `VAELEN_TEST_LARAVEL_APP_ROOT` and the committed probe path as `VAELEN_TEST_LARAVEL_PROBE` to the existing XCTest. Hash the lock, fixture files, probe, package metadata, val binary, and PHP binary into safe retained evidence. Record runtime `PHP_VERSION` and installed framework and phpdotenv package versions without dumping configuration.
4. Extend `Tests/VaelenIPCTests/ProjectDatabaseProvisioningEndToEndTests.swift`. Require the prepared app and probe paths alongside the existing opt-in environment variables. Copy the prepared app into the existing owned `project` before linking. Remove the fake artisan and public entrypoint creation. Start with valid UTF-8 `.env` fixture bytes. Retain the later CRLF review fixture and its preservation assertions. Create the expected-value file only after revealing the actual credential. Add a bounded PHP child helper with allowlisted environment, fixed safe diagnostics, and private output files. Insert the Laravel checks after the successful final connection apply and before any recovery restores `.env`. Preserve every existing collision, stale approval, non-Laravel refusal, recovery, PDO, neighboring-database, restart, unlink, claim, log, and cleanup check.
5. Update `.agents/skills/verify-vaelen/features/project-connection-setup.md` and `project-database-provisioning.md`. State the precise new Laravel runtime proof, fixture and lock version, the locked Composer download requirement, and the remaining limits. Remove only the obsolete claim that this journey never boots Laravel. Keep all other limits.

No source file under `Sources/` or `App/` changes. Keep malformed-byte coverage in the existing Core tests. The integration fixture's initial invalid byte has no Laravel compatibility value and cannot enter this real runtime proof.

## Execution order

1. The shell verifies MySQL 8.4.11 and Vaelen PHP 8.4.27 exactly as today. Additionally assert `PHP_VERSION === '8.4.27'` using that binary. Verify Composer is an actual readable PHP entrypoint. Reject an unresolved wrapper rather than silently use Homebrew PHP.
2. The shell creates and installs the locked app in its disposable preparation root. Composer runs before credentials or the private Core exist. Retain its safe preparation log if installation fails. Keep setup separate from the XCTest's 30-second PHP child budget. Give installation a 300-second deadline with TERM then KILL and reap the owned child before deleting its root. No retry or dependency resolution fallback runs automatically.
3. The XCTest copies the app into its existing private root. It creates `.env` with valid UTF-8, mode `0600`, and inert settings such as `APP_ENV=testing`, `APP_DEBUG=false`, `LOG_CHANNEL=stderr`, `CACHE_STORE=array`, `SESSION_DRIVER=array`, and `QUEUE_CONNECTION=sync`. The later reviewed CRLF fixture carries these settings plus the existing comment and `CUSTOM_VALUE=keep`. Do not set any `DB_*` environment variables in PHP child processes. Do not run Laravel migrations, key generation, package discovery scripts, or a development server.
4. Run the existing MySQL and Core journey through successful actual `val project db connection apply`. Save `appliedEnvironment` bytes exactly as today. Build the private expected JSON from the independent fixture inputs and revealed password. Assert `bootstrap/cache/config.php` is absent. Use an allowlist containing only required `HOME`, `PATH`, and locale entries for PHP children. This prevents inherited `DB_URL`, `DB_*`, `APP_ENV`, and `APP_CONFIG_CACHE` from replacing values or paths.
5. Launch fresh PHP 8.4.27 with the probe and `uncached`. The application boots through its real console kernel, real Laravel environment bootstrap, and installed phpdotenv. Require all six fields, an uncached state, a successful framework MySQL query, zero exit status, and exactly the fixed success token. Assert `.env` still equals `appliedEnvironment` without printing either byte array on failure.
6. Launch a separate PHP 8.4.27 process with the official `artisan config:cache --no-ansi --no-interaction` in the actual project directory and the same clean environment. Require exit zero and a regular `bootstrap/cache/config.php`. Treat this cache as a secret file because it contains the password. Launch with restrictive `umask`, enforce mode `0600` after creation, and keep its parent private. Do not retain or print the cache content.
7. Rename the actual `.env` to a private sibling under the XCTest root. During this short interval, make no Core recovery request. Assert the project `.env` is absent. Launch a fresh PHP process with the probe and `cached`. Require cached state, the same independent six config expectations, a successful Laravel MySQL query, and the fixed success token. This makes a false pass from rereading `.env` observable. Restore the same `.env` file in a guaranteed cleanup scope even when this probe fails. Compare its bytes to `appliedEnvironment` with a boolean assertion. Do not construct a replacement dotenv file.
8. Remove `bootstrap/cache/config.php`, confirm its absence, and delete the expected JSON after successful comparison. Do this before the original Core restore/discard journey. Continue every existing assertion and PDO operation unchanged. Keep the current generated-value parser and PDO check as additional coverage, but never treat their results as the Laravel oracle. Retain generated-password comparison only in a form that cannot print the password on failure.
9. Existing Core shutdown, bounded MySQL stop, exact Keychain cleanup, and root-removal checks finish the XCTest. Only after test-child termination is confirmed does the shell remove its separate preparation root. Retain evidence outside both disposable roots.

## Commands

The acceptance command remains unchanged.

```sh
Scripts/tests/val-project-database-provisioning-test.sh
```

The locked install inside the shell-owned preparation root is equivalent to the following command. The script supplies absolute paths and private Composer directories.

```sh
"$PHP_PACKAGE/php" "$COMPOSER_ENTRY" install \
  --working-dir="$LARAVEL_PREPARED_APP" \
  --no-interaction --no-progress --prefer-dist --no-scripts --no-plugins --no-dev
```

The XCTest launches these real PHP commands as separate bounded children.

```sh
"$PHP" "$PROBE" "$PROJECT" "$EXPECTED" uncached
"$PHP" "$PROJECT/artisan" config:cache --no-ansi --no-interaction
"$PHP" "$PROBE" "$PROJECT" "$EXPECTED" cached
```

Run focused Swift checks through the mandated wrapper before the live recipe.

```sh
Scripts/test.sh --skip-update --disable-automatic-resolution \
  --filter 'ProjectConnectionSetupTests|ProjectDatabaseConnectionProtocolTests|ProjectRelationshipCLIParsingTests|ProjectRegistryTests'
```

The selected live XCTest count remains one, with zero skips. Evidence must distinguish Composer preparation, uncached runtime, cache build, cached runtime, and final cleanup. Extend the existing fixture success record with safe fields `laravel=13.39.0 phpdotenv=5.8.0 php=8.4.27 laravelUncached=passed laravelConfigCache=passed laravelCachedWithoutEnv=passed laravelDatabase=authenticated`.

## Falsifiable pass criteria

All original acceptance assertions pass. Both Laravel phases assert six independent expected config values. Both phases authenticate through Laravel's MySQL connection. The cached phase runs in a fresh process while `.env` is absent. The uncached phase runs without a config cache. The config cache comes from the official `artisan config:cache` command after actual val apply. Every PHP and Composer invocation uses the verified Vaelen binary. All children terminate, the original `.env` returns before recovery, all original recovery checks pass, exact Keychain cleanup succeeds, both disposable roots disappear, and retained evidence contains only safe summaries.

Before calling the implementation complete, run controlled negative checks locally. Change one expected host value and require a field-only failure. Corrupt one selected `DB_*` value in the post-apply file for a throwaway uncached run and require rejection. Remove the generated cache during a cached phase and require rejection. These mutations belong only to temporary acceptance roots and do not become committed fixtures. Add a throwaway secret marker to a controlled probe failure and confirm the PHP helper never propagates raw child output into retained evidence. A failure must still restore a temporarily hidden `.env` and enter existing fixture cleanup.

## Risks and cleanup

Composer installation needs network on an empty disposable cache. The committed lock prevents resolution drift, but registry or dist outages still fail preparation. Report those failures as setup failures, never a skipped acceptance. The lock and official snapshot need deliberate maintenance when Laravel or PHP targets change. Reject incompatible dependencies rather than ignoring platform requirements.

Disabling Composer scripts requires testing the chosen official snapshot without a generated package manifest. The framework and phpdotenv packages install normally. Console boot and config caching are the acceptance gates that expose missing requirements. Do not patch config files to make installation appear to work. If a standard writable directory is required, create it inside the fixture and record the path.

The test creates new secret-bearing files in expected JSON, config cache, Laravel logs, and hidden `.env`. Keep all inside the private XCTest root. Scan runtime logs and captured output in memory for the revealed credential before retaining evidence. Delete secret-bearing probe output on every completion path. On unexpected PHP failure, report only phase, exit status, timeout status, or field name. Do not interpolate Laravel exceptions, failed assertions containing values, raw `.env`, Composer environment dumps, or `config:show` output.

Use the existing root-preservation policy when owned Core or MySQL termination is uncertain. Preserve a root with mode `0700` and report its path without copying its content to evidence. Remove expected JSON, raw PHP output, config cache, and hidden `.env` only when no child may still use them and restoration or teardown is safe. Never kill by process name. Never delete installed packages, user's Composer cache, user projects, shared Keychain namespaces, or retained evidence. The shell owns only preparation and its install child. The XCTest owns the copied app, database, private Core, runtime PHP children, credential namespace, and all connection recovery state.

This proves one pinned Laravel 13.39.0 MySQL configuration path under PHP 8.4.27. It does not prove PostgreSQL Laravel behavior, arbitrary user providers, custom config/database.php conventions, migrations, PHP-FPM, HTTP serving, signed app behavior, or automatic product cache management. Vaelen still does not run config:cache for the user.
