# ADR-0003: Package and Module System

* **Status:** Proposed
* **Date:** 2026-09-17
* **Decision owners:** Vaelen maintainers

## Context

Vaelen is intended to become a modular macOS developer control center.

The module system is therefore not merely an implementation detail. It is one of the defining architectural foundations of the project.

Vaelen must be capable of managing software such as:

```text id="i89qcd"
PHP
MySQL
PostgreSQL
Redis
Mailpit
Meilisearch
Typesense
MinIO
cloudflared
```

without embedding those projects into Vaelen itself or requiring globally installed package managers such as Homebrew.

The system must support:

* independent module installation;
* multiple software versions;
* Apple Silicon binaries;
* future architecture variants if required;
* secure artifact downloads;
* checksum/signature verification;
* atomic installation;
* safe upgrades;
* rollback;
* clean uninstallation;
* independent user data;
* service instances;
* dependencies;
* health checks;
* resource observability;
* eventual community modules.

At the same time, Vaelen must avoid prematurely creating an unrestricted native plugin system that would introduce significant security, compatibility, and maintenance complexity.

This ADR defines the relationship between modules, packages, instances, manifests, and Vaelen Core.

---

# Decision

Vaelen will use a **manifest-driven module system with optional native implementations**.

A module consists conceptually of:

```text id="zgsgbi"
Module
  │
  ├── Manifest
  │     metadata
  │     versions
  │     artifacts
  │     configuration
  │     lifecycle description
  │     health description
  │     dependencies
  │
  └── Optional Native Adapter
        only when declarative behavior
        is insufficient
```

Vaelen Core provides generic mechanisms.

Modules provide tool-specific knowledge.

Official modules initially ship with Vaelen and are trusted as part of the Vaelen release.

The architecture should allow a future external declarative module format without requiring arbitrary third-party Swift code execution.

---

# 1. Fundamental model

The following distinction is mandatory:

```text id="o6g8fn"
Module
   ↓
Package
   ↓
Instance
   ↓
Process
```

These concepts must never collapse into one object.

---

# 2. Module

A **Module** describes a capability Vaelen knows how to manage.

Examples:

```text id="fwxfmi"
php
mysql
redis
mailpit
meilisearch
```

A module may exist without being installed.

For example:

```text id="wx6ue8"
PHP       installed
MySQL     installed
Redis     available
Mailpit   available
```

The presence of Redis in Vaelen's module registry must not imply:

* Redis is downloaded;
* Redis is installed;
* Redis is running;
* Redis is consuming resources.

---

# 3. Package

A **Package** represents one installed version of software belonging to a module.

Example:

```text id="82o8cu"
Module:
    php

Packages:
    php@8.3.26
    php@8.4.13
    php@8.5.0
```

A package contains executable software.

It does not contain user service data.

---

# 4. Instance

An **Instance** represents configured use of a package.

Example:

```text id="skkex8"
Module
    mysql

Packages
    mysql@8.0.43
    mysql@8.4.6

Instances
    mysql/default
        package → 8.4.6
        port → 3306

    mysql/legacy
        package → 8.0.43
        port → 3307
```

Instances own configuration and runtime data appropriate to that service.

---

# 5. Process

A **Process** is a running operating-system process associated with an instance.

For example:

```text id="g8o2xy"
mysql/default
       │
       ▼
mysqld
PID 4281
```

Process lifecycle belongs to the Core supervisor established in ADR-0001.

The module describes how its software should be launched.

Core performs and supervises the launch.

---

# 6. Manifest-driven modules

Where practical, module behavior should be described declaratively.

Conceptually:

```yaml id="ojzxjw"
id: mailpit
name: Mailpit
type: service

versions:
  source: github-releases

artifacts:
  darwin-arm64:
    archive: mailpit-darwin-arm64.tar.gz

executable:
  path: mailpit

instance:
  defaults:
    smtp_port: 1025
    http_port: 8025

process:
  command:
    - "{package}/mailpit"
    - "--smtp"
    - "127.0.0.1:{config.smtp_port}"
    - "--listen"
    - "127.0.0.1:{config.http_port}"

health:
  type: http
  url: "http://127.0.0.1:{config.http_port}/"

ports:
  - name: smtp
    value: "{config.smtp_port}"

  - name: http
    value: "{config.http_port}"
```

This example is illustrative rather than the final manifest syntax.

The principle is:

> A simple service should not require custom Swift code merely to tell Vaelen where its binary is and how to run it.

---

# 7. Why manifests

Declarative manifests provide several advantages.

They are:

* inspectable;
* testable;
* versionable;
* comparatively safe;
* easier to review;
* easier to contribute;
* independent of Swift ABI;
* potentially usable by future community modules.

They also prevent Core from becoming:

```text id="tcfsyk"
MySQLManager.swift
RedisManager.swift
MailpitManager.swift
MeilisearchManager.swift
...
```

with duplicated infrastructure logic.

---

# 8. Native adapters

Not every module will fit a declarative manifest.

PHP is an obvious example.

Managing PHP may require knowledge of:

* PHP-FPM;
* extensions;
* `php.ini`;
* FPM pools;
* sockets;
* version switching;
* extension compatibility;
* configuration discovery.

Such modules may provide a native adapter conforming to Vaelen's internal module protocol.

Conceptually:

```text id="p1a9zo"
PHP Manifest
     +
PHPModuleAdapter.swift
```

The manifest still describes metadata and packages where possible.

The adapter provides behavior that cannot reasonably be expressed declaratively.

---

# 9. Native adapters are exceptional

The existence of native adapters must not become an excuse to implement every module in Swift.

Before adding native behavior, ask:

> Can this behavior be represented safely using existing Core primitives?

If yes, use the manifest.

Core primitives should become richer when multiple modules demonstrate the same legitimate requirement.

Example:

If MySQL, PostgreSQL, and Redis all need:

```text id="j1wqmg"
wait for TCP port
```

Core should provide a generic TCP health check.

Three custom Swift implementations are not justified.

---

# 10. Core mechanisms

Vaelen Core provides reusable package/module infrastructure.

Examples include:

```text id="q0b9db"
ArtifactDownloader
ChecksumVerifier
SignatureVerifier
ArchiveExtractor
AtomicInstaller
VersionResolver
ArchitectureResolver
ProcessRunner
ProcessSupervisor
PortAllocator
SocketManager
HealthChecker
ConfigRenderer
SecretStore
FilesystemManager
DependencyResolver
```

Modules use these capabilities.

They must not reimplement them independently without a strong reason.

---

# 11. Module registry

Core maintains a registry of known modules.

Conceptually:

```text id="rdwv1m"
ModuleRegistry
│
├── php
├── mysql
├── postgresql
├── redis
└── mailpit
```

The registry can answer:

```text id="33q1ql"
What modules are available?

Which are installed?

Which versions are installed?

Which versions are available?

Which instances exist?

Which modules have updates?

What dependencies exist?
```

The registry represents capability metadata.

It must not cause every registered module to perform background work.

---

# 12. Module states

A module may have states such as:

```text id="yk5p57"
AVAILABLE
PARTIALLY_INSTALLED
INSTALLED
UPDATE_AVAILABLE
BROKEN
```

Runtime state belongs primarily to instances.

For example:

```text id="q8ofsi"
Module:
    mysql → INSTALLED

Instance:
    mysql/default → RUNNING

Instance:
    mysql/legacy → STOPPED
```

This prevents confusing software installation with service lifecycle.

---

# 13. Module types

Modules may declare broad capability types.

Initial categories may include:

```text id="3n17yb"
runtime
service
tool
integration
```

Examples:

```text id="wx6txb"
php         runtime
mysql       service
redis       service
mailpit     service
cloudflared tool/integration
```

These categories exist primarily for behavior and presentation.

They should not create unnecessary rigid inheritance hierarchies.

---

# 14. Package sources

A module defines where its software comes from.

Potential source types include:

```text id="1ajl0v"
GitHub Releases
direct HTTPS artifacts
Vaelen-maintained release metadata
Vaelen-maintained binary builds
```

Core owns the download implementation.

The module supplies the source metadata.

---

# 15. Vaelen must not blindly scrape release pages

Package discovery should use stable machine-readable sources wherever possible.

Preferred:

```text id="b4r1nq"
release API
signed metadata
version manifest
known artifact URL pattern
```

Avoid brittle HTML scraping.

If upstream distribution is unsuitable for reliable automated installation, Vaelen may maintain its own package metadata or build pipeline.

---

# 16. Architecture resolution

Packages may differ by CPU architecture.

A module must be able to describe supported artifacts.

Example:

```text id="jsmzrl"
darwin-arm64
darwin-x86_64
```

Vaelen resolves the current platform before downloading.

Initial development may prioritize:

```text id="pv51yw"
darwin-arm64
```

because modern macOS development is primarily Apple Silicon.

However, architecture must remain explicit rather than hard-coded throughout package management.

---

# 17. Artifact verification

Vaelen must not install an artifact merely because it successfully downloaded.

Where upstream provides cryptographic checksums or signatures, Vaelen should verify them.

Minimum conceptual lifecycle:

```text id="jxyh17"
resolve artifact
      ↓
download
      ↓
verify transport
      ↓
verify checksum/signature
      ↓
extract
      ↓
validate expected files
      ↓
install
```

Failure at any verification stage aborts installation.

---

# 18. Vaelen package metadata

Each installed package should have Vaelen-owned metadata.

Conceptually:

```text id="5g3qer"
packages/php/8.4.13/
├── package/
└── .vaelen-package.json
```

Metadata may contain:

```text id="91oucv"
module
version
architecture
source
artifact checksum
installed timestamp
Vaelen version
package format version
```

This allows Core to inspect installations without guessing.

---

# 19. Immutable package installations

Installed package directories should be treated as immutable wherever practical.

Bad:

```text id="40qdg1"
packages/php/8.4/
    continuously mutated
```

Preferred:

```text id="wq0d9p"
packages/php/
├── 8.4.12/
└── 8.4.13/
```

Updates create new package versions.

This improves:

* rollback;
* debugging;
* atomicity;
* reproducibility;
* integrity checking.

---

# 20. Atomic installation

Package installation must not expose partially installed software as usable.

Conceptually:

```text id="oy0f23"
download
    ↓
temporary staging directory
    ↓
verify
    ↓
extract
    ↓
validate
    ↓
atomic move
    ↓
installed
```

For example:

```text id="cn7xcr"
cache/downloads/...
staging/php-8.4.13-<uuid>/
```

becomes:

```text id="f1z8w5"
packages/php/8.4.13/
```

only after successful validation.

---

# 21. Failed installation

If installation fails:

* no package is marked installed;
* temporary files are cleaned where safe;
* previous versions remain untouched;
* structured failure information is preserved;
* user data remains untouched.

Running:

```bash id="jyp1xb"
val module install php@8.4
```

must never break an already functioning PHP 8.3 installation merely because the 8.4 installation failed.

---

# 22. Package activation

Installation and activation are separate concepts.

Example:

```text id="ss9s0b"
PHP 8.3 installed
PHP 8.4 installed
PHP 8.5 installed

default runtime → PHP 8.4
```

Installing PHP 8.5 does not necessarily change the default runtime.

This avoids surprising environment changes after updates.

---

# 23. Version selection

Version requirements may use semantic constraints where appropriate.

Examples:

```text id="1vl6i6"
8.4
8.4.13
^8.4
latest
```

The exact supported syntax will be defined separately.

Resolution must be deterministic.

For project declarations, Vaelen should be capable of reporting:

```text id="6cdtck"
Requested:
    PHP 8.4

Resolved:
    PHP 8.4.13
```

---

# 24. Reproducibility and floating versions

Human-friendly version declarations such as:

```yaml id="x9qq59"
php: "8.4"
```

are convenient but not perfectly reproducible over time.

Vaelen should distinguish:

```text id="jpfpbe"
constraint
```

from:

```text id="u6vpzw"
resolved version
```

Future project state or lock metadata may record resolved versions.

For example:

```text id="m7d5sr"
vaelen.yml
    desired constraints

vaelen.lock
    exact resolved packages
```

A lock file is not required for the first implementation, but the architecture should permit it.

---

# 25. Dependencies

Modules may declare dependencies.

Example:

```text id="f3m7sn"
hypothetical module A
    ↓
requires module B >= 2
```

Dependencies are resolved by Core.

Modules must not independently install other modules behind Core's back.

Dependency resolution should produce an explicit plan.

Example:

```text id="m3q5hw"
Install Meilisearch integration

Requires:
✓ PHP already installed
↓ Meilisearch 1.x needs installation
```

---

# 26. Dependency types

The architecture should distinguish between different relationships.

Potential examples:

```text id="pbce6f"
package dependency
runtime dependency
optional integration
project dependency
```

Not every relationship should force installation.

For example, Mailpit may integrate with PHP/Laravel but should not require PHP merely to exist as a standalone SMTP testing service.

---

# 27. Dependency cycles

Module dependencies must form a valid dependency graph.

Cycles such as:

```text id="x3ghm6"
A → B → C → A
```

must be rejected.

Core owns cycle detection.

---

# 28. Installation plans

Before performing multi-step module operations, Core should build an installation plan.

Example:

```text id="ihh3qc"
Install PHP 8.4

Plan:

1. Download PHP 8.4.13
2. Verify SHA-256
3. Extract package
4. Validate PHP binary
5. Install package
6. Create default configuration
7. Register package

Estimated download:
74 MB
```

Interactive clients may display this.

Automation may execute it directly according to policy.

---

# 29. Package removal

A package may be removed only when doing so will not silently break active instances.

Example:

```text id="nsue49"
php@8.4.13

Used by:
- PHP default runtime
- project-a.test
- project-b.test
```

Attempting removal should report those dependencies.

The user may first migrate those consumers to another version.

---

# 30. Module uninstall

Uninstalling a module means removing its Vaelen-managed executable capability.

It does not automatically mean destroying service data.

Conceptually:

```text id="10a7l6"
val module uninstall mysql
```

may remove:

```text id="j4rlrc"
packages/mysql/*
```

but preserve:

```text id="n7ekqn"
instances/mysql/default/data/
```

unless the user explicitly requests destructive removal.

---

# 31. Purge

A separate destructive concept should exist.

Conceptually:

```bash id="we5m3s"
val module purge mysql
```

could remove:

```text id="ojfsbv"
packages
instances
configuration
data
logs
```

This operation requires explicit confirmation.

For automation, destructive intent must be expressed explicitly.

The exact CLI syntax may change.

The architectural distinction must not.

---

# 32. Orphaned data

If a module is uninstalled while instance data is preserved, Vaelen must continue to know that data exists.

Example:

```text id="n5axqn"
MySQL
Status: Not installed

Preserved data:
mysql/default
2.4 GB

[ Reinstall ]
[ Delete Data ]
```

This is preferable to leaving unexplained directories on disk.

---

# 33. Reinstallation

If compatible preserved instance data exists, reinstalling a module should allow that instance to be restored.

However, Vaelen must verify version/data compatibility.

It must not blindly start an incompatible database version against old data.

Modules may provide migration/compatibility knowledge where required.

---

# 34. Updates

Updates follow:

```text id="lnry3n"
discover
   ↓
download new package
   ↓
verify
   ↓
install alongside old package
   ↓
validate
   ↓
switch selected instances
   ↓
verify health
   ↓
retain old version temporarily
```

The old package should not disappear before the replacement has proven usable.

---

# 35. Update rollback

Where technically possible, failed updates should revert to the previously selected package.

Example:

```text id="exfwnu"
mysql/default
    │
8.4.6
    │
upgrade
    ▼
8.4.7
    │
health fails
    ▼
rollback selection
    │
    ▼
8.4.6
```

However, data-format migrations may make automatic rollback unsafe.

Modules must be able to declare that an update requires special migration semantics.

Core must never assume binary rollback implies data rollback.

---

# 36. Update channels

The architecture may eventually support channels such as:

```text id="6x9by4"
stable
beta
nightly
```

Stable must be the default.

Modules may support only stable releases.

This feature is not required initially.

---

# 37. Configuration templates

Modules may provide configuration templates.

Example:

```text id="uex78g"
mysql.cnf.template
php.ini.template
redis.conf.template
```

Core provides rendering.

Modules provide template knowledge.

Generated configuration belongs to instances, not packages.

Therefore:

```text id="zd9e77"
packages/mysql/8.4.6/
    immutable software

instances/mysql/default/config/
    mutable instance configuration
```

---

# 38. Configuration schema

Modules should describe configurable values in structured form where practical.

Conceptually:

```yaml id="3bj2rn"
configuration:
  port:
    type: port
    default: 3306

  bind:
    type: string
    default: 127.0.0.1
```

This allows the same configuration model to power:

* CLI;
* GUI;
* validation;
* project configuration;
* future automation.

---

# 39. Secrets

Sensitive configuration must be explicitly identified.

Example:

```yaml id="ptj0xj"
password:
  type: secret
```

Core determines appropriate secure storage.

A module should not invent its own plaintext secret-storage mechanism without necessity.

---

# 40. Ports

Modules declare required ports symbolically.

Example:

```text id="y4o9te"
mysql/default

ports:
    mysql → 3306
```

Core checks availability before process launch.

Where appropriate, modules may permit automatic alternative allocation.

Example:

```text id="l2kijm"
3306 occupied

Suggested:
3307
```

The module declares whether alternate ports are valid.

---

# 41. Sockets

Modules may declare UNIX socket endpoints.

Example:

```text id="t19nbn"
php/8.4
    ↓
run/php/8.4.sock
```

Core manages runtime paths and stale socket cleanup.

Modules should not hard-code user-specific filesystem paths.

---

# 42. Health checks

Manifests may declare health checks using Core primitives.

Potential primitives:

```text id="15ihhc"
process
tcp
http
unix-socket
command
```

Examples:

```yaml id="c6zvp8"
health:
  type: tcp
  port: "{config.port}"
```

or:

```yaml id="2wfxm2"
health:
  type: http
  url: "http://127.0.0.1:{config.http_port}/health"
```

Custom native health logic should only be required when generic checks are insufficient.

---

# 43. Lifecycle hooks

Modules may require lifecycle operations beyond simply launching an executable.

Examples:

```text id="0i34hp"
initialize database directory
generate configuration
perform safe migration
validate package
```

The initial module system may support a constrained set of lifecycle actions.

Potential conceptual phases:

```text id="k9zkug"
preInstall
install
postInstall

preConfigure
configure
postConfigure

preStart
start
postStart

preStop
stop
postStop

preUninstall
uninstall
postUninstall
```

These must not become arbitrary root shell hooks.

---

# 44. Declarative actions

Where lifecycle hooks are necessary, prefer structured Core actions.

For example:

```yaml id="zvng1u"
postInstall:
  - createDirectory:
      path: "{instance.data}"

  - execute:
      executable: "{package}/bin/mysqld"
      arguments:
        - "--initialize-insecure"
        - "--datadir={instance.data}"
```

rather than:

```yaml id="if67fx"
postInstall:
  shell: |
    mkdir -p ...
    mysqld --initialize...
```

Structured execution improves:

* validation;
* security;
* logging;
* portability across shells;
* diagnostics.

---

# 45. Shell hooks

Arbitrary shell hooks should not be part of the trusted declarative module format unless a future design explicitly introduces them.

This is particularly important for eventual community modules.

A manifest that can execute:

```text id="g8v1jm"
curl ... | sudo sh
```

is effectively arbitrary native code execution regardless of whether the file itself is YAML.

Declarative does not automatically mean safe.

---

# 46. Module permissions

Modules should declare capabilities they require.

Examples:

```text id="e5y6fk"
network.download
process.execute
filesystem.instance
filesystem.project.read
port.bind
keychain
```

Future community modules may be restricted according to these capabilities.

Official built-in modules remain trusted initially, but designing capability declarations early improves transparency.

---

# 47. Privileged capabilities

Modules cannot directly declare arbitrary root access.

A module requiring privileged functionality must use an existing Core `SystemCapability`.

Example:

```text id="cd4rza"
requires:
    systemCapability: trusted-local-ca
```

If no such capability exists, adding one requires deliberate Core architectural review.

---

# 48. Module resource declaration

Modules should expose enough metadata for Vaelen to explain their runtime footprint.

Example:

```text id="sug6j5"
Mailpit

Processes:
1

Ports:
1025 SMTP
8025 HTTP

Persistent data:
optional

Runs when stopped:
nothing
```

This aligns with Vaelen's resource-honesty philosophy.

---

# 49. Module uninstallability test

Every optional module must answer:

> What exactly remains if I uninstall this module?

Valid remaining artifacts may include explicitly preserved user data.

Unexpected executables, LaunchAgents, sockets, background processes, or system modifications are architectural failures.

---

# 50. Module independence

Installing:

```text id="5ynxtm"
Redis
```

must not implicitly install unrelated capabilities such as:

```text id="rfynfr"
MySQL
Mailpit
Meilisearch
```

unless a genuine dependency exists.

The module graph should reflect technical necessity, not product bundling.

---

# 51. Modules do not poll when absent

An available-but-uninstalled module should be metadata.

It should not instantiate a runtime service merely to remain visible.

For example:

```text id="y3fl9d"
Redis available
```

must not imply:

```text id="oizbvb"
RedisModule background timer
Redis health polling
Redis process watcher
```

There is nothing to monitor because Redis is not installed/running.

---

# 52. Module discovery and updates

The first Vaelen releases may ship module metadata directly with the application.

Conceptually:

```text id="u8d3yf"
Vaelen.app
└── Modules/
    ├── php/
    ├── mysql/
    ├── redis/
    └── mailpit/
```

This provides deterministic trusted modules.

Later, module metadata may be independently updated through a signed registry.

That evolution must not require changing the fundamental Module → Package → Instance model.

---

# 53. Official module registry

A future official registry could conceptually provide:

```text id="6jd73v"
registry.vaelen.dev
```

or a signed repository containing:

```text id="r2a2i1"
module metadata
versions
artifact metadata
checksums
compatibility
```

The exact distribution mechanism is intentionally deferred.

Vaelen must not require an account merely to access public module metadata.

---

# 54. Community modules

Community modules are a long-term architectural goal.

They are not required for v1.

The preferred future model is:

```text id="wzlm3h"
Community Module
       │
       ▼
Signed/inspectable manifest
       │
       ▼
Allowed Core primitives
       │
       ▼
Upstream software
```

rather than:

```text id="u01rhz"
Download arbitrary .dylib
       │
       ▼
Load into vaelend
       │
       ▼
hope for the best
```

---

# 55. Community code isolation

If future modules genuinely require executable custom logic, that logic should not automatically execute inside `vaelend`.

Potential future designs may use:

```text id="5sz4rx"
separate helper process
sandbox
XPC boundary
capability restrictions
signature verification
```

This requires a dedicated future ADR.

Core stability must not depend on arbitrary community code.

---

# 56. Module compatibility

Modules should declare compatibility with relevant Vaelen module API versions.

Conceptually:

```yaml id="6kafrb"
vaelen:
  module_api: 1
```

Core can then reject incompatible modules cleanly.

This is preferable to allowing subtle runtime failure.

---

# 57. Manifest schema version

Module manifests themselves must be versioned.

Example:

```yaml id="gyyrjq"
schema: 1
```

Schema evolution should be deliberate.

Old manifests may be migrated or rejected with a useful explanation.

---

# 58. Module identifiers

Module identifiers must be stable and machine-friendly.

Examples:

```text id="7s4k50"
php
mysql
postgresql
redis
mailpit
meilisearch
```

Display names may change.

Identifiers should not.

For future third-party modules, namespacing may become necessary.

Example:

```text id="8p4f8c"
community.vendor.module
```

The exact naming convention is deferred.

---

# 59. Module CLI

The generic module interface should enable commands such as:

```bash id="wzt0cf"
val module list
val module info mailpit

val module install mailpit
val module uninstall mailpit

val module update mailpit
```

Version-specific operations may include:

```bash id="tvebm4"
val module install php@8.4
val module install php@8.5
```

The CLI must not require a dedicated command implementation for every simple module.

---

# 60. Specialized CLI commands

Important runtimes may expose convenience commands.

For example:

```bash id="f97aqp"
val php versions
val php install 8.4
val php use 8.4
```

These are convenience interfaces over the same underlying module/package operations.

They must not bypass Core.

---

# 61. Module inspection

Users should be able to understand what a module represents before installing it.

Conceptually:

```text id="s6aqlz"
$ val module info mailpit

Mailpit
Local email testing service

Status:
Not installed

Latest:
1.x

Source:
Mailpit upstream releases

Architecture:
Apple Silicon

Processes when running:
1

Ports:
1025 SMTP
8025 Web UI

Persistent data:
None by default

Permissions:
Local network
Filesystem: Vaelen instance directory
```

This makes module behavior explicit rather than magical.

---

# 62. Installation transparency

Before installation, Vaelen should be able to answer:

```text id="esay70"
What will be downloaded?

From where?

How large is it?

How will it be verified?

Where will it be installed?

What processes can it run?

What ports will it use?

What persistent data will it create?
```

This is the module equivalent of Vorssaint-style permission/resource honesty.

---

# 63. Module diagnostics

Modules contribute diagnostic definitions to `val doctor`.

Example:

```text id="82svzv"
MySQL

✓ package 8.4.6 valid
✓ data directory writable
✓ configuration valid
✓ port 3306 available
✓ process running
✓ TCP health check successful
```

Core provides the diagnostic framework.

Modules provide relevant domain knowledge.

---

# 64. Binary provenance

Vaelen should preserve provenance information for every managed package.

A user or diagnostic tool should eventually be able to determine:

```text id="6b1w86"
Module:
Mailpit

Version:
1.x

Source:
upstream GitHub release

Artifact:
...

SHA-256:
...

Installed:
...

Architecture:
arm64
```

This improves both security and debugging.

---

# 65. No Homebrew ownership

Vaelen does not use Homebrew as the authoritative package store for Vaelen-managed modules.

This avoids external mutations such as:

```bash id="0wh6fo"
brew upgrade
brew unlink
brew uninstall
```

silently changing Vaelen's environment.

Homebrew may be detected for conflict diagnostics or interoperability.

It is not the package manager beneath Vaelen.

---

# 66. Upstream licensing

Each module must record upstream licensing information where appropriate.

Vaelen must respect:

* redistribution terms;
* attribution requirements;
* binary redistribution restrictions;
* trademark requirements.

A technically integrable tool is not automatically legally redistributable.

Where redistribution is inappropriate, Vaelen may download directly from the upstream source rather than bundle the binary.

---

# 67. Package cache

Downloaded artifacts may be cached separately from installed packages.

Conceptually:

```text id="u98k6x"
~/Library/Caches/Vaelen/
└── downloads/
```

Cache data is disposable.

Deleting the cache must not break installed packages.

---

# 68. Garbage collection

Vaelen may eventually provide:

```bash id="b4ifgk"
val clean
```

to identify removable artifacts such as:

```text id="xsdik1"
old downloads
staging directories
unused package versions
old logs
```

Garbage collection must never silently remove:

* active packages;
* required rollback versions;
* user databases;
* project files.

---

# 69. Package integrity checks

`val doctor` or another maintenance operation may verify installed package integrity.

For immutable package files, Vaelen can compare expected metadata or checksums where practical.

Unexpected modification should be reported rather than silently overwritten.

---

# 70. Manual modification

Advanced users may manually modify Vaelen-managed files.

Vaelen should not attempt to make this impossible.

However, package directories are considered Vaelen-owned and immutable.

Manual modifications may be overwritten by package management operations.

Instance configuration is a different category and may eventually support explicit user overrides.

This distinction should be documented clearly.

---

# 71. User overrides

Generated module configuration should eventually support controlled overrides.

Conceptually:

```text id="r29vlr"
module defaults
      ↓
Vaelen defaults
      ↓
instance configuration
      ↓
user overrides
```

User overrides should not require modifying immutable package contents.

---

# 72. Initial official modules

The module architecture should first be proven using deliberately different modules.

Recommended progression:

```text id="9m9il8"
1. PHP
2. Mailpit
3. Redis
4. MySQL
```

These exercise increasingly difficult aspects of the architecture.

### PHP

Tests:

* multiple versions;
* native adapter;
* sockets;
* configuration;
* runtime selection.

### Mailpit

Tests:

* simple declarative service;
* artifact download;
* two ports;
* HTTP health;
* install/start/stop/uninstall.

### Redis

Tests:

* persistent service;
* configuration;
* TCP health;
* data directory.

### MySQL

Tests:

* complex initialization;
* persistent valuable data;
* version compatibility;
* upgrades;
* multiple instances.

If the same Core model handles all four cleanly, the module architecture is likely sound.

---

# 73. Module acceptance test

Before an official module is accepted, maintainers should answer:

### Purpose

Does this solve a real developer workflow problem?

### Upstream

Is the upstream software mature enough to depend upon?

### Distribution

Can Vaelen reliably obtain compatible macOS binaries?

### Verification

Can downloaded software be verified?

### Lifecycle

Can Vaelen start and stop it predictably?

### Isolation

Can it remain independent of unrelated modules?

### Uninstallation

Can it be completely removed?

### Data

Can software and user data be separated?

### Resources

Can Vaelen explain what it runs and consumes?

### Privilege

Can it run without root?

### Maintenance

Who owns compatibility when upstream changes?

### Core impact

Does supporting this module require contaminating Core with service-specific logic?

If the final answer is yes, the abstraction should be reconsidered.

---

# 74. The Vorssaint test

Every optional module should satisfy the spirit of:

> Install only what you use.

If installed but stopped:

> Off means off.

If uninstalled:

> The executable footprint disappears.

If running:

> Vaelen can explain its resource cost.

And before adding it:

> Does this capability actually belong inside a macOS developer control center?

---

# 75. Consequences

## Positive

### Modules remain independent

Adding a service does not require redesigning Core.

### Simple modules become inexpensive to implement

Many services can potentially be represented primarily by manifests.

### Future community modules remain possible

The architecture does not require Swift ABI plugins.

### Security is stronger

Declarative capabilities can eventually be constrained and audited.

### Package ownership is deterministic

Vaelen controls exactly which binaries it manages.

### Updates are safer

Immutable versioned packages allow validation and rollback.

### User data remains protected

Software lifecycle is distinct from data lifecycle.

### GUI and CLI become generic

Both can render module information from structured metadata.

---

# 76. Costs

The module system requires substantial foundational work:

* manifest schema;
* package manager;
* version resolver;
* artifact verification;
* configuration renderer;
* dependency graph;
* lifecycle action model;
* migration strategy;
* compatibility handling.

This is more work than writing custom shell scripts for each service.

That cost is accepted because modularity is a defining Vaelen requirement rather than an optional implementation convenience.

---

# 77. Alternatives Considered

## Hard-code every integration in Swift

Rejected.

This would work initially but gradually turn Core into a monolith.

---

## Homebrew as package backend

Rejected as the authoritative package system.

It would make Vaelen-managed state externally mutable and make installation/removal behavior dependent on another package manager.

---

## Arbitrary shell-script modules

Rejected as the primary module model.

They are easy to create but difficult to:

* secure;
* inspect;
* validate;
* reason about;
* expose consistently through GUI;
* restrict for community modules.

---

## Dynamic Swift plugins

Rejected for the initial architecture.

They introduce unnecessary:

* ABI complexity;
* crash risk;
* security concerns;
* signing requirements;
* compatibility problems.

---

## Containers as module packages

Rejected.

Vaelen's runtime philosophy is native macOS processes.

---

# 78. Open Implementation Questions

The following remain intentionally unresolved:

1. Final manifest format: YAML, JSON, or another representation.
2. Exact module schema.
3. Version constraint syntax.
4. Initial package metadata source.
5. Whether Vaelen builds/distributes PHP itself or consumes a trusted upstream build pipeline.
6. Signature/checksum policy when upstream does not provide cryptographic metadata.
7. Exact module capability/permission schema.
8. How lifecycle migrations are represented.
9. Exact update rollback policy for stateful services.
10. Whether `vaelen.lock` should exist and when it should be introduced.
11. How module registry metadata is signed and distributed in the future.
12. Whether x86_64 support is worth maintaining.
13. How community executable extensions could eventually be isolated.
14. Exact garbage-collection retention policy.

These should be resolved through implementation prototypes and focused ADRs.

---

# 79. Invariants Established by This ADR

1. Module, Package, Instance, and Process are separate concepts.
2. Modules provide tool-specific knowledge; Core provides generic mechanisms.
3. Simple modules should be declarative where practical.
4. Native module adapters are available when declarative behavior is insufficient.
5. Native adapters are exceptional rather than the default.
6. Vaelen owns the packages it manages.
7. Homebrew is not Vaelen's authoritative package backend.
8. Package versions may coexist.
9. Installed package directories are immutable where practical.
10. New versions are installed alongside old versions.
11. Installation must be atomic where practical.
12. Package installation and package activation are separate operations.
13. Software data and user service data are separate.
14. Module uninstall must not silently destroy user data.
15. Destructive purge requires explicit intent.
16. Modules cannot independently perform arbitrary privileged operations.
17. Modules cannot install dependencies behind Core's back.
18. Core owns dependency resolution.
19. Module artifacts must be verified where reliable verification metadata exists.
20. Package provenance must be retained.
21. Uninstalled modules must not consume runtime resources.
22. Stopped instances must not leave their service processes running.
23. Community modules are a future capability, not a v1 requirement.
24. Future community modules should favor declarative capabilities over arbitrary native code.
25. Arbitrary community code must not execute inside `vaelend` without a separate architectural decision.
26. Module manifests and module API contracts are versioned.
27. Module configuration must not require modifying immutable package contents.
28. Package cache is disposable and separate from installed software.
29. Vaelen must be able to explain what a module installs, runs, stores, and requires.
30. Supporting a new module should not require contaminating Core with module-specific branching.

---

# Summary

Vaelen's module architecture follows one central rule:

> **Core provides mechanisms. Modules provide knowledge.**

A module describes a developer capability.

A package is an installed version of its software.

An instance configures that software for use.

A process is the native macOS process Vaelen supervises.

Simple modules should primarily be data.

Complex modules may add trusted native behavior.

Software is installed atomically, versioned independently, observable while running, removable when unwanted, and separated from valuable user data.

The architecture intentionally begins with trusted official modules while preserving a path toward a future ecosystem of inspectable, declarative community modules.

The long-term goal is that adding:

```text id="8f7yuf"
Mailpit
Redis
MySQL
Meilisearch
Typesense
MinIO
```

does not make Vaelen Core progressively understand Mailpit, Redis, MySQL, Meilisearch, Typesense, or MinIO.

Core should continue understanding only:

```text id="7nj7gu"
packages
instances
processes
configuration
dependencies
health
resources
```

That is what allows Vaelen to become a Swiss army knife without becoming a monolith.
