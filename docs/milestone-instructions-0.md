You are working on **Vaelen**, an open-source, native macOS developer control center.

Your task is to implement **Milestone 0 only: the foundational Core/daemon/CLI/menu-bar application skeleton**.

Do not attempt to build the complete product.

Before writing or modifying any code, you MUST study the project's architecture documentation.

# 1. Read the documentation first

Read these files completely:

```text
docs/PHILOSOPHY.md
docs/ARCHITECTURE.md

docs/adr/0001-core-runtime-model.md
docs/adr/0002-routing-provider.md
docs/adr/0003-package-and-module-system.md
docs/adr/0004-filesystem-state-and-ownership.md
docs/adr/0005-ipc-and-client-protocol.md
docs/adr/0006-privilege-dns-and-tls.md
docs/adr/0007-php-runtime-architecture.md
docs/adr/0008-project-model-and-desired-state-reconciliation.md
```

Treat these documents as the architectural source of truth.

Pay particular attention to:

* Core owns authoritative runtime state.
* `Vaelen.app` is a client.
* `val` is a client.
* `vaelend` is the authoritative per-user Core process.
* GUI and CLI must use the same Core semantics.
* Core must not depend on SwiftUI.
* Core must not contain presentation logic.
* Core must remain small and generic.
* IPC protocol semantics must remain independent from transport.
* Ordinary Core clients are intended to use per-user UNIX domain socket IPC.
* The privileged helper is separate and MUST NOT be implemented yet.
* Native macOS processes are preferred.
* No Docker.
* No Electron.
* No Homebrew dependency for Vaelen-managed infrastructure.
* No arbitrary shell architecture.
* Installed does not mean running.
* Off means off.
* User and filesystem ownership must remain explicit.
* Do not add PHP, Caddy, DNS, TLS, MySQL, Redis, Mailpit, modules, project drivers, or reconciliation yet.

If implementation details in this prompt conflict with an ADR, the ADR wins.

If two ADRs appear to conflict, stop and explain the conflict before making a structural decision.

---

# 2. Understand the goal

This is **Milestone 0**, not Vaelen v0.1.

We are proving this architecture:

```text
Vaelen.app ──┐
             │
             ├── Core protocol ──► vaelend
             │
val ─────────┘
```

At the end of this milestone:

1. A native macOS Vaelen menu-bar application launches.
2. A `vaelend` executable exists and acts as the authoritative Core process.
3. A `val` CLI executable exists.
4. `val` can communicate with `vaelend`.
5. `Vaelen.app` can communicate with `vaelend`.
6. Both clients obtain the same authoritative Core status.
7. IPC is structured and versioned.
8. The basic architecture is covered by tests.
9. Nothing beyond this foundation is prematurely implemented.

The milestone should be deliberately boring.

That is a feature, not a problem.

---

# 3. First inspect the repository

Before changing anything:

1. Inspect the complete repository tree.
2. Determine whether an Xcode project, Swift package, source directories, tests, or existing implementation already exist.
3. Read existing Swift/package/project configuration before replacing anything.
4. Preserve useful existing work.
5. Do not blindly regenerate the repository if it already contains structure.

Then briefly state the implementation plan before editing.

Do not ask me questions that can be answered by inspecting the repository or the architecture documents.

---

# 4. Technical direction

Use:

* Swift
* Swift Package Manager for reusable/core components
* SwiftUI for the macOS app
* native macOS APIs
* Swift structured concurrency where appropriate
* XCTest or the appropriate native Swift testing mechanism already established by the project

Avoid unnecessary third-party dependencies.

For Milestone 0, prefer Foundation/macOS-native functionality.

Do not introduce a dependency merely to avoid writing a small amount of straightforward Swift.

---

# 5. Desired logical structure

Use this as guidance, but inspect the repository first and adapt it cleanly rather than mechanically forcing paths:

```text
Vaelen/
├── docs/
│   ├── PHILOSOPHY.md
│   ├── ARCHITECTURE.md
│   └── adr/
│
├── Package.swift
│
├── Sources/
│   ├── VaelenCore/
│   ├── VaelenIPC/
│   ├── VaelenCLI/
│   └── VaelenDaemon/
│
├── Tests/
│   ├── VaelenCoreTests/
│   └── VaelenIPCTests/
│
└── App/
    └── Vaelen/
```

The important part is not the exact directory spelling.

The important part is the dependency boundary.

---

# 6. Dependency rules

The architecture should approximately follow:

```text
Vaelen.app
    │
    └── VaelenIPC client

VaelenCLI
    │
    └── VaelenIPC client

VaelenDaemon
    │
    ├── VaelenIPC server
    └── VaelenCore

VaelenIPC
    │
    └── shared protocol models

VaelenCore
    │
    └── Foundation / generic domain logic
```

Enforce these rules:

### VaelenCore MUST NOT depend on:

* SwiftUI
* Vaelen.app
* VaelenCLI
* presentation code

### VaelenIPC MUST NOT contain:

* PHP knowledge
* Caddy knowledge
* Laravel knowledge
* WordPress knowledge
* module-specific lifecycle logic

### VaelenCLI MUST NOT:

* directly manage infrastructure
* directly manipulate daemon state files as its normal execution path
* become a second Core implementation

### Vaelen.app MUST NOT:

* directly start/kill infrastructure processes
* directly mutate Core state
* duplicate Core business logic

### VaelenDaemon

is the process hosting authoritative Core state.

---

# 7. Implement the smallest Core model

For Milestone 0, Core only needs enough state to prove ownership.

Create a small status model representing something conceptually equivalent to:

```text
Vaelen Core

state: running
version: 0.0.1-dev
pid: <actual daemon PID>
protocolVersion: 1
```

Use typed Swift models.

Do not represent the status internally as formatted strings.

For example, conceptually:

```swift
struct CoreStatus: Codable, Sendable {
    let state: CoreState
    let version: String
    let pid: Int32
    let protocolVersion: Int
}
```

This is illustrative.

Choose correct Swift types and naming based on the codebase.

The Core owns this information.

Clients request it.

---

# 8. Define protocol version 1

Implement the smallest useful structured IPC protocol.

Milestone 0 only needs something equivalent to:

```text
core.handshake
core.status
```

Do NOT create dozens of speculative methods for future modules.

The protocol should already support:

* request IDs
* structured requests
* structured responses
* structured errors
* protocol version
* client identity/version during handshake

Use JSON as established in ADR-0005.

Use explicit stream message framing.

Do NOT assume:

```text
one socket read == one complete JSON message
```

Implement a deterministic framing mechanism, preferably a length-prefixed frame as described by ADR-0005.

---

# 9. Keep protocol semantics separate from transport

Do not make Core operations themselves socket-specific.

There should be a conceptual separation similar to:

```text
Core protocol
     │
     ▼
transport
```

The client should communicate through an abstraction that allows a test transport.

For example, conceptually:

```swift
protocol CoreTransport {
    func connect() async throws
    func send(...)
    func receive(...) async throws -> ...
    func disconnect() async
}
```

Do not copy this blindly if a better Swift design exists.

The architectural property matters more than matching the pseudocode.

---

# 10. Implement UNIX domain socket transport

For production Milestone 0 IPC, implement a local per-user UNIX domain socket.

Do not use:

* localhost HTTP
* REST
* WebSocket
* gRPC
* TCP control port

The socket should live in an appropriate Vaelen runtime location consistent with ADR-0004.

Use a centralized filesystem/path abstraction rather than scattering hard-coded paths.

For example, there should be one authoritative place that determines Vaelen paths.

Do not duplicate:

```text
~/Library/Application Support/Vaelen/...
```

strings throughout the codebase.

---

# 11. Runtime directory

The daemon should ensure its required user-level runtime directories exist safely.

Follow ADR-0004.

Do not:

* create root-owned files
* write mutable state into the application bundle
* use arbitrary `/tmp/vaelen` paths without ownership reasoning
* follow unsafe symlinks during cleanup

Milestone 0 only needs what IPC actually requires.

Do not create the complete future filesystem hierarchy just because it exists in the ADR.

---

# 12. Socket lifecycle

The daemon owns the Core socket.

Handle:

* socket creation
* restrictive user-level permissions
* clean shutdown
* stale socket detection
* stale socket cleanup only when safe
* failure when another valid daemon already owns the endpoint

Do not simply delete an existing socket path every time the daemon starts.

We have a single-daemon invariant.

---

# 13. Single daemon

Milestone 0 should prevent two independent `vaelend` processes from believing they are authoritative simultaneously.

Implement the smallest robust mechanism appropriate for the current architecture.

Do not overengineer distributed locking.

This is one Mac and one user.

But do not ignore the problem.

---

# 14. Daemon process

Create the `vaelend` executable.

Its responsibilities for this milestone are only:

1. initialize Core;
2. establish the local IPC server;
3. accept authenticated/user-scoped local clients as reasonably possible at this stage;
4. perform protocol handshake;
5. answer `core.status`;
6. shut down cleanly.

Do not implement:

* PHP
* modules
* package downloads
* Caddy
* routing
* DNS
* TLS
* project registry
* reconciliation
* process supervisor beyond what is strictly required for the daemon itself

We will build those later.

---

# 15. launchd

ADR-0001 specifies that `vaelend` ultimately runs as a per-user LaunchAgent managed by `launchd`.

For Milestone 0:

* structure the daemon so this is possible;
* if cleanly feasible, add the minimal LaunchAgent integration required for local development;
* do not build a privileged installer;
* do not create a large service-management framework.

If LaunchAgent installation would materially complicate this first slice, keep daemon execution developer-friendly and document the exact remaining step.

Do not fake successful launchd integration.

---

# 16. Shared client

Implement one reusable Core client.

Both:

```text
val
```

and:

```text
Vaelen.app
```

must use it.

Do not implement two separate socket clients.

The shared client should handle:

* connection
* handshake
* protocol compatibility
* request IDs
* request/response encoding
* framing
* disconnect
* structured errors

Keep reconnect logic minimal for now.

---

# 17. CLI

Create the `val` executable.

For Milestone 0, implement:

```bash
val status
```

Human output should be approximately:

```text
Vaelen

Core       Running
Version    0.0.1-dev
PID        41832
Protocol   1
```

Use the actual daemon PID.

Do not hard-code status.

---

# 18. JSON CLI output

Also implement:

```bash
val status --json
```

It must render structured Core data directly.

Example shape:

```json
{
  "core": {
    "state": "running",
    "version": "0.0.1-dev",
    "pid": 41832,
    "protocolVersion": 1
  }
}
```

Do not generate JSON by parsing human terminal output.

Human and JSON output must originate from the same typed Core response.

---

# 19. CLI failure behavior

If Core is unavailable:

```bash
val status
```

should fail clearly.

Something like:

```text
Vaelen Core is not running.
```

is sufficient.

Do not print a giant Swift stack trace for expected connection failures.

Use non-zero exit status for command failure.

Keep diagnostic detail available where useful.

---

# 20. Native menu-bar app

Create the smallest native SwiftUI macOS application.

Use the appropriate native menu-bar application API for the supported macOS target.

The initial UI should be intentionally minimal.

Conceptually:

```text
Vaelen

● Core Running

Version 0.0.1-dev
PID 41832
```

If Core is unavailable:

```text
Vaelen

○ Core Unavailable
```

Do not build:

* dashboards
* module cards
* project screens
* settings architecture
* animations
* onboarding
* custom design system
* resource charts

yet.

We are proving the boundary, not designing the product.

---

# 21. GUI state

The GUI obtains Core state through the shared Core client.

Do not:

* inspect daemon processes directly from SwiftUI
* hard-code `running`
* read Core internal state files
* spawn `val status` and parse its output

The GUI is a first-class Core client.

---

# 22. Presentation separation

Keep SwiftUI-specific state adapters/view models in the app target.

Do not import SwiftUI into VaelenCore.

The flow should look roughly like:

```text
SwiftUI
   │
   ▼
App model / view model
   │
   ▼
VaelenCoreClient
   │
   ▼
IPC
   │
   ▼
vaelend
```

---

# 23. Protocol mismatch

Implement basic protocol compatibility handling now.

If client protocol and daemon protocol are incompatible, produce a structured protocol error.

CLI should render something understandable such as:

```text
Vaelen Core uses an incompatible protocol version.

Client: 1
Core:   2
```

Do not silently continue.

---

# 24. Structured errors

Create a small error model.

Only add errors actually needed by Milestone 0.

Potential examples:

```text
CORE_UNAVAILABLE
PROTOCOL_INCOMPATIBLE
INVALID_REQUEST
INTERNAL_ERROR
```

Do not predefine the entire future Vaelen error taxonomy yet.

---

# 25. Logging

Add minimal useful daemon logging.

Logs should help diagnose:

* daemon startup
* socket startup
* client connection
* protocol failure
* clean shutdown
* unexpected server errors

Follow the filesystem ownership model from ADR-0004.

Do not introduce a large logging framework unless genuinely necessary.

Never log arbitrary future secrets.

---

# 26. Testing

Testing is part of Milestone 0.

At minimum, cover:

### Protocol encoding/decoding

A request survives encode/decode correctly.

### Framing

Multiple framed messages can be decoded correctly even when stream reads split data at arbitrary boundaries.

This is important.

Do not only test the happy case where one read equals one frame.

### Core status

Core returns typed authoritative status.

### Protocol compatibility

Compatible handshake succeeds.

Incompatible protocol fails predictably.

### Shared client

The Core client can communicate through a test/in-memory transport.

### Real IPC

Where practical, add an integration test using a temporary UNIX socket and actual client/server communication.

### Single-daemon/stale socket behavior

Test the safe cases that can reasonably be isolated.

---

# 27. Testability rule

Do not design IPC in a way that requires launching the entire GUI just to test it.

The important pieces should be testable from Swift Package tests.

---

# 28. Concurrency

Use Swift concurrency deliberately.

Avoid:

* uncontrolled detached tasks
* shared mutable global state
* blocking the SwiftUI main actor with socket I/O
* callback pyramids where async/await is appropriate

Do not create an elaborate actor hierarchy merely because actors exist.

Use isolation where there is actual mutable state.

---

# 29. No global singleton architecture

Avoid turning Core into:

```swift
Vaelen.shared
```

with global mutable state accessed everywhere.

Dependencies should be explicit enough to test and reason about.

---

# 30. No speculative abstractions

This is extremely important.

Do NOT create empty protocols/types for:

```text
MySQL
Redis
Mailpit
PHP
Caddy
ProjectDriver
ModuleRegistry
PackageManager
ReconciliationEngine
PrivilegedHelper
MCP
Cloudflare
```

just because the ADRs mention them.

Create abstractions when Milestone 0 actually needs them.

We want architectural boundaries, not hundreds of empty future-facing files.

---

# 31. Do not implement the privileged helper

ADR-0006 defines it.

Milestone 0 does not need it.

Therefore it must not exist yet.

Do not:

* request administrator authorization
* use sudo
* modify `/etc`
* modify Keychain trust
* configure DNS
* bind privileged ports

---

# 32. Do not implement routing

ADR-0002 selected Caddy as the initial Router provider.

Ignore it for this milestone.

Do not download Caddy.

Do not create Caddy configuration.

Do not create placeholder `CaddyManager` code.

---

# 33. Do not implement PHP

ADR-0007 defines PHP architecture.

Ignore it for this milestone.

Do not download PHP.

Do not inspect system PHP.

Do not create PHP-specific Core types.

---

# 34. Do not implement project management

ADR-0008 defines the project model.

Ignore it for this milestone.

Do not implement:

```text
val park
val link
val up
```

yet.

Only:

```text
val status
```

is required.

---

# 35. Code quality

Prefer:

* small focused types
* explicit ownership
* clear naming
* typed errors
* deterministic behavior
* comments explaining non-obvious architectural reasons

Avoid comments that merely repeat code.

Avoid giant files.

Avoid premature framework-building.

---

# 36. Build frequently

Do not make the entire implementation and only then attempt to compile.

Work incrementally.

Suggested sequence:

### Step 1

Establish Swift package/targets and ensure they build.

### Step 2

Implement Core status model and tests.

### Step 3

Implement protocol models and serialization tests.

### Step 4

Implement framing and adversarial framing tests.

### Step 5

Implement transport abstraction and in-memory test transport.

### Step 6

Implement UNIX domain socket transport/server.

### Step 7

Implement `vaelend`.

### Step 8

Implement shared Core client.

### Step 9

Implement:

```bash
val status
```

and:

```bash
val status --json
```

### Step 10

Implement minimal SwiftUI menu-bar client.

### Step 11

Run full test suite.

### Step 12

Perform manual end-to-end validation.

Do not move to the next major step while the current code does not compile.

---

# 37. Manual acceptance test

At completion, demonstrate this exact flow.

Start Core using the supported development mechanism.

Then:

```bash
val status
```

must report the real daemon.

Then:

```bash
val status --json
```

must return valid machine-readable JSON.

Then launch Vaelen.app.

The app must display the same Core version/PID/protocol state.

Verify:

```text
CLI PID == GUI PID == actual vaelend PID
```

That proves both clients are talking to the same authoritative process.

---

# 38. Daemon failure acceptance test

While the app is open:

1. stop `vaelend`;
2. verify the app transitions to unavailable rather than continuing to display stale "running" state;
3. run `val status`;
4. verify it fails clearly.

Then restart the daemon and verify clients can communicate again.

Do not fake liveness from cached state.

---

# 39. Multiple-client acceptance test

Connect:

* Vaelen.app
* one or more `val status` invocations

to the same daemon.

The daemon must safely support multiple clients.

---

# 40. Inspect the resulting process model

At completion, verify that the process tree is conceptually:

```text
Vaelen.app

vaelend

val
  ↳ short-lived when command runs
```

There should be no:

* hidden web server
* Node process
* Electron process
* Docker process
* helper daemon
* PHP process
* Caddy process

from Vaelen Milestone 0.

---

# 41. Resource honesty

At idle after closing the GUI, only the infrastructure intentionally required by the current development setup should remain.

Do not introduce polling loops that constantly wake the machine unnecessarily.

The menu-bar app may refresh/reconnect reasonably, but avoid aggressive polling.

Prefer event/connection state where practical.

---

# 42. Documentation during implementation

Do not rewrite the ADRs to match your implementation.

If you discover that an ADR assumption is technically wrong or materially impractical:

1. stop before implementing a contradictory architecture;
2. document:

   * the ADR assumption;
   * what macOS/Swift behavior contradicts it;
   * available alternatives;
   * your recommended change;
3. wait for architectural approval if the change is significant.

Minor implementation details left explicitly open by ADRs may be decided normally.

---

# 43. README

If the repository README is empty or missing, create only a minimal developer-oriented README for Milestone 0.

It may include:

* what Vaelen is;
* current development status;
* build requirements;
* how to build;
* how to run `vaelend`;
* how to run `val status`;
* how to launch the app;
* how to run tests.

Do not write marketing claims for features that do not exist.

---

# 44. Do not fake completion

If something cannot yet work because of:

* Xcode configuration
* signing
* LaunchAgent behavior
* macOS API constraints
* SwiftPM limitation
* UNIX socket API issue

do not hide it behind mocks in production code.

Mocks are appropriate for tests.

Production Milestone 0 should represent what actually works.

---

# 45. Completion report

When finished, provide a concise engineering report containing:

## Implemented

What actually works.

## Architecture

Final target/package dependency structure.

## Tests

Tests added and their result.

## Manual verification

Commands executed and observed results.

## Files

Important files created or changed.

## Decisions

Implementation details you had to choose where ADRs intentionally left the answer open.

## ADR concerns

Any assumption from the architecture documents that implementation evidence suggests we should revisit.

## Deferred

Everything intentionally not implemented because it belongs to later milestones.

Do not say "done" unless the project builds and the acceptance path has actually been tested.

---

# Definition of Done

Milestone 0 is complete only when all of these are true:

```text
[ ] VaelenCore exists and has no UI dependency
[ ] VaelenIPC exists
[ ] IPC protocol version 1 exists
[ ] IPC uses structured messages
[ ] IPC uses deterministic stream framing
[ ] UNIX domain socket transport works
[ ] vaelend exists
[ ] only one authoritative daemon can own the endpoint
[ ] shared Core client exists
[ ] val exists
[ ] val status works
[ ] val status --json works
[ ] native Vaelen menu-bar app exists
[ ] app gets status from vaelend
[ ] CLI gets status from vaelend
[ ] GUI and CLI report the same daemon PID
[ ] protocol mismatch is handled
[ ] Core-unavailable state is handled
[ ] multiple clients work
[ ] protocol/framing/Core tests pass
[ ] real IPC has been integration-tested where feasible
[ ] no privileged helper was added
[ ] no PHP was added
[ ] no Caddy was added
[ ] no DNS/TLS was added
[ ] no project system was added
[ ] no Docker dependency exists
[ ] no Electron dependency exists
[ ] no unnecessary third-party dependency exists
[ ] repository builds cleanly
[ ] test suite passes
```

Stop at that point.

Do **not** continue automatically into Milestone 1.

The purpose of this implementation is to establish a trustworthy skeleton on which the rest of Vaelen can be built.
