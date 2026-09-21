# ADR-0014: Core Daemon Installation and Lifecycle

* **Status:** Accepted — ADR accepted; M14 production implementation and evidence are not yet complete, and M14 is not accepted or frozen
* **Date:** 2026-09-19
* **Decision owners:** Vaelen maintainers
* **Scope:** M14 architecture decision and boundary, including the accepted
  canonical signing trust boundary; no lifecycle mutation or release scope is
  implied by this document.

> This ADR records the accepted M14 architecture and boundary. Production
> implementation and supported-product evidence remain required before M14 can
> be accepted or frozen. The disposable experiment is not Vaelen Core and must
> not be treated as a production artifact.

## Context and authority

The authority levels must not be conflated:

* ADR-0013 and the accepted/frozen M0-M13 baseline are the current accepted
  authority. In particular, GUI and CLI must use Core rather than duplicate a
  mutation authority, and existing live service state must be preserved unless
  an explicitly authorized operation says otherwise.
* ADR-0001, ADR-0004, ADR-0005, and ADR-0006 remain **Proposed** and are not
  accepted or frozen ADR authority. Their unrelated per-user runtime,
  filesystem ownership, IPC, and privilege rules remain outside this ADR's
  authority.
* ADR-0010 is referenced only as the existing constraint for passive
  observation; this ADR does not independently freeze it.
* This ADR records the accepted direction: Core is the sole semantic
  lifecycle authority. GUI and CLI are clients. A narrowly scoped platform
  executor may issue `SMAppService` calls for Core, but has no semantic
  authority and cannot accept requests from GUI/CLI directly.

This ADR distinguishes accepted lifecycle decisions from implementation and
evidence that remain NOT-YET-PROVEN. It does not itself freeze ADR-0001/0004/
0005/0006 or authorize their unrelated implementation.

This ADR addresses the lifecycle boundary needed to make that topology
operational: installing a signed app and LaunchAgent, starting Core, finding
and reaching it, observing readiness, and recovering from crashes. Replacement,
updater, rollback, old-bundle cleanup, and version handoff are explicitly
deferred beyond the minimum M14 boundary. It does not authorize changing the
application, launchd database, Syncproof, or production runtime.

## Empirical evidence

The following are observations, not universal platform guarantees:

* **E-002 (RUNTIME-PROVEN, bounded):** A repaired-A disposable app registered
  with `SMAppService.agent`; status was `rawValue: 1`, launchd reported
  `running`, and the helper ran with PPID 1 and UID/EUID 501/501. launchd's
  `BundleProgram` was `Contents/Resources/M14CoreLifecycleAgent`.
* **E-004 (RUNTIME-PROVEN for the harness):** The old helper rejected a split
  bundle because it derived a path from `argv[0]`, which was the resource
  helper path. The repaired helper used `proc_pidpath(getpid())` and exact
  full-path validation. This establishes a harness path defect and repair, not
  signing causality.
* **E-006 (RUNTIME-PROVEN, one bounded case):** After a controller verified the
  exact PID, UID, and executable path and issued one SIGKILL, launchd relaunched
  generation 3 with a new PID; registration/status, label, and BTM UUID
  remained present, `runs` became 2, and the recovered process remained UID 501
  with PPID 1. Heartbeats continued. No readiness endpoint was present, so
  process recovery was not application readiness.
* E-002/E-006 observed the helper signing identifier
  `dev.vaelen.m14-lifecycle-experiment.agent` and TeamIdentifier `TFKZJV643`.
  E-003 invalidated the purported controlled A/B causal claim; the historical
  launch-constraint/signing explanation remains a hypothesis.
* The repository already has a user-scoped runtime layout, `core.sock`, a
  `vaelend.lock`, mode 700 runtime directories, a mode 600 socket, peer-UID
  validation, stale-socket checks, and protocol handshake compatibility checks.
  These are source observations, not lifecycle acceptance evidence.
* The experiment bundle is deliberately outside Vaelen and Syncproof, uses
  `BundleProgram` rather than an absolute `ProgramArguments` executable, and
  requires an explicitly selected stable signing identity. Its `register` and
  `unregister` calls are the only ServiceManagement mutations in that harness.

## Inferences and boundaries

1. launchd registration, launchd job presence, process presence, socket
   reachability, protocol compatibility, and application readiness are
   separate predicates. “Installed” or “running” cannot be reported as
   “ready”.
2. The observed relaunch supports considering launchd as the sole process supervisor
   for Core, but does not prove behavior for every exit, boot/login state,
   throttle condition, OS version, or malformed bundle.
3. `BundleProgram` is the appropriate production direction for a helper inside
   an app bundle, but the exact production bundle layout, signing identity,
   and designated requirement remain not-yet-proven. Update behavior is
   explicitly outside M14, not an acceptance target.
4. A PID file or heartbeat sidecar cannot be the lifecycle authority: it can be
   stale across a crash and cannot prove registration, executable identity, or
readiness. No new lifecycle sidecar is part of this ADR.
5. Existing Vaelen durable state may record installation intent/version,
   observed facts, ownership proof, and mutation provenance, but a diagnostic
   record alone never authorizes deletion, adoption, or signaling. External
   lifecycle facts must be re-observed and ownership must be proved before a
    destructive operation. The narrow durable model and fail-closed rule are
     accepted decisions; their production implementation remains NOT-YET-PROVEN.

### Canonical signing trust boundary (accepted Class C boundary)

Production bootstrap preflight fails closed unless the candidate is a valid,
non-ad-hoc Apple-signed `Vaelen.app` with bundle identifier `dev.vaelen.app`,
TeamIdentifier exactly `TFKZJV643G`, and a valid nested
`Contents/Resources/vaelend` executable whose signing identifier is exactly
`vaelend` and whose TeamIdentifier is the same. The app and daemon are each
checked against a valid designated requirement containing the canonical
identifier, Apple generic anchor, and exact team ID; nested verification is
performed as well. The LaunchAgent must be at the canonical
`Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist` path with label
`dev.vaelen.vaelend` and `BundleProgram` exactly
`Contents/Resources/vaelend`; arbitrary `ProgramArguments` are rejected.

This is an identity/product trust boundary, not an artifact fingerprint
allowlist. Certificate leaf hashes, subject suffixes, SHA-256 values, and
CDHashes are evidence only and are not pinned, so legitimate certificate
rotation and rebuilt binaries with the same canonical identity remain in
scope. Distribution, updater, replacement, rollback, and lifecycle mutation
remain outside this narrow decision.

## Accepted architecture contract

### 0. Core-owned semantic lifecycle

Core owns the lifecycle state machine and is the only component that may
interpret an install/register/start/unregister request or an internal
transient stop step, authorize
its preconditions, write intent and journal records, and decide whether the
result is success, failure, unknown, or requires recovery. GUI and CLI submit
typed requests to Core and render Core's result; neither calls ServiceManagement
or makes an independent lifecycle decision.

Core may delegate only the narrow platform side effect to an optional,
versioned platform executor. The executor receives a Core-issued operation ID,
validated target identity, and one explicit mutation (for example register or
unregister). It returns a structured result containing the platform API outcome,
observed identity/status where available, diagnostics, and executor provenance.
It does not accept GUI/CLI requests, maintain desired state, choose adoption or
rollback, retry semantically, or write lifecycle truth. Core remains authoritative
when the executor is absent, rejects a request, times out, exits, or returns an
ambiguous result: Core records the failure/unknown result, re-observes the
platform, and fails closed rather than guessing or using a hidden fallback.

The request boundary is `client -> Core lifecycle request -> optional executor
side effect -> Core observation/result`; the result boundary is `Core -> client`,
never executor -> client. Platform mutation and SQLite commit are not atomic. A
successful executor return is not proof of registration, ownership, process
identity, or readiness until Core performs fresh observation. This selects the
mutation-owner contract only; placement, activation, and exact journal schema
remain to be proven. Replacement/rollback are explicitly deferred, not open
M14 choices. No second
mutation path is permitted. The disposable controller remains evidence for
ServiceManagement behavior only.

#### Operation generations and fencing

Every lifecycle intent and journal operation carries a monotonically increasing
per-resource `intentGeneration` (and an operation ID unique within that
generation). Core advances the generation transactionally when a newer intent
supersedes an older one. An executor request, callback, timeout, recovery task,
and result is accepted only if its operation ID and generation still match the
current durable intent and the operation is not terminal. A durable `Off`
therefore fences every delayed `On` request and every executor result from an
older generation: such results may be retained as diagnostics, but cannot
register, start, adopt, or publish success. The same rule applies to delayed
results from a replaced resource. Generation checks occur before dispatch, on
result receipt, and before every durable state transition; they are not a
best-effort client convention.

The executor must authenticate the Core-issued request at its boundary and
reject replays (for example, by a protected request envelope containing the
operation ID, generation, target identity, nonce/deadline, and an authenticated
Core instance/session binding). It has no GUI/CLI/client ingress and cannot
reuse a request after its deadline or after Core has fenced it. The exact
encoding and mechanism remain open. Calls have a bounded timeout; timeout is
`unknown`, not permission to replay blindly.

The signed app/controller is also authorized for one distinct, pre-Core
bootstrap operation. It is a strictly constrained executor, never a second
semantic authority: it may perform only that fixed operation for the fixed
canonical Vaelen identity. An explicit user-invoked `val start` supplies a
one-time invocation-authorization token bound to that fixed operation and
user; an implicit, background, launchd, retry, or recovery invocation has no
such authorization. The token authorizes attempting this fixed bootstrap
operation only; it does not select arbitrary desired state or grant semantic
authority. The bootstrap epoch, operation ID, and nonce are immutable values
minted by the executor only for this fixed operation (never supplied by a
caller and never reused). Arbitrary paths, labels, bundle IDs, versions,
executable arguments, and identities are rejected.

Before acting, the executor must validate the immutable bundle,
signature/designated requirement, canonical label/program/endpoint, user
scope, and the existing per-user lifecycle lock and endpoint exclusion. It
must also prove that Core is absent. An existing durable `Off` blocks
implicit/background bootstrap, but an explicit, valid `val start`
invocation-authorization token permits this one fixed bootstrap attempt; the
executor still does not choose or commit `On`. Any unresolved journal
operation, a held lifecycle lock, a reachable Core, any existing registration
(matching or conflicting), an absent/invalid/expired/mismatched token, or any
other ambiguity is a fail-closed refusal. In particular, a matching
registration is not adoption. The executor does not publish lifecycle truth
or accept a GUI/CLI request as a semantic command.

The executor may write exactly one narrow `bootstrap_receipt` record in the
existing SQLite store, and no desired-state or ownership record. Before any
ServiceManagement mutation, it must atomically reserve that receipt in the
existing same-user-protected SQLite database. The reservation contains only
the fixed canonical identity, immutable bootstrap epoch, operation ID, nonce,
expiry, invocation provenance including the explicit authorization token, and
`reserved` phase. Only after that commit
may the executor perform the single fixed platform call. It then atomically
records the executor result and fresh post-observation, together with the
result phase, in that same receipt; it may not create a second receipt or
perform another platform call.

The canonical field encoding carries an integrity digest and is bound to the
signed, fixed-identity controller, authenticated local user/peer context,
immutable epoch/operation/nonce, explicit invocation token, expiry, and
canonical identity. Core verifies
those bindings, the protected SQLite access context, and the digest before
accepting the receipt. The exact cryptographic authentication mechanism is an
implementation detail and **NOT-YET-PROVEN**; no unestablished handoff key is
assumed here. A missing, malformed, altered, expired, duplicated, or
conflicting row is invalid. This receipt is evidence for handoff only: it is
not desired state, ownership truth, authorization, or adoption proof.

An existing receipt, including an orphan left by a crash, is itself a
fail-closed refusal to mint another bootstrap epoch, operation, or nonce; it
must be handed off once or quarantined for explicit recovery. After
registration, Core must be reached through the canonical endpoint and
must validate the receipt, authenticated peer, explicit invocation token,
lock/endpoint exclusion, immutable epoch and operation ID/nonce, canonical
identity, expiry, and a fresh platform post-observation. Only then may Core
promote the receipt into the normal Core journal and provenance. If the prior
durable intent was `Off`, that promotion is also the sole Core transaction
that may commit a new `On` generation superseding `Off`; until it succeeds,
`Off` remains the barrier. Promotion completes this operation; it is not
adoption. Core is the sole writer of desired lifecycle and ownership truth
 after handoff. The controller holds one canonical lifecycle-bootstrap lock
 exclusively through barrier revalidation, receipt reservation, the single
 platform call, and durable result recording. It releases that lease before
 waiting for launchd or reconnecting. The daemon acquires the same exclusive
 lock for admission, validates the durable receipt/journal and fresh runtime
 identity, establishes endpoint/readiness, then releases it at the narrow
 serving handoff point. No descriptor transfer, shared-to-exclusive upgrade,
 or continuous flock crosses the controller/launchd boundary. The lock is
 coordination only and never ownership provenance.

Crash outcomes are bounded and never authorize blind replay. An `Off` barrier
continues to block implicit or automatic recovery; only the same explicit
`val start` authorization can begin the exceptional bootstrap path, and only
Core can supersede `Off` after successful promotion. If a crash occurs
before reservation commit, SQLite atomicity leaves no receipt reservation and
no platform call was permitted; a new explicit invocation may mint a new
receipt. A crash during reservation commit yields the same atomic alternatives:
if the reservation exists, later invocations refuse; if it does not, no call
was permitted and a new invocation may proceed. A crash after reservation but
before the API leaves an orphan reservation that Core quarantines as
failed/unknown after fresh observation; it is not reused. A crash during the
ServiceManagement API, or after the API before authenticated executor
result/post-observation commit, is unconditionally
`unknown/recovery-required`: Core may not promote from a reservation plus a
matching observation alone. Later invocations refuse, and no identity-only
adoption or blind retry is allowed. Core may resolve the quarantine only from
an authenticated result-bearing receipt or a separately authorized recovery
operation whose fresh observation and provenance rules are satisfied. A crash
before handoff leaves a valid result-bearing receipt orphaned until Core
validates it; otherwise it remains quarantined and unknown. Promotion is
SQLite-atomic and yields either no promotion or one promoted Core journal
result. A crash after promotion is recovered from that Core journal. No crash
window permits adoption, unregister, signaling, a second epoch, or a second
platform call; invalid or ambiguous invocation authorization always refuses.

### 1. Observation algebra, not synthetic lifecycle status

Lifecycle is a product of independently observed predicates. Each predicate
has a value of `true`, `false`, `unknown`, `stale`, or `incompatible`, plus an
observation timestamp, source, identity, and diagnostic reason. These values
must not be collapsed into healthy/running labels.

```text
bundlePresent      := expected canonical bundle exists
layoutValid        := bundle layout and plist parse and validate
signatureValid     := signature/designated-requirement observation passes
registrationMatch  := platform registration matches label, bundle, and program identity
processMatch       := live process matches expected UID, executable, and launch identity
endpointReachable  := canonical socket accepts a connection
protocolCompatible := versioned handshake is compatible
coreReady          := explicit future readiness response says startup is complete
supervisorObserved := launchd identifies the expected job/supervisor
```

The accepted observation record is this vector, not one synthetic status.
Labels such as `notInstalled`, `registered`, `starting`, `ready`, `degraded`,
`failed`, and `stopped` are views with documented derivation rules; production
derivation and evidence remain NOT-YET-PROVEN. `ready` requires fresh compatible evidence for
`endpointReachable && protocolCompatible && coreReady`; launchd `running`, a
PID, a socket, or a heartbeat alone cannot produce `ready`.

Observation is read-only on status/restart and must not activate projects or
reconcile desired services merely because Core was restarted. This follows
ADR-0010. Explicit lifecycle commands may request the minimum M14
registration/start, unregister, or Off operations subject to the evidence
gates. Stop is only an internal transient step. Replacement is not an M14
operation.

### 2. Ownership, provenance, and crash windows without a new sidecar

The accepted ownership chain is:

```text
signed Vaelen.app / embedded daemon
        -> per-user LaunchAgent identity and BundleProgram
        -> launchd-owned vaelend process
        -> Vaelen runtime socket and lock
        -> Core durable state in the existing Vaelen state store
```

The app bundle is provenance for immutable code; the launchd label and
registration are provenance for the installed service; the process path, UID,
peer credentials, lock, socket, and handshake are provenance for the live
process. The lifecycle-specific durable model is intentionally minimal, not a
generic transition framework. The existing SQLite state store needs only:

* **desired intent:** Core-owned desired lifecycle, limited to `On`/registered
  versus `Off`/unregistered, with fixed target identity, actor, operation ID,
  and intent generation. There is no durable `Stop` intent in minimum M14.
  It covers a crash before dispatch and is not proof that anything was
  installed or owned.
* **durable ownership/provenance:** only the immutable artifact and
  registration identity Core previously proved it installed/registered:
  canonical path, bundle ID, label, BundleProgram, signing/team/
  designated-requirement evidence, hashes, and operation provenance. It covers
  destructive-action recovery and prevents adoption; it is not current process
  state.
* **operation journal/receipt:** operation ID/generation, narrow mutation,
  pre-observation, executor/API result, post-observation, terminal result or
  `unknown/recovery-required`, and recovery disposition. A `bootstrap_receipt`
  is the only executor-written SQLite record and exists solely for the
  Core-absent handoff; it is not desired state or ownership truth, and Core
  promotion is required. This covers non-atomic platform-call / SQLite-commit
  windows and replay fencing.

Observed platform and runtime identity are fresh/ephemeral inputs, not durable
ownership keys. They include registration/status, label, bundle/program/
signing identity, process PID/start identity, UID, executable path, socket
owner/peer, handshake/build identity, and readiness. PID, runtime generation,
heartbeat, or a matching observation cannot establish ownership or authorize
adoption.

The mutation journal must record operation ID, pre-observation, requested
mutation, post-observation, result/error, and provenance. Intent and journal
updates use SQLite transactions/atomic commits. Platform mutation and SQLite
commit are not one atomic transaction, so recovery must re-observe after every
crash window (before mutation, after mutation/before journal commit, and after
commit/before post-observation). Missing or ambiguous proof is fail-closed:
do not unregister, delete, replace, adopt, or signal. A diagnostic record alone
never authorizes deletion or adoption. No new sidecar is part of this ADR.

Completion has a fixed provenance sequence, recorded in one operation journal:

```text
fresh pre-observation
  -> Core-authorized operation and durable in-flight record
  -> authenticated executor/API result
  -> fresh exact post-observation
  -> SQLite commit of the completed result and provenance
```

The post-observation must match the operation's target and stable ownership
fields, and must include the relevant registration, process, endpoint, and
readiness predicates rather than a synthetic status. Recovery evidence is
operation-bound: an old operation's result or post-check cannot complete a
newer operation. An observation that merely matches an identity is
observation-only evidence; it is not proof that this operation caused or owns
the registration. Core must not silently adopt it. A registration that appears
owned by the product but has no matching durable operation/provenance is
`unresolved/unknown`; cleanup is fail-closed until an explicitly authorized,
freshly proven operation establishes what may be removed. If any sequence step
is missing, Core records incomplete/unknown and re-observes rather than
claiming success.

The journal state machine is explicit: `pending` (durable intent, not
dispatched), `in-flight` (Core-authorized request dispatched), `succeeded`,
`failed`, and `unknown/recovery-required`. `succeeded` and
`failed` are terminal for that operation; `unknown/recovery-required` is
terminal for blind replay but not proof of the requested postcondition and can
advance only through fresh observation and an explicitly authorized recovery
operation. Only Core may transition these states, with generation fencing and
SQLite transactions.
Disconnecting clients do not cancel or authorize a mutation: Core continues a
bounded operation, persists its state, and lets a later client query the same
operation. A client retry creates a new operation/generation or attaches to an
explicitly matching pending operation; it never blindly replays an in-flight
or unknown side effect. Unknown/recovery-required operations require fresh
observation and an explicit recovery policy. Terminal `Off` cannot be
overwritten by stale work; only an explicit newer `On` creates a new generation.

Destructive action requires agreement between durable provenance and a fresh
platform observation on stable ownership fields (at minimum canonical bundle
identity, label, program identity, and signing/designated requirement). Runtime
identity may be an additional live safety gate but is not a durable ownership
key. If durable provenance and fresh platform identity disagree, Core records an
ownership conflict and does not silently adopt, unregister, delete, signal, or
replace. A fresh match still does not permit deleting files outside the recorded
owned artifact.

The eight required destructive/crash cases are handled as follows:

1. **Off before mutation:** persist Off and its journal intent before invoking
   the executor; with no freshly proven owned registration, complete as an
   idempotent no-op, never by searching or deleting.
2. **Executor fails before the API call:** record failure, leave intent durable,
   observe, and return failed/unknown; do not use another authority or fallback.
3. **Platform mutation succeeds before SQLite commit:** after restart, re-observe
   and record only a result matching durable provenance and fresh identity;
   ambiguity remains blocked.
4. **SQLite commit precedes interrupted post-observation:** mark the post-check
   incomplete and re-observe before completion; a committed request is not
   platform proof.
5. **Core crashes during destructive work:** the next Core instance marks the
   operation unresolved and observes first; it never blindly replays the
   mutation.
6. **Foreign/replaced/mismatched platform identity:** disagreement blocks
   unregister/delete/replace even when durable records claim ownership; no
   silent adoption is allowed.
7. **Executor success with stale, absent, or contradictory observation:** return
   unknown/degraded, retain the old artifact, and require re-observation or an
   explicit recovery policy.
8. **Off versus crash recovery:** Off is a durable desired-state barrier. Crash
   recovery may complete only explicitly journaled, proven-safe cleanup; it must
   not re-register or restart merely because old intent requested On. A later
   explicit On is required.

9. **Owned-but-unrecorded registration:** matching observation without
   operation-bound provenance is unresolved/unknown; Core does not adopt or
   silently unregister it, and any cleanup remains fail-closed.

These rules govern unregistration. Replacement and rollback are outside M14.

Crash windows are handled by re-observation, not a sidecar or speculative
rollback (replacement is not an M14 operation):

* after install but before registration, observe the bundle and registration;
* after registration but before process launch, observe launchd status;
* after process launch but before socket bind, observe process then endpoint;
* after socket bind but before readiness, connect and perform the handshake;
* after Core crash, discard stale socket/lock evidence only under the existing
  owner/connection checks, then let launchd relaunch and recompose status;
* after a successful external mutation but before durable recording, record the
  observed result on next startup and fail closed where ownership is ambiguous.

No stale PID file, heartbeat file, or second supervisor is required. Existing
socket and lock artifacts are runtime coordination artifacts, not lifecycle
sidecars; their ownership checks must remain strict.

### 2a. Stop is transient; Off is the disabled barrier

`Stop` is a private, non-public, transient implementation step in minimum M14,
not a client operation and never durable desired intent. It may be used while
Core carries out an explicit `Off` or another Core-authorized operation, but it
cannot be requested independently, retained across restart, or reverse `Off`.
Durable desired intent is only `On`/registered versus `Off`/unregistered.

**Off** is the only authoritative user-facing disabled barrier. It includes,
as applicable, unregister/disable and stopping owned work, and succeeds only
after a bounded fresh post-check proves registration disabled or unregistered,
the expected process absent, and the canonical endpoint unreachable. Failure
or inability to prove any required postcondition is
`unknown/recovery-required`, not success. Off's destructive scope is limited
to the exact recorded artifact/registration and owned process identity; it
never means “find and remove anything that looks like Core.” Only a new
explicit `On` may reverse Off.

TOCTOU protection requires rechecking process start identity (and executable,
   UID, and path) immediately before any signal or destructive action and in
the bounded post-check. A PID observed earlier is not sufficient: PID reuse,
replacement, or a changed start identity fences the action and yields
unknown/conflict.

### 3. Installation versus execution

Installation is staging one complete, validated, signed app bundle and its
embedded LaunchAgent metadata in a user-owned, stable canonical location, plus
making a Core-authorized registration request. Minimum M14 identity is the
fixed bundle identifier, fixed agent label, fixed BundleProgram, fixed expected
daemon path, fixed signing/designated requirement, and canonical user-scoped
endpoint. Placement details may be measured without adding updater behavior.
M14 has no updater, replacement, rollback, old-bundle cleanup, or version
handoff. Mutable in-place overwrite is forbidden. Execution is launchd selecting
the registered job and starting the embedded daemon. They are distinct
operations and statuses.

Installation must not run Core directly as a hidden fallback, and a successful
`register()` must not be reported as readiness. Uninstall/replacement must
first establish which registration and bundle are owned by this product; an
unknown or conflicting identity blocks destructive action.

### 4. IPC readiness and endpoint contract

The accepted contract retains the existing per-user
`~/Library/Application Support/Vaelen/runtime/sockets/core.sock` (subject to
the existing path-length check). The daemon creates its 700 directories,
acquires the existing per-user lock, binds the socket with mode 600, validates
peer UID, and serves the existing framed protocol. The first request is the
versioned handshake; only a compatible handshake followed by an explicit
ready response constitutes `ready`.

This readiness operation does not currently exist and is not established by
E-006. If later selected, the Core client should have a bounded
discovery/connection procedure: locate
the canonical endpoint, connect, handshake, query lifecycle readiness, and
return structured “not installed / not registered / starting / incompatible /
unavailable” errors. It must not start a private daemon or bypass Core.
Readiness must tolerate a launchd process that has started but has not yet
bound its socket, with bounded retry/backoff and no duplicate launch attempt.

### 5. Bundle, LaunchAgent, BundleProgram, and signing identity

The bounded production direction is a signed `Vaelen.app` containing the Core
executable at a stable bundle-relative path (for example,
`Contents/Resources/vaelend`) and a LaunchAgent plist at
`Contents/Library/LaunchAgents/<stable-agent-label>.plist`. The plist should
use Apple's bundle-relative `BundleProgram`, not an absolute path or a
caller-controlled `ProgramArguments` executable. `Label`, bundle identifier,
BundleProgram, and expected process path must agree. Exact supported placement
and packaging metadata remain Class A/B details to prove; versioned directory
naming, retention, and update discovery are not M14 behavior and must not be
implemented here.

The final product bundle must be signed as a coherent release artifact. The
daemon's signing identifier, app designated requirement/team identity, and
whether macOS requires the helper's own CodeDirectory identifier to match a
specific requirement must be measured on supported deployment systems. The
experiment's identifier and TeamIdentifier are evidence only; they are not
production values. Ad-hoc or accidentally generated identities are not an
acceptance substitute.

### 6. Authoritative CLI discovery

`val` discovers Core through the canonical `CoreEndpointPaths` user-scoped
layout and the protocol handshake. It does not discover a PID, scan arbitrary
paths, invoke `launchctl` as its semantic API, or choose among multiple Core
instances. Lifecycle diagnostics may query launchd through a Core-owned
implementation or a narrowly specified read-only observation adapter, but the
CLI's service operations still go through `VaelenCoreClient` and Core.

If the endpoint is absent, the CLI reports Core unavailable/not ready with an
actionable lifecycle state. `val` remains a Core client. `val start` may submit
a typed Core request when Core is reachable; when it is absent, it may invoke
only the fixed-identity signed bootstrap executor described above, then must
reconnect and prove handoff. If bootstrap cannot prove handoff, it returns a
structured unavailable/unknown result. It must not create a second supervisor,
call ServiceManagement directly, use arbitrary inputs, or execute module
operations locally. It may never use a private daemon fallback.

### 7. Replacement, update, and rollback are deferred

Replacement, updater, rollback, same-label version handoff, and old-bundle
cleanup are outside minimum M14 and are not M14 operations. M14 must neither
implement nor require them. The future-safe
boundary is limited to staging an immutable, validated bundle without in-place
overwrite; identity conflicts fail closed. No old bundle may be removed and no
version handoff may be inferred from an observation. A later ADR may define
these operations after separate authorization and evidence.

### 8. Per-user privilege

The LaunchAgent and `vaelend` run as the logged-in user, with the user's UID,
home, Application Support, state, runtime, socket, and managed child services.
Registration must not require administrator authentication in the tested
per-user case; E-002's no-admin-prompt observation is bounded and must not be
generalized to all systems. No root Core, root launch agent, or privileged
service supervisor is part of this ADR.

Operations that genuinely require elevation remain behind the separate,
narrowly scoped helper required by ADR-0006 and ADR-0005. Installation of a
future privileged helper is not part of this lifecycle contract and must not be
smuggled into Core installation.

### 9. launchd failure and recovery; no second supervisor

launchd is the one supervisor for `vaelend`. Core must not fork a watchdog,
have the GUI/CLI restart it in a loop, or install another daemon to monitor the
LaunchAgent. `KeepAlive`/`RunAtLoad`, throttling, exit policy, and logging must
be selected deliberately in the production plist; they are not inferred from
the experiment's settings.

On startup, the accepted ordering is: open SQLite; load intent/journal; observe
bundle and platform registration; observe process identity; observe endpoint;
perform handshake; then publish the future readiness response. Launchd
`running` with no endpoint/readiness is `supervisorObserved=true` combined with
endpoint/readiness `false` or `unknown`, not `ready`.

On a crash, clients observe the composed states, retry boundedly, and reconnect
to the new process. Core startup reopens durable state and performs passive
observation/reconciliation only as permitted by the ADR-0010
constraint. Repeated launch
failure becomes a visible degraded/failed state with launchd evidence and no
unbounded client retry storm. Unregister/disable is an explicit lifecycle
operation and must be distinguishable from a crash.

E-006 supports this contract for one SIGKILL and one replacement PID/generation
only. It does not prove behavior for clean exit, crash loops, throttling,
login/logout, sleep/wake, upgrade failure, or universal macOS versions.

### 10. GUI and CLI through Core

Every GUI and CLI lifecycle or service operation uses the same typed Core
protocol and authority. The GUI may render composed lifecycle observations; it
does not call ServiceManagement to perform product operations, launch module
processes, mutate runtime state, or infer ownership. The CLI has the same
restriction. This extends ADR-0013's Core-authoritative client rule to M14.

## Alternatives considered; deferred work is not an M14 fork

* **GUI-launched daemon:** rejected; conflicts with the ADR-0001
  proposal and the accepted M13 Core-authority boundary.
* **CLI-launched private daemon or per-command supervisor:** rejected; creates
  competing authorities and breaks identical GUI/CLI behavior.
* **Root `vaelend` or root LaunchDaemon:** rejected; conflicts with
  the ADR-0006 proposal and
  grants unnecessary authority to ordinary Core features.
* **PID/heartbeat sidecar as authority:** rejected; stale and non-provenance
  bearing across crash windows. Composed observation is preferred.
* **Absolute plist executable path:** rejected for the bundle contract;
  it is less relocatable and was not the experiment's BundleProgram model.
* **XPC for every client operation:** rejected under the ADR-0005
  transport proposal;
  ordinary clients use the transport-independent protocol over the user socket.
  XPC remains appropriate for the privileged boundary.
* **Multiple Core instances with client race/selection:** rejected;
  the ADR-0001 proposal requires exactly one authoritative Core per logged-in
  user, with the existing lock and endpoint ownership checks.
* **In-place binary replacement:** rejected; it creates an unsafe crash/relaunch
  window and prevents reliable rollback.

## Implementation and evidence NOT-YET-PROVEN

The following are implementation and production-evidence tasks, not
architectural uncertainty. They must be completed and evidenced before M14 can
be accepted or frozen.

1. What are the exact production `Vaelen.app` placement, bundle identifier,
   agent label, BundleProgram path, and signing/designated-requirement
   arrangement (Class A/B detail)?
2. Which launchd status fields are stable enough to expose, and how should clean
   exit, crash loop, throttle, login/logout, and sleep/wake be classified?
3. Does a production signed app need a distinct daemon CodeDirectory identifier,
   and which requirement does ServiceManagement evaluate? E-003 leaves the
   historical causal claim NOT-YET-PROVEN.
4. What is the exact readiness response and timeout/backoff policy, including
   when launchd says running but the socket never appears?
5. Which universal platform guarantees, if any, can be claimed when E-006 is
   only one repaired-A observation and not production acceptance?
6. How do the minimal intent/ownership/journal records fit the existing SQLite
   schema and migration/retention policy without a generic transition framework
   or weakened ADR-0013 fail-closed provenance rules?
7. Which generic Core-issued executor envelope encoding and bounded timeout
   details remain needed, and which platform observations are available after
   each ServiceManagement failure mode? The bootstrap receipt authentication,
   integrity, expiry, and promotion gates above are not open choices.
8. Which recovery and retention rules apply to malformed, truncated, or
   partially committed journal records?

Bootstrap authority, receipt handoff, identity fencing, and the deferral of
replacement/update/rollback are accepted decisions recorded above, not
architectural uncertainty. Their supported product-path proof is
**NOT-YET-PROVEN** evidence,
as are the exact production packaging/signing details, platform lifecycle
classifications, readiness contract, recovery/retention implementation, and
the fit of the narrow records into the existing SQLite schema. Replacement,
update, rollback, old-bundle cleanup, and version handoff remain explicitly
deferred rather than acceptance targets.

## First production implementation slices and acceptance matrix

The first slices are deliberately sequenced: (1) immutable bundle identity,
validation, and read-only observation; (2) Core durable `On`/registered versus
`Off`/unregistered intent, ownership, and minimal journal with generation
fencing; (3) Core-to-executor registration path; (4) the distinct fixed-
identity, pre-Core bootstrap operation, existing-lock/endpoint exclusion,
narrow `bootstrap_receipt`, and Core promotion; (5) `val`/`val start`
product-path reconnect, readiness, transient Stop only within Core operations,
Off, and structured failure handling. No slice includes updater, replacement,
rollback, old-bundle cleanup, or version handoff.

The matrix must falsify incorrect implementations, not only exercise happy
paths. Evidence strength is separate from product-path acceptance: unit/source
coverage and disposable runtime observations cannot be presented as public
product acceptance. At present this is read-only planning only. The current
authorization permits no further destructive lifecycle experiment; any future
mutation requires explicit authority and a bounded disposable procedure.

| Area | Negative/falsifying cases | Required evidence and gate |
|---|---|---|
| Bundle/install | wrong bundle ID, TeamIdentifier/designated requirement or daemon identifier, malformed/incomplete plist or bundle, missing/wrong BundleProgram, non-canonical endpoint, invalid signature, replaced bundle, in-place overwrite, crash before registration | artifact hashes/signing provenance and agreement of bundle ID/label/program/path/endpoint; stage completely before registration; reject without hidden direct launch; retain artifacts on ambiguity |
| Registration | registered-but-not-running, stale registration, mismatched label/path, repeated register/unregister | distinguish registration from process/readiness; record exact platform result and ownership proof; no dual mutation path |
| Core/executor authority | GUI/CLI direct call, executor accepts client request, executor retries semantically, Core bypasses journal, two concurrent owners | trace one typed client→Core→optional executor→Core result path; executor has no semantic state or client ingress; Core serializes/authorizes and returns structured failure/unknown |
| Operation generation/fencing | delayed On after durable Off, stale callback, duplicate/replayed result, old replacement result | monotonic generation and authenticated operation ID; stale work is rejected before dispatch/result commit and cannot resurrect registration |
| Executor authentication/replay | forged request, wrong Core/session, replayed nonce, expired request, client ingress, timeout | boundary authentication and user/session binding; no client ingress; bounded timeout; replay rejection; bootstrap uses fixed identity and cannot choose state |
| Core-absent bootstrap | implicit/background invocation with durable Off, explicit `val start` with absent/invalid/expired/mismatched authorization token, arbitrary input, unresolved journal, held lock, reachable Core, matching/conflicting registration, existing/orphan receipt, crash before reservation commit, during reservation commit, after reservation before API, during API, after API before result commit, before handoff or during promotion, duplicate/altered/expired receipt, failed reconnect, second bootstrap, stale/wrong/Off daemon admission | implicit/background recovery refuses and Off remains authoritative; explicit user token may authorize only the fixed operation; Core alone commits the new On generation; fixed canonical identity; immutable epoch/operation/nonce; one canonical exclusive lock with controller release before daemon admission and daemon release after endpoint/readiness; no descriptor transfer, shared-to-exclusive upgrade, continuous flock, or lock-as-ownership proof; atomically reserve the sole narrow receipt before any ServiceManagement call; fault-injected proof that absent reservation means zero platform calls, while an existing reservation permits no second epoch/replay or blind retry; result/post-observation atomically update that receipt; API/result crash is unconditionally unknown/recovery-required unless authenticated result-bearing receipt or separately authorized recovery resolves it; signed preflight; no adoption; receipt integrity/authentication/expiry; fresh post-observation/runtime identity; Core-only operation-bound promotion; orphan quarantine and ambiguity fail closed |
| Executor failure boundary | executor unavailable, timeout, process exit, API rejection, success without observable effect | durable intent and journal result; fresh Core observation; no hidden fallback, blind retry, adoption, or success claim on ambiguous result |
| Journal state/idempotence | pending/in-flight crash, malformed/truncated/unknown state, invalid generation or operation relationship, schema/migration failure, client disconnect, retry of unknown operation | explicit pending/in-flight/succeeded/failed/unknown-recovery states plus durable On/Off intent; atomic commits, operation lookup, no blind replay, recovery/retention before completion |
| Provenance completion | missing pre-observation, missing post-observation, result from another operation, identity-only match, owned-but-unrecorded registration | exact pre→authorized operation→executor/API result→exact post→SQLite sequence; operation-bound evidence only; observation-only match is not adoption; unresolved cleanup fails closed |
| Process ownership/TOCTOU | PID reuse, wrong UID, wrong executable/path/start identity, stale record, process changes between check and signal | exact identity observation immediately before destructive action and in bounded post-check; no PID-only signal/adoption; ambiguity blocks mutation |
| IPC/discovery | missing socket, stale socket, wrong peer UID, incompatible schema, multiple candidate endpoints | socket/peer/handshake evidence; CLI returns structured unavailable/incompatible and never starts a private daemon |
| Readiness | launchd says running but socket absent; socket exists but handshake fails; handshake succeeds but future ready is false/unknown; stale readiness | readiness implementation/evidence remains NOT-YET-PROVEN; `ready` requires fresh endpoint + compatible handshake + explicit Core response; E-006 does not prove readiness |
| Crash/recovery | clean exit, SIGKILL, crash loop, throttle, login/logout, sleep/wake | bounded, separately authorized disposable observation; no second supervisor; E-006 covers only one SIGKILL/relaunch |
| Passive restart | Core restart with pending/unknown work, durable Off, stale socket/lock, or active projects | reload durable records before observation; passive observation only; no replay, project activation, service reconciliation, or reversal of Off; distinguish crash from explicit disable |
| Durable provenance/crash windows | crash before mutation, after platform mutation before SQLite commit, after commit before post-observation; corrupt journal | existing SQLite intent/observation/ownership/journal records; atomic commits and re-observation; ambiguous ownership fails closed; no sidecar |
| Provenance agreement | durable ownership matches, conflicts with, or is absent from fresh platform identity; PID/runtime generation changes | destructive mutation only on stable durable+fresh platform agreement; runtime identity is supplemental and never a durable ownership key; conflicts fail closed/no silent adoption |
| Unregister/delete | unknown registration, replaced app, mismatched label, missing proof, repeated unregister | no unrelated process/file removal; unregister requires exact ownership; diagnostic record alone cannot authorize deletion |
| Safe no-op/refusal | Off without proven ownership, repeated Off, foreign/unknown registration, matching observation without operation provenance | idempotent no-op or unknown as applicable; no adoption, search, signal, unregister, or delete; user-facing Off remains authoritative |
| Stop/unregister/Off | public Stop request, durable Stop after restart, Off races mutation, crash after Off, stale On intent, endpoint still reachable, process still present | Stop is private/transient only; Off is the sole user-facing disabled barrier and proves disabled/unregistered, expected process absent, endpoint unreachable via bounded post-check; only explicit On reverses Off |
| Off/crash recovery | Off races mutation, crash after Off, stale On intent after relaunch, repeated Off | Off is durable barrier; recovery never re-registers/restarts from stale On intent; only proven journaled cleanup may complete; explicit On required |
| Deferred replacement boundary | updater, same-label replacement, rollback, old-bundle cleanup, version handoff, in-place overwrite | minimum M14 rejects/does not require all of these; immutable validated bundle and identity conflicts fail closed |
| Multi-resource independence | Off/register operation for resource A races On/replace operation for resource B; shared executor/client retries | per-resource generation, lock/transaction scope, and provenance; one resource's fence or failure cannot mutate or complete another |
| CLI/GUI authority | GUI or CLI directly calls ServiceManagement, launches Core, or mutates modules; surfaces disagree | source/unit evidence plus actual supported product-path tracing; both use Core authority; no acceptance from internal diagnostic path |
| Privilege/isolation | root Core, admin prompt assumption, experiment path/label/socket collision with live Vaelen | ordinary-user UID/EUID and dedicated artifact/path evidence; privilege claims limited to observed system; live Vaelen remains untouched |
| launchd observations | infer readiness or ownership from `running`, PID, heartbeat, or status enum alone | raw launchd fields plus observation algebra and freshness/unknown/incompatible values; no unsupported synthetic claim |
| Provider/API failures | unavailable provider, malformed response, contradictory status, partial success, provider restart | structured failed/unknown result, fresh exact post-observation, bounded recovery; no assumption that API return equals platform truth |
| Product-path limitations | internal diagnostic path passes while GUI/CLI/product path bypasses Core or cannot expose recovery state | supported product-path tracing for both clients, structured unknown/failure rendering, and no acceptance based only on harness/diagnostic calls |

Evidence is sequenced and classified as follows:

1. **Unit/source evidence:** identity validation, preflight rejection,
   generation fencing, journal transitions, receipt schema/promotion,
   malformed/orphan handling, Off barriers, and client authority boundaries.
2. **Disposable read-only/runtime evidence:** signed bundle and LaunchAgent
   observations, launchd state versus readiness, crash-window observation,
   protocol reconnect, and bootstrap failure windows using an isolated artifact.
   This evidence must not mutate live Vaelen state and is not product acceptance.
3. **Supported product-path evidence:** the installed supported bundle through
   Core and `val`/`val start`, including Core-present operation, Core-absent
   fixed bootstrap and receipt promotion, reconnect/readiness, structured
   unavailable/unknown results, Off, and recovery. This is the only evidence
   that can support M14 acceptance.

Acceptance must include artifact provenance (revision where available,
bundle/plist hashes, signing identifier, CDHash, TeamIdentifier, experiment
generation, and evidence path where material). Missing provenance is recorded
as missing, never inferred. Passing the matrix would still require completion
of the remaining Class A/B implementation details and NOT-YET-PROVEN evidence,
plus explicit M14 acceptance/freeze before production M14 implementation is
authorized. The Core-owned semantic authority and bootstrap/defer directions
recorded above are accepted ADR decisions, not M14 acceptance or implementation
authorization.

## Non-goals

This ADR does not implement M14, alter production launchd registration,
change the Vaelen app or CLI, add a privileged helper, alter Syncproof, define
module supervision policy, authorize destructive replacement/uninstall, or
accept/freeze M14. M14 remains not accepted/frozen. The disposable experiment remains the only lifecycle
artifact covered by E-002/E-004/E-006.
