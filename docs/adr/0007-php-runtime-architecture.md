# ADR-0007: PHP Runtime Architecture

* **Status:** Proposed
* **Date:** 2026-09-17
* **Decision owners:** Vaelen maintainers

## Context

PHP is Vaelen's first runtime module and the foundation of the v0.1 local web-development environment.

Vaelen must support a workflow such as:

```bash
val php install 8.4
val php install 8.3

cd ~/Code/project-a
val php use 8.4

cd ~/Code/project-b
val php use 8.3
```

while allowing both projects to remain available simultaneously:

```text
https://project-a.test → PHP 8.4
https://project-b.test → PHP 8.3
```

The runtime must also support ordinary terminal usage:

```bash
php -v
composer install
php artisan migrate
wp cli ...
```

without forcing every command to run through Vaelen.

PHP therefore creates several distinct concerns:

* binary distribution;
* version installation;
* PHP CLI selection;
* PHP-FPM lifecycle;
* simultaneous PHP versions;
* per-project runtime selection;
* extensions;
* `php.ini`;
* FPM configuration;
* sockets;
* routing;
* process supervision;
* upgrades;
* architecture compatibility;
* shell integration.

The implementation must solve these without making Vaelen Core fundamentally PHP-specific.

---

# Decision

PHP will be implemented as an official Vaelen module using the generic module/package/process infrastructure established by previous ADRs.

Vaelen will own the PHP binaries it manages.

Multiple PHP versions may coexist.

Each active PHP version will have its own supervised PHP-FPM process and UNIX socket.

Projects select a PHP version.

The Router forwards PHP requests to the socket corresponding to the project's selected version.

Conceptually:

```text
project-a.test
      │
      ▼
    Router
      │
      ▼
php-8.4.sock
      │
      ▼
PHP-FPM 8.4


project-b.test
      │
      ▼
    Router
      │
      ▼
php-8.3.sock
      │
      ▼
PHP-FPM 8.3
```

CLI PHP selection and web PHP selection are related but separate concerns.

---

# 1. PHP is a module

Core understands generic concepts:

```text
module
package
version
instance
process
health
configuration
```

Core must not contain logic such as:

```swift
if module == "php" {
    startPHPFPM()
}
```

Instead:

```text
PHPModule
    │
    ├── describes packages
    ├── renders PHP configuration
    ├── describes FPM processes
    ├── exposes runtime endpoints
    └── reports health
```

Core provides generic mechanisms.

---

# 2. PHP package model

Each installed PHP version is a Vaelen package.

Conceptually:

```text
~/Library/Application Support/Vaelen/packages/php/

├── 8.3.26/
├── 8.4.13/
└── 8.5.0/
```

Exact versions are illustrative.

Each package should be self-contained enough to run independently from other Vaelen PHP versions.

---

# 3. Vaelen owns managed PHP

PHP installed through:

```bash
val php install 8.4
```

is Vaelen-owned.

It should not depend on:

```text
brew install php
brew unlink php
brew link php
```

for ordinary runtime lifecycle.

Homebrew PHP may be detected for diagnostics.

It remains externally owned.

---

# 4. Why Vaelen owns PHP binaries

Relying on a global package manager would weaken several Vaelen guarantees:

* deterministic installed versions;
* safe coexistence;
* controlled updates;
* rollback;
* uninstall ownership;
* reproducible project requirements;
* architecture consistency.

Vaelen needs to know:

```text
exact binary
exact version
exact configuration
exact process
```

for every runtime it manages.

---

# 5. PHP binary distribution

Vaelen should consume trusted prebuilt PHP distributions suitable for supported macOS architectures rather than compiling PHP locally during ordinary installation.

Desired flow:

```text
manifest
   ↓
resolve version + architecture
   ↓
download archive
   ↓
verify
   ↓
extract to staging
   ↓
validate binaries
   ↓
atomic install
```

The exact upstream/distribution source is intentionally not frozen by this ADR.

---

# 6. Distribution provider abstraction

The PHP module should separate:

```text
PHP runtime semantics
```

from:

```text
where PHP binaries come from
```

Conceptually:

```text
PHPModule
    │
    ▼
PHPDistributionProvider
    │
    ├── availableVersions()
    ├── artifact(for:)
    ├── checksum(for:)
    └── metadata(for:)
```

This allows Vaelen to change binary sources without redesigning project/runtime semantics.

---

# 7. static-php-cli

`static-php-cli` remains a strong candidate for building/distributing Vaelen-compatible PHP binaries.

However, Vaelen should not encode:

```text
PHP == static-php-cli
```

into Core architecture.

It is a distribution/build implementation decision.

Before committing, Vaelen must prototype the actual required extension matrix and PHP-FPM behavior.

---

# 8. Distribution acceptance criteria

A PHP distribution strategy is acceptable only if it can reliably provide the extensions required by mainstream Vaelen workloads.

At minimum, the v0.1 investigation should include common Laravel and WordPress needs such as:

```text
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
```

Exact bundled defaults will be decided from real compatibility testing.

---

# 9. Extensions are part of runtime compatibility

A runtime is not adequately described by:

```text
PHP 8.4
```

alone.

Real compatibility also depends on extensions.

Therefore PHP package metadata should expose installed/bundled extensions.

Example:

```text
PHP 8.4.13
Architecture: arm64

Extensions:
✓ curl
✓ intl
✓ mbstring
✓ mysqli
✓ pdo_mysql
✓ sodium
✓ zip
...
```

---

# 10. Extension strategy

Vaelen should prefer a useful, opinionated default PHP build over requiring developers to manually construct a minimal extension set.

The initial goal is:

> Install PHP and successfully run normal Laravel and WordPress projects.

Vaelen should not optimize binary size at the expense of everyday compatibility.

---

# 11. Optional extensions

Some extensions may be too specialized, difficult, or heavy to include universally.

Examples may include:

```text
imagick
xdebug
mongodb
redis
grpc
```

These should eventually have explicit lifecycle semantics rather than being silently expected.

Potential future model:

```bash
val php extension install imagick --php 8.4
```

The exact extension package architecture is deferred.

---

# 12. No arbitrary mutation of package directories

Base PHP packages should remain immutable where practical.

User-specific PHP configuration must not be written into:

```text
packages/php/8.4.13/
```

unless it is immutable package-owned configuration.

Mutable runtime configuration belongs elsewhere.

---

# 13. PHP runtime configuration

PHP configuration should live in Vaelen-managed instance/configuration state.

Conceptually:

```text
~/Library/Application Support/Vaelen/instances/php/

└── 8.4/
    ├── config/
    │   ├── php.ini
    │   ├── conf.d/
    │   └── php-fpm.conf
    │
    └── metadata.json
```

The exact instance naming may evolve.

---

# 14. Version vs instance

For the initial PHP module, one default runtime instance per installed PHP version is sufficient.

Conceptually:

```text
php/8.3
php/8.4
```

This does not prohibit future multiple differently configured instances of the same version.

The Core model remains generic enough to support them.

---

# 15. PHP-FPM process model

Each active PHP runtime version receives its own PHP-FPM master process.

Example:

```text
PHP-FPM 8.3
    │
    └── php-8.3.sock

PHP-FPM 8.4
    │
    └── php-8.4.sock
```

This allows simultaneous per-project PHP versions.

---

# 16. Why not one global PHP-FPM

A single FPM runtime would make:

```text
project A → PHP 8.3
project B → PHP 8.4
```

impossible simultaneously.

Switching one global runtime would disrupt unrelated projects.

Therefore Vaelen treats active PHP versions independently.

---

# 17. FPM sockets

PHP-FPM should communicate with the Router through UNIX domain sockets rather than arbitrary localhost TCP ports where practical.

Conceptually:

```text
runtime/sockets/php/

├── 8.3.sock
└── 8.4.sock
```

Benefits include:

* no TCP port allocation;
* local-only transport;
* clear ownership;
* easy attribution;
* straightforward per-version routing.

---

# 18. Socket lifecycle

The socket belongs to the running PHP-FPM process.

Core tracks:

```text
socket path
owner process
PHP version
health
```

A socket existing on disk does not prove FPM is alive.

After verifying the owning process is gone, stale sockets may be removed automatically.

---

# 19. FPM process ownership

PHP-FPM is started by Vaelen's Process Supervisor.

Core records:

```text
package
executable
PID
process identity
arguments
configuration
socket
start time
health
```

Vaelen must not supervise arbitrary externally started PHP-FPM processes as though it owned them.

---

# 20. FPM desired state

PHP-FPM should run only when required.

For example:

```text
PHP 8.3 installed
no project uses PHP 8.3
      ↓
FPM 8.3 need not run
```

while:

```text
project-a.test
requires PHP 8.4
      ↓
FPM 8.4 required
```

This directly supports:

> Off means off.

---

# 21. Demand-driven FPM

The desired long-term behavior is:

```text
Active linked projects
       │
       ▼
Required PHP versions
       │
       ▼
Required FPM processes
```

If no active project requires PHP 8.3, Vaelen may stop its FPM runtime.

The exact idle shutdown policy can be tuned after dogfooding.

---

# 22. Explicit runtime start

Users may still explicitly request a runtime to remain active.

The desired-state model should distinguish:

```text
required by project
```

from:

```text
explicitly requested by user
```

Core reconciles both sources of demand.

---

# 23. Router integration

The Router does not infer PHP versions itself.

Core resolves project runtime state.

Conceptually:

```text
Project
    │
    │ php: 8.4
    ▼
Core
    │
    ├── ensure PHP 8.4 installed
    ├── ensure FPM 8.4 running
    └── provide endpoint
             │
             ▼
       php-8.4.sock
```

Router configuration receives the resolved endpoint.

---

# 24. Router remains PHP-agnostic where practical

The Router implementation obviously needs to support FastCGI.

However, Core routing abstractions should describe a backend such as:

```text
FastCGIBackend
    socket: ...
```

rather than embedding PHP package-management logic into the Router.

---

# 25. Per-project PHP version

Projects may declare PHP in:

```text
vaelen.yml
```

Example:

```yaml
version: 1

php: "8.4"
```

This represents desired runtime compatibility.

---

# 26. Version constraints

Eventually project PHP requirements should support useful version constraints.

Potential examples:

```yaml
php: "8.4"
```

or:

```yaml
php: "^8.3"
```

However, exact constraint semantics should remain simple initially.

For v0.1, selecting a PHP minor line such as:

```text
8.4
```

and resolving it to the latest installed/approved compatible patch is sufficient.

---

# 27. Patch resolution

If the project specifies:

```text
8.4
```

and Vaelen has:

```text
8.4.11
8.4.13
```

installed, Core should have deterministic rules for selecting the active patch.

A sensible default is the latest installed compatible patch unless a lock or exact version overrides it.

Exact lock semantics belong to ADR-0008.

---

# 28. Composer compatibility

Vaelen should inspect:

```text
composer.json
```

through the appropriate project driver when no explicit Vaelen PHP version exists.

For example:

```json
{
  "require": {
    "php": "^8.3"
  }
}
```

may inform runtime recommendation or default selection.

However:

> Project metadata detection must not silently override explicit `vaelen.yml`.

Explicit Vaelen configuration wins.

---

# 29. Framework detection

Laravel, WordPress, Symfony, and Generic PHP drivers may help determine sensible defaults.

Examples:

```text
Laravel
    public/ document root

WordPress
    project root or configured web root

Symfony
    public/ document root
```

The PHP module itself should not detect Laravel.

That belongs to project drivers.

---

# 30. CLI PHP is separate from FPM selection

Consider:

```text
project-a.test → PHP 8.3
project-b.test → PHP 8.4
```

There is no single PHP version that can represent both projects globally.

Therefore Vaelen distinguishes:

```text
Web runtime
```

from:

```text
Shell PHP resolution
```

---

# 31. Global CLI default

Vaelen maintains a default CLI PHP version.

Example:

```bash
val php use 8.4
```

sets:

```text
default CLI PHP → 8.4
```

This controls ordinary:

```bash
php -v
```

outside project-specific resolution.

---

# 32. Project-aware CLI resolution

The preferred long-term behavior is:

```bash
cd ~/Code/project-a
php -v
```

returns the PHP version selected for project A.

Then:

```bash
cd ~/Code/project-b
php -v
```

returns project B's version.

This provides parity between:

```text
browser PHP
```

and:

```text
terminal PHP
```

without requiring manual switching.

---

# 33. CLI shim

The likely implementation is a lightweight Vaelen-managed `php` shim placed early in the user's PATH.

Conceptually:

```text
php
 │
 ▼
Vaelen PHP shim
 │
 ├── determine current directory
 ├── resolve registered project
 ├── resolve project PHP
 │
 └── otherwise use global default
        │
        ▼
actual Vaelen PHP binary
```

This must remain extremely fast.

---

# 34. Shim is not Core IPC dependent for every invocation

Running:

```bash
php artisan
```

must not incur expensive daemon IPC merely to locate PHP if that can be safely avoided.

The CLI resolver should use a fast local representation of PHP selection state or another efficient mechanism.

The exact mechanism should be benchmarked.

---

# 35. Core remains authoritative

Fast shell resolution may use cached/generated state.

However, Core remains authoritative for configuration changes.

Conceptually:

```text
Core state
   │
   ▼
atomic shell resolution map
   │
   ▼
php shim
```

The shim does not independently modify Vaelen state.

---

# 36. No shell alias dependency

Vaelen should not rely solely on:

```bash
alias php="..."
```

because aliases:

* differ by shell;
* may not apply to subprocesses;
* are awkward for tools and IDEs;
* are not a robust executable-resolution mechanism.

A real executable/shim is preferred.

---

# 37. Shell integration

Vaelen may add one stable directory to PATH.

Conceptually:

```text
~/.vaelen/bin
```

or an appropriate Vaelen-managed location.

This directory contains stable entry points such as:

```text
php
composer
val
```

where appropriate.

The exact path belongs to implementation.

---

# 38. Minimal shell modification

Vaelen should avoid rewriting large sections of:

```text
.zshrc
.bashrc
```

It should make the smallest reversible shell integration necessary.

Any modification must be tracked according to ADR-0004.

---

# 39. Composer

Composer is closely related to PHP but should not become embedded inside the PHP executable itself.

Vaelen may provide a managed Composer entry point.

The important behavior is:

```text
composer
```

should run using the PHP version resolved for the current project.

Conceptually:

```text
composer shim
     │
     ▼
resolve PHP
     │
     ▼
php <composer.phar>
```

Exact Composer lifecycle may be addressed during implementation.

---

# 40. Global tools

Tools such as:

```text
Composer
WP-CLI
Laravel installer
PHP CS Fixer
PHPStan
Pest
```

raise separate questions about global tooling.

They are not required to be solved by PHP module v0.1.

Vaelen should not turn PHP runtime design into a global PHP package manager prematurely.

---

# 41. PHP configuration layers

PHP configuration should support clear layering.

Conceptually:

```text
Vaelen package defaults
        │
        ▼
Vaelen PHP-version config
        │
        ▼
optional project overrides
```

Project overrides should be constrained and explicit.

---

# 42. Base `php.ini`

Vaelen should ship or generate sensible development defaults.

Examples of development-oriented behavior may include:

```text
display_errors
error_reporting
memory_limit
upload limits
timezone handling
```

Exact defaults should be chosen from real Laravel/WordPress compatibility needs.

They should not pretend to represent production PHP configuration.

---

# 43. CLI and FPM configuration

CLI and FPM may require some distinct settings.

The configuration architecture should allow:

```text
shared PHP configuration
CLI-specific configuration
FPM-specific configuration
```

without duplicating the entire config.

---

# 44. Configuration inspection

Users should be able to discover the effective runtime configuration.

Potential commands:

```bash
val php info 8.4
val php config 8.4
```

The exact CLI surface can evolve.

The GUI should expose equivalent information.

---

# 45. Configuration ownership

Vaelen-generated configuration should be clearly identified.

Advanced users may eventually be allowed to edit overrides.

Vaelen should not overwrite explicitly user-owned overrides during routine updates.

Generated files and user override files should remain distinguishable.

---

# 46. PHP-FPM pool model

For v0.1, one FPM pool per PHP version is the preferred starting point.

Conceptually:

```text
PHP 8.4
   │
   ▼
Vaelen pool
   │
   ▼
php-8.4.sock
```

Projects sharing PHP 8.4 share the FPM runtime.

---

# 47. Why not one pool per project initially

One pool per project would provide stronger isolation but significantly increase:

* process count;
* memory;
* configuration;
* lifecycle complexity.

For a lightweight local environment, sharing by PHP version is a better initial tradeoff.

---

# 48. Future project isolation

The architecture must not prevent future project-specific pools.

Potential future configuration:

```yaml
php:
  version: "8.4"
  isolated: true
```

would allow:

```text
project-a → dedicated FPM pool
```

without changing the package model.

This is explicitly not required for v0.1.

---

# 49. FPM worker policy

Development defaults should favor low idle resource consumption.

Vaelen should investigate FPM process-manager modes appropriate for local development.

The goal is:

```text
idle project
    ↓
minimal PHP worker footprint
```

while preserving responsive first requests.

Exact FPM tuning must be benchmarked.

---

# 50. Resource observability

Vaelen should expose runtime metrics.

Example:

```text
PHP 8.4

Status       ● Running
Version      8.4.13
FPM PID      42182
Workers      2
Memory       41 MB
Socket       php-8.4.sock

Used by:
• syncproof.test
• callthewaiter.test
```

This reinforces resource honesty.

---

# 51. Runtime health

PHP runtime health is more than:

```text
PID exists
```

Core should verify:

```text
FPM process identity
socket exists
socket accepts expected communication
runtime responds correctly
```

A process that exists but cannot serve requests is degraded or failed.

---

# 52. Health probe

The PHP module may implement a lightweight FastCGI health probe or equivalent runtime validation.

The Router's ability to reach the FPM endpoint may also contribute to platform diagnostics.

Health semantics should remain module-defined and Core-executed where possible.

---

# 53. PHP CLI health

Installation validation should also execute:

```bash
php -v
```

and inspect expected output.

Potential additional validation:

```bash
php -m
```

for required extensions.

A package is not considered successfully installed merely because extraction completed.

---

# 54. Architecture support

Vaelen initially targets Apple Silicon.

PHP package resolution must include:

```text
architecture: arm64
```

If x86_64 support is introduced later, it becomes an explicit package dimension.

Vaelen should not silently run translated binaries when a native package is expected.

---

# 55. Rosetta

Rosetta-based PHP execution should not be the default strategy.

If future compatibility requires it for a specialized extension, Vaelen should expose that fact explicitly.

Native Apple Silicon remains preferred.

---

# 56. Package update

Updating PHP follows ADR-0004 package semantics.

Example:

```text
8.4.13 installed
       │
       ▼
download 8.4.14
       │
       ▼
verify
       │
       ▼
install alongside
       │
       ▼
validate CLI + FPM
       │
       ▼
switch resolved 8.4 runtime
       │
       ▼
stop old FPM when unused
```

The working version is not destroyed before replacement validation succeeds.

---

# 57. Patch updates and projects

A project declaring:

```yaml
php: "8.4"
```

may move from:

```text
8.4.13
```

to:

```text
8.4.14
```

according to Vaelen's update/reconciliation policy.

A future lock file may pin the exact patch.

ADR-0008 defines the project-side semantics.

---

# 58. Runtime switch

Switching the resolved package behind PHP 8.4 should be coordinated.

Conceptually:

```text
install new package
       ↓
render compatible config
       ↓
start new FPM
       ↓
health check
       ↓
switch router endpoint
       ↓
stop old FPM
```

This minimizes disruption.

---

# 59. Rollback

If the new FPM fails validation:

```text
new package
    FAILED
```

the existing working runtime remains selected.

Vaelen reports the update failure.

It must not leave all PHP 8.4 projects offline merely because an update failed.

---

# 60. PHP uninstall

Running:

```bash
val php uninstall 8.3
```

must check dependencies.

If projects currently require PHP 8.3:

```text
Cannot uninstall PHP 8.3.

Used by:
• legacy-shop.test
• old-api.test
```

Vaelen should not silently break those projects.

---

# 61. Forced removal

A future explicit force option may allow removal despite dependencies.

That is destructive to environment functionality and must be clearly presented.

The default is dependency-safe.

---

# 62. PHP module uninstall

Removing the PHP module entirely is distinct from removing one PHP version.

Conceptually:

```text
php package versions
runtime configuration
FPM runtime state
```

may be removed according to module lifecycle.

Project files remain untouched.

Project configuration declaring PHP remains untouched.

---

# 63. Reinstallation

If PHP is later reinstalled, existing projects declaring:

```yaml
php: "8.4"
```

should be able to reconcile again.

Project declarations survive runtime removal.

---

# 64. PHP logs

PHP/FPM logs belong under Vaelen's log hierarchy.

Conceptually:

```text
~/Library/Logs/Vaelen/modules/php/

├── 8.3/
└── 8.4/
```

or an equivalent structured layout.

They should not accumulate unboundedly.

---

# 65. Project PHP errors

Vaelen may eventually provide a richer project log viewer.

However, v0.1 does not need to intercept or reinterpret every PHP exception.

First establish reliable runtime and log access.

---

# 66. Xdebug

Xdebug is valuable but not part of the minimum PHP runtime.

It should eventually behave as an optional capability.

Potential future UX:

```text
PHP 8.4

Xdebug
○ Off
```

When off, it should not impose unnecessary runtime overhead.

This fits Vaelen's philosophy particularly well.

---

# 67. Imagick

Imagick is an important compatibility test because many WordPress applications depend on it.

Before selecting the PHP distribution strategy, Vaelen should explicitly test:

```text
Imagick installation
ImageMagick dependency ownership
Apple Silicon compatibility
PHP version compatibility
update behavior
```

This is a distribution acceptance test, not something to postpone until users complain.

---

# 68. Database drivers

PHP v0.1 must support the client extensions needed to connect to common local databases even before Vaelen manages those databases itself.

For example:

```text
pdo_mysql
mysqli
```

should work with an externally installed MySQL during early dogfooding.

The PHP module must not require the Vaelen MySQL module merely to include MySQL client support.

---

# 69. Redis extension vs Redis service

These are separate concepts.

```text
PHP Redis extension
```

is PHP runtime capability.

```text
Redis server
```

is a Vaelen service module.

The architecture must not confuse them.

A project may use:

```text
phpredis
```

to connect to an external Redis server.

---

# 70. PHP runtime dependency graph

Conceptually:

```text
Project
   │
   └── requires PHP 8.4
             │
             ▼
        PHP Instance
             │
             ├── package PHP 8.4.13
             ├── config
             ├── FPM process
             └── socket
                       │
                       ▼
                    Router
```

Optional extension dependencies may extend this graph later.

---

# 71. CLI dependency graph

Separately:

```text
Terminal
   │
   ▼
php shim
   │
   ├── current project?
   │       │
   │       └── resolve project PHP
   │
   └── otherwise
           │
           └── global PHP default
                    │
                    ▼
             actual PHP binary
```

No FPM process is required merely to execute PHP CLI.

---

# 72. CLI must work when Core is stopped

If the PHP package and shell resolution state are valid:

```bash
php -v
```

should ideally continue working even if `vaelend` temporarily crashes.

This improves resilience and avoids making PHP CLI unnecessarily dependent on daemon availability.

State changes still require Core.

---

# 73. Project commands

A future:

```bash
val run php artisan migrate
```

may explicitly execute inside Vaelen's resolved project environment.

However, normal:

```bash
php artisan migrate
```

should already work correctly through project-aware PHP resolution.

Vaelen should not force developers to prefix every PHP command with `val`.

---

# 74. Environment variables

PHP-FPM and project processes may require environment configuration.

The PHP module should not indiscriminately import the entire GUI or daemon environment.

Environment construction should be explicit and predictable.

Project-specific environment semantics belong primarily to ADR-0008.

---

# 75. PATH inside project processes

Processes launched by Vaelen should receive a PATH that resolves Vaelen-managed runtime tools consistently.

For a PHP 8.4 project:

```text
php
```

inside a Vaelen-launched queue worker should resolve to PHP 8.4.

This must not accidentally depend on whichever global PHP happens to be selected.

---

# 76. Absolute runtime execution

Internally, Core should prefer resolved executable paths.

Example:

```text
.../packages/php/8.4.13/bin/php
```

rather than:

```text
php
```

when starting managed processes.

This avoids PATH ambiguity.

---

# 77. Queue workers

Laravel queue workers are project processes, not PHP module processes.

Conceptually:

```text
PHP Module
    provides PHP 8.4

Project Process
    command:
        php artisan queue:work

Core resolves:
    php → project PHP 8.4
```

This distinction keeps the PHP module generic.

---

# 78. Scheduler

The same applies to:

```text
php artisan schedule:work
```

The PHP module provides runtime capability.

The project model owns the process declaration.

---

# 79. WordPress

WordPress support should not require a special WordPress PHP binary.

The WordPress driver provides:

```text
document root
front-controller behavior
project detection
possibly WP-CLI integration
```

while PHP remains ordinary PHP.

---

# 80. Laravel

Likewise, Laravel does not belong inside PHPModule.

LaravelDriver may determine:

```text
document root: public/
artisan availability
framework metadata
```

but PHP runtime architecture remains framework-neutral.

---

# 81. Generic PHP

A simple directory containing:

```text
index.php
```

should remain a valid Vaelen project without Laravel or WordPress.

Framework drivers enhance behavior.

They are not prerequisites.

---

# 82. PHP runtime UI

The GUI should be generated from Core/module state rather than hard-coded assumptions.

Conceptually:

```text
PHP

Installed versions

8.4.13    ● Running
Used by 3 projects

8.3.26    ○ Stopped
Used by 0 projects

[ Install Version ]
```

Selecting a version can expose:

```text
extensions
configuration
process
socket
logs
resource use
dependent projects
```

---

# 83. No PHP-specific GUI ownership of lifecycle

Clicking:

```text
Stop PHP 8.4
```

does not directly kill FPM from SwiftUI.

It sends the canonical Core operation.

The same operation is available through CLI.

---

# 84. `val php` convenience namespace

Although canonical Core operations remain generic, PHP deserves ergonomic CLI commands.

Examples:

```bash
val php versions
val php install 8.4
val php uninstall 8.3
val php use 8.4
val php info 8.4
```

These map to generic module/package/runtime operations.

---

# 85. Generic equivalents

Internally:

```text
val php install 8.4
```

maps conceptually to:

```text
module package install
    module: php
    version: 8.4
```

The convenience CLI does not justify PHP-specific Core architecture.

---

# 86. Diagnostics

`val doctor` should inspect PHP independently.

Example:

```text
PHP 8.4

✓ package installed
✓ arm64 binary
✓ CLI executable
✓ required extensions
✓ configuration valid
✓ FPM running
✓ socket available
✓ FastCGI health
✓ used by project.test
```

Failures should identify the layer.

---

# 87. External PHP detection

Diagnostics may report:

```text
External PHP detected

/opt/homebrew/bin/php
Version 8.3.19

Vaelen PHP:
8.4.13

Shell currently resolves:
Vaelen PHP 8.4.13
```

This helps diagnose PATH conflicts.

---

# 88. Vaelen does not uninstall external PHP

Even if Homebrew PHP conflicts with shell resolution, Vaelen may:

* explain the conflict;
* provide PATH guidance;
* offer explicit safe integration.

It must not silently run:

```text
brew uninstall php
```

---

# 89. Dogfooding requirement

PHP v0.1 is not complete because:

```text
php -v
```

works.

It must be tested against real projects.

At minimum:

```text
Laravel application
WordPress/WooCommerce application
generic PHP application
```

should be served through Vaelen.

---

# 90. Real compatibility tests

Dogfooding should include operations such as:

```text
Composer install/update

Laravel:
artisan commands
database connection
queues
scheduler
file uploads
image handling

WordPress:
admin
plugin installation
WooCommerce
REST API
uploads
permalinks
WP-CLI
```

This validates the runtime distribution far better than synthetic checks alone.

---

# 91. Herd replacement test

For the user who currently relies on Herd Free, a key milestone is:

```text
Herd disabled
      │
      ▼
Vaelen owns:
.test
HTTPS
routing
PHP
      │
      ▼
real Laravel and WordPress work continues normally
```

This is the practical proof that v0.1 works.

---

# 92. Failure principle

If Vaelen cannot provide a reliable PHP runtime distribution with the extensions required by normal Laravel and WordPress work, the correct response is not to hide the limitation behind architecture.

The distribution strategy must change.

The abstraction exists to make that possible.

---

# 93. Consequences

## Positive

### Multiple PHP versions

Projects can run different PHP versions simultaneously.

### Low idle overhead

Only required FPM versions need to run.

### Native execution

No containers or VM are involved.

### Predictable ownership

Vaelen knows exactly which PHP binaries and processes it manages.

### Project-aware CLI

Browser and terminal environments can agree on PHP version.

### Framework independence

Laravel and WordPress remain project-driver concerns.

### Replaceable distribution

PHP binary sourcing can evolve independently from Core.

---

# 94. Costs

PHP distribution is non-trivial.

Vaelen must solve:

* binary sourcing;
* extension compatibility;
* Apple Silicon;
* FPM;
* configuration;
* CLI resolution;
* shell integration;
* updates;
* health checks.

The runtime layer is likely more technically demanding than the initial SwiftUI application.

That complexity is accepted because PHP is core to Vaelen's first real use case.

---

# 95. Alternatives Considered

## Homebrew-managed PHP

Rejected as Vaelen's primary runtime.

Useful externally, but Vaelen would not fully own lifecycle/version behavior.

---

## One global PHP version

Rejected.

Does not support realistic multi-project development.

---

## One global FPM process

Rejected.

Cannot serve simultaneous PHP versions.

---

## One FPM pool per project from day one

Deferred.

Provides isolation but adds unnecessary initial resource/lifecycle complexity.

---

## TCP ports for each FPM version

Not preferred.

UNIX sockets are simpler and avoid port allocation.

---

## Require `val php ...` for every PHP invocation

Rejected.

Normal development commands should remain natural.

---

## Shell aliases for PHP switching

Rejected as the primary mechanism.

Not reliable enough across tools and subprocesses.

---

## Compile PHP locally on every installation

Rejected as the normal user experience.

Too slow and too dependent on local build environments.

---

# 96. Open Implementation Questions

1. Exact PHP binary distribution source.
2. Whether Vaelen maintains its own build pipeline using static-php-cli.
3. Exact default extension matrix.
4. Imagick packaging.
5. Xdebug packaging.
6. PECL/optional extension lifecycle.
7. Exact PHP configuration defaults.
8. Exact FPM process-manager settings.
9. Exact socket path.
10. Exact project-aware PHP shim implementation.
11. Shell PATH installation mechanism.
12. Composer lifecycle.
13. Patch-version resolution rules.
14. Exact PHP package metadata format.
15. Exact FastCGI health-check implementation.
16. Whether project-specific FPM pools become necessary sooner than expected.
17. How PHP extension dependencies such as ImageMagick libraries are packaged.
18. Exact minimum PHP versions supported by Vaelen v0.1.

These are implementation questions to prototype rather than reasons to add more Core abstractions.

---

# 97. Invariants Established by This ADR

1. PHP is an official module, not special Core logic.
2. Vaelen owns PHP versions installed through Vaelen.
3. Managed PHP does not depend on Homebrew lifecycle.
4. Multiple PHP versions may coexist.
5. Each active PHP version has an independent FPM runtime.
6. PHP-FPM runs as the logged-in user.
7. FPM uses UNIX sockets where practical.
8. Router configuration uses the project's resolved PHP endpoint.
9. Projects may use different PHP versions simultaneously.
10. Installed PHP does not imply running PHP-FPM.
11. FPM should run only when demanded or explicitly requested.
12. PHP CLI and PHP-FPM selection are separate concerns.
13. Projects determine their web PHP runtime.
14. Shell PHP resolution should become project-aware.
15. Normal PHP CLI usage should not require prefixing commands with `val`.
16. Shell resolution should remain fast.
17. PHP CLI should ideally remain usable during temporary Core unavailability.
18. Core internally uses resolved executable paths rather than ambiguous PATH lookup.
19. Base PHP packages remain immutable where practical.
20. Mutable configuration lives outside package directories.
21. PHP distributions are validated after installation.
22. Extension compatibility is part of runtime compatibility.
23. Laravel and WordPress behavior belongs to project drivers.
24. Queue workers and schedulers are project processes, not PHP module processes.
25. Package updates install and validate before switching.
26. Failed PHP updates preserve the existing working runtime.
27. PHP versions required by active projects are protected from ordinary uninstall.
28. External PHP installations remain externally owned.
29. PHP runtime resource use is observable.
30. The distribution implementation remains replaceable.

---

# Summary

Vaelen treats PHP as a native, versioned runtime capability:

```text
                     PHP Module
                         │
              ┌──────────┴──────────┐
              │                     │
         PHP 8.3 package       PHP 8.4 package
              │                     │
         FPM 8.3                FPM 8.4
              │                     │
        8.3.sock                8.4.sock
              │                     │
              └──────────┬──────────┘
                         │
                       Router
                    ┌────┴────┐
                    │         │
              project A   project B
                PHP 8.3     PHP 8.4
```

The terminal resolves PHP separately:

```text
                    php command
                         │
                         ▼
                    Vaelen shim
                         │
                current project?
                    ┌────┴────┐
                   yes        no
                    │          │
              project PHP   default PHP
                    │          │
                    └────┬─────┘
                         ▼
                  actual binary
```

The important distinction is:

> **PHP packages provide runtime capability. Projects decide which capability they require. Core reconciles and supervises the resulting processes.**

PHP is the first serious test of Vaelen's module architecture.

If this can be implemented without PHP-specific behavior leaking into Core, the architecture is ready for MySQL, Redis, Mailpit, and the wider module system.
