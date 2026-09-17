# ADR-0001: Core Runtime Model

* **Status:** Proposed
* **Date:** 2026-09-17
* **Decision owners:** Vaelen maintainers

## Context

Vaelen is a native macOS developer control center.

Its graphical application and CLI need to manage long-lived developer processes such as PHP-FPM, routing, databases, mail servers, queues, schedulers, and other optional modules.

These processes must continue operating independently of whether the Vaelen graphical application is open.

Vaelen must also:

* know which processes it owns;
* recover accurate state after Vaelen itself crashes or restarts;
* survive GUI and CLI disconnection;
* avoid unnecessary privileged execution;
* provide identical behavior through the GUI and CLI;
* expose observable process state;
* prevent multiple clients from independently manipulating the same infrastructure;
* support future project reconciliation through `val up`;
* remain lightweight when idle.

This ADR defines the runtime topology responsible for those requirements.

---

# Decision

Vaelen will use a **single per-user core daemon**, named `vaelend`, as the authoritative runtime coordinator.

`Vaelen.app` and the `val` CLI are clients of `vaelend`.

Managed developer services are child processes supervised by `vaelend` but are not embedded inside the daemon.

A separate, narrowly scoped privileged helper may be installed for the small number of macOS operations that genuinely require elevated privileges.

The resulting runtime model is:

```text
                         macOS
                           │
             ┌─────────────┴─────────────┐
             │                           │
        Vaelen.app                      val
         SwiftUI                        CLI
             │                           │
             └─────────────┬─────────────┘
                           │
                     authenticated IPC
                           │
                    ┌──────▼──────┐
                    │   vaelend   │
                    │             │
                    │ Vaelen Core │
                    └──────┬──────┘
                           │
                    Process Supervisor
                           │
          ┌────────────────┼─────────────────┐
          │                │                 │
        Router           PHP-FPM           Modules
          │                │                 │
        Caddy           PHP 8.4       MySQL / Redis /
                                      Mailpit / etc.
                           │
                           │ privileged requests only
                           ▼
                  ┌──────────────────┐
                  │ Vaelen Helper    │
                  │      root        │
                  └──────────────────┘
```

---

# 1. `vaelend` is authoritative

There must be exactly one authoritative Vaelen Core runtime per logged-in user.

Neither the GUI nor CLI independently owns infrastructure state.

`vaelend` owns:

* module state;
* package state;
* instance state;
* project registry;
* process supervision;
* runtime configuration;
* health state;
* routing state;
* reconciliation;
* lifecycle operations.

Clients ask Core to perform operations.

They do not reproduce those operations themselves.

For example:

```text
Vaelen.app
    │
    │ stopService("mysql/default")
    ▼
 vaelend
```

and:

```text
val service stop mysql
    │
    │ stopService("mysql/default")
    ▼
 vaelend
```

must resolve to the same Core operation.

---

# 2. The GUI is disposable

Closing `Vaelen.app` must not stop the developer environment.

A user may:

1. start Vaelen;
2. start PHP and MySQL;
3. close the Vaelen window;
4. quit the graphical application;
5. continue developing normally.

The runtime remains available because infrastructure belongs to `vaelend`, not the GUI process.

Reopening Vaelen should reconnect to the existing daemon and immediately obtain current state.

The GUI therefore behaves as a native control surface over Vaelen Core.

---

# 3. The CLI is disposable

`val` is also a short-lived client.

Executing:

```bash
val status
```

should conceptually perform:

```text
start CLI
    ↓
connect to vaelend
    ↓
request status
    ↓
render response
    ↓
disconnect
    ↓
exit
```

The CLI does not remain resident after the command completes.

Running a long-lived service through:

```bash
val service start mysql
```

must not make MySQL dependent on the lifetime of that CLI process.

---

# 4. Daemon lifecycle

`vaelend` should be managed by `launchd` as a **per-user LaunchAgent**.

It must not run as root.

Conceptually:

```text
~/Library/LaunchAgents/
    dev.vaelen.daemon.plist
```

The exact bundle identifiers and installation paths may change during implementation.

`launchd` is responsible for making the daemon available when required.

Vaelen should prefer **on-demand activation** where technically practical rather than keeping an unnecessary busy daemon alive permanently.

However, the daemon may remain resident while it is actively supervising running Vaelen services.

The intended behavior is:

```text
No Vaelen services running
No active Vaelen clients
        │
        ▼
daemon may become idle / eligible to exit

              vs.

PHP / MySQL / etc. running
        │
        ▼
vaelend remains available to supervise them
```

The implementation must prioritize reliable supervision over aggressively terminating the daemon.

"Off means off" applies to unused modules and unnecessary work, not to sacrificing process reliability to save a few megabytes.

---

# 5. `vaelend` runs as the user

The daemon must run under the logged-in user's account.

It must not run as root.

This means ordinary managed processes inherit normal user-level access.

Examples include:

* PHP-FPM
* MySQL
* PostgreSQL
* Redis
* Mailpit
* Meilisearch
* Typesense
* queue workers
* schedulers
* project processes

This ensures that files created by development services normally belong to the developer rather than root.

It also substantially reduces the security impact of a Core vulnerability.

---

# 6. Managed processes are separate processes

Services must not be embedded inside `vaelend`.

For example:

```text
vaelend
   │
   ├── caddy
   ├── php-fpm 8.4
   ├── mysql
   ├── redis
   └── mailpit
```

Each remains an independent native process.

This provides:

* crash isolation;
* independent lifecycle management;
* accurate resource accounting;
* upstream compatibility;
* simple upgrades;
* clean uninstallation;
* direct diagnostics.

A crash in Mailpit must not crash Vaelen Core.

A crash in Vaelen Core must not automatically corrupt MySQL.

---

# 7. Process ownership

Vaelen distinguishes between:

### Managed process

A process intentionally started and supervised by Vaelen.

### External process

A process Vaelen discovers but does not own.

For example, if Homebrew MySQL is already running:

```text
mysqld :3306
```

Vaelen may detect the conflict.

It must not assume ownership of that process.

Therefore:

```bash
val service stop mysql
```

must never blindly terminate an unrelated MySQL installation merely because it uses the expected port.

---

# 8. Process identity

A PID is not sufficient proof of process identity.

PIDs may be reused by macOS.

For every managed process, Vaelen should persist enough information to verify ownership.

Potential identity information includes:

* PID;
* executable path;
* executable identity;
* launch timestamp;
* arguments;
* module identifier;
* instance identifier;
* expected ports or sockets;
* Vaelen-generated runtime token where practical.

Before terminating a previously recorded process, Vaelen must verify that the PID still corresponds to the expected process.

Conceptually:

```text
state says:

PID = 4812
binary = .../mysql/8.4/bin/mysqld

            ↓

PID 4812 exists

            ↓

Does executable identity match?

       YES          NO
        │            │
        ▼            ▼
   manageable     stale state
```

Vaelen must prefer leaving an unknown process alive over accidentally terminating an unrelated one.

---

# 9. Runtime state is persisted

`vaelend` cannot rely exclusively on in-memory state.

Core may crash.

macOS may restart.

The user may force-quit Vaelen.

Runtime metadata must therefore be persisted.

Conceptually:

```text
~/Library/Application Support/Vaelen/state/
```

may contain state describing:

```text
installed packages
configured instances
managed processes
project registry
runtime selections
service configuration
```

Ephemeral process artifacts may live under:

```text
~/Library/Application Support/Vaelen/run/
```

or an appropriate cache/runtime directory.

Examples:

```text
run/
├── sockets/
├── locks/
└── process-state/
```

Persistent configuration and disposable runtime state must remain distinguishable.

---

# 10. Startup reconciliation

When `vaelend` starts, it must not blindly trust persisted runtime state.

It performs reconciliation.

Conceptually:

```text
Load persisted state
        │
        ▼
Inspect actual machine
        │
        ▼
Compare desired / recorded / actual state
        │
        ▼
Reconcile
```

Example:

Persisted state says:

```text
mysql/default
PID: 4182
state: RUNNING
```

but PID 4182 no longer exists.

Core transitions the instance to an appropriate state such as:

```text
STOPPED
```

or:

```text
FAILED
```

depending on the expected lifecycle.

Conversely, if the recorded process still exists and its identity can be verified, Vaelen may adopt it back into active supervision.

---

# 11. Process adoption

Vaelen should support safe adoption of its own surviving processes after Core restarts.

This is different from adopting arbitrary external processes.

A process is adoptable only when Vaelen can establish with sufficient confidence that Vaelen originally launched it.

Evidence may include:

* persisted executable identity;
* PID;
* launch time;
* known runtime files;
* expected arguments;
* expected socket;
* process environment markers;
* Vaelen-generated instance identifier.

If ownership cannot be established, the process is treated as external.

---

# 12. Crash behavior

Different crash scenarios require different behavior.

## GUI crashes

No infrastructure impact.

`vaelend` and managed services continue.

## CLI crashes

No infrastructure impact after an operation has been accepted by Core.

## Module process crashes

The supervisor detects the exit and updates instance state.

Depending on restart policy, it may restart the process.

## `vaelend` crashes

`launchd` may restart it.

The new daemon reconciles persisted state with actual processes.

## Privileged helper crashes

Normal development services continue.

Only privileged system operations temporarily become unavailable.

---

# 13. Restart policies

Restart behavior belongs to instance/process configuration.

Possible policies include:

```text
never
on-failure
always
```

Defaults should be conservative.

A development database may reasonably restart after an unexpected crash.

A project-specific command that repeatedly fails should not enter an uncontrolled restart loop.

Restart policies must support:

* retry limits;
* backoff;
* failure visibility.

Example:

```text
queue worker crashes
       ↓
restart after 1s
       ↓
crashes again
       ↓
restart after 2s
       ↓
crashes again
       ↓
restart after 5s
       ↓
threshold reached
       ↓
FAILED
```

The user must be able to see why the process failed.

---

# 14. Health is different from process existence

The following is insufficient:

```text
PID exists → RUNNING
```

A process can exist while being unusable.

Vaelen distinguishes:

```text
process state
```

from:

```text
service health
```

Example:

```text
mysqld PID exists
       │
       ▼
TCP :3306 responds?
       │
       ▼
optional module-specific health check
       │
       ▼
HEALTHY
```

Possible health states:

```text
UNKNOWN
STARTING
HEALTHY
DEGRADED
UNHEALTHY
```

Modules provide the knowledge necessary to test their health.

Core provides reusable health-check mechanisms.

---

# 15. IPC topology

All unprivileged clients communicate with `vaelend`.

Preferred topology:

```text
Vaelen.app ──┐
             │
             ├── authenticated local IPC ──► vaelend
             │
val ─────────┘
```

The exact IPC implementation should favor native macOS mechanisms.

XPC is the preferred candidate for communication involving the graphical application and privileged helper.

The CLI transport requires implementation validation because command-line tools and XPC lifecycle behavior have different constraints.

The architectural requirement is not a specific API.

The requirement is:

> There is one authenticated local Core API regardless of client.

Transport decisions may therefore use:

* XPC;
* UNIX domain sockets;
* or a carefully justified combination.

---

# 16. No localhost HTTP control API by default

Vaelen should not expose its Core management API through an ordinary TCP HTTP port unless a future requirement clearly justifies doing so.

Prefer:

```text
XPC
```

or:

```text
UNIX domain socket
```

over:

```text
http://127.0.0.1:random-port
```

for internal Core communication.

This reduces:

* network exposure;
* port conflicts;
* accidental browser access;
* unnecessary authentication surface.

Future integrations such as MCP should remain clients of Core rather than requiring Core itself to become a network server.

---

# 17. Core API semantics

The Core API should distinguish between:

## Commands

Operations that change state.

Examples:

```text
InstallModule
UninstallModule
StartInstance
StopInstance
LinkProject
UnlinkProject
ReconcileProject
```

## Queries

Operations that inspect state.

Examples:

```text
GetStatus
ListModules
ListInstances
ListProjects
GetProcessMetrics
```

## Events

Asynchronous state changes.

Examples:

```text
ModuleInstalled
InstanceStarted
InstanceStopped
InstanceFailed
ProcessExited
HealthChanged
ProjectLinked
```

## Progress

Long-running commands emit structured progress.

Example:

```text
Install PHP 8.4

Resolving version
Downloading              38%
Verifying                 ✓
Extracting                64%
Validating                ✓
Installing                ✓
Complete
```

Both GUI and CLI consume the same progress model.

---

# 18. Operations have identities

Long-running or state-changing Core operations should have unique operation identifiers.

Example:

```text
operation:
    id: 01K...
    type: module.install
    target: php@8.4.13
    state: running
```

This allows clients to:

* subscribe to progress;
* reconnect after temporary disconnection;
* inspect failures;
* avoid accidentally starting duplicate operations.

---

# 19. Mutating operations are serialized where necessary

Vaelen must prevent conflicting operations.

For example, these cannot safely occur simultaneously against the same instance:

```text
start mysql/default
uninstall mysql
upgrade mysql/default
delete mysql/default
```

Core therefore owns locking and operation serialization.

Clients do not implement their own locking.

Locks should be scoped as narrowly as practical.

For example:

```text
package:mysql:8.4
instance:mysql:default
project:/Users/example/Code/foo
```

rather than globally locking all of Vaelen unnecessarily.

---

# 20. Operations should be idempotent

Where practical:

```bash
val service start mysql
```

when MySQL is already healthy should succeed without starting another MySQL process.

Similarly:

```bash
val service stop mysql
```

when the instance is already stopped should not be considered a catastrophic error.

And:

```bash
val up
```

should be safe to execute repeatedly.

The system should converge toward desired state rather than depend on fragile command ordering.

---

# 21. Privileged helper

Vaelen may install a separate privileged helper for operations requiring root privileges.

The helper:

* runs separately from `vaelend`;
* has no module business logic;
* does not supervise ordinary developer services;
* does not run arbitrary shell commands;
* exposes only explicitly defined privileged operations.

Conceptually:

```text
                 vaelend
                    │
                    │ authenticated XPC
                    ▼
         VaelenPrivilegedHelper
                    │
          ┌─────────┼─────────┐
          ▼         ▼         ▼
         DNS       TLS      System
       changes    trust    integration
```

---

# 22. Privileged API is capability-based

Bad:

```swift
func executeAsRoot(_ command: String)
```

This must never exist.

Better:

```swift
func installResolver(domain: String, target: ResolverTarget)

func removeResolver(domain: String)

func installTrustedCertificate(
    certificate: CertificateReference
)

func removeTrustedCertificate(
    fingerprint: CertificateFingerprint
)
```

Each operation validates its input and performs exactly one known class of privileged action.

---

# 23. Modules cannot request arbitrary privilege

Modules must not be able to say:

```text
run this command as root
```

If a module genuinely requires a new privileged capability, that capability must be deliberately added to Vaelen's privileged interface and reviewed as part of Core architecture.

This prevents the module ecosystem from gradually turning the privileged helper into a generic root executor.

---

# 24. Router process

The routing provider is supervised by Core like other infrastructure processes.

The architectural interface is a Router abstraction.

Conceptually:

```text
Router
├── start()
├── stop()
├── status()
├── addRoute()
├── updateRoute()
├── removeRoute()
└── health()
```

The initial implementation is expected to use Caddy, but Core must not expose Caddy-specific concepts unnecessarily.

The routing provider decision belongs to a separate ADR.

---

# 25. Runtime selection

Projects reference runtime requirements rather than process identifiers.

For example:

```yaml
php: "8.4"
```

Core resolves this into:

```text
requested runtime
      ↓
installed package
      ↓
runtime instance
      ↓
PHP-FPM socket
      ↓
project route
```

Projects must not need to know Vaelen's internal package paths or process identifiers.

---

# 26. UNIX sockets should be preferred where appropriate

For local inter-process communication such as PHP-FPM, UNIX domain sockets should be preferred where they provide a cleaner local-only interface.

Conceptually:

```text
Caddy
   │
   │ FastCGI
   ▼
~/.../run/php/8.4.sock
   │
   ▼
PHP-FPM 8.4
```

Benefits include:

* no unnecessary TCP port;
* reduced port conflicts;
* clear local-only semantics;
* natural ownership/permissions.

TCP remains appropriate for services whose normal protocol expects it, such as:

* MySQL;
* PostgreSQL;
* Redis;
* Mailpit SMTP/HTTP;
* search engines.

---

# 27. Port ownership

Vaelen maintains awareness of ports required by managed instances.

Before starting a service, Core should determine whether the requested port is available.

If unavailable:

```text
Requested: MySQL :3306

Port 3306 already occupied
           │
           ▼
identify process where possible
           │
     ┌─────┴─────┐
     │           │
Vaelen-owned   External
     │           │
     ▼           ▼
handle state   report conflict
```

Vaelen must not kill an external process merely to reclaim a port.

Automatic alternate-port allocation may be supported by modules where appropriate.

---

# 28. Service dependencies

Core supports explicit dependency relationships.

Example:

```text
Laravel project
    │
    ├── PHP 8.4
    ├── MySQL
    └── Redis
```

or:

```text
Project Route
    │
    ├── Router
    └── PHP-FPM 8.4
```

Dependencies form a directed graph.

Starting a project may require starting its dependencies first.

Stopping a dependency that is actively required by other running components should produce an explicit decision rather than silently breaking unrelated projects.

The dependency system must avoid service-specific logic inside Core.

---

# 29. Project reconciliation

`val up` is implemented as desired-state reconciliation.

Conceptually:

```text
Read vaelen.yml
       │
       ▼
Resolve project driver
       │
       ▼
Resolve required modules
       │
       ▼
Resolve required packages
       │
       ▼
Compare desired state
with machine state
       │
       ▼
Build reconciliation plan
       │
       ▼
Apply operations
       │
       ▼
Verify health
```

Before applying destructive or unusual operations, Core may present the plan to the client.

Example:

```text
Vaelen will:

✓ Use PHP 8.4.13
↓ Install MySQL 8.4.6
▶ Start Redis
✓ Configure project.test
✓ Enable HTTPS

Proceed?
```

Non-interactive operation must eventually be possible for automation.

---

# 30. `val down`

`val down` means:

> Stop project-specific runtime state that is no longer required.

It does not mean:

> Stop every shared service listed in the project's configuration.

For example, two projects may depend on the same MySQL instance.

```text
Project A ──┐
            ├── mysql/default
Project B ──┘
```

Running:

```bash
cd project-a
val down
```

must not blindly stop MySQL if Project B still requires it.

Core therefore needs dependency/reference awareness.

---

# 31. Shared vs project-scoped instances

Vaelen supports the conceptual distinction between:

### Shared instance

Example:

```text
mysql/default
redis/default
```

Used by multiple projects.

### Project-scoped process or instance

Example:

```text
project/foo/queue/default
project/foo/scheduler
```

The architecture must not force every service into one model.

Databases may commonly be shared.

Queue workers are naturally project-scoped.

The module or project configuration determines the appropriate scope.

---

# 32. Background project processes

Projects may declare background commands such as:

```yaml
processes:
  queue:
    command: php artisan queue:work

  scheduler:
    command: php artisan schedule:work
```

These are supervised processes just like infrastructure services.

They receive:

* process identity;
* logs;
* lifecycle state;
* restart policy;
* health information where available.

They must not be implemented as detached shell commands Vaelen subsequently forgets about.

---

# 33. Environment construction

Core owns deterministic construction of process environments.

A managed process should not depend unpredictably on whatever shell happened to launch Vaelen.

Environment construction may include:

```text
Vaelen runtime paths
module paths
project environment
selected runtime
user PATH where appropriate
explicit module variables
```

Core should avoid invoking an interactive shell merely to discover runtime configuration.

This improves reliability across:

* Terminal;
* GUI launch;
* login;
* reboot;
* different user shells.

---

# 34. Shell execution

Core should prefer structured process execution:

```text
executable
arguments[]
environment
workingDirectory
```

over:

```text
/bin/sh -c "arbitrary string"
```

Shell interpretation should be used only where shell semantics are genuinely required.

This reduces:

* quoting bugs;
* injection risk;
* differences between shells;
* environment unpredictability.

Project-defined commands require additional consideration because users may intentionally define shell commands.

Those commands still execute as the normal user.

---

# 35. Logs

Every supervised process has explicit stdout/stderr handling.

Logs should never depend on the process inheriting an open Terminal.

Conceptually:

```text
logs/
├── core/
├── router/
├── php/
│   └── 8.4/
├── mysql/
│   └── default/
└── projects/
    └── <project-id>/
        ├── queue.log
        └── scheduler.log
```

The exact layout may evolve.

Clients should request logs through Core rather than requiring knowledge of filesystem paths.

Therefore:

```bash
val logs mysql
```

and the GUI log viewer use the same underlying source.

---

# 36. Resource metrics

Core may inspect supervised processes and expose:

```text
PID
CPU
memory
uptime
ports
health
```

Resource monitoring must itself remain lightweight.

Vaelen must not create significant constant CPU usage merely to prove that other services are lightweight.

Metrics collection should therefore use sensible intervals and become less active when nobody is observing detailed statistics.

---

# 37. Event-driven clients

Clients should not continuously poll Core for complete state.

Preferred model:

```text
connect
   ↓
request snapshot
   ↓
subscribe to events
   ↓
update local presentation state
```

For example:

```text
InstanceStarted(mysql/default)
HealthChanged(mysql/default, healthy)
ProcessExited(redis/default)
ModuleInstalled(mailpit)
```

This supports an efficient menu bar application.

---

# 38. Core version compatibility

Clients and Core may temporarily have different versions during application updates or restarts.

The IPC protocol should therefore expose protocol/version information.

Example:

```text
client protocol: 1
daemon protocol: 1
```

If incompatible, the client should fail clearly rather than invoke undefined behavior.

The protocol should evolve deliberately.

---

# 39. Single-daemon enforcement

Only one authoritative `vaelend` should operate for a user.

`launchd` should provide most lifecycle guarantees.

Core should additionally protect state-changing resources against accidental duplicate daemon execution where practical.

Two Core instances must never simultaneously believe they own the same module processes or state database.

---

# 40. State storage implementation

The architecture requires persistent structured state but does not yet mandate a specific storage engine.

Possible implementations include:

* SQLite;
* structured files;
* a combination.

The implementation should be selected based on:

* atomicity;
* migration support;
* concurrency;
* inspectability;
* recovery;
* complexity.

This requires a separate implementation decision.

Human-editable project configuration remains separate from internal Core state.

---

# 41. Daemon updates

Updating Vaelen may require replacing `vaelend`.

The update sequence must avoid unnecessarily terminating managed developer services.

Conceptually:

```text
new Vaelen installed
       │
       ▼
old daemon prepares state
       │
       ▼
daemon replaced/restarted
       │
       ▼
new daemon starts
       │
       ▼
reconcile surviving processes
       │
       ▼
resume supervision
```

Whether every process can survive every upgrade is implementation-dependent.

The architecture should nevertheless treat service continuity as desirable.

---

# 42. Shutdown

A normal daemon shutdown must distinguish between:

```text
daemon stopping
```

and:

```text
developer environment stopping
```

These are not equivalent.

Restarting Core for an application update should not necessarily terminate every managed service.

Conversely:

```bash
val stop
```

or another explicit future environment-wide command may intentionally stop managed services.

The intent must be explicit.

---

# 43. Resource honesty

At any moment, Vaelen should be able to answer:

```text
What is running?

Why is it running?

Who started it?

Which module owns it?

Which project needs it?

How much memory is it using?

Which ports does it occupy?

How do I stop it?
```

If Vaelen cannot answer these questions for a process it started, the supervision model is incomplete.

---

# 44. Failure transparency

Vaelen should never silently hide infrastructure failures behind generic UI states.

If MySQL fails because port 3306 is occupied:

```text
MySQL failed to start.

Port 3306 is already used by:
    /opt/homebrew/bin/mysqld
    PID 8912
```

is preferable to:

```text
MySQL could not start.
```

Core should preserve structured failure information so every client can present useful diagnostics.

---

# 45. `val doctor` consumes Core diagnostics

Diagnostics should not be implemented as an unrelated CLI script.

Core exposes diagnostic checks.

The CLI renders them through:

```bash
val doctor
```

The GUI may expose the same checks through a future Diagnostics interface.

This preserves GUI/CLI parity.

---

# 46. No hidden global dependencies

Core must not silently depend on:

```text
Homebrew
system PHP
system nginx
system MySQL
Docker
Podman
```

Vaelen-managed modules use Vaelen-managed packages.

macOS system facilities may naturally be used where appropriate.

External installations may be detected for compatibility/conflict diagnostics but are not considered Vaelen-owned.

---

# 47. Architectural boundaries

The final responsibility boundaries are:

```text
Vaelen.app
    presentation
    user interaction
    notifications

val
    CLI parsing
    human/machine output
    user interaction

vaelend
    authoritative state
    orchestration
    supervision
    reconciliation
    modules
    projects
    health
    diagnostics

Module
    upstream-specific knowledge
    configuration knowledge
    lifecycle description
    health semantics

Driver
    project/framework knowledge

Router Provider
    HTTP/HTTPS routing implementation

Privileged Helper
    narrowly defined root operations

launchd
    lifecycle of Vaelen infrastructure
```

---

# Consequences

## Positive

### Services survive GUI closure

The graphical application is no longer the infrastructure owner.

### CLI and GUI remain consistent

Both invoke the same Core API.

### Processes are observable

Vaelen knows what it launches and why.

### Privilege is minimized

Most of Vaelen runs entirely as the developer.

### Core crashes are recoverable

Persisted state and process reconciliation allow supervision to resume.

### Future automation becomes straightforward

MCP, IDE integrations, scripts, and other clients can consume the same Core model.

### Project orchestration becomes possible

`val up` can reconcile desired state centrally.

### Resource usage remains explainable

The supervisor provides a single view of active infrastructure.

---

# Costs

This model is more complex than making the GUI directly execute shell commands.

It requires:

* IPC;
* daemon lifecycle management;
* state persistence;
* process identity;
* reconciliation;
* concurrency control;
* protocol versioning;
* privilege separation.

That complexity is intentional.

Without it, Vaelen would become a graphical collection of scripts rather than a reliable developer control center.

---

# Alternatives Considered

## GUI owns all processes

Rejected.

Services would become coupled to the graphical application's lifecycle and CLI parity would be difficult.

---

## CLI directly manages processes

Rejected.

Different CLI invocations would need to reconstruct state independently and could race with the GUI.

---

## Run everything through `launchd`

Rejected as the primary abstraction.

`launchd` remains useful for Vaelen infrastructure, but delegating every module instance and project process directly to it would leak macOS service-management details throughout the module architecture and complicate project-scoped dynamic processes.

Vaelen's supervisor should remain authoritative.

Selective use of `launchd` beneath that abstraction may be considered later where technically beneficial.

---

## Run Core as root

Rejected.

The vast majority of developer infrastructure does not require root privileges.

A root Core would dramatically increase Vaelen's attack surface and cause undesirable filesystem ownership behavior.

---

## HTTP Core API

Rejected as the default internal control plane.

A local network listener is unnecessary when macOS provides stronger local IPC mechanisms.

---

## Docker/Podman supervisor

Rejected.

Containerization contradicts Vaelen's native-process architecture and target workflow.

---

# Open Implementation Questions

This ADR deliberately establishes boundaries without prematurely selecting every implementation detail.

The following require focused implementation decisions or prototypes:

1. Whether client-to-Core IPC should use XPC, UNIX domain sockets, or a combination.
2. Exact `launchd` activation strategy for `vaelend`.
3. SQLite versus structured files for Core state.
4. Exact process-adoption identity mechanism.
5. Whether the router can remain entirely user-owned while serving ports 80 and 443.
6. Exact privileged helper installation/update mechanism.
7. Exact runtime directory location for sockets and locks.
8. How service continuity behaves during Vaelen upgrades.
9. How aggressively Core should automatically restart failed services.
10. How process metrics are collected efficiently on macOS.

These questions should be resolved through small prototypes and subsequent ADRs rather than assumptions.

---

# Invariants Established by This ADR

1. There is one authoritative Vaelen Core runtime per user.
2. GUI and CLI are clients of Core.
3. `vaelend` runs as the user.
4. Ordinary developer services run as the user.
5. Root functionality exists only behind a narrow privileged boundary.
6. The privileged helper cannot execute arbitrary commands.
7. Managed services are independent native processes.
8. Core persists enough state to recover after restart.
9. Core verifies process ownership before destructive lifecycle operations.
10. External processes are never automatically treated as Vaelen-owned.
11. Process existence and service health are separate concepts.
12. Long-running operations expose structured progress.
13. Core serializes conflicting mutations.
14. Project orchestration uses desired-state reconciliation.
15. `val down` respects shared dependencies.
16. Clients consume structured Core state rather than independently discovering infrastructure.
17. Internal Core control does not require a localhost HTTP server.
18. Restarting the Vaelen GUI does not imply restarting the developer environment.
19. Restarting Core does not inherently mean terminating managed developer services.
20. Vaelen must always be able to explain the processes it owns.

---

# Summary

Vaelen's runtime is built around one principle:

> **The application is a control surface. The CLI is a control surface. Vaelen Core owns the environment.**

`vaelend` provides the single authoritative model of the developer environment.

Modules describe capabilities.

The supervisor owns native processes.

Projects describe desired state.

The privileged helper performs only narrowly defined system operations.

Clients observe and control this system through one stable Core contract.

This gives Vaelen the foundation required to remain native, modular, observable, lightweight, recoverable, and predictable as the number of supported developer tools grows.

