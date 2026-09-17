# ADR-0008: Project Model and Desired-State Reconciliation

* **Status:** Proposed
* **Date:** 2026-09-17
* **Decision owners:** Vaelen maintainers

## Context

The previous ADRs define the infrastructure beneath Vaelen:

* Core owns runtime state and process supervision;
* routing is provided through a replaceable Router;
* modules provide capabilities;
* packages, instances, and processes have distinct lifecycles;
* filesystem ownership is explicit;
* GUI and CLI communicate with the same Core;
* privileged operations are narrow;
* PHP provides a versioned native runtime.

What remains is the object developers actually care about:

> The project.

A developer does not primarily think:

```text
Start PHP-FPM 8.4.
Create a FastCGI socket.
Configure a Caddy route.
Start MySQL.
Start Redis.
Create a certificate.
Start a queue worker.
```

They think:

```text
I want to work on this project.
```

Vaelen therefore needs a project model capable of translating project intent into infrastructure.

The desired experience is eventually:

```bash
git clone ...
cd project
val up
```

and then:

```text
https://project.test
```

works with the correct runtime and required services.

This ADR defines:

* project identity;
* `park`;
* `link`;
* drivers;
* project discovery;
* `vaelen.yml`;
* configuration precedence;
* desired state;
* reconciliation;
* shared services;
* project processes;
* `val up`;
* `val down`;
* failure semantics;
* reproducibility.

---

# Decision

Vaelen projects are **declarative desired-state objects**.

A project may describe its requirements in:

```text
vaelen.yml
```

Vaelen Core combines:

```text
explicit project configuration
        +
driver-discovered conventions
        +
Vaelen defaults
        +
current machine state
```

to construct a desired project state.

Core then computes:

```text
Desired State
     -
Actual State
     =
Reconciliation Plan
```

and safely executes that plan.

The central operation is:

```bash
val up
```

meaning:

> Make this project's Vaelen-managed environment match its declared and resolved requirements.

---

# 1. Project

A Project represents a developer-owned directory registered with Vaelen.

Conceptually:

```text
Project
├── identity
├── root path
├── domains
├── driver
├── runtime requirements
├── service requirements
├── routing requirements
├── project processes
└── desired state
```

A project is not:

* a copy of the source directory;
* a container;
* a VM;
* an FPM process;
* a Caddy configuration;
* a database instance.

It is the declaration that causes those capabilities to be composed.

---

# 2. Project ownership

Project source remains owned by the developer.

Example:

```text
~/Code/syncproof
```

Vaelen stores a reference to that directory.

It does not move it into:

```text
~/Library/Application Support/Vaelen/
```

Registering a project never transfers filesystem ownership to Vaelen.

This follows ADR-0004.

---

# 3. Stable project identity

A filesystem path alone should not necessarily become the permanent internal identity of a project.

Core assigns a stable project identifier.

Conceptually:

```text
id:
    01K...

path:
    /Users/bane/Code/syncproof

name:
    syncproof
```

The exact identifier format is an implementation decision.

---

# 4. Project name

By default, Vaelen derives a project name from the directory.

Example:

```text
~/Code/callthewaiter
        ↓
callthewaiter
```

which may produce:

```text
callthewaiter.test
```

Names may be overridden.

---

# 5. Project registration

Projects can enter Vaelen through two primary mechanisms:

```text
link
park
```

These intentionally preserve the successful Valet/Herd mental model.

---

# 6. `val link`

From a project directory:

```bash
cd ~/Code/syncproof
val link
```

registers that exact project.

Conceptually:

```text
Current directory
      ↓
canonicalize
      ↓
detect project
      ↓
assign/resolve identity
      ↓
register
      ↓
resolve default domain
      ↓
reconcile routing/runtime
```

---

# 7. Named links

Vaelen may support:

```bash
val link shop
```

to override the default local hostname.

Example:

```text
~/Code/woocommerce-client
        ↓
shop.test
```

The exact CLI syntax may be refined during implementation.

---

# 8. `val unlink`

Running:

```bash
val unlink
```

removes Vaelen registration for the project.

It may reconcile away:

* project routes;
* project-specific processes;
* project-specific generated state;
* runtime demand attributable only to that project.

It never deletes project source.

---

# 9. `val park`

Running:

```bash
cd ~/Code
val park
```

registers a directory as a project-discovery root.

Conceptually:

```text
~/Code/
├── project-a/
├── project-b/
└── project-c/
```

may become:

```text
project-a.test
project-b.test
project-c.test
```

according to Vaelen discovery rules.

---

# 10. Park is discovery, not eager infrastructure

Parking:

```text
~/Code
```

must not mean:

> Start every possible service for every directory under ~/Code.

Parking provides project discovery.

Infrastructure should remain demand-driven.

This preserves resource honesty.

---

# 11. Park depth

Initial park behavior should inspect immediate child directories only.

Example:

```text
~/Code/project
```

rather than recursively treating every nested package as a Vaelen project.

Recursive discovery introduces ambiguity and unnecessary filesystem work.

More advanced discovery may be introduced later if justified.

---

# 12. Explicit link wins

If a project is both discoverable through a parked directory and explicitly linked, explicit registration takes precedence for configurable properties such as:

```text
domain
driver override
project settings
```

There should still be one logical Project.

---

# 13. Project driver

A Driver understands project conventions.

Initial conceptual drivers include:

```text
LaravelDriver
WordPressDriver
SymfonyDriver
GenericPHPDriver
StaticDriver
```

Drivers do not install modules.

Drivers do not start processes directly.

Drivers interpret projects.

---

# 14. Driver responsibilities

A driver may determine or suggest:

```text
project type
document root
front controller behavior
framework metadata
useful default processes
configuration hints
runtime requirements discoverable from project files
```

For example:

```text
LaravelDriver
    document root → public/
```

while:

```text
GenericPHPDriver
    document root → project root
```

---

# 15. Driver boundaries

A Laravel driver may know about:

```text
artisan
composer.json
public/
bootstrap/
```

It must not know how to:

```text
download PHP
start PHP-FPM
configure Caddy
install MySQL
modify DNS
```

Those capabilities belong elsewhere.

---

# 16. Driver detection

Drivers may expose detection logic.

Conceptually:

```swift
protocol ProjectDriver {
    var identifier: DriverID { get }

    func detect(project: ProjectInspection) -> DetectionResult
    func inspect(project: ProjectInspection) async throws -> ProjectHints
}
```

The exact Swift interface is implementation-specific.

---

# 17. Driver confidence

Detection should support confidence or priority.

Example:

```text
LaravelDriver
    composer.json contains laravel/framework
    artisan exists
    public/index.php exists

confidence:
high
```

This is preferable to arbitrary first-match behavior.

---

# 18. Explicit driver override

A project may explicitly select a driver when automatic detection is wrong.

Conceptually:

```yaml
driver: laravel
```

Explicit configuration wins over automatic detection.

---

# 19. Generic fallback

Failure to detect a framework must not make Vaelen unusable.

A generic project driver should provide a fallback where technically possible.

Vaelen should support ordinary PHP projects without framework recognition.

---

# 20. `vaelen.yml`

The canonical project declaration is:

```text
vaelen.yml
```

located at the project root.

It represents project-owned desired environment configuration.

It may be committed to version control.

---

# 21. Minimal project declaration

A valid declaration should be capable of being extremely small.

Example:

```yaml
version: 1

php: "8.4"
```

Vaelen supplies reasonable defaults for everything else.

---

# 22. Richer declaration

Conceptually:

```yaml
version: 1

php: "8.4"

web:
  secure: true

services:
  mysql:
    version: "8.4"

  redis:
    version: "8"

  mailpit: true

processes:
  queue:
    command:
      - php
      - artisan
      - queue:work

  scheduler:
    command:
      - php
      - artisan
      - schedule:work
```

The exact schema should evolve conservatively from real requirements.

---

# 23. Schema version

Every project declaration begins with a schema version.

Example:

```yaml
version: 1
```

Unknown future schemas must be rejected safely.

Vaelen must not silently reinterpret configuration written for a newer incompatible schema.

---

# 24. Explicit configuration beats inference

Configuration precedence follows:

```text
explicit vaelen.yml
       ↓
explicit Vaelen project settings
       ↓
driver/project metadata
       ↓
Vaelen defaults
```

An inferred value must never silently override an explicit declaration.

---

# 25. Detection is assistance

Vaelen may inspect:

```text
composer.json
package.json
artisan
wp-config.php
.env
framework structure
```

to help determine sensible project requirements.

Detection exists to reduce configuration burden.

It does not make project behavior mysterious.

---

# 26. No uncontrolled `.env` ownership

Vaelen may need to read selected `.env` values for integration or diagnostics.

It must not assume ownership of the project's `.env`.

Routine reconciliation must not rewrite it without an explicit feature designed for that purpose.

---

# 27. Desired state

After combining configuration and discovery, Core constructs a normalized desired state.

Conceptually:

```text
ProjectDesiredState

project:
    syncproof

domain:
    syncproof.test

driver:
    laravel

web:
    https

runtime:
    php 8.4

services:
    mysql 8.4
    redis 8

processes:
    queue
```

This normalized representation is what reconciliation consumes.

---

# 28. Actual state

Core independently observes actual machine state.

Conceptually:

```text
PHP 8.4 package:
installed

PHP 8.4 FPM:
stopped

MySQL:
not installed

Redis:
running

route:
missing

queue:
stopped
```

Actual state is determined from reality plus validated Core state.

It is not assumed from configuration alone.

---

# 29. Reconciliation

Reconciliation computes the operations necessary to transform actual state into desired state.

Example:

```text
Desired:
PHP 8.4
MySQL 8.4
Redis
HTTPS route
queue

Actual:
PHP installed
MySQL absent
Redis running
route absent
queue absent

Plan:

1. Start PHP 8.4 FPM
2. Install MySQL 8.4
3. Configure MySQL instance
4. Start MySQL
5. Add HTTPS route
6. Start queue process
```

---

# 30. Reconciliation is not a script

`val up` should not fundamentally mean:

```text
execute these commands in this order every time
```

It means:

```text
make reality equal desired state
```

If part of the environment already satisfies the declaration, Vaelen does not unnecessarily recreate it.

---

# 31. Idempotency

Running:

```bash
val up
val up
val up
```

on an already reconciled project should converge to:

```text
No changes required.
```

It must not:

* recreate databases;
* regenerate everything;
* restart healthy services without reason;
* duplicate processes;
* create duplicate routes.

---

# 32. Reconciliation plan

Before mutation, Core builds a structured plan.

Conceptually:

```text
Project: syncproof

Changes required:

PHP 8.4
  START runtime

MySQL 8.4
  INSTALL package
  CREATE instance
  START instance

Routing
  CREATE syncproof.test
  ENABLE HTTPS

Queue
  START process
```

The GUI and CLI render the same plan.

---

# 33. Plan execution

Operations should execute according to dependency order.

Conceptually:

```text
packages
   ↓
instances/configuration
   ↓
services/runtime
   ↓
routes
   ↓
project processes
   ↓
health verification
```

Actual dependency graphs may allow parallel work.

---

# 34. Parallel reconciliation

Independent operations may execute concurrently.

Example:

```text
download MySQL
download PHP
```

may happen in parallel if safe.

However, implementation simplicity and correctness take priority over maximizing concurrency in v0.1.

---

# 35. Reconciliation failure

Suppose:

```text
PHP succeeds
Redis succeeds
MySQL fails
```

Vaelen must report partial state accurately.

It must not claim:

```text
Project failed to start and nothing happened.
```

when resources are actually running.

---

# 36. No reckless rollback

Automatic rollback is appropriate only where semantically safe.

For example, if MySQL installation fails after PHP starts, stopping PHP may provide no meaningful benefit.

Desired state remains unsatisfied.

Core reports:

```text
Project DEGRADED

✓ PHP 8.4
✕ MySQL 8.4
✓ Redis
○ Route waiting on dependencies
```

The user can fix the cause and run:

```bash
val up
```

again.

---

# 37. Retry

Because reconciliation is idempotent, retry becomes natural.

```text
failure
   ↓
fix cause
   ↓
val up
   ↓
reconcile remaining difference
```

No special "resume script at step 4" model is necessary.

---

# 38. Project state

A project may have high-level states such as:

```text
DOWN

STARTING

UP

DEGRADED

STOPPING
```

These summarize underlying desired/actual state.

They do not replace detailed component status.

---

# 39. `val up`

From a registered or discoverable project:

```bash
val up
```

performs conceptually:

```text
locate project
      ↓
load vaelen.yml
      ↓
select/detect driver
      ↓
inspect project metadata
      ↓
normalize desired state
      ↓
resolve versions
      ↓
inspect actual state
      ↓
build reconciliation plan
      ↓
execute
      ↓
verify health
      ↓
report result
```

---

# 40. Implicit registration

If the current directory contains a valid project but is not yet registered, `val up` may offer or perform safe implicit registration according to final CLI UX.

The desirable long-term workflow is:

```bash
git clone ...
cd project
val up
```

without requiring ceremony.

---

# 41. `val down`

`val down` means:

> Remove this project's active demand on Vaelen-managed runtime resources and stop project-scoped processes.

It does not mean:

> Stop everything this project has ever used.

This distinction matters because services may be shared.

---

# 42. Shared runtime example

Suppose:

```text
Project A → PHP 8.4
Project B → PHP 8.4
```

Both share:

```text
PHP-FPM 8.4
```

Running:

```bash
cd project-a
val down
```

must not stop PHP 8.4 if Project B still requires it.

---

# 43. Demand references

Core conceptually tracks why a shared resource is required.

Example:

```text
PHP 8.4

Required by:
• project-a
• project-b
```

After project A goes down:

```text
PHP 8.4

Required by:
• project-b
```

Therefore the runtime remains active.

---

# 44. Last consumer

If project B then runs:

```bash
val down
```

the PHP 8.4 runtime may become unnecessary.

According to lifecycle policy, Core may stop it.

This is reference-count-like behavior based on desired-state demand rather than raw integer counters.

---

# 45. Shared services

Some services naturally support sharing.

Example:

```text
mysql/default
redis/default
mailpit/default
```

Multiple projects may depend on the same instance.

Vaelen must not duplicate these merely because multiple projects request them.

---

# 46. Service identity

A project requirement such as:

```yaml
services:
  mysql:
    version: "8.4"
```

does not automatically mean:

```text
create dedicated MySQL server for this project
```

The default may resolve to a shared compatible Vaelen instance.

---

# 47. Dedicated services

Future configuration may permit:

```yaml
services:
  mysql:
    version: "8.4"
    isolated: true
```

to request a project-specific instance.

This is not necessary for v0.1.

The model must allow it later.

---

# 48. Shared service data

Sharing a MySQL server does not imply sharing a database schema.

Projects may still use distinct logical databases:

```text
mysql/default

databases:
    project_a
    project_b
```

Database creation itself may eventually become declarative.

That is not required in the first project schema.

---

# 49. External services

A project may intentionally use external infrastructure.

Example:

```text
external MySQL
external Redis
remote database
```

Vaelen must not infer that every application dependency should be managed locally.

Only declared Vaelen-managed services become reconciliation targets.

---

# 50. Project processes

Projects may declare background processes.

Examples:

```text
queue worker
scheduler
Vite
custom worker
```

These are supervised by Core.

They are not detached shell commands.

---

# 51. Structured process commands

Preferred:

```yaml
processes:
  queue:
    command:
      - php
      - artisan
      - queue:work
```

rather than one opaque shell string.

Structured commands improve:

* argument handling;
* security;
* executable resolution;
* logging;
* diagnostics.

---

# 52. Shell execution

Some legitimate developer commands require shell semantics.

A future explicit shell mode may exist.

It must be opt-in and clearly distinguishable from structured execution.

For v0.1, prefer structured command arrays.

---

# 53. Runtime-aware executable resolution

For:

```yaml
command:
  - php
  - artisan
  - queue:work
```

Core resolves:

```text
php
```

to the project's selected PHP package.

It must not accidentally use the global shell default.

---

# 54. Node processes

The same architecture should eventually support:

```yaml
processes:
  vite:
    command:
      - npm
      - run
      - dev
```

once Node runtime management exists.

Project process architecture must therefore remain runtime-neutral.

---

# 55. Process working directory

Project processes default to the project root.

This may eventually be overridden explicitly.

Core must not depend on daemon current working directory.

---

# 56. Process environment

Project process environment is constructed deterministically.

Potential layers include:

```text
minimal system environment
        ↓
Vaelen runtime paths
        ↓
project environment
        ↓
process-specific environment
```

The exact `.env` integration policy requires implementation care.

---

# 57. Process logs

Each project process receives explicit stdout/stderr handling.

Conceptually:

```text
~/Library/Logs/Vaelen/projects/<project-id>/

├── queue.log
├── scheduler.log
└── vite.log
```

Processes must not disappear into detached terminal sessions.

---

# 58. Process restart policy

Project processes may eventually specify:

```yaml
restart: on-failure
```

using the generic restart policy from ADR-0001.

Defaults should be conservative.

A broken command must not create an infinite rapid restart loop.

---

# 59. Routing intent

Projects declare routing requirements.

Conceptually:

```yaml
web:
  secure: true
```

plus project identity/domain.

The driver supplies document-root behavior.

Core resolves runtime endpoint.

Router receives a normalized route.

---

# 60. Multiple domains

The architecture should support projects with more than one hostname.

Conceptually:

```yaml
web:
  domains:
    - shop.test
    - admin.shop.test
```

This may be implemented after basic single-domain routing.

---

# 61. Wildcard subdomains

Drivers or project configuration may eventually request:

```text
*.project.test
```

The Router and TLS architecture already allow this conceptually.

It is not required for the first milestone.

---

# 62. HTTPS

HTTPS is enabled by default according to ADR-0006.

Project configuration may explicitly disable it when necessary.

A project does not directly manipulate certificates.

It requests secure routing.

---

# 63. `val open`

Vaelen should support:

```bash
val open
```

to open the project's primary local URL.

Example:

```text
https://syncproof.test
```

This is convenience behavior based on project state.

---

# 64. `val status`

Within a project:

```bash
val status
```

should prioritize project-relevant information.

Conceptually:

```text
syncproof
https://syncproof.test

Driver      Laravel
State       ● Up

PHP         8.4.13       ● Healthy
MySQL       8.4          ● Healthy
Redis       8            ● Healthy

Processes
queue                     ● Running

Routing                   ● Healthy
HTTPS                     ● Trusted
```

---

# 65. Global status

Outside a project:

```bash
val status
```

may provide environment-wide status.

Project context affects presentation, not Core ownership.

---

# 66. Project inspection

A command such as:

```bash
val inspect
```

may eventually explain what Vaelen inferred.

Example:

```text
Driver:
Laravel

Detected:
composer.json
artisan
public/index.php

PHP requirement:
^8.3 from composer.json

Resolved:
8.4.13

Document root:
public/

Domain:
syncproof.test
```

This supports transparency.

---

# 67. Explainability

Vaelen should be able to answer:

> Why is this running?

Example:

```text
PHP 8.4 is running because:

• syncproof.test requires PHP 8.4
• callthewaiter.test requires PHP 8.4
```

Likewise:

> Why was MySQL installed?

should have an inspectable answer.

This is a core part of resource honesty.

---

# 68. No invisible inference

If Vaelen detects something that materially changes infrastructure, that inference should be inspectable.

For example:

```text
MySQL inferred because ...
```

should not occur invisibly.

For early versions, Vaelen should be conservative about inferring service dependencies.

---

# 69. Runtime inference vs service inference

Inferring:

```text
PHP version from composer.json
```

is relatively safe.

Inferring:

```text
install MySQL because DB_CONNECTION=mysql
```

has much larger consequences.

Therefore the initial policy should be:

```text
runtime hints:
may infer/recommend

service installation:
prefer explicit declaration
```

This avoids surprising downloads and processes.

---

# 70. No package installation merely from repository contents without intent

Cloning an unknown repository must not cause Vaelen to automatically install software merely because a file exists.

Installation occurs through explicit actions such as:

```text
val up
```

or explicit module commands.

Project inspection itself is non-destructive.

---

# 71. Project config validation

Before reconciliation, `vaelen.yml` is validated.

Errors should be precise.

Example:

```text
vaelen.yml:12

Unknown service:
myssql

Did you mean:
mysql?
```

No partial reconciliation should begin from an invalid project declaration.

---

# 72. Unknown fields

Before 1.0, schema evolution may be frequent.

However, silently ignoring unknown fields can produce dangerous misunderstandings.

The preferred default is to reject unknown configuration keys unless the schema explicitly permits extensions.

---

# 73. Project config safety

A cloned `vaelen.yml` is user-controlled input.

It must not be able to:

* execute arbitrary root commands;
* write arbitrary system files;
* modify certificate trust directly;
* kill external processes;
* escape Vaelen filesystem boundaries through paths.

This follows ADR-0006.

---

# 74. Project commands are trusted developer code

There is an important distinction.

A project may legitimately declare:

```yaml
processes:
  queue:
    command:
      - php
      - artisan
      - queue:work
```

That command executes as the developer.

A repository can therefore cause user-level project code to execute when the developer intentionally runs:

```bash
val up
```

Vaelen should communicate this clearly.

This is analogous to intentionally running project scripts locally.

It does not justify privileged execution.

---

# 75. Future confirmation policy

For a newly cloned project containing process declarations, Vaelen may eventually present:

```text
This project defines background processes:

• php artisan queue:work
• npm run dev

Start them?
```

Trust UX can evolve from dogfooding.

It is not necessary to overbuild a permissions system for v0.1.

---

# 76. Project lock file

A future:

```text
vaelen.lock
```

may record exact resolved package versions.

Example:

```text
PHP:
8.4.13

MySQL:
8.4.6

Redis:
8.2.1
```

This improves reproducibility across machines and time.

---

# 77. Declaration vs lock

Conceptually:

```text
vaelen.yml
    what versions are acceptable

vaelen.lock
    what exact versions were resolved
```

This is similar in spirit to modern dependency-management systems.

---

# 78. Lock file is deferred

A lock file is architecturally supported but not required for v0.1.

The first implementation should prove:

```text
link
park
PHP selection
routing
val up
val down
```

before adding another persistence format.

---

# 79. Version resolution without lock

Initially:

```yaml
php: "8.4"
```

means:

> Use the preferred installed or available Vaelen-supported PHP patch within the 8.4 line.

The resolved version should always be visible.

---

# 80. Reproducibility levels

Vaelen should recognize that reproducibility exists on a spectrum.

### Level 1

```text
php: 8.4
```

Reproducible minor runtime family.

### Level 2

Exact package versions through future lock state.

### Level 3

Exact services, processes, and runtime configuration.

Vaelen does not need to pretend v0.1 provides perfect bit-for-bit environment reproduction.

---

# 81. Native reproducibility

Vaelen's reproducibility goal differs from container-image reproducibility.

Vaelen aims for:

> Deterministic native developer environment composition on supported macOS systems.

It does not claim to reproduce an arbitrary Linux production image byte-for-byte.

---

# 82. Project portability

A committed:

```text
vaelen.yml
```

should avoid machine-specific absolute paths wherever possible.

Another Vaelen user should be able to clone the repository and run:

```bash
val up
```

with sensible results.

---

# 83. Missing module

If a project declares:

```yaml
services:
  redis:
    version: "8"
```

and Redis is not installed, reconciliation may include:

```text
Install Redis 8
```

because the user explicitly invoked:

```bash
val up
```

against a declaration requiring Redis.

---

# 84. Unsupported requirement

If a project requires something Vaelen cannot provide:

```text
PHP 7.1
```

for example, Vaelen should fail clearly.

It must not silently substitute:

```text
PHP 8.4
```

merely to make reconciliation succeed.

---

# 85. External satisfaction

Future versions may allow project requirements to be satisfied by explicitly declared external services.

Example:

```yaml
services:
  mysql:
    managed: false
```

The exact schema is deferred.

The project model must not assume Vaelen owns the entire machine.

---

# 86. Removing configuration

Suppose a project changes from:

```yaml
services:
  redis: true
```

to no Redis declaration.

The next:

```bash
val up
```

removes that project's demand for Redis.

It does not necessarily uninstall Redis.

---

# 87. Reconciliation is not garbage collection

This distinction is important.

Project reconciliation manages:

```text
desired active environment
```

It does not aggressively delete:

```text
unused packages
preserved service data
logs
caches
```

Those belong to lifecycle/cleanup operations such as:

```text
val clean
```

---

# 88. Removing project process declarations

If:

```text
queue
```

is removed from `vaelen.yml`, reconciliation should stop the Vaelen-managed queue process for that project.

Because it is project-scoped, no other project's queue is affected.

---

# 89. Removing route declarations

If a project is no longer intended to be web-served, reconciliation may remove its route while leaving other services intact.

Capabilities remain independently composable.

---

# 90. `val down` does not uninstall

Running:

```bash
val down
```

must not:

* uninstall PHP;
* uninstall MySQL;
* delete databases;
* delete packages;
* delete project configuration.

It changes active demand.

---

# 91. `val unlink` does not uninstall

Likewise:

```bash
val unlink
```

removes project registration.

Shared installed infrastructure remains unless explicitly cleaned later.

---

# 92. Project removal lifecycle

Conceptually:

```text
val down
    ↓
stop project-scoped active demand

val unlink
    ↓
remove project registration

val clean
    ↓
optionally reclaim now-unused disposable infrastructure
```

These operations must remain semantically distinct.

---

# 93. Project rename

If a project directory is renamed:

```text
old-name
    ↓
new-name
```

Vaelen should attempt to preserve project identity where safely detectable.

The exact mechanism is implementation-dependent.

A stable project ID helps separate identity from display name/path.

---

# 94. Missing project directory

If a registered project path disappears:

```text
Project:
syncproof

Path:
missing
```

Vaelen marks the project unavailable.

It must not assume the project should be deleted from the registry immediately.

The directory may be on temporarily unavailable storage or simply moved.

---

# 95. Symlinked projects

Project path canonicalization must follow ADR-0004 safety rules.

The behavior of symlinked roots should be consistent and documented.

Vaelen must not accidentally register the same project multiple times through equivalent paths.

---

# 96. Project lifecycle events

Core may emit:

```text
project.registered
project.updated
project.reconciled
project.degraded
project.down
project.unlinked
```

GUI and CLI clients consume these through ADR-0005.

---

# 97. Reconciliation operations

A project reconciliation itself is a Core long-running operation.

Conceptually:

```text
operation:
project.reconcile

project:
syncproof

phases:
inspect
resolve
plan
apply
verify
complete
```

The client may disconnect without corrupting the operation.

---

# 98. Reconciliation locking

Only one mutating reconciliation should operate on the same project at a time.

Two simultaneous:

```bash
val up
```

requests should not race package/service/project state.

Core owns the lock.

---

# 99. Cross-project concurrency

Independent project reconciliations may proceed concurrently where their shared resource dependencies do not conflict.

The first implementation may serialize more aggressively for correctness.

Optimization can come later.

---

# 100. Reconciliation graph

The desired-state engine should conceptually operate on resources.

Example:

```text
Project: syncproof

             PHP Package
                  │
                  ▼
              PHP FPM
                  │
                  ▼
               Route
                  │
                  ▼
               Project

MySQL Package
      │
      ▼
MySQL Instance
      │
      └────────────► Project

Redis Package
      │
      ▼
Redis Instance
      │
      └────────────► Project

PHP FPM
      │
      ▼
Queue Process
      │
      └────────────► Project
```

Dependencies determine execution order.

---

# 101. Resource model

A reconciliation resource should expose conceptual operations such as:

```text
desiredState
actualState
diff
apply
verify
```

The exact Swift abstraction should be discovered during implementation.

Avoid creating a giant generic framework before the first PHP project works.

---

# 102. Reconciliation should emerge incrementally

For v0.1, resources may initially be limited to:

```text
ProjectRegistration
PHPRuntime
Route
TLS
```

Then later:

```text
Mailpit
Redis
MySQL
ProjectProcess
```

The conceptual reconciliation model is fixed.

The implementation can grow incrementally.

---

# 103. v0.1 `val up`

The first useful implementation only needs to make this work:

```yaml
version: 1

php: "8.4"

web:
  secure: true
```

Then:

```bash
cd ~/Code/project
val up
```

produces:

```text
✓ PHP 8.4 available
✓ PHP-FPM running
✓ .test DNS healthy
✓ HTTPS available
✓ route configured

https://project.test
```

That is sufficient to prove the architecture.

---

# 104. Automatic driver behavior in v0.1

Initial drivers should focus on document-root detection.

For example:

```text
Laravel
    public/

WordPress
    ./

Generic PHP
    ./
```

Do not build elaborate framework automation before the local web environment is proven.

---

# 105. Dogfooding milestone

Vaelen reaches its first meaningful milestone when the maintainer can:

1. disable Herd;
2. register real Laravel and WordPress projects;
3. use `.test`;
4. use trusted HTTPS;
5. run multiple PHP versions where needed;
6. execute normal CLI PHP/Composer workflows;
7. perform daily development without returning to Herd.

This is the v0.1 success test.

---

# 106. `val up` philosophy

`val up` should eventually become one of Vaelen's defining commands.

It should mean:

> I am here. Make this project ready for development.

Not:

> Run a predefined startup script and hope the machine matches its assumptions.

---

# 107. Future module composition

Once the model is proven, a richer project may become:

```yaml
version: 1

php: "8.4"

web:
  secure: true

services:
  mysql:
    version: "8.4"

  redis:
    version: "8"

  mailpit: true

processes:
  queue:
    command:
      - php
      - artisan
      - queue:work

  vite:
    command:
      - npm
      - run
      - dev
```

Core still sees generic requirements and resources.

---

# 108. Future non-PHP projects

Nothing in the project model should fundamentally require PHP.

Future examples may include:

```yaml
version: 1

node: "24"

web:
  target:
    process: app
```

or:

```yaml
version: 1

python: "3.14"
```

PHP is the first runtime, not the definition of a Vaelen project.

---

# 109. Future static projects

A static project may require only:

```text
route
TLS
document root
```

with no runtime module at all.

The project model must support that naturally.

---

# 110. Future project presets

Drivers or community definitions may eventually provide presets.

Example:

```text
Laravel
WordPress
Statamic
Craft CMS
Symfony
```

Presets should generate or suggest desired state.

They should not create a second infrastructure system beside modules.

---

# 111. Future team workflow

A committed `vaelen.yml` could allow a team member to:

```bash
git clone ...
val up
```

and receive the project's native macOS development environment.

No Vaelen account is required for this workflow.

---

# 112. No cloud control plane

Project reconciliation remains local.

Vaelen does not need to upload:

```text
project paths
project configuration
runtime versions
service usage
```

to a remote server merely to determine local desired state.

---

# 113. GUI project model

The GUI should present projects as compositions.

Conceptually:

```text
SYNCProof

https://syncproof.test

Runtime
PHP 8.4.13          ●

Services
MySQL 8.4           ●
Redis 8             ●

Processes
Queue               ●

Infrastructure
DNS                 ●
HTTPS               ●
Routing             ●

[ Stop Project ]
```

Every displayed state comes from Core.

---

# 114. Project actions

GUI actions map to canonical Core operations.

Examples:

```text
Start Project
    → project.reconcile

Stop Project
    → project.down

Open
    → project.primaryURL

Restart Queue
    → process.restart
```

SwiftUI does not directly manage infrastructure.

---

# 115. Explain plan before destructive changes

Most `val up` reconciliation is additive/non-destructive.

If a future desired-state change requires destructive migration, Core should explicitly surface that fact before execution.

Example:

```text
MySQL 8.4 → 9.x

This upgrade may modify the database data format.
```

Ordinary reconciliation must not hide destructive transitions.

---

# 116. Desired state is scoped to Vaelen ownership

Vaelen reconciles only resources it owns or has explicitly been authorized to manage.

It does not attempt to make the entire Mac match `vaelen.yml`.

For example, it does not uninstall an external Homebrew Redis because the project no longer requests Redis.

---

# 117. Actual state includes external conflicts

External state still matters.

Example:

```text
Desired:
router on 443

Actual:
external nginx owns 443
```

Reconciliation result:

```text
BLOCKED
```

not:

```text
kill nginx
```

---

# 118. Resource states

Reconciliation resources may conceptually report:

```text
SATISFIED

MISSING

DIFFERENT

STARTING

DEGRADED

BLOCKED

FAILED
```

The exact enum should remain as simple as implementation permits.

---

# 119. Blocked vs failed

This distinction is useful.

Example:

```text
Port 443 owned by Herd
```

is:

```text
BLOCKED
```

because an external condition prevents reconciliation.

A Vaelen-owned Caddy process crashing repeatedly is:

```text
FAILED
```

Different causes deserve different recovery guidance.

---

# 120. Project health

A project is healthy when all required resources are satisfied and healthy.

Optional components may have separate status.

Conceptually:

```text
UP
```

means:

> All required declared resources are currently satisfied.

---

# 121. Degraded project

A project is:

```text
DEGRADED
```

when it exists and some capabilities work, but one or more required resources do not.

Example:

```text
✓ PHP
✓ route
✕ MySQL
```

The GUI should not collapse this into simply "off."

---

# 122. Drift

Machine state may drift after successful reconciliation.

Examples:

```text
FPM crashes
external process takes port
package files manually deleted
route disappears
```

Core should detect relevant drift through supervision/health mechanisms.

It should update project state accordingly.

---

# 123. Automatic repair

Not every drift event should immediately cause automatic mutation.

Safe process restart may follow configured restart policy.

Privileged/system repairs may require user intent.

The desired-state model does not mean:

> Vaelen fights the user forever until the machine matches its database.

Reconciliation must remain respectful of explicit user actions and ownership.

---

# 124. Manual stop

If a user explicitly stops:

```text
PHP 8.4
```

while active projects require it, Core must represent the tension honestly.

Possible state:

```text
PHP 8.4
Stopped manually

Required by:
• project-a.test

Project:
DEGRADED
```

Vaelen should not immediately restart it behind the user's back unless the operation explicitly represented a temporary restart.

---

# 125. Desired state includes user intent

This means desired state cannot be derived solely from static `vaelen.yml`.

It combines:

```text
project declarations
+
registration/activity state
+
explicit user runtime intent
+
system policy
```

This prevents the reconciler from becoming hostile to manual control.

---

# 126. `val down` changes desired state

Running:

```bash
val down
```

does not merely kill processes.

It records:

> This project is no longer requesting active infrastructure.

Core then reconciles shared resources accordingly.

This is a much stronger model than process killing.

---

# 127. Restart

A future:

```bash
val restart
```

should mean:

```text
restart project-scoped processes
and required runtime components where semantically appropriate
```

without reinstalling packages or destroying state.

Exact semantics should be defined from real usage.

---

# 128. Rebuild

If Vaelen eventually provides:

```bash
val rebuild
```

it must be carefully distinguished from:

```text
up
restart
clean
purge
```

Do not introduce overlapping lifecycle verbs prematurely.

---

# 129. CLI restraint

For v0.1, the project CLI should stay small.

Core commands:

```bash
val park
val link
val unlink

val up
val down

val status
val open
val doctor
```

Add commands only when dogfooding demonstrates a recurring need.

---

# 130. Project model acceptance test

Before considering the project architecture successful, the following should work naturally:

### Laravel

```text
link
detect Laravel
public/ document root
PHP selection
HTTPS
CLI PHP parity
```

### WordPress

```text
link
detect WordPress
correct document root
PHP selection
HTTPS
permalinks
```

### Generic PHP

```text
link
no framework dependency
index.php
PHP selection
HTTPS
```

### Multiple versions

```text
Project A → PHP 8.3
Project B → PHP 8.4
both online simultaneously
```

### Shared runtime

```text
Project B down
Project A remains online
shared PHP remains when required
```

### Idempotency

```text
val up
val up
```

causes no destructive or duplicate behavior.

### Failure

A blocked port or broken runtime produces an explainable degraded state.

---

# 131. Consequences

## Positive

### Projects become the center of the UX

Developers manage projects rather than individual daemon mechanics.

### Native reproducibility

`vaelen.yml` can describe a native macOS environment.

### Idempotency

`val up` safely converges instead of replaying scripts.

### Resource sharing

Projects can share compatible native services efficiently.

### Resource honesty

Vaelen can explain why every shared service is running.

### Framework extensibility

Drivers add framework knowledge without contaminating Core.

### Module composition

Projects consume module capabilities without knowing their installation mechanics.

### Future runtimes

The model naturally extends beyond PHP.

---

# 132. Costs

Desired-state reconciliation introduces complexity beyond a simple service launcher.

Core must model:

* desired state;
* actual state;
* resource dependencies;
* operation plans;
* shared demand;
* drift;
* partial failure;
* project state.

This complexity is justified because it becomes the foundation for Vaelen's defining workflow.

---

# 133. Alternatives Considered

## Imperative project scripts

Rejected as the primary architecture.

Easy initially, but poor at drift, idempotency, shared services, diagnostics, and GUI representation.

---

## One environment per project with duplicated services

Rejected as the default.

Contradicts Vaelen's lightweight native-resource philosophy.

Isolation may remain opt-in later.

---

## Infer everything automatically

Rejected.

Convenient demos, but surprising infrastructure changes and poor reproducibility.

---

## Require everything explicitly

Rejected.

Creates unnecessary configuration for obvious framework conventions.

Drivers should provide safe convention-based defaults.

---

## Container-style project isolation

Rejected.

Vaelen intentionally composes native macOS processes.

---

## Global service manager without project model

Rejected.

That would make Vaelen a service dashboard rather than a coherent developer environment.

---

# 134. Open Implementation Questions

1. Exact `vaelen.yml` v1 schema.
2. Exact project identifier format.
3. Driver detection interface.
4. Exact park discovery mechanism.
5. Whether parked projects are persisted individually or discovered dynamically.
6. Exact project activity state persistence.
7. Initial version-resolution rules.
8. When `vaelen.lock` should be introduced.
9. Exact shared-service matching rules.
10. Project process environment construction.
11. Whether newly cloned process declarations require confirmation.
12. Exact drift-repair policy.
13. Exact resource abstraction used by reconciliation.
14. How aggressively independent reconciliation operations execute in parallel.
15. Exact `val down` behavior for routes.
16. Whether routes remain available for down projects and display a useful stopped page, or disappear entirely.
17. Exact project rename/move detection.
18. Whether `val up` implicitly links an unregistered current project.
19. Exact semantics for manually stopped shared resources.
20. How much Composer runtime inference belongs in v0.1.

These should now be answered through implementation rather than another round of speculative architecture.

---

# 135. Invariants Established by This ADR

1. Projects are declarative desired-state objects.
2. Project source remains developer-owned.
3. Project registration never transfers filesystem ownership.
4. `link` and `park` remain primary project-discovery concepts.
5. Parking does not eagerly start every discovered project.
6. Drivers interpret project conventions.
7. Drivers do not install or supervise infrastructure directly.
8. `vaelen.yml` is the canonical project declaration.
9. Explicit configuration wins over inference.
10. Driver inference is inspectable.
11. Service installation should be explicit rather than aggressively inferred.
12. Core normalizes project requirements before reconciliation.
13. Actual state is observed independently from desired state.
14. `val up` means reconcile reality to desired state.
15. `val up` is idempotent.
16. Reconciliation produces a structured plan.
17. Partial failure is represented honestly.
18. Retry continues from actual state rather than replaying a script blindly.
19. `val down` removes project demand rather than blindly stopping shared resources.
20. Shared resources remain running while another active project requires them.
21. Project processes are supervised by Core.
22. Project processes use project runtime resolution.
23. Routing consumes normalized project/runtime state.
24. HTTPS remains a platform capability.
25. Reconciliation never deletes user project source.
26. `val down` never uninstalls packages or deletes service data.
27. `val unlink` never uninstalls unrelated infrastructure.
28. Reconciliation and garbage collection are separate concepts.
29. Project declarations cannot express arbitrary privileged operations.
30. External resources remain externally owned.
31. External conflicts may block reconciliation but are never silently destroyed.
32. `vaelen.lock` remains possible without being required for v0.1.
33. Reproducibility means deterministic native macOS environment composition, not container-image equivalence.
34. The project model remains runtime-neutral despite PHP being first.
35. Core can explain why a shared resource is running.
36. Desired state includes explicit user intent, not merely static configuration.
37. Manual user stops must not be immediately fought by an over-aggressive reconciler.
38. Drift changes project health and may trigger only policy-approved recovery.
39. The first implementation should implement only the smallest useful reconciliation resource set.
40. Further project architecture decisions should now be driven by implementation.

---

# Summary

Vaelen's architecture ultimately converges on one model:

```text
                  vaelen.yml
                      │
                      ▼
               Project Driver
                      │
                      ▼
                Desired State
                      │
                      │
                      ▼
             ┌─────────────────┐
             │  Reconciliation │
             └────────┬────────┘
                      │
              compare with reality
                      │
       ┌──────────────┼───────────────┐
       │              │               │
       ▼              ▼               ▼
    Modules        Runtime          Platform
       │              │               │
       ▼              ▼               ▼
     MySQL          PHP-FPM       DNS / TLS
     Redis          Processes      Router
     Mailpit
```

The developer sees:

```bash
git clone ...
cd project
val up
```

Vaelen sees:

```text
inspect
resolve
compare
plan
apply
verify
```

The developer does not need to think about:

```text
FPM socket paths
Caddy configuration
package directories
process IDs
certificate generation
shared-service reference counts
```

unless they want to inspect them.

But Vaelen always knows those details and can explain them.

That distinction is central:

> **Simple on the surface. Explicit underneath.**

`val up` is therefore not merely another command.

It is the point where Vaelen's module system, project drivers, native runtimes, routing, TLS, process supervision, ownership model, and resource philosophy become one coherent developer environment.
