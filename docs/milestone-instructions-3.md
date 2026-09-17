
You are continuing development of Vaelen.

Milestone 0 and Milestone 1 have been completed successfully, manually verified, and should now be treated as stable foundations.

M0 proved:

    Vaelen.app ──┐
                 ├──► vaelend
    val ─────────┘

with:

- authoritative per-user Core
- structured IPC over UNIX domain sockets
- shared Core client
- protocol versioning
- single-daemon enforcement
- typed status
- JSON CLI output
- native menu-bar client

M1 proved:

    persistent registration ──┐
                              ├──► Project Registry ──► Core
    filesystem discovery ─────┘

with:

- explicit project registration
- parked path discovery
- SQLite persistence
- canonical path handling
- stable UUID identity for registered projects
- ephemeral filesystem-derived discovery
- safe merging of linked/discovered projects
- Core-authoritative mutations
- strict source-directory ownership boundaries

Do not redesign M0 or M1 unless implementation evidence demonstrates a genuine architectural defect.

Your task is now:

# MILESTONE 2 — PHP RUNTIME

This is Vaelen's first managed runtime.

The milestone must prove that Vaelen can:

1. discover available PHP versions from an approved distribution source;
2. download a compatible PHP distribution;
3. verify it;
4. install it into Vaelen-owned package storage;
5. validate it before activation;
6. support multiple PHP versions side-by-side;
7. execute Vaelen-managed PHP for CLI use;
8. configure and supervise PHP-FPM;
9. expose PHP-FPM over a UNIX domain socket;
10. start/stop PHP-FPM honestly;
11. observe its process identity and health;
12. expose the same state through Core, CLI, and the minimal GUI;
13. preserve M0/M1 architecture and ownership rules.

However:

# DO NOT BEGIN BY IMPLEMENTING THE PHP MODULE.

This milestone has a mandatory investigation/prototype gate.

The PHP distribution strategy must be proven before production architecture is built around it.

==================================================
1. READ THE DOCUMENTATION FIRST
==================================================

Before modifying code, read completely:

    docs/PHILOSOPHY.md
    docs/ARCHITECTURE.md

    docs/adr/0001-core-runtime-model.md
    docs/adr/0003-package-and-module-system.md
    docs/adr/0004-filesystem-state-and-ownership.md
    docs/adr/0005-ipc-and-client-protocol.md
    docs/adr/0007-php-runtime-architecture.md
    docs/adr/0008-project-model-and-desired-state-reconciliation.md

Also consult:

    docs/adr/0002-routing-provider.md
    docs/adr/0006-privilege-dns-and-tls.md

when necessary to ensure M2 does not accidentally cross their boundaries.

ADR-0003 and ADR-0007 are especially important.

Treat the documentation as architectural source of truth.

If this prompt conflicts with an ADR, the ADR wins.

If implementation evidence materially contradicts an ADR assumption, STOP before building around the contradiction and report it.

==================================================
2. INSPECT THE EXISTING IMPLEMENTATION
==================================================

Before editing:

1. inspect the entire repository;
2. inspect Package.swift;
3. inspect VaelenCore;
4. inspect VaelenIPC;
5. inspect VaelenDaemon;
6. inspect VaelenCLI;
7. inspect Vaelen.app;
8. inspect SQLite/state architecture;
9. inspect filesystem/path abstractions;
10. inspect current logging;
11. inspect operation/concurrency architecture;
12. inspect all tests.

Preserve working M0/M1 architecture.

Before implementing anything, provide a concise plan describing:

- existing extension points;
- what M2 requires;
- what will remain untouched;
- how Phase A will validate the PHP distribution;
- what conditions must pass before Phase B begins.

==================================================
3. M2 HAS TWO MANDATORY PHASES
==================================================

M2 is explicitly divided into:

    PHASE A — DISTRIBUTION PROOF
    PHASE B — RUNTIME IMPLEMENTATION

Do not skip Phase A.

Do not build production PHP architecture around an assumed distribution before Phase A succeeds.

==================================================
4. PHASE A — PHP DISTRIBUTION PROOF
==================================================

ADR-0007 identifies static-php-cli as a strong candidate.

It is NOT architectural identity.

Do not assume it is acceptable merely because the ADR mentions it.

Investigate the current practical options for distributing self-contained Vaelen-managed PHP binaries on macOS.

The preferred properties are:

- Apple Silicon native;
- predictable downloadable artifacts;
- redistributable under compatible licensing;
- PHP CLI support;
- PHP-FPM support;
- appropriate Laravel extensions;
- appropriate WordPress/WooCommerce extensions;
- low external dependency burden;
- version-addressable releases;
- checksum/signature verification where available;
- practical automated installation;
- no Homebrew lifecycle dependency;
- no Docker;
- no VM;
- no compilation required during ordinary user installation.

static-php-cli should be investigated first because ADR-0007 identifies it as the current strong candidate.

But evaluate evidence, not preference.

==================================================
5. REQUIRED PHASE A VALIDATION
==================================================

Create a temporary/prototype investigation outside the production architecture where practical.

Validate at least one current PHP 8.4 build suitable for Apple Silicon.

The exact patch version should be determined from the actual available distribution, not hard-coded from this prompt.

Verify:

    php -v

works.

Verify:

    php -m

works.

Verify PHP-FPM exists and runs:

    php-fpm -v

or the distribution's equivalent.

Verify architecture:

    file <php-binary>

It must be native arm64 for initial Vaelen support.

Inspect dynamic dependencies:

    otool -L <php-binary>

Understand what external libraries are required.

The goal is not necessarily “zero dynamic libraries.”

The goal is:

    Vaelen understands and owns the runtime dependencies required for reliable execution.

Do not accidentally depend on arbitrary Homebrew paths.

==================================================
6. REQUIRED EXTENSION INVESTIGATION
==================================================

ADR-0007 identifies the initial compatibility target approximately as:

    bcmath
    ctype
    curl
    dom
    fileinfo
    filter
    gd
    iconv
    intl
    mbstring
    mysqli
    mysqlnd
    openssl
    pcntl
    pdo
    pdo_mysql
    phar
    session
    simplexml
    sodium
    tokenizer
    xml
    xmlreader
    xmlwriter
    zip

Determine which are:

- built into the selected distribution;
- statically compiled;
- dynamically loadable;
- unavailable;
- named differently in current PHP.

Do not fail a candidate merely because a modern PHP version integrates functionality differently.

Validate actual runtime capabilities.

==================================================
7. IMAGICK INVESTIGATION
==================================================

Imagick deserves explicit investigation because it matters substantially for real WordPress usage.

Determine:

- whether the selected PHP distribution can support Imagick;
- whether an arm64-compatible Imagick extension is available;
- what ImageMagick libraries it requires;
- whether those dependencies can be cleanly owned/distributed by Vaelen;
- whether loading Imagick introduces Homebrew assumptions;
- whether it materially complicates package distribution.

Do NOT force Imagick into M2 if doing so would compromise the architecture.

If core PHP distribution passes but Imagick requires a separate extension/package architecture, document that clearly and defer implementation.

The important requirement is that we understand the path before claiming WordPress compatibility.

==================================================
8. PHASE A REAL-WORLD SMOKE TESTS
==================================================

Where practical, use the candidate PHP binary against disposable or existing test fixtures to validate:

    php -r 'echo PHP_VERSION, PHP_EOL;'

and basic:

- JSON
- OpenSSL
- cURL
- mbstring
- PDO MySQL extension loading
- mysqli loading
- ZIP
- GD
- intl

Do not require a running database server.

Verify extension availability, not database connectivity.

If Composer is available independently, verify that the candidate PHP can execute Composer.

Do not make Composer installation part of M2 yet.

==================================================
9. PHASE A FPM TEST
==================================================

Create a minimal temporary PHP-FPM configuration.

Start FPM as the current user.

Configure it to listen on a temporary UNIX domain socket.

Verify:

- master process starts;
- socket appears;
- process is arm64;
- process stops cleanly;
- socket cleanup behavior is understood;
- no root privileges are required.

Do not involve Caddy/nginx yet.

M2 tests PHP-FPM itself, not HTTP routing.

==================================================
10. PHASE A LICENSING / DISTRIBUTION CHECK
==================================================

Inspect relevant upstream licenses and redistribution requirements.

Document:

- PHP license;
- selected binary distribution/project license;
- bundled library considerations;
- extension licensing considerations where relevant.

Do not provide legal conclusions beyond what the licenses state.

The implementation must preserve required notices/licenses.

Do not copy third-party artifacts into the repository unnecessarily.

==================================================
11. PHASE A OUTPUT
==================================================

Before Phase B, produce a concise internal engineering conclusion:

    Candidate:
    Architecture:
    PHP CLI:
    PHP-FPM:
    Required extensions:
    Imagick:
    Dynamic dependencies:
    Artifact verification:
    Licensing:
    Distribution automation:
    Risks:
    Recommendation:

If the candidate satisfies the architectural requirements, continue to Phase B.

If it does NOT, STOP.

Do not silently choose Homebrew.

Do not silently compile PHP locally.

Do not weaken ADR-0007 merely to complete the milestone.

Report the blocker and candidate alternatives.

==================================================
12. PHASE B — IMPLEMENTATION
==================================================

Only after Phase A succeeds should production implementation begin.

M2 should implement the smallest architecture necessary to manage PHP correctly.

Do NOT build the entire future module ecosystem.

ADR-0003 defines the direction.

M2 proves that direction with one real runtime.

==================================================
13. DOMAIN MODEL
==================================================

Introduce only the generic concepts M2 actually requires.

Conceptually:

    Module
      ↓
    Package
      ↓
    Instance
      ↓
    Process

But do not build a huge generic framework.

For PHP:

    PHP module
        │
        ▼
    PHP package/version
        │
        ▼
    PHP runtime instance
        │
        ├── CLI binary
        │
        └── FPM process/socket

Core must remain free of PHP-specific branching where the ADR says generic mechanisms belong.

At the same time, do not create generic abstractions with no second use case merely for architectural purity.

Balance matters.

==================================================
14. PACKAGE STORAGE
==================================================

Follow ADR-0004.

Vaelen-managed PHP must live under Vaelen-owned Application Support package storage.

Conceptually:

    ~/Library/Application Support/Vaelen/
        packages/
            php/
                <exact-version>/

Do not store packages:

- inside Vaelen.app;
- inside project directories;
- under arbitrary /usr/local paths;
- inside Homebrew;
- inside ~/.vaelen unless architecture already established otherwise.

Exact paths must come from the centralized Vaelen path abstraction.

==================================================
15. VERSION-ADDRESSED PACKAGES
==================================================

Installed PHP packages must use exact versions.

Conceptually:

    php/
        8.3.XX/
        8.4.XX/

Multiple versions must coexist.

Installing PHP 8.4 must not overwrite PHP 8.3.

Installing PHP 8.4.XX+1 must not destructively overwrite 8.4.XX before validation.

==================================================
16. PACKAGE INSTALLATION PIPELINE
==================================================

Implement the installation flow described by ADR-0003:

    resolve
      ↓
    download
      ↓
    verify
      ↓
    extract to staging
      ↓
    validate
      ↓
    atomic install
      ↓
    record package metadata

Do not install directly into the final package directory while downloading/extracting.

Use Vaelen cache/staging paths appropriately.

Failed installation must not leave a package appearing valid.

==================================================
17. ARTIFACT VERIFICATION
==================================================

Use the strongest practical upstream verification available.

At minimum, use trusted checksums if provided by the chosen distribution mechanism.

Never treat a successful HTTP download as sufficient integrity validation.

Store provenance metadata sufficient to understand:

- source;
- artifact;
- version;
- architecture;
- checksum;
- installation state.

Do not invent cryptographic guarantees the upstream does not provide.

==================================================
18. PACKAGE VALIDATION
==================================================

Before activation, validate the installed candidate.

At minimum:

    php -v
    php -m
    php-fpm -v

Confirm expected version and architecture.

Confirm required baseline capabilities/extensions.

If validation fails:

- installation fails;
- package does not become active;
- existing working version remains untouched.

==================================================
19. PACKAGE METADATA VS FILESYSTEM REALITY
==================================================

Remember ADR-0004:

    SQLite stores metadata about reality.
    It does not become reality itself.

If SQLite says PHP 8.4 exists but its package directory is gone, Vaelen must report it missing/degraded.

If package files exist but metadata is missing, do not automatically delete them.

Bias toward preservation and diagnosis.

==================================================
20. VERSION RESOLUTION
==================================================

Support user-facing minor-line installation:

    val php install 8.4

This should resolve to an exact approved patch version:

    8.4.x

according to the selected distribution metadata.

The resolved exact version must be visible.

Do not silently reinterpret:

    8.4

as arbitrary system PHP.

Also allow exact version installation if the distribution supports it cleanly:

    val php install 8.4.x

==================================================
21. CLI — VERSION LISTING
==================================================

Implement:

    val php versions

or the clean equivalent consistent with existing CLI architecture.

It should distinguish:

- available versions;
- installed versions;
- current CLI default where applicable;
- running FPM versions where applicable.

Keep human output compact.

Support JSON output if the existing CLI output architecture makes it straightforward.

==================================================
22. INSTALLED != RUNNING
==================================================

This invariant is non-negotiable.

After:

    val php install 8.4

there should be no PHP-FPM process merely because PHP is installed.

Installation means:

    binary/package available

not:

    service running

Verify with process inspection.

==================================================
23. PHP-FPM INSTANCE
==================================================

M2 should initially use one default FPM runtime instance per installed/active PHP version as ADR-0007 specifies.

Do NOT create one FPM pool per project yet.

Conceptually:

    php@8.4
        ↓
    default FPM instance
        ↓
    php-8.4.sock

Exact socket naming/path should follow Vaelen runtime conventions.

==================================================
24. FPM CONFIGURATION
==================================================

Generate Vaelen-owned PHP-FPM configuration outside immutable package directories.

Package:

    immutable software

Instance:

    mutable configuration/runtime/data as appropriate

Keep these separate.

Do not mutate package files to represent runtime configuration unless the upstream runtime makes it unavoidable and the architecture explicitly accounts for it.

==================================================
25. UNIX DOMAIN SOCKET
==================================================

PHP-FPM should listen on a Vaelen-owned UNIX domain socket.

Do not use an arbitrary TCP port for normal FPM operation.

Core should know:

- socket path;
- owning PHP version;
- FPM process identity;
- health.

Socket existence alone is not proof of health.

==================================================
26. FPM START
==================================================

Implement:

    val php start 8.4

or equivalent.

It should:

1. resolve installed PHP version;
2. validate package availability;
3. generate/validate instance config;
4. ensure no conflicting Vaelen-owned instance is already starting;
5. start PHP-FPM;
6. record process identity;
7. wait for readiness;
8. verify health;
9. report actual status.

Do not return success merely because `fork/exec` succeeded.

==================================================
27. FPM STOP
==================================================

Implement:

    val php stop 8.4

or equivalent.

Stopping must:

- target only the Vaelen-owned FPM process;
- verify identity before signaling;
- request graceful shutdown where appropriate;
- escalate only according to explicit lifecycle policy;
- verify termination;
- safely handle stale runtime socket state.

After successful stop:

    pgrep / process inspection

must show the Vaelen-owned FPM process is gone.

Off means off.

==================================================
28. NEVER KILL BY PID ALONE
==================================================

ADR-0001 explicitly forbids this.

Persisted PID alone is insufficient process ownership proof.

Before signaling a process, validate enough identity to establish that it is the Vaelen-owned PHP-FPM process expected for that runtime.

Use the M0/M1 architecture and ADR guidance.

Never kill an unrelated external PHP-FPM process merely because a PID was reused.

==================================================
29. FPM STATUS
==================================================

Implement:

    val php status 8.4

Human output should expose useful truth.

Conceptually:

    PHP 8.4.x

    Package     Installed
    FPM         Running
    PID         12345
    Socket      ~/Library/.../php-8.4.sock
    Health      Healthy

Do not display fake resource metrics if they are not implemented yet.

==================================================
30. FPM HEALTH
==================================================

Health must be stronger than:

    PID exists

At minimum combine appropriate evidence such as:

- expected process identity;
- expected executable;
- socket existence/type;
- process liveness;
- FPM-specific readiness where practical.

Do not introduce Caddy merely to health-check FPM.

==================================================
31. PROCESS SUPERVISION
==================================================

M2 is the first real consumer of the process-supervision architecture from ADR-0001.

Implement only the generic process-supervision capability required by PHP-FPM.

Core should understand:

- executable path;
- arguments;
- environment;
- working directory where relevant;
- PID;
- launch identity/time;
- stdout/stderr/log destinations;
- lifecycle state;
- health;
- socket;
- ownership metadata.

Do not build a giant generic process framework.

But do not put all lifecycle logic directly into `PHPModule`.

==================================================
32. DAEMON RESTART RECONCILIATION
==================================================

This is important.

Scenario:

    vaelend
      starts PHP-FPM
         ↓
    vaelend crashes/stops
         ↓
    PHP-FPM survives

When Core restarts, it must not blindly:

- start a duplicate FPM;
- kill the existing FPM;
- assume persisted PID is valid.

Use ADR-0001's reconciliation rules.

If safe ownership can be established, adopt/reconcile the surviving Vaelen-owned process.

If ownership cannot be established safely, report degraded/unknown rather than killing arbitrary processes.

Add tests where feasible.

==================================================
33. FPM CRASH
==================================================

If PHP-FPM exits unexpectedly, Core should detect that its previous process is gone.

Do not necessarily implement automatic restart yet unless the existing supervisor architecture naturally supports the ADR policy.

At minimum status must become truthful:

    Running
        ↓ crash
    Failed / Stopped / Degraded

according to the chosen lifecycle semantics.

Do not leave stale Running state.

==================================================
34. LOGGING
==================================================

Capture PHP-FPM logs in Vaelen-owned log storage.

Expose enough information for debugging.

Do not dump everything into the daemon's own log.

Conceptually:

    ~/Library/Logs/Vaelen/
        php/
            ...

Follow existing path abstractions.

Rotate/manage logs only to the degree necessary for M2.

Do not build the final log viewer yet.

==================================================
35. CLI PHP DEFAULT
==================================================

Implement:

    val php use 8.4

to set Vaelen's global/default CLI PHP version.

This is Vaelen-owned user configuration.

Persist the selection.

It must resolve to an installed exact package.

Do not allow selecting a version Vaelen does not have installed without a clear error.

==================================================
36. CLI PHP EXECUTION
==================================================

Provide a reliable way to execute the selected Vaelen-managed PHP.

At minimum, this must be possible through Vaelen itself, for example:

    val php exec -- -v

or another clean command consistent with the CLI architecture.

The output must come from the Vaelen-managed PHP binary, not `/usr/bin/php`, Homebrew PHP, or Herd.

==================================================
37. `php` SHIM — IMPLEMENT ONLY IF CLEAN
==================================================

ADR-0007's long-term goal is:

    cd project
    php -v

resolves the correct Vaelen PHP.

However, project-aware PHP selection is not fully required until project runtime configuration exists.

For M2, a lightweight global `php` shim may be implemented IF it can be done cleanly and reversibly.

If implemented:

- it must be extremely fast;
- it must not require daemon IPC on every `php` invocation;
- it should resolve from generated/cached selection state;
- Core remains authoritative for changes;
- shell integration must be reversible;
- it must not overwrite system PHP;
- it must not modify unrelated shell configuration destructively.

If this becomes complicated, STOP at:

    val php exec

plus:

    val php use

and document shim integration as deferred.

Do not compromise architecture merely to make `php -v` pretty in M2.

==================================================
38. PROJECT-AWARE PHP IS NOT M2
==================================================

Do not yet implement:

    project A → PHP 8.3
    project B → PHP 8.4

as automatic CLI behavior.

ADR-0007 requires it eventually.

ADR-0008 provides the project model.

But M2 proves PHP runtime management first.

Project-to-runtime reconciliation belongs to a later milestone.

You may ensure the architecture can support it.

Do not implement it prematurely.

==================================================
39. FPM DEMAND-DRIVEN SEMANTICS
==================================================

ADR-0007 ultimately wants FPM to run according to project demand.

M2 has no routing/project-runtime reconciliation yet.

Therefore explicit commands are the initial demand mechanism:

    val php start 8.4
    val php stop 8.4

Do not invent fake project demand before routing exists.

Later `val up` will drive this automatically.

==================================================
40. MULTIPLE PHP VERSIONS
==================================================

M2 must prove coexistence.

Where distribution availability allows, install two supported PHP lines, preferably something like:

    8.3
    8.4

Do not hard-code these if upstream current support differs.

Verify:

- both packages coexist;
- both CLI binaries work;
- both FPM instances can run simultaneously;
- each uses a different UNIX socket;
- stopping one does not stop the other.

This is one of M2's key architectural proofs.

==================================================
41. NO ROUTER
==================================================

Do not implement Caddy.

Do not send FastCGI requests through Caddy.

Do not configure hostnames.

Do not create `.test` routes.

M2 ends at:

    PHP-FPM UNIX socket

M3 will connect routing to it.

==================================================
42. NO DNS OR TLS
==================================================

Do not:

- modify `/etc/resolver`;
- create certificates;
- modify Keychain trust;
- bind 80/443;
- create privileged helper.

M2 is entirely user-level.

==================================================
43. NO DATABASES
==================================================

Do not install:

- MySQL
- PostgreSQL
- Redis

PHP extensions for talking to those systems are fine.

The services themselves are later modules.

==================================================
44. NO COMPOSER MANAGEMENT YET
==================================================

Do not turn Composer into a managed module in M2.

If Composer is already installed on the development machine, it may be used for compatibility testing.

The selected PHP runtime must be capable of running Composer.

Actual Composer installation/version lifecycle can be handled later.

==================================================
45. NO FRAMEWORK DRIVERS
==================================================

Do not implement:

- LaravelDriver
- WordPressDriver
- SymfonyDriver

M2 is PHP runtime architecture.

Framework detection will become relevant when projects begin resolving runtimes/routing.

==================================================
46. GUI SCOPE
==================================================

Keep Vaelen.app deliberately minimal.

Extend it only enough to prove the GUI sees Core-owned PHP state.

Something conceptually like:

    Vaelen
    ● Core Running

    PHP

    8.4.x
    ● FPM Running
    PID 12345

    8.3.x
    ○ Stopped

is enough.

Do not build:

- package browser;
- extension manager;
- PHP settings UI;
- process charts;
- final module cards;
- installer onboarding.

CLI is the primary M2 test surface.

==================================================
47. GUI MUST NOT MANAGE PHP DIRECTLY
==================================================

The app must never:

- spawn php-fpm itself;
- kill PHP;
- inspect package directories as its source of truth;
- edit PHP configuration directly.

Correct:

    Vaelen.app
        ↓
    Core client
        ↓
    IPC
        ↓
    vaelend
        ↓
    PHP runtime/package/process architecture

==================================================
48. PERSISTENCE
==================================================

Extend SQLite only with state M2 genuinely needs.

Potential persisted concepts:

- installed package metadata;
- PHP default CLI selection;
- runtime instance metadata;
- process ownership metadata needed for safe reconciliation.

Do not persist every transient observation.

Actual process state must always be observed from macOS.

Do not trust SQLite's `running = true` after restart.

==================================================
49. PACKAGE REMOVAL
==================================================

If manageable within M2, implement:

    val php uninstall <version>

Rules:

- refuse while its FPM instance is running unless explicit lifecycle semantics safely stop it;
- refuse if it is the selected CLI version unless the user selects another version or explicit behavior is defined;
- never remove another version;
- remove Vaelen-owned package files only;
- preserve unrelated user data/config according to ADR-0004;
- never touch Homebrew/system/Herd PHP.

If uninstall meaningfully expands M2 beyond safe scope, it may be deferred.

But package ownership/removability must be designed correctly.

==================================================
50. INSTALLATION FAILURE TESTS
==================================================

Test failures such as:

- download failure;
- invalid checksum;
- extraction failure;
- missing PHP binary;
- wrong version;
- wrong architecture;
- missing required baseline capability.

A failed install must not become a valid installed package.

Existing versions must remain usable.

==================================================
51. PROCESS SAFETY TESTS
==================================================

Test:

- start;
- idempotent start;
- stop;
- idempotent stop;
- crash detection;
- stale PID;
- PID reuse protection where practical;
- stale socket;
- two versions simultaneously;
- stopping one version leaves the other running.

Do not kill arbitrary system processes in tests.

Use controlled fixtures/processes.

==================================================
52. FILESYSTEM SAFETY TESTS
==================================================

Ensure package cleanup only operates inside validated Vaelen-owned roots.

Test protection against:

- path traversal;
- unexpected symlinks;
- malformed package versions;
- deletion outside package root.

Deletion code deserves stricter tests than creation code.

==================================================
53. PERSISTENCE TESTS
==================================================

Using isolated temporary databases:

- installed package metadata persists;
- default PHP selection persists;
- runtime metadata persists as appropriate;
- actual process reality overrides stale persisted state.

Never use the developer's real Vaelen database in automated tests.

==================================================
54. IPC TESTS
==================================================

Extend typed IPC for PHP operations.

Conceptually:

    php.availableVersions
    php.installedVersions
    php.install
    php.use
    php.start
    php.stop
    php.status

Use established naming conventions rather than these exact strings if appropriate.

Long-running installation must use the M0 operation/progress architecture if available.

Do not hold a fragile request socket open with no operation semantics for a potentially long download/install.

==================================================
55. PROGRESS
==================================================

Installation should expose meaningful stages where supported:

    Resolving PHP 8.4
    Downloading
    Verifying
    Extracting
    Validating
    Installing
    Complete

Do not fake percentage precision if download size/progress is unavailable.

Stage-based progress is acceptable.

==================================================
56. CONCURRENT INSTALLS
==================================================

Prevent two clients from corrupting the same package installation.

For example, concurrent:

    val php install 8.4
    val php install 8.4

must serialize/deduplicate appropriately.

Do not allow both to extract into the same final directory.

==================================================
57. CONCURRENT START/STOP
==================================================

Mutations for the same runtime instance must be serialized.

Two clients cannot both independently start the same FPM instance.

Start/stop races must resolve deterministically.

==================================================
58. EXTERNAL PHP
==================================================

Vaelen may detect external PHP for diagnostics.

But M2 must never:

- adopt Homebrew PHP as a Vaelen-owned package;
- uninstall it;
- modify its configuration;
- kill its FPM;
- treat it as equivalent to Vaelen-managed PHP.

Ownership must remain explicit.

==================================================
59. RESOURCE HONESTY
==================================================

After installing PHP but before starting FPM:

    installed: yes
    running: no

Process inspection must confirm no FPM process.

After starting:

    running: yes
    PID: real
    socket: real

After stopping:

    running: no

Process inspection must confirm process termination.

No hidden worker should remain merely because PHP is installed.

==================================================
60. PERFORMANCE
==================================================

Measure enough to establish a baseline:

- installed package size;
- PHP CLI startup time approximately;
- FPM idle process count;
- FPM idle memory approximately;
- daemon resource impact before/after PHP support.

Do not optimize prematurely.

Record observations.

This will matter later when comparing Vaelen's native runtime model.

==================================================
61. MANUAL ACCEPTANCE — INSTALL
==================================================

Using actual CLI:

    val php install 8.4

Verify exact resolved version.

Then inspect Vaelen package storage.

Verify:

- exact version directory;
- binary architecture;
- package metadata;
- no Homebrew installation was performed.

Run:

    <Vaelen-managed-php> -v

and:

    val php exec -- -v

Both should identify the same managed PHP.

==================================================
62. MANUAL ACCEPTANCE — INSTALLED != RUNNING
==================================================

Immediately after installation:

    val php status 8.4

should report FPM stopped.

Inspect processes.

There must be no Vaelen PHP-FPM process.

==================================================
63. MANUAL ACCEPTANCE — START
==================================================

Run:

    val php start 8.4

Then:

    val php status 8.4

Verify:

- Running
- real PID
- real socket
- Healthy

Inspect the process using macOS tools.

Confirm reported PID matches actual FPM master process.

Inspect socket.

==================================================
64. MANUAL ACCEPTANCE — STOP
==================================================

Run:

    val php stop 8.4

Verify:

    val php status 8.4

reports stopped.

Verify actual FPM process is gone.

Verify stale socket state is handled correctly.

==================================================
65. MANUAL ACCEPTANCE — MULTIPLE VERSIONS
==================================================

Install two supported PHP lines.

Start both.

Verify:

    PHP A → PID A → socket A
    PHP B → PID B → socket B

Both must coexist.

Stop PHP A.

Verify PHP B remains healthy.

Then stop PHP B.

==================================================
66. MANUAL ACCEPTANCE — DAEMON RESTART
==================================================

Start FPM.

Record FPM PID.

Restart/kill only `vaelend`, not PHP-FPM.

Observe what happens.

According to the implemented safe reconciliation design:

- duplicate FPM must not be started;
- unrelated process must not be killed;
- surviving Vaelen-owned FPM should be safely reconciled/adopted if ownership can be proven.

Verify status becomes truthful after Core restart.

Document exact observed behavior.

==================================================
67. MANUAL ACCEPTANCE — FPM CRASH
==================================================

Start FPM.

Terminate the controlled FPM process externally.

Query:

    val php status 8.4

Vaelen must not continue reporting stale Running state.

Do not test by killing unrelated PHP processes.

==================================================
68. MANUAL ACCEPTANCE — CORE AUTHORITY
==================================================

Stop `vaelend`.

Attempt:

    val php start 8.4

It must fail.

CLI must not bypass Core and start FPM directly.

Restart Core.

Command should work again.

==================================================
69. MANUAL ACCEPTANCE — GUI
==================================================

With PHP installed/stopped:

GUI should show stopped.

Start PHP through CLI.

GUI should eventually show running after refresh/event update.

Stop PHP.

GUI should show stopped.

GUI state and CLI state must originate from the same Core.

==================================================
70. MANUAL ACCEPTANCE — NO COLLATERAL INFRASTRUCTURE
==================================================

After M2 inspect running processes.

Expected Vaelen-related infrastructure:

    vaelend
    Vaelen.app
    optional Vaelen-managed php-fpm versions explicitly started

Not expected:

    Caddy
    nginx
    dnsmasq
    MySQL
    Redis
    Mailpit
    Docker
    Podman
    privileged helper

M2 is PHP only.

==================================================
71. REAL-WORLD COMPATIBILITY SMOKE TEST
==================================================

After the runtime works, use Vaelen-managed PHP against representative existing code without changing project runtime architecture yet.

For a Laravel project, manually run using the Vaelen PHP executable:

    php artisan --version

or equivalent through `val php exec`.

For a WordPress/WooCommerce project, validate basic CLI execution and extension availability where practical.

Do not alter those projects.

Do not make them Vaelen runtime-managed yet.

The goal is compatibility evidence.

==================================================
72. DO NOT HIDE DISTRIBUTION PROBLEMS
==================================================

If during implementation you discover:

- required extensions are missing;
- FPM is unreliable;
- binary depends on Homebrew unexpectedly;
- architecture is wrong;
- signing/quarantine makes distribution impractical;
- upstream artifacts cannot be verified;
- licensing creates an issue;
- Imagick architecture is problematic;
- binary updates cannot be reliably discovered;

STOP and report.

Do not create hacks just to satisfy the milestone checklist.

M2 exists partly to discover whether ADR-0007's assumptions survive reality.

==================================================
73. BUILD INCREMENTALLY
==================================================

Recommended sequence:

PHASE A

1. inspect architecture and M0/M1;
2. research candidate PHP distribution;
3. acquire candidate artifact;
4. verify architecture/dependencies;
5. verify CLI;
6. verify extensions;
7. investigate Imagick;
8. verify FPM;
9. verify UDS operation;
10. inspect licensing/distribution;
11. produce Phase A conclusion.

ONLY IF ACCEPTED:

PHASE B

12. implement minimal package domain;
13. implement artifact resolution/download;
14. implement verification;
15. implement staging/extraction;
16. implement validation;
17. implement atomic package installation;
18. persist package metadata;
19. implement PHP version resolution;
20. implement PHP CLI execution;
21. implement CLI default selection;
22. implement PHP-FPM instance config;
23. implement process supervision primitives;
24. implement start;
25. implement health/status;
26. implement stop;
27. implement daemon restart reconciliation;
28. extend IPC;
29. extend CLI;
30. minimally extend GUI;
31. add comprehensive tests;
32. run manual acceptance tests;
33. run real Laravel/WordPress smoke tests.

Do not implement the entire milestone and compile only at the end.

==================================================
74. COMPLETION REPORT
==================================================

When finished, provide:

## Phase A — Distribution Proof

Candidate selected.

Exact PHP versions tested.

Architecture.

CLI result.

FPM result.

Extension matrix.

Imagick findings.

Dynamic dependencies.

Artifact verification mechanism.

Licensing observations.

Risks.

Why the candidate was accepted.

## Implemented

What M2 actually does.

## Package Architecture

Storage layout.

Metadata.

Version resolution.

Download/verification/install flow.

Atomicity behavior.

## PHP Runtime

CLI execution.

Default version.

FPM configuration.

Sockets.

Process lifecycle.

Health.

## Process Supervision

Ownership verification.

Start/stop behavior.

Crash behavior.

Daemon restart reconciliation.

## IPC

Methods added.

Protocol compatibility decision.

## CLI

Commands implemented with examples.

## GUI

Minimal PHP representation.

## Tests

Tests added and complete result.

## Manual Verification

Commands actually executed and observed results.

## Performance

Package size.

Approximate CLI startup.

FPM idle process/memory observations.

## Files

Important files added/changed.

## Decisions

Implementation choices left open by ADRs.

## ADR Concerns

Anything implementation evidence suggests should be reconsidered.

## Deferred

Explicitly list:

- routing
- DNS
- TLS
- project-aware PHP
- automatic project demand
- databases
- Redis
- Mailpit
- Composer management
- framework drivers
- extension management if deferred
- Imagick if deferred
- privileged helper
- final GUI

Do not say M2 is complete unless production code builds, tests pass, and real PHP binaries have been manually exercised.

==================================================
75. DEFINITION OF DONE
==================================================

M2 is complete only when:

PHASE A

[ ] a real PHP distribution candidate was investigated
[ ] Apple Silicon architecture was verified
[ ] PHP CLI was executed
[ ] PHP-FPM was executed
[ ] FPM over UNIX socket was proven
[ ] required baseline extension compatibility was investigated
[ ] Imagick path was explicitly investigated
[ ] dynamic dependencies were inspected
[ ] artifact verification strategy was established
[ ] licensing/redistribution requirements were inspected
[ ] candidate was explicitly accepted before production integration

PACKAGE MANAGEMENT

[ ] PHP versions resolve to exact versions
[ ] package artifacts are downloaded into Vaelen-controlled staging/cache
[ ] artifacts are verified
[ ] packages are validated before activation
[ ] installation is atomic
[ ] exact versions are stored separately
[ ] multiple versions coexist
[ ] package metadata persists
[ ] filesystem reality overrides stale metadata
[ ] failed installation does not damage working packages
[ ] no Homebrew lifecycle dependency exists

CLI PHP

[ ] Vaelen-managed PHP CLI executes
[ ] `val php exec` or equivalent works
[ ] global/default PHP selection persists
[ ] selected PHP resolves to an installed Vaelen package
[ ] PHP execution does not accidentally use system/Herd/Homebrew PHP

PHP-FPM

[ ] installed does not imply running
[ ] FPM config is separate from immutable package
[ ] FPM runs as current user
[ ] FPM listens on a Vaelen-owned UNIX socket
[ ] start works
[ ] repeated start is safe
[ ] stop works
[ ] repeated stop is safe
[ ] actual process disappears after stop
[ ] process ownership is verified before signaling
[ ] PID alone is never trusted
[ ] health is stronger than PID existence
[ ] stale sockets are handled safely
[ ] unexpected process exit produces truthful state
[ ] daemon restart does not create duplicate FPM
[ ] multiple PHP versions can run simultaneously
[ ] stopping one version does not stop another

CORE / IPC

[ ] PHP lifecycle is Core-authoritative
[ ] CLI does not start PHP directly
[ ] GUI does not start PHP directly
[ ] typed IPC operations exist
[ ] concurrent lifecycle mutations are serialized
[ ] concurrent installs cannot corrupt packages
[ ] existing M0/M1 behavior still works

GUI

[ ] minimal PHP state is visible
[ ] GUI state originates from Core
[ ] GUI does not inspect PHP independently

SAFETY

[ ] no project source files are modified
[ ] no system PHP is modified
[ ] no Homebrew PHP is modified
[ ] no Herd PHP is modified
[ ] no external PHP-FPM process is killed
[ ] no root privileges are required
[ ] no privileged helper is added
[ ] deletion is constrained to Vaelen-owned paths

SCOPE

[ ] no Caddy
[ ] no nginx
[ ] no DNS changes
[ ] no TLS changes
[ ] no MySQL server
[ ] no PostgreSQL server
[ ] no Redis server
[ ] no Mailpit
[ ] no Docker
[ ] no Podman
[ ] no framework drivers
[ ] no project-aware automatic PHP selection
[ ] no `val up`
[ ] no final module UI

QUALITY

[ ] repository builds cleanly
[ ] full M0 tests still pass
[ ] full M1 tests still pass
[ ] new M2 tests pass
[ ] real PHP CLI tested manually
[ ] real PHP-FPM tested manually
[ ] real multiple-version behavior tested where available
[ ] Laravel compatibility smoke-tested
[ ] WordPress/WooCommerce compatibility investigated where practical

Stop there.

DO NOT automatically begin Milestone 3.

==================================================
FINAL ENGINEERING PRINCIPLE
==================================================

M0 proved:

    clients → Core

M1 proved:

    intent + filesystem reality → Core

M2 must prove:

    upstream software
          │
          ▼
    verified package
          │
          ▼
    Vaelen ownership
          │
          ▼
    configured instance
          │
          ▼
    supervised native process
          │
          ▼
       real health

The goal is NOT merely:

    "Vaelen can run PHP."

The goal is:

    "Vaelen can responsibly own the lifecycle of software it manages."

That distinction is foundational.

If we cannot trust Vaelen to install, identify, start, observe, stop, update, and eventually remove one PHP runtime safely, we should not build MySQL, Redis, Mailpit, Caddy, or anything else on top of the same architecture.

Keep M2 narrow.

Make PHP real.

Make ownership explicit.

Make lifecycle truthful.

And stop when the milestone is proven.
