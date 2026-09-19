# Vaelen Evidence Ledger

Append empirical observations here. Each entry distinguishes observed facts
from conclusions and preserves artifact/provenance limits.

## Provenance policy

For material empirical experiments, record each relevant available identity:

- Git commit SHA, when the experiment is tied to a repository revision;
- binary SHA-256 and plist/configuration SHA-256, when available;
- signing identifier, CDHash, and TeamIdentifier, when signing is material;
- experiment/artifact generation;
- evidence, event, or unified-log path;
- capture time, operation, and environment where relevant.

Do not require irrelevant fields, and never invent unavailable provenance.
Record missing provenance as a limitation. Claim status and validation
strength are separate: use `OBSERVED FACT`, `INFERENCE`, `HYPOTHESIS`,
`INVALIDATED`, or `FROZEN DECISION` for what a statement is, and use
`UNIT-COVERED`, `RUNTIME-PROVEN`, or `NOT-YET-PROVEN` when the strength of
validation materially matters.

## E-001 — Frozen milestone provenance

- Provenance: repository history and supplied milestone state.
- Observed: M12 freeze tag/commit are `v0.0.13-m12` /
  `e76e260b69b6b1e0216fdc8985ce13cfa4c79964`; M13 freeze tag/commit are
  `v0.0.14-m13` / `534da3618895717624cb9d4bf7dd685f5dfd571b`.
- Observed: ADR-0013 is accepted/frozen; M0–M13 are frozen.
- Supported conclusion: M14 is not production-authorized by the frozen
  baseline.

## E-002 — Repaired-A stable baseline

- Provenance: test Mac, repaired-A final app under
  `~/Library/Application Support/M14CoreLifecycleExperiment/App/`; controller
  observations on 2026-09-19 UTC; events at the same path. Repository-side
  capture commands and artifact-generation hashes remain in the preserved
  experiment workspace, not this ledger.
- Operation: read-only `status`, `agent-pid`, `ps`, `launchctl print`, and
  `evidence`.
- Observed: `SMAppServiceStatus(rawValue: 1)`; PID `6130`; PPID `1`; UID/EUID
  `501/501`; launchd state `running`; `BundleProgram` is
  `Contents/Resources/M14CoreLifecycleAgent`.
- Observed: LWCR requires signing identifier
  `dev.vaelen.m14-lifecycle-experiment.agent` and TeamIdentifier `TFKZJV643G`.
- Observed: generation 2 heartbeats continued through at least
  `2026-09-19T15:46:39Z`; prior `agent-path-validation` passed with the exact
  proc-derived helper path.
- Supported conclusion: repaired-A was a stable observed baseline at the
  time of capture.
- Unsupported conclusion: this does not prove launchd crash/recovery.
- Claim status: `OBSERVED FACT` / bounded `INFERENCE`.
- Validation strength: `RUNTIME-PROVEN` for the captured repaired-A baseline;
  `NOT-YET-PROVEN` for crash/recovery and production acceptance.
- Available provenance: helper signing identifier
  `dev.vaelen.m14-lifecycle-experiment.agent`; TeamIdentifier `TFKZJV643G`;
  generation 2; event path listed above. Binary/configuration hashes and Git
  revision were not preserved in this ledger entry and are not invented.

## E-003 — Invalid controlled A/B claim

- Provenance: preserved `AB` directory and artifact inspection.
- Observed: preserved unsigned inputs and `artifacts/A` exist; no
  `artifacts/B` exists; repaired-A is a separate generation.
- Observed: the 2026-09-19 registration/runtime evidence reports the `.agent`
  helper identifier, not B's proposed containing-app identifier.
- Supported conclusion: the claimed controlled A/B comparison is invalid.
- Invalidated conclusion: changing only the helper CodeDirectory identifier
  caused the historical admission difference.
- Remaining hypothesis: the signing-identifier explanation remains untested.
- Claim status: `INVALIDATED` for the causal conclusion; `HYPOTHESIS` for
  the signing explanation.
- Validation strength: `NOT-YET-PROVEN` for the signing hypothesis.

## E-004 — Repaired helper path defect and repair

- Provenance: disposable M14 helper source and repaired-A events.
- Evidence path: `~/Library/Application Support/M14CoreLifecycleExperiment/events.jsonl`;
  repaired-A generation 2.
- Observed: the old helper saw `argv[0] = Contents/Resources/M14CoreLifecycleAgent`
  and derived `/`, causing its stale path guard to reject the split layout.
- Observed: repaired-A uses `proc_pidpath(getpid())`, exact standardized full
  path validation, and recorded `pathValidationPassed = true`.
- Supported conclusion: the old refusal was an experiment-local harness
  defect; repaired-A corrected that defect without establishing any signing
  causality.
- Claim status: `OBSERVED FACT` / bounded `INFERENCE`.
- Validation strength: `RUNTIME-PROVEN` for repaired-A path validation;
  `NOT-YET-PROVEN` for any production lifecycle implication.

## Evidence classification

- `OBSERVED FACT`: directly recorded output, source, artifact, or log.
- `INFERENCE`: bounded interpretation explicitly tied to facts.
- `HYPOTHESIS`: unresolved explanation requiring evidence.
- `INVALIDATED`: prior conclusion contradicted by preserved evidence.
- `FROZEN DECISION`: accepted architecture/milestone authority, not an
  empirical claim.

## E-005 — Delegation-chain and configuration preparation

- Provenance: controlled delegation observations and repository inspection;
  no experiment artifact or production runtime mutation.
- Observed: PM -> `vaelen-lead` delegation works; nested Lead ->
  `investigator` delegation works; Investigator -> Lead -> PM result
  propagation works; and native read-only repository inspection works through
  the chain.
- Observed: `opencode.json` retains `default_agent: vaelen-pm` and
  `experimental.subagent_depth: 2`.
- Observed: `vaelen-lead` remains `mode: subagent` with corrected YAML
  indentation. Controlled before/after evidence strongly supports malformed
  indentation as the cause of the prior rejection; parser normalization was
  not directly observed.
- Observed: the disposable probe and failed shell/Git acceptance attempts were
  transport/permission failures. They do not invalidate the successful chain
  observations. Cleanup was finally checked through shell-free file inspection.
- Limitation: no `git diff --check` result was available because shell access
  was denied in this session.
- Claim status: `OBSERVED FACT` for the delegation/configuration observations;
  bounded `INFERENCE` for the indentation cause.
- Validation strength: `RUNTIME-PROVEN` for the controlled delegation chain;
  `NOT-YET-PROVEN` for shell-based diff-check acceptance.

## E-006 — Repaired-A single crash/recovery observation

- Provenance: disposable repaired-A runtime artifact and controller output on
  the test Mac, 2026-09-19 UTC. Runtime evidence path:
  `~/Library/Application Support/M14CoreLifecycleExperiment/events.jsonl`.
  At read time the artifact SHA-256 was
  `c099c1631a0ddd9e71fb33d9abbd247647cc6f7132401e2688b868585bc0b89a`;
  the file is live and append-only, so later inspection records can change the
  hash. The experiment root is the fixed disposable root, not a Vaelen or
  Syncproof path. The runtime binary Git revision was not separately embedded
  in the event records.
- Identity observed before mutation: bundle ID
  `dev.vaelen.m14-lifecycle-experiment`; agent label
  `dev.vaelen.m14-lifecycle-experiment.agent`; helper path under the fixed
  experiment root; helper signing identifier
  `dev.vaelen.m14-lifecycle-experiment.agent`; TeamIdentifier `TFKZJV643G`;
  deep codesign verification passed. The controller verified the target PID's
  exact proc-derived helper path and UID 501 before signaling.
- Observed baseline at `2026-09-19T16:54:42Z`: SMAppService status raw value
  `1`, PID 6130, generation 2, UID/EUID 501, PPID 1, and launchd state
  `running`. Captured launchd fields were `runs = 1`, exact BundleProgram
  `Contents/Resources/M14CoreLifecycleAgent`, BTM UUID
  `4E05A4AA-B888-4105-9B36-5F9CB00D82E4`, and no prior exit.
- Authorized operation: at `2026-09-19T16:55:05Z`, the controller recorded
  `terminate-agent-attempt` and `terminate-agent-signal-issued` for exactly PID
  6130, verified UID 501 and the exact helper path, then issued SIGKILL. This
  consumed the single-use authorization. No register, unregister, rebuild,
  mutating launchctl operation, production change, or cleanup occurred.
- Observed recovery: generation 3 launched at `2026-09-19T16:55:05Z` as PID
  10313. The helper recorded exact `proc_pidpath(getpid())` equality and
  `pathValidationPassed = true`; launchd remained `running` with the same
  label/BTM UUID, `runs = 2`, PID 10313, and `last terminating signal =
  Killed: 9`. The recovered process was observed with PPID 1 and UID/EUID
  501. Post-recovery status/evidence at `16:55:24Z` retained raw status 1,
  and heartbeats continued through at least `16:58:50Z`.
- Supported conclusion: for this exact repaired-A disposable registration and
  this observed SIGKILL, launchd automatically relaunched the agent with a new
  PID/generation while registration/status remained present. This is bounded
  runtime evidence, not a universal macOS guarantee or production acceptance.
- Preservation/failure findings: the controller's identity and ownership
  gates passed; no failure-path artifact was produced because signaling and
  recovery succeeded. The controller's read-only `status`/`evidence` commands
  append records to the live ledger. No endpoint/readiness facility exists in
  this harness, so application readiness was not tested.
- Claim status: `OBSERVED FACT` for recorded identities, operation, launchd
  fields, PID/generation, status, ownership, path validation, and heartbeats;
  bounded `INFERENCE` for automatic recovery and registration continuity.
- Validation strength: `RUNTIME-PROVEN` for this bounded repaired-A crash /
  recovery path; `NOT-YET-PROVEN` for universal platform behavior, other
  termination/failure modes, public product acceptance, and production M14.

## E-007 — M14 architecture convergence review

- Provenance: repository inspection and independent read-only specialist reviews
  on 2026-09-19 UTC; draft artifact
  `docs/adr/ADR-0014-core-daemon-installation-and-lifecycle-draft.md`.
- Observed: the draft remains explicitly `Draft — not accepted or frozen` and
  contains no production implementation or lifecycle mutation.
- Observed: investigator mapping found current `vaelend` startup is manual;
  the daemon owns the existing per-user socket/lock and protocol handshake, but
  production `SMAppService.agent` registration, app-contained daemon packaging,
  lifecycle persistence, readiness response, and CLI/GUI lifecycle activation
  are not implemented. Current SQLite schema has no daemon installation or
  registration record.
- Observed: architecture review identified unresolved Class C choices for the
  sole install/register/unregister/replacement mutation owner, durable
  lifecycle provenance/journal semantics, exact production bundle identity and
  replacement protocol, and the future readiness contract. It rejected treating
  proposed ADR-0001/0004/0005/0006 rules as frozen authority.
- Observed: test audit found the acceptance matrix must use negative/falsifying
  cases and distinguish unit/source coverage, disposable runtime evidence, and
  supported public product-path acceptance. Registration/process identity and
  one SIGKILL recovery are bounded `RUNTIME-PROVEN`; readiness, replacement,
  unregister/off, crash windows, production packaging, and product-path parity
  remain `NOT-YET-PROVEN`.
- Supported conclusion: the per-user SMAppService/launchd direction is suitable
  for continued architectural convergence, but the draft is not yet an
  accepted production contract. No additional destructive experiment is needed
  or authorized for the current review.
- Claim status: `OBSERVED FACT` for repository/review findings; bounded
  `INFERENCE` for the proposed architecture direction.
- Validation strength: `UNIT-COVERED` for existing IPC/authority source tests;
  `RUNTIME-PROVEN` only for the bounded E-002/E-004/E-006 experiment facts;
  `NOT-YET-PROVEN` for production lifecycle architecture and acceptance.

## E-008 — Core-owned lifecycle authority architecture review

- Provenance: Bane Class C direction, repository investigation, and independent
  architecture-reviewer/test-auditor review of the revised ADR-0014 draft on
  2026-09-19 UTC. Draft artifact:
  `docs/adr/ADR-0014-core-daemon-installation-and-lifecycle-draft.md`.
- FROZEN/CLASS C DECISION: Core is the sole semantic lifecycle authority.
  GUI and CLI are typed Core clients. An optional platform executor may issue a
  narrowly scoped Core-authenticated ServiceManagement side effect, but cannot
  receive client requests, own desired state, decide ownership/adoption,
  choose replacement/rollback, retry semantically, or publish lifecycle truth.
- Observed in the revised draft: operation generations fence delayed results;
  durable Off fences stale On work; executor requests require authenticated
  operation/session binding and bounded deadlines; executor/API success still
  requires fresh Core post-observation; unknown results are not blindly replayed.
- Observed in the revised draft: durable desired intent, provenance/ownership,
  mutation journal, observed platform identity, and observed runtime identity
  are distinct. Runtime PID/start identity, endpoint, peer, protocol, and
  readiness are not durable ownership keys. Matching observation without
  operation-bound provenance remains unresolved/unknown and is never silently
  adopted.
- Observed in the revised draft: Stop, Unregister, and Off have distinct
  semantics; Off requires a durable barrier plus bounded proof of disabled
  registration, absent expected process, and unreachable endpoint. Only an
  explicit On may reverse Off. TOCTOU process start identity is rechecked before
  destructive action.
- Architecture-review finding: Core-owned authority is sound, but bootstrap
  when Core is absent, executor authentication/placement, orphaned successful
  registration recovery, terminal/unknown operation semantics, exact Off
  postconditions, and replacement handoff/rollback remain unresolved or
  require implementation evidence. These are not silently resolved by
  re-observation alone.
- Test-auditor finding: all M14 lifecycle authority, provenance, crash-window,
  readiness, Off, replacement, and public CLI/GUI claims remain
  `NOT-YET-PROVEN`; E-002/E-004/E-006 remain bounded disposable evidence only.
  Required future falsifiers include malformed/foreign provenance, executor
  timeout/ambiguous result, stale journal, delayed On after Off, false
  readiness, process start-identity mismatch, and real product-path authority.
- Narrowed alternatives: immutable versioned staging beside a stable active
  identity is the safer proposed packaging direction; in-place overwrite is
  rejected. A future `val start` may only be a typed Core request, but its
  Core-absent bootstrap path is unresolved. Lifecycle persistence should be a
  narrowly scoped SQLite schema/journal, not a generic workflow engine or
  sidecar. Same-label replacement and rollback remain evidence-dependent.
- Claim status: `FROZEN DECISION` for Bane's Core semantic-authority choice;
  `OBSERVED FACT` for source/review findings; `INFERENCE` for narrowed design
  directions.
- Validation strength: `UNIT-COVERED` for existing IPC/authority patterns;
  `RUNTIME-PROVEN` only for bounded experiment facts; `NOT-YET-PROVEN` for
  production lifecycle implementation and product acceptance.

## E-009 — M14 bootstrap and deferral convergence review

- Provenance: Bane Class C decisions, repository investigation, revised draft
  ADR-0014, and independent architecture-reviewer/test-auditor reviews on
  2026-09-19 UTC. Draft remains
  `docs/adr/ADR-0014-core-daemon-installation-and-lifecycle-draft.md`.
- FROZEN/CLASS C DECISION: a signed app/controller may execute only the fixed
  Core-absent bootstrap registration operation. Core remains the sole semantic
  authority. Replacement, updater, rollback, same-label handoff, old-bundle
  cleanup, and version handoff are deferred beyond minimum M14.
- Observed in the draft: bootstrap requires explicit invocation, fixed
  canonical identity, absence of reachable Core, no existing registration,
  durable Off, unresolved journal, held lock, or existing receipt; arbitrary
  caller-selected paths/labels/versions/identities are rejected. A pre-mutation
  SQLite reservation is required before any platform call, followed by one
  operation-bound receipt and Core-only promotion after reconnect and fresh
  post-observation.
- Observed in the draft: reservation-only or crash-during-API outcomes are
  unconditionally `unknown/recovery-required`; identity-only matching cannot
  promote or adopt. Missing reservation proves no platform call was permitted
  by the contract. Orphan reservations are quarantined and cannot mint a second
  epoch or replay blindly.
- Observed in the draft: minimum durable state is reduced to On/registered
  versus Off/unregistered desired intent, durable ownership/provenance, and a
  lifecycle-specific operation journal/receipt. Stop is transient and
  non-public. Each record is tied to concrete crash windows and generation
  fencing; no lifecycle sidecar or generic workflow engine is proposed.
- Architecture-review verdict: the pre-mutation reservation closes the prior
  bootstrap issuer/race blocker. An API crash without a result-bearing receipt
  must remain unknown and cannot promote from matching observation; the draft
  now states this explicitly. No new Class C fork was identified after that
  correction.
- Test-auditor verdict: the matrix is a sufficient falsifier plan, including
  bootstrap pre-reservation zero-call proof, receipt crash windows, no-adoption,
  Off, readiness, Core/GUI/CLI authority, and deferred replacement boundaries.
  It is planning evidence only; all production lifecycle claims remain
  `NOT-YET-PROVEN`.
- Claim status: `FROZEN DECISION` for Bane's bootstrap and replacement-deferral
  directions; `OBSERVED FACT` for review/draft contents; bounded `INFERENCE`
  for the proposed implementation contract.
- Validation strength: `RUNTIME-PROVEN` only for bounded E-002/E-004/E-006
  experiment facts; `UNIT-COVERED` for existing IPC/authority patterns;
  `NOT-YET-PROVEN` for bootstrap handoff, lifecycle journal, readiness, Off,
  product-path acceptance, and all production implementation.

## E-010 — ADR-0014 acceptance-candidate review

- Provenance: revised draft ADR-0014 and final read-only architecture-reviewer
  challenge on 2026-09-19 UTC.
- Observed: the draft distinguishes implicit/background bootstrap from explicit
  user-invoked `val start`. Implicit bootstrap refuses durable Off. Explicit
  `val start` may carry a one-time fixed-identity bootstrap authorization; the
  executor writes only the constrained receipt, and Core alone promotes it and
  commits a new On generation superseding Off.
- Observed: invalid, expired, replayed, ambiguous, or non-explicit bootstrap
  requests remain refused or `unknown/recovery-required`; stale recovery cannot
  reverse Off. Replacement/update/rollback remain deferred beyond M14.
- Architecture-review verdict: no remaining genuine Class C blocker was
  identified. Remaining production signing/packaging details, readiness,
  lifecycle classifications, schema implementation, and runtime acceptance are
  Class A/B or `NOT-YET-PROVEN` matters.
- Test-auditor classification: the acceptance matrix is a falsifier plan, not
  acceptance evidence. Bootstrap handoff, journal crash windows, Off, readiness,
  GUI/CLI/Core product authority, and all production lifecycle claims remain
  `NOT-YET-PROVEN`.
- Claim status: `OBSERVED FACT` for draft/review contents; `FROZEN DECISION`
  for Bane's bootstrap/Off reactivation and replacement-deferral directions;
  bounded `INFERENCE` for the proposed contract.
- Validation strength: `RUNTIME-PROVEN` only for E-002/E-004/E-006's bounded
  disposable facts; `UNIT-COVERED` for existing IPC/authority patterns;
  `NOT-YET-PROVEN` for every production M14 lifecycle claim.

## E-011 — ADR-0014 accepted

- Provenance: Bane Class C acceptance decision and final ADR read-only review on
  2026-09-19 UTC. Accepted artifact:
  `docs/adr/ADR-0014-core-daemon-installation-and-lifecycle.md`.
- FROZEN DECISION: ADR-0014 is accepted. It establishes per-user
  `SMAppService.agent`, launchd as sole process supervisor, Core as sole
  semantic lifecycle authority, constrained fixed-identity Core-absent
  bootstrap, narrow durable intent/provenance/journal evidence, fresh
  platform/runtime observation, fail-closed destructive authority, typed Core
  IPC for GUI/CLI, Off fencing/postconditions, and replacement/update/rollback
  deferral beyond minimum M14.
- Observed: the ADR explicitly preserves E-002, E-004, and E-006 as bounded
  disposable `RUNTIME-PROVEN` evidence only. It explicitly labels production
  packaging/signing, bootstrap reservation/receipt, Core promotion, lifecycle
  SQLite schema, executor behavior, readiness, Off-means-off, GUI/CLI/Core
  parity, crash-window recovery, broader launchd behavior, and public
  product-path acceptance as implementation/evidence `NOT-YET-PROVEN`.
- Observed: the ADR states M14 is not accepted or frozen and production M14
  implementation is not authorized. Replacement, updater, rollback,
  same-label handoff, and old-bundle cleanup remain outside M14.
- Architecture-reviewer final consistency result: no inconsistency or new
  Class C blocker was found after status finalization.
- Test-auditor result: acceptance of ADR-0014 does not promote any empirical
  claim; all production lifecycle gates remain `NOT-YET-PROVEN` until supported
  product-path evidence exists.
- Claim status: `FROZEN DECISION` for ADR-0014 acceptance; `OBSERVED FACT` for
  final ADR contents; `NOT-YET-PROVEN` for production implementation and
  acceptance.
- Validation strength: `RUNTIME-PROVEN` remains limited to E-002/E-004/E-006;
  ADR acceptance is architectural authority, not runtime proof.
