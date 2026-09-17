# Vaelen Architecture

> The modular, native macOS developer control center.

## 1. Purpose

This document defines the architectural boundaries, terminology, lifecycle rules, security model, filesystem conventions, and public interfaces of Vaelen.

It exists to protect the core principles described in `PHILOSOPHY.md` as the project grows.

Vaelen is not a collection of unrelated developer tools bundled into one application.

Vaelen is a small native macOS platform capable of installing, configuring, running, observing, composing, and removing independent developer modules.

The architecture should make adding the twentieth module fundamentally similar to adding the fifth.

---

# 2. Architectural Principles

## 2.1 macOS is the platform

Vaelen targets macOS only.

It does not attempt to abstract macOS behind cross-platform compatibility layers.

Where appropriate, Vaelen should use native macOS facilities directly:

* Swift
* SwiftUI
* XPC
* `launchd`
* Keychain
* Security framework
* native process APIs
* filesystem events
* UNIX domain sockets
* native notifications
* native networking and system configuration APIs

Supporting Windows or Linux is not an architectural requirement.

Decisions should optimize the macOS experience rather than preserve hypothetical portability.

---

## 2.2 Native processes over containers

Vaelen manages native macOS processes.

PHP, Caddy, MySQL, Redis, Mailpit, Meilisearch, and other services run directly on macOS.

Vaelen does not require:

* Docker
* Podman
* a Linux VM
* Docker Compose
* container images
* container networking
* mounted container volumes

This is not a claim that containers are inferior.

Vaelen exists for developers who prefer native local development on macOS.

---

## 2.3 Core must remain small

Vaelen Core must not accumulate knowledge about every supported developer tool.

Core understands generic concepts such as:

* modules
* packages
* instances
* processes
* projects
* configuration
* dependencies
* health checks
* ports
* sockets
* system capabilities

Core should not contain large collections of special cases such as:

```text
if mysql ...
if redis ...
if mailpit ...
if meilisearch ...
```

Tool-specific behavior belongs to modules.

---

## 2.4 Do not reinvent mature software

Vaelen integrates excellent existing software whenever practical.

Examples include:

* PHP
* Caddy
* MySQL
* PostgreSQL
* Redis
* Mailpit
* Meilisearch
* Typesense
* MinIO
* cloudflared

Vaelen's responsibility is:

```text
discover
    ↓
download
    ↓
verify
    ↓
install
    ↓
configure
    ↓
start
    ↓
observe
    ↓
integrate
    ↓
stop
    ↓
update
    ↓
uninstall
```

The upstream project remains responsible for the underlying functionality.

Vaelen should not fork or obscure upstream software without a compelling technical reason.

---

## 2.5 Installed is not running

These states are fundamentally different.

A module may be:

```text
AVAILABLE
INSTALLED
CONFIGURED
STOPPED
STARTING
RUNNING
DEGRADED
STOPPING
FAILED
```

Installing MySQL does not imply that MySQL must always run.

Stopping MySQL does not uninstall it.

Uninstalling MySQL removes its managed binaries but must not silently destroy user data.

---

## 2.6 Off means off

When a module or instance is stopped, Vaelen should not leave its service process running.

When a module is uninstalled, its executable code should no longer consume runtime resources.

Modules that are not installed should not perform background work merely because Vaelen supports them.

No unnecessary:

* polling
* file watching
* sockets
* processes
* ports
* timers
* memory usage

should exist for unused functionality.

---

## 2.7 CLI and GUI are clients

Neither the graphical application nor the CLI owns Vaelen's business logic.

Both communicate with the same underlying core.

Conceptually:

```text
             ┌───────────────┐
             │  Vaelen.app   │
             │    SwiftUI    │
             └───────┬───────┘
                     │
                     │ IPC
                     │
             ┌───────▼───────┐
             │    vaelend    │
             │               │
             │  Vaelen Core  │
             └───────▲───────┘
                     │
                     │ IPC
                     │
             ┌───────┴───────┐
             │      val      │
             │      CLI      │
             └───────────────┘
```

Clicking:

```text
MySQL → Stop
```

and executing:

```bash
val service stop mysql
```

must invoke the same operation.

---

# 3. Core Domain Model

Vaelen defines the following fundamental concepts.

## 3.1 Module

A **Module** describes a capability Vaelen knows how to provide.

Examples:

```text
php
mysql
redis
mailpit
meilisearch
```

A module contains knowledge about:

* available versions
* package sources
* installation requirements
* configuration
* executable locations
* lifecycle behavior
* health checks
* dependencies
* supported architectures

A module is not necessarily installed.

---

## 3.2 Package

A **Package** is a particular installed version of software belonging to a module.

Examples:

```text
php@8.4.13
php@8.5.0
mysql@8.4.6
redis@8.2.1
mailpit@1.27.7
```

Multiple package versions may coexist.

Packages are immutable after successful installation wherever practical.

Updating a package means installing a new version rather than mutating the old version in place.

---

## 3.3 Instance

An **Instance** is a configured runnable installation of a module package.

For example:

```text
mysql/default
mysql/legacy-client
```

Both could potentially use different MySQL versions, ports, configuration, and data directories.

Therefore:

```text
Module ≠ Package ≠ Instance
```

Example:

```text
Module
    mysql

Packages
    mysql@8.0
    mysql@8.4

Instances
    mysql/default       → mysql@8.4
    mysql/legacy        → mysql@8.0
```

This distinction must remain explicit throughout the architecture.

---

## 3.4 Process

A **Process** is an operating-system process started and owned by Vaelen.

Vaelen records enough information to safely identify and manage every process it launches.

At minimum:

```text
process identifier
executable
arguments
module
instance
project, if applicable
start time
ports
sockets
log locations
restart policy
health state
```

A PID alone is not sufficient process identity because PIDs can be reused.

Vaelen must verify process identity before performing destructive operations.

---

## 3.5 Project

A **Project** is a developer-controlled directory registered with Vaelen.

Example:

```text
~/Code/my-project
```

A project may specify:

* runtime requirements
* domain
* TLS requirements
* services
* background processes
* environment integration
* framework-specific behavior

Projects may be registered through mechanisms such as parking, linking, or explicit initialization.

---

## 3.6 Driver

A **Driver** understands the structure and conventions of a particular type of project.

Examples:

```text
LaravelDriver
WordPressDriver
SymfonyDriver
GenericPHPDriver
StaticDriver
```

Drivers may determine things such as:

* document root
* front controller
* framework type
* useful commands
* default log locations
* framework-specific integrations

Drivers do not install infrastructure.

That is the responsibility of modules.

Therefore:

```text
Module → provides capability
Driver → understands project
```

---

## 3.7 System Capability

A **SystemCapability** represents integration with macOS itself.

Examples:

```text
DNS resolver
trusted local certificate authority
privileged network configuration
shell integration
login item
```

System capabilities are deliberately separate from ordinary modules.

Modules should not independently perform arbitrary privileged system modifications.

---

# 4. High-Level Architecture

```text
                        macOS
                          │
               ┌──────────┴──────────┐
               │                     │
          Vaelen.app                val
           SwiftUI                   CLI
               │                     │
               └──────────┬──────────┘
                          │
                         IPC
                          │
                  ┌───────▼────────┐
                  │    vaelend     │
                  │                │
                  │  Vaelen Core   │
                  └───────┬────────┘
                          │
          ┌───────────────┼────────────────┐
          │               │                │
     Core Platform      Modules         Projects
          │               │                │
     DNS / TLS          PHP             Drivers
     Routing            MySQL           Config
     Registry           Redis           Processes
     Supervisor         Mailpit
     Health             Search
          │
          │ privileged operations only
          ▼
              ┌───────────────────────┐
              │ Privileged Helper     │
              │                       │
              │ narrow XPC interface  │
              └───────────────────────┘
```

---

# 5. Vaelen Core

`vaelend` is the authoritative runtime coordinator.

It should run as the logged-in user.

Its responsibilities include:

### Module Registry

Knows:

* which modules exist
* which modules are installed
* available package versions
* dependencies
* module metadata

### Package Manager

Responsible for generic operations such as:

* downloading
* checksum verification
* signature verification where available
* archive extraction
* atomic installation
* version switching
* package removal

### Instance Registry

Tracks configured service instances.

### Project Registry

Tracks:

* parked directories
* linked projects
* domains
* project configuration
* detected drivers

### Process Supervisor

Owns processes launched by Vaelen.

### Configuration Engine

Builds configuration from:

```text
Vaelen defaults
        ↓
module defaults
        ↓
instance configuration
        ↓
project configuration
        ↓
explicit user overrides
```

### Health Monitor

Determines whether managed processes are actually healthy rather than merely existing.

### Event Bus

Publishes state changes to interested clients.

Examples:

```text
module.installed
module.removed
package.updated
instance.started
instance.stopped
instance.failed
project.added
project.removed
process.crashed
health.changed
```

The GUI should primarily react to these events rather than constantly polling Core.

---

# 6. Module Architecture

Official modules initially ship as part of the Vaelen codebase but conform to a strict common interface.

Dynamic third-party Swift plugins are explicitly not required for the initial architecture.

This avoids unnecessary complexity involving:

* Swift ABI compatibility
* arbitrary code execution
* code signing
* plugin security
* plugin crashes
* version compatibility

The internal architecture should nevertheless avoid assumptions that prevent a future external module format.

Conceptually:

```swift
protocol VaelenModule {
    var identifier: ModuleID { get }
    var metadata: ModuleMetadata { get }

    func availableVersions() async throws -> [ModuleVersion]

    func install(version: ModuleVersion) async throws
    func uninstall(version: ModuleVersion) async throws

    func configure(instance: Instance) async throws

    func start(instance: Instance) async throws
    func stop(instance: Instance) async throws

    func status(instance: Instance) async -> ModuleStatus
    func health(instance: Instance) async -> HealthStatus
}
```

The exact Swift interface may evolve.

The architectural boundary should not.

---

# 7. Core Provides Mechanisms, Modules Provide Knowledge

Modules should not independently implement generic infrastructure.

Core should expose reusable facilities such as:

```text
Downloader
ChecksumVerifier
ArchiveExtractor
ProcessRunner
ProcessSupervisor
PortAllocator
SocketManager
FilesystemManager
ConfigurationRenderer
SecretStore
HealthChecker
ArchitectureResolver
VersionResolver
```

For example, a Mailpit module should describe:

```text
where Mailpit releases are found
which artifact belongs to arm64
which artifact belongs to x86_64
expected checksum
executable name
default SMTP port
default HTTP port
startup arguments
health endpoint
```

It should not contain a custom HTTP downloader, archive extractor, PID tracker, or generic port scanner.

The rule is:

> Modules describe what is required. Core provides the mechanisms to accomplish it.

---

# 8. Platform Services vs Optional Modules

Not every component has identical semantics.

Vaelen therefore distinguishes **platform services** from **optional modules**.

## Platform services

Required to provide Vaelen's fundamental local-development experience.

Examples:

```text
Project Registry
DNS
TLS
Routing
Process Supervisor
Configuration
Module System
```

Caddy may initially be an implementation detail of the routing platform.

The architecture should not unnecessarily expose implementation details as user-facing concepts.

## Optional modules

Capabilities the user explicitly chooses to install.

Examples:

```text
PHP
MySQL
PostgreSQL
Redis
Mailpit
Meilisearch
Typesense
MinIO
Tunnel
```

PHP remains a module because Vaelen should not architecturally assume that every future project requires PHP.

---

# 9. Filesystem Layout

The Vaelen application bundle contains application code only:

```text
/Applications/Vaelen.app
```

Mutable application state must not be stored inside the application bundle.

Primary data resides under:

```text
~/Library/Application Support/Vaelen/
```

Suggested structure:

```text
~/Library/Application Support/Vaelen/
│
├── packages/
│   ├── php/
│   │   ├── 8.3.26/
│   │   ├── 8.4.13/
│   │   └── 8.5.0/
│   │
│   ├── mysql/
│   │   ├── 8.0.43/
│   │   └── 8.4.6/
│   │
│   └── mailpit/
│       └── 1.27.7/
│
├── instances/
│   ├── mysql/
│   │   └── default/
│   │       ├── config/
│   │       ├── data/
│   │       └── logs/
│   │
│   └── redis/
│       └── default/
│
├── projects/
│   └── registry.json
│
├── config/
│   └── vaelen.json
│
├── logs/
│
├── state/
│
└── run/
    ├── sockets/
    ├── locks/
    └── process-state/
```

Caches should use the appropriate macOS cache location:

```text
~/Library/Caches/Vaelen/
```

User secrets should use Keychain whenever appropriate rather than plaintext configuration.

---

# 10. Package Versioning

Multiple versions of packages may coexist.

Example:

```text
packages/php/
├── 8.3.26/
├── 8.4.12/
├── 8.4.13/
└── 8.5.0/
```

Package upgrades should follow approximately:

```text
download new version
        ↓
verify integrity
        ↓
extract into temporary location
        ↓
validate executable
        ↓
atomically install
        ↓
make available
        ↓
switch instances when requested
        ↓
optionally garbage-collect old version
```

An update must not destroy the currently functioning version before the replacement has been validated.

Rollback should remain possible wherever practical.

---

# 11. User Data Is Not Package Data

This distinction is mandatory.

For example:

```text
packages/mysql/8.4.6/
```

contains software.

While:

```text
instances/mysql/default/data/
```

contains user data.

Executing:

```bash
val module uninstall mysql
```

may remove managed MySQL packages.

It must not silently delete database contents.

Destructive removal must require an explicit operation such as a future:

```bash
val module purge mysql
```

with appropriate confirmation.

Upgrading software must never implicitly mean destroying user data.

---

# 12. Project Configuration

Vaelen should eventually support declarative project configuration.

The canonical project file is:

```text
vaelen.yml
```

Example:

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
    command: php artisan queue:work

  scheduler:
    command: php artisan schedule:work
```

The exact schema will evolve separately from this architecture document.

The important architectural concept is:

> Project configuration describes desired state.

Running:

```bash
val up
```

means:

> Reconcile the current machine state with the project's declared desired state.

It does not merely mean:

> Execute a fixed sequence of shell commands.

This distinction enables idempotent project orchestration.

---

# 13. Project Discovery

Vaelen supports two primary project-discovery concepts.

## Parking

A parked directory contains projects.

Example:

```bash
cd ~/Code
val park
```

Directories below it become discoverable as local sites.

## Linking

An individual directory can explicitly become a Vaelen project.

```bash
cd ~/Projects/special-project
val link
```

Vaelen should preserve the simplicity and predictability of the Valet park/link mental model.

---

# 14. Process Supervision

The process supervisor is one of Vaelen's most important components.

Every process started by Vaelen must be attributable to:

```text
module
instance
project, where relevant
```

The supervisor tracks:

```text
PID
process identity
executable
arguments
environment
working directory
start time
ports
sockets
stdout
stderr
restart policy
health state
```

Supported lifecycle states should include:

```text
STOPPED
STARTING
RUNNING
DEGRADED
STOPPING
FAILED
```

A process existing does not necessarily mean a service is healthy.

Modules therefore provide health checks.

Examples:

```text
TCP connection
HTTP endpoint
UNIX socket response
process signal
command execution
```

---

# 15. Resource Observability

Vaelen should make resource usage visible wherever practical.

For running services it may expose:

```text
CPU
memory
PID
ports
uptime
version
health
dependent projects
```

Example:

```text
MYSQL

Status       Running
Version      8.4.6
Memory       127 MB
CPU          0.1%
Port         3306
PID          38194
Uptime       2h 17m

Used by
- project-a.test
- project-b.test
```

This implements the project's principle of resource honesty.

---

# 16. Privilege Boundary

Vaelen follows the principle:

> Run everything as the user unless root privileges are genuinely required.

Normal services should run as the logged-in user.

Examples:

```text
PHP
MySQL
Redis
Mailpit
queues
schedulers
search engines
```

`vaelend` itself should also run as the user.

A separate privileged helper may exist for narrowly scoped system operations.

Conceptually:

```text
Vaelen.app / val
       │
       ▼
    vaelend
       │
       │ authenticated XPC
       ▼
VaelenPrivilegedHelper
```

The privileged helper exposes narrowly defined operations.

Possible examples:

```text
installResolver(...)
removeResolver(...)

installTrustedCA(...)
removeTrustedCA(...)

performSpecificNetworkConfiguration(...)
```

It must never expose a generic interface such as:

```text
runAsRoot(command: String)
```

The privileged helper is not a root shell.

Every privileged operation should:

* be explicit
* validate input
* operate on known resources
* be auditable
* be reversible where possible

The root attack surface should remain extremely small.

---

# 17. DNS

Vaelen owns local-development domain resolution.

The initial default TLD is:

```text
.test
```

The implementation should prefer the smallest macOS integration necessary.

Project routing should not require modifying `/etc/hosts` for every site.

DNS configuration is a platform concern, not the responsibility of individual modules.

---

# 18. TLS

Vaelen should provide trusted local HTTPS with minimal user interaction.

Vaelen may maintain its own local certificate authority.

The private key must be protected appropriately.

Certificate trust installation is a privileged/system operation and therefore belongs behind the privilege boundary.

Individual project certificates should be generated and managed automatically.

A user should normally experience:

```text
val link
```

followed by:

```text
https://project.test
```

without manually managing certificates.

---

# 19. Routing

Routing is a Vaelen platform concern.

A routing implementation such as Caddy may provide:

* HTTP
* HTTPS
* local certificates
* reverse proxying
* FastCGI
* project routing

The rest of Vaelen should depend on a routing abstraction rather than unnecessarily coupling every subsystem to Caddy-specific behavior.

This preserves the ability to change implementation details later without redesigning modules or projects.

---

# 20. IPC

`Vaelen.app`, `val`, and `vaelend` require a stable communication contract.

The transport may use XPC or another appropriate native IPC mechanism.

The contract should support:

```text
commands
queries
events
progress
errors
```

Long-running operations such as:

```text
install PHP
install MySQL
upgrade package
initialize database
```

must expose progress rather than blocking clients without feedback.

The GUI and CLI should receive the same underlying progress information.

---

# 21. CLI Contract

The CLI executable is:

```bash
val
```

CLI semantics should remain predictable.

General convention:

```text
val <noun> <verb> [arguments]
```

where practical.

Core commands may include:

```bash
val status
val ps
val doctor

val park
val link
val unlink
val sites
val open

val module list
val module search
val module install <module>
val module uninstall <module>

val service list
val service start <instance>
val service stop <instance>
val service restart <instance>

val php versions
val php install <version>
val php use <version>

val logs <service>

val up
val down
```

The distinction between modules and services must remain clear:

```text
module install mysql
```

means:

> Install the MySQL capability/software.

While:

```text
service start mysql
```

means:

> Start a configured MySQL instance.

Convenience aliases may exist, but they must map to canonical Core operations.

---

# 22. Machine-Readable CLI

The CLI should be usable by humans and automation.

Commands returning structured information should eventually support:

```bash
val status --json
val ps --json
val sites --json
```

Human-readable formatting belongs to the CLI client.

Core should return structured data.

This also prepares Vaelen for future integrations such as:

* IDEs
* scripts
* automation
* MCP
* coding agents

without coupling Core to those integrations.

---

# 23. `val doctor`

Diagnostics are a first-class architectural feature.

Vaelen should be capable of inspecting its environment and explaining common failures.

Example:

```text
$ val doctor

Vaelen 0.1.0
macOS 26
Apple Silicon

Core
✓ vaelend responding
✓ configuration valid
✓ filesystem permissions valid

Networking
✓ .test resolver installed
✓ router responding
✓ port 80 available
✓ port 443 available

TLS
✓ Vaelen CA installed
✓ Vaelen CA trusted

PHP
✓ PHP 8.4 installed
✓ PHP-FPM running
✓ socket responding

Conflicts
! Another process is listening on port 53
! Herd appears to be running
```

Diagnostics should distinguish between:

```text
healthy
warning
error
```

Automatic repair may eventually be exposed through:

```bash
val doctor --fix
```

Only operations known to be safe should be automatically repaired.

---

# 24. Failure and Recovery

Vaelen must assume processes crash, installations fail, downloads are interrupted, and configuration becomes invalid.

Operations should therefore be designed to be:

* atomic where possible
* idempotent where possible
* recoverable
* observable

Examples:

A failed package download must not create an installed package.

A failed update must not destroy the previous working package.

A crashed service must transition to `FAILED` rather than remain incorrectly represented as running.

An interrupted configuration operation should not leave partially written configuration files where atomic replacement is possible.

---

# 25. Logging

Vaelen should maintain logs for its own infrastructure separately from project logs.

Potential categories include:

```text
core
module installation
process lifecycle
privileged helper
routing
DNS
TLS
```

Logs must not casually expose secrets.

Module configuration containing passwords, tokens, certificates, or environment secrets must be redacted appropriately.

---

# 26. Security

Vaelen runs developer software and therefore has significant access to the local machine.

Security should be treated as part of architecture rather than a later feature.

Rules include:

1. Run services without root privileges whenever possible.
2. Keep privileged operations narrowly scoped.
3. Verify downloaded artifacts.
4. Prefer HTTPS for package retrieval.
5. Validate checksums/signatures when upstream provides them.
6. Never execute arbitrary remote module code merely to discover metadata.
7. Protect secrets with appropriate macOS facilities.
8. Validate process identity before terminating processes.
9. Avoid shell interpolation where structured process execution is possible.
10. Treat third-party/community modules as a future security boundary requiring separate design.

---

# 27. Uninstallation

Vaelen must be capable of explaining what it owns.

A full uninstall should be able to identify:

```text
application
daemon
privileged helper
packages
configuration
runtime state
system resolver configuration
trusted certificates
shell integration
```

User-created project directories must never be treated as Vaelen-owned data.

Database/service data requires explicit handling because deletion may be destructive.

The user should be able to remove Vaelen without wondering what invisible system modifications remain behind.

---

# 28. Future Community Modules

Community modules are a desired future capability, not an initial implementation requirement.

Core should avoid architectural decisions that make them impossible.

However, external modules introduce major concerns:

* trust
* arbitrary code execution
* signatures
* sandboxing
* compatibility
* distribution
* updates
* malicious modules
* dependency conflicts

Therefore the initial implementation should prioritize official modules with a stable internal protocol.

A future external module system should preferably be declarative where possible rather than granting arbitrary native code execution.

This requires its own future design document.

---

# 29. Future AI and MCP Integration

AI integration is not part of Vaelen Core.

Core should nevertheless expose structured operations and state so future integrations can safely consume them.

A future MCP layer could expose capabilities such as:

```text
list projects
inspect project
inspect logs
inspect service health
restart service
run framework command
run migration
inspect route
```

MCP should be a client of Core.

Core must never become dependent on MCP.

Architecture:

```text
Claude / Cursor / Agent
          │
          ▼
       Vaelen MCP
          │
          ▼
       Vaelen Core
```

not:

```text
Vaelen Core → AI-specific architecture
```

---

# 30. Explicit Non-Goals

Vaelen Core is not:

* a Docker replacement
* a VM manager
* a Linux compatibility layer
* a cloud platform
* a package manager for the entire operating system
* an IDE
* a replacement for mature upstream databases or runtimes
* a generic root command executor
* a framework-specific Laravel application
* a requirement that every supported service always runs

Vaelen may integrate tools from some of these categories without becoming them.

---

# 31. Architectural Decision Test

Before adding a new subsystem or capability, ask:

### Does this belong in Core?

Core should contain it only if multiple modules/projects require the capability generically.

### Does this belong in a Module?

Use a module when the functionality represents independently installable developer capability.

### Does this belong in a Driver?

Use a driver when the functionality exists to understand a project/framework.

### Does this require privilege?

If it can safely run as the user, it must run as the user.

### Does Vaelen need to implement it?

If mature upstream software already solves the underlying problem, prefer integration.

### What happens when it is disabled?

The answer should be measurable.

### What happens when it is uninstalled?

Its executable/runtime footprint should disappear.

### What user data does it own?

Software and user data must remain distinct.

### Can Core remain unaware of its implementation details?

If not, reconsider the abstraction.

---

# 32. Architectural Invariants

The following are invariants of Vaelen.

Future implementation decisions must preserve them unless an explicit architectural decision supersedes this document.

### Invariant 1

Vaelen does not require Docker, Podman, or a VM.

### Invariant 2

Vaelen-managed developer services run natively on macOS.

### Invariant 3

Unused optional modules must not consume background runtime resources.

### Invariant 4

GUI and CLI invoke the same Core operations.

### Invariant 5

Vaelen Core does not contain service-specific business logic that properly belongs in modules.

### Invariant 6

Vaelen never silently destroys user service data during package removal or upgrades.

### Invariant 7

Ordinary services do not run as root.

### Invariant 8

The privileged helper never exposes arbitrary command execution.

### Invariant 9

Package versions may coexist.

### Invariant 10

Processes launched by Vaelen remain attributable and observable.

### Invariant 11

Vaelen owns the software it manages rather than depending on globally mutable Homebrew installations.

### Invariant 12

Projects describe desired state; Vaelen reconciles that state.

### Invariant 13

Upstream software remains replaceable implementation beneath stable Vaelen abstractions.

### Invariant 14

The macOS experience takes precedence over cross-platform portability.

### Invariant 15

The architecture must allow Vaelen to remain useful even when only a minimal subset of modules is installed.

---

# 33. Initial Implementation Boundary

The first implementation should prove the architecture rather than the eventual feature set.

A reasonable initial boundary is:

```text
Vaelen Core

Module Registry
Package Manager
Process Supervisor
Project Registry
IPC
Diagnostics

Platform

DNS
TLS
Routing

Modules

PHP

Project support

park
link
unlink
.test routing
per-project PHP selection
```

This is sufficient to answer the first important question:

> Can Vaelen replace the basic native PHP development environment on the author's own Mac while preserving the architecture described here?

Only after this foundation proves reliable should additional modules such as Mailpit, Redis, and MySQL be used to validate the generic module architecture.

---

# 34. Long-Term Architectural Goal

Vaelen should eventually make this possible:

```bash
git clone git@github.com:example/project.git
cd project

val up
```

Vaelen reads the project's desired state.

It determines what is missing.

It installs only what is required.

It configures each component.

It starts only what the project needs.

It establishes DNS and HTTPS.

It supervises every process.

It exposes their health and resource usage.

And when the developer is finished:

```bash
val down
```

the project-specific runtime disappears.

No containers.

No VM.

No unnecessary background services.

No hidden processes.

Just native macOS development infrastructure managed as one coherent system.

That is Vaelen.

