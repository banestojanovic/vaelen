# Vaelen Project Decisions

This file records active project-management decisions only. It does not
replace or amend ADRs.

## D-001 — M14 remains validation-only

M14 is limited to disposable platform/lifecycle validation. Production M14
implementation and ADR-0014 remain unauthorized and unfrozen.

## D-002 — Preserve the repaired-A boundary

Repaired-A is the known-good experiment generation. Preserve its evidence and
do not create B, alter signing identifiers, reset BTM/ServiceManagement state,
or use mutating `launchctl` as part of unresolved historical-cause analysis.

## D-003 — Evidence before causal claims

The missing B artifact invalidates the prior A/B causal conclusion. Future PM
reports must keep artifact provenance, runtime attribution, and causal claims
separate. A failed or invalid experiment is not evidence for its intended
causal hypothesis.

## D-004 — Next bounded boundary

The next candidate is one repaired-A launchd recovery observation using only
the controller's verified `terminate-agent` operation. It must remain
read-only until explicitly authorized, use one termination, and stop on any
identity, ownership, admission, recovery, authorization, or service-state
failure.

## D-005 — Delegation cleanup boundary

The disposable delegation probe is removed after successful PM -> Lead,
nested Lead -> Investigator, and Investigator -> Lead -> PM propagation
observations, including native read-only inspection through the chain. The PM
retains authority to delegate to `vaelen-lead` and the approved read-only
specialists; no mutation authority is added to `investigator`. The
`default_agent` remains `vaelen-pm`, `subagent_depth` remains `2`, and
`vaelen-lead` remains a `subagent`. The malformed/inconsistent Lead YAML
indentation was repaired before Lead became launchable as a subagent; this is
supported by controlled before/after evidence, not direct parser observation.

The disposable probe and failed shell/Git acceptance attempts are recorded as
non-invalidating transport/permission failures. No lifecycle operation,
experiment-controller invocation, production change, frozen ADR change, or
Experiments/ change is authorized by this cleanup.

## D-006 — Single repaired-A recovery observation consumed

The one explicitly authorized repaired-A `terminate-agent` operation was
executed once against verified disposable PID 6130. The preserved experiment
evidence reports launchd recovery to PID 10313, generation 3, with the same
experiment label/BTM UUID, UID/EUID 501, exact helper path validation, status
`SMAppServiceStatus(rawValue: 1)`, and continued heartbeats. This authorizes no
additional lifecycle mutation, production implementation, ADR change, or
milestone acceptance.

## D-007 — Lifecycle architecture convergence authorized

Bane authorized research and draft design convergence around per-user
`SMAppService.agent` with launchd lifecycle supervision. This does not accept or
freeze ADR-0014 and does not authorize production implementation. The draft must
preserve separate registration, process, endpoint, protocol, readiness, and
ownership observations; fail closed on ambiguous destructive authority; and
leave unresolved Class C choices explicit, including the sole owner of
install/register/unregister/replacement mutations.

## D-008 — Core-owned lifecycle semantic authority

Bane selected Core as the sole semantic authority for daemon lifecycle. Core
owns desired intent, authorization, provenance evaluation, mutation journaling,
reconciliation, fail-closed destructive decisions, and the semantic results
returned to GUI and CLI. GUI and CLI must not mutate ServiceManagement or
implement independent lifecycle paths. A narrowly scoped platform executor may
perform a Core-issued ServiceManagement side effect only; it has no desired
state, ownership, adoption, replacement, retry, or client authority.

The draft must preserve durable intent/provenance/journal state separately from
fresh platform identity and ephemeral runtime identity. Off must fence stale On
work and require authoritative postconditions before success. This decision
does not accept or freeze ADR-0014 and does not authorize production
implementation.

## D-009 — Core-absent bootstrap and replacement deferral

Bane authorized a signed app/controller as a strictly constrained executor for
the fixed canonical Core registration only when Core is absent. It may not
choose desired state, adopt an existing registration, or publish lifecycle
truth. The draft requires an atomic pre-mutation bootstrap reservation in the
existing SQLite store, fixed identity/epoch/operation/nonce, lock and endpoint
exclusion, one authenticated receipt, Core reconnect, fresh post-observation,
and Core-only promotion. Reservation-only or ambiguous API outcomes are
`unknown/recovery-required`; matching observation cannot silently promote or
adopt.

Replacement, updater, rollback, same-label handoff, old-bundle cleanup, and
version handoff are deferred beyond minimum M14. M14 must not implement or
experiment on them, while retaining immutable-bundle and identity-conflict
fail-closed boundaries.

## D-010 — Explicit bootstrap reactivation after Off

Implicit or background bootstrap must refuse a durable Off barrier. An explicit
user-invoked `val start` may submit the fixed bootstrap operation with a
one-time invocation authorization bound to the canonical identity and
bootstrap receipt. The bootstrap executor still cannot choose arbitrary desired
state or publish lifecycle truth. Core alone validates the receipt and fresh
platform state, then commits a new On generation superseding Off. Invalid,
expired, replayed, ambiguous, or non-explicit bootstrap requests remain refused
or `unknown/recovery-required`; stale recovery never reverses Off.

## D-011 — ADR-0014 accepted; M14 remains active

Bane accepted ADR-0014: Core Daemon Installation and Lifecycle. The accepted
architecture establishes per-user `SMAppService.agent`, launchd as sole process
supervisor, Core as sole semantic lifecycle authority, constrained Core-absent
bootstrap, narrow durable lifecycle evidence, fresh observation, fail-closed
destructive authority, typed Core IPC, and explicit replacement/update/
rollback deferral.

ADR-0014 acceptance does not accept or freeze M14, authorize production
implementation, establish production packaging/readiness/Off evidence, or
promote E-002/E-004/E-006 beyond bounded disposable runtime proof. No tag,
push, lifecycle mutation, or Syncproof change is authorized.

## D-012 — Production M14 implementation authorized

Bane authorized production implementation under accepted ADR-0014. Source,
migrations, typed IPC/API changes, tests, and minimum packaging integration may
proceed, while M14 remains active and unfrozen. This authorization does not
authorize new destructive real-system lifecycle experiments, release, tag,
 push, or commit. Production lifecycle claims remain `NOT-YET-PROVEN` until
 their required evidence exists.

## D-013 — Release-before-daemon-admission handoff

Bane selected the Class C handoff contract: one canonical exclusive
`lifecycle-bootstrap.lock`; the controller revalidates barriers, reserves the
durable receipt, performs at most one fixed registration, records the result,
and releases the lock before waiting/reconnecting. The launchd daemon acquires
the same exclusive lock for operation-bound admission, validates durable
receipt/journal, fresh identity, and generation, establishes endpoint/readiness,
then releases it. No descriptor transfer, shared-to-exclusive upgrade, or
continuous flock crosses the process boundary. Lock acquisition is never
ownership provenance. No lifecycle mutation, release, tag, push, or commit is
 authorized by this decision.

## D-014 — Canonical Class C signing trust boundary

Bane accepted the production preflight trust boundary: app and embedded daemon
must each be valid Apple-signed code under TeamIdentifier `TFKZJV643G`, with
canonical identities `dev.vaelen.app` and `vaelend`, respectively, coherent
nested verification, and the canonical embedded path and LaunchAgent
layout/label/BundleProgram. Certificate, subject, SHA-256, and CDHash values
are evidence only and are not pinned. This does not authorize lifecycle
mutation, updater/distribution scope, or milestone acceptance.
