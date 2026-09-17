# ADR-0005: IPC and Client Protocol

* **Status:** Proposed
* **Date:** 2026-09-17
* **Decision owners:** Vaelen maintainers

## Context

ADR-0001 established that:

* `vaelend` is the authoritative Vaelen Core;
* `Vaelen.app` is a client;
* `val` is a client;
* GUI and CLI must invoke the same Core operations;
* the privileged helper is separate from Core;
* future clients such as MCP or IDE integrations should consume the same underlying Core model.

Vaelen therefore requires a reliable local communication architecture.

The communication system must support:

* commands;
* queries;
* events;
* long-running operation progress;
* concurrent clients;
* reconnects;
* protocol versioning;
* authentication;
* structured errors;
* machine-readable output;
* future client types.

At the same time, Vaelen should use native macOS facilities where they provide a meaningful advantage.

---

# Decision

Vaelen will separate its **Core protocol** from its **transport**.

The initial architecture will use:

```text id="5tzgko"
Vaelen.app
     │
     │
     ▼
 Core Client
     │
     │
     ▼
Local IPC Transport
     │
     ▼
  vaelend
```

and:

```text id="eq7b4d"
val
 │
 ▼
Core Client
 │
 ▼
Local IPC Transport
 │
 ▼
vaelend
```

The Core protocol is transport-independent.

The preferred initial transport for ordinary Core clients is a **per-user UNIX domain socket**.

XPC will be used where macOS security and service-management semantics provide clear advantages, particularly communication with the privileged helper.

Conceptually:

```text id="58fgj6"
                    Vaelen.app
                        │
                        │
                       UDS
                        │
                        ▼
                      vaelend
                        ▲
                        │
                       UDS
                        │
                       val


                      vaelend
                        │
                        │ authenticated XPC
                        ▼
             VaelenPrivilegedHelper
```

This is intentionally a hybrid architecture.

---

# 1. Protocol and transport are different concepts

Core must not define operations in terms of:

```text id="qvq9pv"
socket messages
```

or:

```text id="0m3apc"
XPC methods
```

The Core protocol defines semantic operations.

Examples:

```text id="i66yht"
GetStatus

ListModules

InstallModule

StartInstance

StopInstance

LinkProject

ReconcileProject

SubscribeEvents
```

Transport determines how those operations move between processes.

This allows transport implementation to evolve without redesigning Vaelen Core.

---

# 2. Why UNIX domain sockets for Core clients

A UNIX domain socket provides several properties well suited to Vaelen:

* local-machine only;
* no TCP port;
* straightforward CLI access;
* filesystem permissions;
* efficient bidirectional communication;
* language independence;
* support for multiple simultaneous clients;
* future compatibility with external developer tooling.

Conceptually:

```text id="r7tyi5"
~/Library/Application Support/Vaelen/runtime/sockets/core.sock
```

The exact location remains implementation-dependent.

The socket is user-scoped.

It must not be world-writable.

---

# 3. Why not XPC everywhere

XPC is an excellent native macOS mechanism.

However, making the entire Vaelen Core API depend directly on XPC would unnecessarily couple the public local client architecture to Apple-specific XPC interfaces.

Vaelen itself is intentionally macOS-only, so portability is not the concern.

The concern is **client simplicity and protocol independence**.

Future clients may include:

```text id="vjjcq8"
val
MCP server
IDE plugin
automation
debugging tools
scripts
```

A local socket with a documented structured protocol is easier for such tools to consume without embedding Vaelen-specific native frameworks.

Therefore:

> Native macOS implementation does not require every internal boundary to use the most Apple-specific IPC mechanism available.

Use the mechanism that best fits each boundary.

---

# 4. Why XPC for privileged communication

The privileged helper is fundamentally different.

Communication with it crosses a security boundary:

```text id="a7n8pk"
normal user
     │
     ▼
privileged process
     │
     ▼
root operations
```

This boundary benefits from native macOS service identity, code-signing integration, and authenticated IPC semantics.

Therefore:

```text id="9z9pc4"
vaelend
   │
   │ XPC
   ▼
Privileged Helper
```

is preferred.

The privileged helper API remains narrow regardless of transport.

---

# 5. GUI and CLI use the same client library

Vaelen should provide an internal shared Core client implementation.

Conceptually:

```text id="uxw6a9"
             VaelenCoreClient
                  │
          ┌───────┴───────┐
          │               │
     Vaelen.app           val
```

This library understands:

* connection establishment;
* protocol negotiation;
* request IDs;
* encoding;
* decoding;
* errors;
* progress;
* events;
* reconnect behavior.

The GUI and CLI should not independently implement the protocol.

---

# 6. The protocol is structured

The Core protocol must not consist of arbitrary shell command strings.

Bad:

```text id="88mwp9"
"start mysql"
```

Preferred conceptual request:

```json id="scf4pb"
{
  "id": "request-123",
  "method": "instance.start",
  "params": {
    "instance": "mysql/default"
  }
}
```

The exact serialization format may differ.

The important property is structured semantics.

---

# 7. Initial serialization

JSON is the preferred initial serialization format.

Reasons:

* human-readable;
* easy to debug;
* mature Swift support;
* language-independent;
* suitable for future tooling;
* sufficient performance for Vaelen's control-plane traffic.

Vaelen is not streaming video or high-frequency financial data.

The IPC workload is primarily:

```text id="6k5duv"
commands
state
events
progress
diagnostics
```

Binary serialization is unnecessary initially.

The protocol abstraction should not make JSON impossible to replace later if a real need appears.

---

# 8. Message framing

Because the transport is stream-oriented, messages require explicit framing.

Vaelen must not assume:

```text id="bjzfn3"
one socket read == one message
```

Potential framing approaches include:

```text id="0dhblq"
length-prefixed messages
```

or another deterministic framed protocol.

Newline-delimited JSON is attractive for debugging but becomes awkward if payload assumptions change.

The implementation should favor robust framing.

Preferred conceptual format:

```text id="qkhdmx"
[4/8 byte length][JSON payload]
[4/8 byte length][JSON payload]
...
```

Exact integer size and byte order are implementation details.

---

# 9. Request identity

Every request receives a unique identifier.

Example:

```json id="aqnzz5"
{
  "id": "01K...",
  "method": "module.install",
  "params": {
    "module": "php",
    "version": "8.4"
  }
}
```

Responses reference the same identifier.

This allows multiple requests to be in flight simultaneously.

---

# 10. Response model

Successful requests return structured results.

Conceptually:

```json id="vlq3mp"
{
  "id": "01K...",
  "result": {
    "state": "running"
  }
}
```

Failures return structured errors.

Conceptually:

```json id="yuvbdc"
{
  "id": "01K...",
  "error": {
    "code": "PORT_IN_USE",
    "message": "Port 3306 is already in use.",
    "details": {
      "port": 3306,
      "pid": 8124
    }
  }
}
```

Clients should not need to parse human-readable strings to understand errors.

---

# 11. Human messages are presentation

Core may provide a useful fallback message.

However:

```text id="g0o0dd"
PORT_IN_USE
```

is the machine-readable meaning.

The CLI can render:

```text id="jpeueu"
MySQL could not start because port 3306 is already in use.
```

The GUI can render a native error interface.

Future automation can inspect:

```text id="k4h0rx"
error.code
```

All consume the same Core result.

---

# 12. Error taxonomy

Core should define stable error categories.

Examples:

```text id="rxkry4"
MODULE_NOT_FOUND

PACKAGE_NOT_INSTALLED

INSTANCE_NOT_FOUND

INSTANCE_ALREADY_RUNNING

PORT_IN_USE

PERMISSION_REQUIRED

DOWNLOAD_FAILED

VERIFICATION_FAILED

CONFIGURATION_INVALID

PROCESS_FAILED

HEALTH_CHECK_FAILED

DEPENDENCY_FAILED

PROTOCOL_INCOMPATIBLE

OPERATION_CONFLICT

PROJECT_NOT_FOUND

UNSAFE_DELETION
```

Module-specific details may accompany generic categories.

---

# 13. Long-running operations

Some requests complete immediately.

Example:

```text id="nnuvpa"
status
```

Others may take minutes:

```text id="xcn0hj"
install PHP
install MySQL
initialize database
val up
```

Long-running operations must not require keeping one fragile request call blocked without progress.

Core creates an operation.

Conceptually:

```json id="yjtfpy"
{
  "id": "request-1",
  "result": {
    "operation": "operation-42"
  }
}
```

The client then receives progress events associated with that operation.

---

# 14. Operation progress

Progress is structured.

Example:

```text id="n75y1d"
operation-42

RESOLVING
DOWNLOADING       42%
VERIFYING
EXTRACTING
VALIDATING
INSTALLING
COMPLETE
```

Conceptual event:

```json id="6bnl0k"
{
  "event": "operation.progress",
  "operation": "operation-42",
  "phase": "downloading",
  "progress": 0.42
}
```

Clients decide how to display this.

---

# 15. Client disconnect does not cancel accepted operations

Suppose:

```bash id="c29nl6"
val module install php@8.4
```

starts downloading PHP.

If the Terminal closes after Core accepts the operation, the installation should not automatically become corrupted or abandoned.

The operation belongs to Core.

The client is observing it.

Conceptually:

```text id="0hwh5e"
client request
      ↓
Core accepts operation
      ↓
operation belongs to Core
      ↓
client may disconnect
```

---

# 16. Explicit cancellation

Operations that can be safely cancelled may expose cancellation.

Example:

```text id="r0l8q2"
CancelOperation(operation-42)
```

Core determines whether cancellation is currently safe.

For example:

```text id="6tyf5a"
downloading
    → cancellable

atomic package switch
    → temporarily not cancellable
```

Cancellation must preserve state integrity.

---

# 17. Operation history

Core should retain recent operation results.

This allows:

```text id="kn2ikg"
GUI reconnect
      ↓
query operation-42
      ↓
installation completed
```

rather than losing all context because the client disconnected.

Operation history does not need indefinite retention.

---

# 18. Events

Core emits asynchronous events.

Examples:

```text id="pc6fnx"
module.installed

module.updated

instance.started

instance.stopped

instance.failed

process.exited

health.changed

project.linked

project.unlinked

route.changed
```

Clients may subscribe to relevant event streams.

---

# 19. Snapshot plus events

A newly connected client follows:

```text id="ft3c4s"
connect
   ↓
negotiate protocol
   ↓
request snapshot
   ↓
subscribe to events
   ↓
maintain local presentation state
```

The client should not need to repeatedly request the complete environment every second.

---

# 20. Event ordering

Events should include enough ordering information to detect stale presentation state.

Potential metadata:

```text id="sqqkwq"
sequence
timestamp
entity revision
```

The exact model requires implementation testing.

Clients must have a recovery path:

```text id="n2g3ve"
event stream uncertain
       ↓
request fresh snapshot
```

Correctness is more important than attempting perfect distributed-system complexity on one Mac.

---

# 21. Connection lifecycle

The client library should expose states such as:

```text id="h35ugx"
DISCONNECTED

CONNECTING

NEGOTIATING

CONNECTED

INCOMPATIBLE
```

The GUI can react appropriately.

For example:

```text id="f1ok3s"
Vaelen Core is starting…
```

rather than displaying every module as stopped simply because IPC has not connected yet.

---

# 22. Daemon discovery

Clients should use a deterministic per-user Core endpoint.

They should not scan ports or processes.

Conceptually:

```text id="m0ev95"
known socket location
       │
       ▼
attempt connection
       │
       ├── success → negotiate
       │
       └── unavailable → request/trigger daemon activation
```

`launchd` owns daemon lifecycle.

---

# 23. Daemon activation

If `vaelend` is not running, a client should be able to cause it to become available through the supported `launchd` lifecycle.

The client must not manually fork arbitrary copies of:

```text id="5p49zb"
vaelend
```

This preserves the single-daemon invariant.

---

# 24. Socket ownership

The Core socket belongs to the logged-in user.

The socket directory should use restrictive permissions.

A different local user should not be able to connect merely because they know the pathname.

Vaelen should validate peer identity where macOS APIs make that practical.

Filesystem permissions are one layer, not necessarily the entire authentication model.

---

# 25. No network exposure

The Core socket is local filesystem IPC.

Vaelen Core does not listen on:

```text id="by4gdr"
0.0.0.0
```

or expose its management protocol over the LAN.

Remote management is outside the initial architecture.

---

# 26. Protocol handshake

Every connection begins with negotiation.

Conceptually:

```json id="br1sq1"
{
  "protocol": 1,
  "client": "val",
  "clientVersion": "0.1.0"
}
```

Core responds:

```json id="fykj7g"
{
  "protocol": 1,
  "serverVersion": "0.1.0",
  "capabilities": [...]
}
```

This prevents clients from blindly communicating using incompatible assumptions.

---

# 27. Protocol version

Protocol version is distinct from Vaelen application version.

For example:

```text id="ndsvq9"
Vaelen.app 0.5
Protocol 2

vaelend 0.5
Protocol 2

val 0.5
Protocol 2
```

Application releases may occur without changing the protocol.

---

# 28. Compatibility

Minor additive protocol changes should not require immediate breakage where avoidable.

Clients should ignore unknown optional response fields.

Core should reject unknown required semantics explicitly.

Breaking protocol changes require a protocol version transition.

---

# 29. Capabilities

The handshake may expose capabilities.

Example:

```text id="w4cw0h"
module-management
project-reconciliation
router
operation-cancellation
resource-metrics
```

This is useful during upgrades and future integrations.

Clients should not infer capabilities solely from version strings.

---

# 30. CLI output

`val` has two conceptual presentation modes.

Human:

```bash id="23f6pe"
val status
```

Machine-readable:

```bash id="qolqox"
val status --json
```

Both use the same Core response.

The JSON mode should expose structured data rather than attempting to convert formatted terminal text back into JSON.

---

# 31. Stable machine output

Machine-readable CLI output becomes an external interface.

Once documented, field names should be treated carefully.

Example:

```json id="44xk7g"
{
  "services": [
    {
      "id": "mysql/default",
      "state": "running",
      "health": "healthy"
    }
  ]
}
```

This enables:

```text id="7mt4f8"
shell scripts
IDE integrations
automation
MCP
CI helpers
```

without requiring those clients to speak the socket protocol directly.

---

# 32. CLI as compatibility layer

For simple future integrations, invoking:

```text id="gn0mja"
val status --json
```

may be preferable to directly consuming Vaelen's private IPC protocol.

Therefore Vaelen has two possible integration levels:

```text id="e2x6s8"
External Tool
     │
     ├── val --json
     │
     └── Core protocol
```

The CLI is the safer initial public automation interface.

The raw Core protocol may remain internal until intentionally documented.

---

# 33. MCP architecture

A future MCP integration should not duplicate Core behavior.

Preferred:

```text id="juz7zb"
AI Client
    │
    ▼
Vaelen MCP Server
    │
    ▼
VaelenCoreClient
    │
    ▼
vaelend
```

Alternatively, the MCP server may initially invoke structured `val --json` commands.

The MCP layer does not directly manage PHP, MySQL, or project processes.

---

# 34. IDE integrations

Future IDE integrations follow the same principle.

Example:

```text id="1ruybq"
VS Code / Cursor / JetBrains
           │
           ▼
      integration
           │
           ▼
       Core client
           │
           ▼
        vaelend
```

No IDE receives special infrastructure ownership.

---

# 35. Concurrency

Multiple clients may be connected simultaneously.

Example:

```text id="t0nqj2"
Vaelen.app
     │
     ├─────► vaelend
     │
val ─┤
     │
MCP ─┘
```

Core owns mutation serialization as established in ADR-0001.

Clients must not coordinate locks with one another.

---

# 36. Concurrent reads

Read-only queries should generally be concurrent.

Examples:

```text id="n71vbo"
status
module list
project list
metrics
```

A long package download should not unnecessarily prevent the GUI from reading status.

---

# 37. Conflicting mutations

If two clients request:

```text id="y7nwl1"
GUI:
upgrade mysql/default

CLI:
uninstall mysql
```

Core detects the conflict.

The second operation may receive:

```text id="3nt17k"
OPERATION_CONFLICT
```

with details about the active operation.

---

# 38. Idempotency

Mutating requests should be designed to tolerate retries where practical.

A client reconnecting after uncertainty may not know whether its previous request reached Core.

Operation IDs and idempotent semantics help avoid duplicate work.

For particularly important mutations, the client may provide an idempotency key.

The exact mechanism can be introduced when implementation requires it.

---

# 39. Timeouts

Client request timeout and Core operation timeout are different.

For example:

```text id="s2j5ql"
client waits 30 seconds
```

does not mean:

```text id="gjrcfw"
kill PHP installation after 30 seconds
```

Long-running operations belong to Core.

Clients may stop waiting without implicitly cancelling them.

---

# 40. Backpressure

Event and log streaming must account for slow clients.

A GUI that stops reading must not cause `vaelend` to consume unbounded memory.

Core may:

* buffer within limits;
* coalesce replaceable events;
* drop non-critical telemetry;
* disconnect unresponsive clients.

Critical authoritative state remains queryable through a fresh snapshot.

---

# 41. Logs are streams, not state

A client may request live logs.

Example:

```bash id="1u2b4e"
val logs mysql --follow
```

This creates a streaming subscription.

If the client disconnects, MySQL does not stop.

Log delivery is observational.

---

# 42. Resource metrics

Detailed CPU/memory updates may also use subscriptions.

Example:

```text id="yzhv6s"
subscribe metrics
    interval: 2s
```

When nobody subscribes to detailed metrics, Core should avoid unnecessary high-frequency collection.

This preserves resource honesty.

---

# 43. Security boundary

The Core protocol allows powerful operations.

Examples:

```text id="v2r80f"
stop database
delete package
modify routing
run project process
```

Therefore access must remain restricted to the owning user.

The socket must not become a generic unauthenticated local control endpoint.

---

# 44. No arbitrary root escalation through Core protocol

Even an authenticated Core client cannot ask:

```text id="lft54v"
execute arbitrary command as root
```

Core itself does not possess that capability.

Privileged actions are separately constrained through the privileged helper contract.

This maintains defense in depth.

---

# 45. No arbitrary shell API

Core should not expose a generic IPC method such as:

```text id="ol4l18"
shell.execute(command)
```

as a general-purpose external client API.

Project-defined process execution may exist through carefully scoped project operations.

The Core protocol should describe intent rather than become a remote shell.

---

# 46. Auditability

Important state-changing operations should be attributable.

Core may retain:

```text id="5zuwzn"
operation
timestamp
client type
target
result
```

Example:

```text id="62p2j5"
14:32:11
client: val
operation: instance.stop
target: mysql/default
result: success
```

This is useful for diagnostics.

It is not intended as invasive user telemetry.

It remains local.

---

# 47. Privacy

IPC traffic remains local.

Vaelen does not send Core commands, project information, process lists, or developer activity to a Vaelen cloud service merely for the control plane to function.

No account is required.

No telemetry is required for IPC.

---

# 48. Connection failure UX

Clients should distinguish:

```text id="lvr7e6"
Core not running

Core starting

Core unreachable

Core incompatible

Core crashed
```

rather than reporting all cases as:

```text id="vv3dtl"
Connection failed
```

This distinction should come from the shared Core client library.

---

# 49. `val doctor` and IPC

`val doctor` must be capable of diagnosing Core connectivity itself.

Therefore diagnostics have two layers.

### Client-level checks

Possible without Core:

```text id="0a5pqv"
Is LaunchAgent installed?
Does socket path exist?
Can Core be contacted?
Are versions compatible?
```

### Core-level checks

Once connected:

```text id="y5ub3k"
module health
routing
DNS
TLS
packages
processes
```

This prevents a broken Core connection from making `val doctor` completely useless.

---

# 50. Emergency diagnostics

Vaelen may provide narrowly scoped CLI diagnostics that inspect local Vaelen files/process metadata when Core cannot start.

These operations are diagnostic only.

They must not create a second competing infrastructure manager.

For example:

```text id="bwe67o"
val doctor
```

may inspect daemon logs.

It should not directly start MySQL behind Core's back.

---

# 51. Core shutdown

A Core shutdown request is distinct from environment shutdown.

Protocol operations must preserve that distinction.

Conceptually:

```text id="8s7pjo"
core.restart
```

is not:

```text id="z8awbf"
environment.stop
```

This follows ADR-0001.

---

# 52. App updates

During an update, the GUI may temporarily reconnect to a newly started Core.

The protocol handshake must detect incompatible combinations.

The app should provide a clear recovery path rather than silently attempting unsupported operations.

---

# 53. Message size limits

Core should impose reasonable message-size limits.

The control protocol is not intended to transport:

```text id="ixhw6q"
database dumps
large binaries
project archives
```

Large data should use filesystem-based or dedicated streaming mechanisms.

This reduces memory and abuse risk.

---

# 54. Binary downloads do not pass through IPC

For example:

```text id="f90y5c"
PHP package
    ↓
Core downloader
    ↓
cache/staging
```

not:

```text id="5esr3f"
PHP package
    ↓
GUI
    ↓
IPC
    ↓
Core
```

The client requests installation.

Core owns the actual package lifecycle.

---

# 55. File references

When an operation needs a local file, the protocol should normally pass a validated path or controlled file reference rather than copying large file contents through IPC.

Core must validate that the operation is allowed to access the referenced path.

---

# 56. Protocol namespace

Methods should use stable semantic namespaces.

Examples:

```text id="y3q0ml"
core.status

module.list
module.install
module.uninstall

instance.list
instance.start
instance.stop
instance.restart

project.list
project.link
project.unlink
project.reconcile

router.status

diagnostics.run
```

This keeps the protocol understandable as it grows.

---

# 57. Protocol does not mirror Swift types blindly

Internal Swift implementation details should not automatically become protocol contracts.

For example, renaming:

```text id="zrh5ta"
ProcessSupervisorService
```

inside Swift should not require changing the external protocol.

The protocol models Vaelen concepts, not source-code structure.

---

# 58. Event namespace

Events should follow similarly stable naming.

Examples:

```text id="q6p6wb"
core.ready

module.installed
module.updated

instance.started
instance.stopped
instance.failed

process.exited

health.changed

project.linked
project.unlinked

operation.progress
operation.completed
operation.failed
```

---

# 59. Event payloads

Events contain enough identity to retrieve authoritative state.

For example:

```json id="ny09o7"
{
  "event": "health.changed",
  "entity": "mysql/default",
  "health": "unhealthy"
}
```

Clients should be able to query the entity if more information is required.

Events do not need to duplicate the entire state graph.

---

# 60. Public vs private protocol

Initially, the Core socket protocol should be considered an internal Vaelen interface.

The supported external automation contract should primarily be:

```text id="i2w5ea"
val
```

including machine-readable output.

This allows the internal protocol to evolve while Vaelen matures.

If ecosystem demand develops, the Core protocol may later be formally documented and stabilized.

---

# 61. Testing

The transport-independent protocol architecture enables testing without real sockets.

Conceptually:

```text id="ndn57e"
VaelenCoreClient
       │
       ▼
MockTransport
       │
       ▼
Test Core
```

Likewise:

```text id="uvmtbq"
Test Client
     │
     ▼
InMemoryTransport
     │
     ▼
Core
```

This is important for reliable lifecycle tests.

---

# 62. Transport abstraction

Conceptually:

```swift id="0y9lsj"
protocol CoreTransport {
    func connect() async throws
    func send(_ message: Data) async throws
    func receive() async throws -> Data
    func disconnect() async
}
```

Production:

```text id="e1bvvk"
UnixSocketTransport
```

Tests:

```text id="0dbfjv"
InMemoryTransport
```

A future alternative could be introduced without changing the Core protocol.

---

# 63. Swift concurrency

The client and daemon implementations should use Swift's structured concurrency where appropriate.

Long-running operations, event streams, and client connections naturally map to asynchronous tasks.

Shared mutable state must remain centralized and controlled.

The architecture should avoid callback-heavy IPC plumbing where modern Swift concurrency provides clearer ownership.

Exact actor boundaries belong to implementation design.

---

# 64. Core state isolation

A strong implementation candidate is for authoritative mutable Core state to be isolated behind one or more Swift actors.

Conceptually:

```text id="h5qvfj"
IPC Clients
    │
    ▼
Core API
    │
    ▼
Core State Actor
    │
    ├── Module Registry
    ├── Project Registry
    ├── Supervisor
    └── Operations
```

This should be validated during implementation rather than mandated as the only possible internal structure.

---

# 65. Consequences

## Positive

### One Core protocol

GUI, CLI, and future integrations share semantics.

### Simple CLI connectivity

UNIX sockets are straightforward for a command-line client.

### No TCP control port

Core remains local-only without consuming a network port.

### Native security where needed

XPC is retained for the privileged boundary.

### Future tooling

Language-independent structured IPC remains possible.

### Testability

Protocol logic can be tested independently from transport.

### Debuggability

JSON messages are inspectable during development.

### Resilience

Long-running operations belong to Core rather than client lifetime.

---

# 66. Costs

The hybrid model requires:

* UNIX socket implementation;
* message framing;
* protocol negotiation;
* connection management;
* shared client library;
* XPC implementation for privilege;
* event subscriptions;
* operation tracking.

This is more infrastructure than simply calling Swift functions from the GUI.

That complexity is required by the daemon/CLI architecture.

---

# 67. Alternatives Considered

## XPC everywhere

Not selected initially.

Excellent for native macOS process communication but less convenient as the universal client protocol for CLI and future tooling.

---

## UNIX sockets everywhere

Not selected.

Suitable for Core clients, but the privileged helper benefits from stronger native macOS XPC/service identity integration.

---

## Localhost HTTP

Rejected as the default Core transport.

It requires a TCP listener and expands the network-facing control surface without providing a meaningful advantage for local Vaelen clients.

---

## gRPC

Rejected initially.

It introduces unnecessary framework and code-generation complexity for a small local control plane.

---

## Direct GUI calls into Core

Rejected.

It would undermine daemon ownership and CLI parity.

---

## Shelling out from GUI to `val`

Rejected as the primary architecture.

Although possible for prototypes, the GUI should consume the Core client directly rather than spawn CLI processes to manage infrastructure.

---

# 68. Open Implementation Questions

1. Exact UNIX socket API/library implementation in Swift.
2. Exact runtime socket path.
3. Message length field size and byte order.
4. Whether JSON uses `Codable` directly or an explicit protocol serialization layer.
5. Exact peer-credential validation available on supported macOS versions.
6. `launchd` socket activation versus daemon-created socket.
7. Exact reconnect/backoff behavior.
8. Event sequencing model.
9. Operation history retention.
10. Maximum message size.
11. Whether the GUI ever benefits from a direct XPC Core transport later.
12. Exact protocol compatibility policy before 1.0.
13. Whether public third-party access to the raw Core protocol should ever be supported.
14. Exact audit-log retention.
15. Actor/isolation structure inside `vaelend`.

---

# 69. Invariants Established by This ADR

1. Core protocol semantics are independent of transport.
2. GUI and CLI consume the same Core semantics.
3. Ordinary Core clients initially communicate through a per-user UNIX domain socket.
4. The privileged helper uses an authenticated native XPC boundary.
5. Core does not expose a TCP management port by default.
6. The protocol uses structured messages rather than shell command strings.
7. JSON is the preferred initial serialization.
8. Stream messages use explicit framing.
9. Requests have unique identities.
10. Errors have stable machine-readable codes.
11. Long-running work becomes a Core-owned operation.
12. Client disconnection does not implicitly cancel accepted work.
13. Progress is structured.
14. Events are structured.
15. New clients obtain a snapshot and then consume events.
16. Multiple clients may connect simultaneously.
17. Core owns mutation serialization.
18. Clients do not coordinate locks among themselves.
19. The socket is restricted to the owning user.
20. Core protocol access does not imply arbitrary shell access.
21. Core protocol access does not imply arbitrary root access.
22. Binary package downloads are performed by Core, not transported through GUI IPC.
23. `val --json` is the initial preferred external automation interface.
24. The raw Core protocol remains internal until deliberately stabilized.
25. Future MCP and IDE integrations remain Core clients rather than infrastructure owners.
26. Transport implementations must be replaceable/testable.
27. Protocol version is distinct from application version.
28. Clients and Core negotiate compatibility.
29. Resource telemetry should become active only as needed.
30. A broken Core connection must not make local diagnostics completely unavailable.

---

# Summary

Vaelen has one control plane but more than one kind of process boundary.

For ordinary clients:

```text id="v5h9en"
Vaelen.app ──┐
             ├── UNIX socket ──► vaelend
val ─────────┘
```

For privileged operations:

```text id="f8qj3b"
vaelend
   │
   └── authenticated XPC ──► privileged helper
```

The important architectural boundary is not the socket or XPC mechanism.

It is the Core protocol:

```text id="ugk8v5"
commands
queries
operations
progress
events
errors
```

That protocol represents Vaelen's concepts independently of presentation and transport.

The GUI is a client.

The CLI is a client.

Future MCP and IDE integrations are clients.

Only Core owns the developer environment.
