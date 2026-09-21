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

## E-012 — M14 implementation foundation and isolated validation

- Provenance: working tree based on accepted ADR commit
  `2ebf14aaa860245b787a861f87d0c7061b0e8f47`, with uncommitted M14 source,
  test, IPC, CLI/GUI, and packaging changes; validation performed on
  2026-09-19 UTC by `vaelen-lead`.
- Observed: the implementation adds schema v7 lifecycle intent, ownership,
  operation journal, and bootstrap receipt records; Core-authoritative typed
  lifecycle/readiness/bootstrap IPC; generation and restart fencing; a
  constrained SMAppService adapter; passive observation; explicit CLI/GUI Core
  paths; and minimum Xcode LaunchAgent/embedded-daemon packaging.
- Observed: isolated tests and full Swift validation passed with 195 tests
  passed and 2 skipped in the latest reported run; `swift build` passed and
  `git diff --check` passed. The reported Xcode Debug build and Release archive
  also passed in disposable derived-data/archive locations.
- Observed: no ServiceManagement registration/unregistration, lifecycle
  termination, destructive real-system experiment, tag, push, or commit was
  performed during implementation. `Experiments/` remains outside the
  implementation file set.
- UNIT-COVERED: lifecycle generation fencing, malformed/restart journal
  classification, executor credential/replay states, ownership refusal,
  bootstrap reservation/receipt/promotion/replay barriers, Off reactivation
  fencing, readiness predicates, CLI/GUI Core routing, and isolated lock
  behavior.
- NOT-YET-PROVEN: production signed bundle identity and designated requirement
  acceptance, real SMAppService registration/launchd execution, endpoint and
  readiness runtime behavior, real Off postconditions, crash-window behavior
  on the production process, GUI/CLI live parity, and public product-path
  acceptance. E-002/E-004/E-006 remain bounded disposable runtime evidence.
- Claim status: `OBSERVED FACT` for the reported build/test outcomes;
  `UNIT-COVERED` for the listed isolated contracts; `NOT-YET-PROVEN` for
  production lifecycle acceptance.

## E-013 — Validation-count correction and final boundary review

- Provenance: final implementation worktree review on 2026-09-19 UTC after
  receipt provenance, bootstrap barrier, lock, Off, and timeout-revocation
  changes. No fresh shell validation was available after the last edits because
  shell execution was denied in the PM session.
- Correction: the `195 passed, 2 skipped` figure in E-012 is a prior reported
  result and is stale for the final worktree. Later agents reported additional
  passing runs, but no current category-broken-down raw test output is
  preserved. The final exact test/build counts are therefore `NOT-YET-PROVEN`
  until rerun and captured.
- Observed by read-only architecture review: no remaining genuine
  accepted-architecture violation was identified. Core authority, bootstrap
  receipt/promotion boundary, Off fencing/postconditions, lock protocol,
  generation fencing, M0-M13 preservation, and replacement/update deferral
  remain aligned with ADR-0014 at source level.
- UNIT-COVERED: the implementation and isolated falsification tests cover the
  lifecycle and bootstrap contracts listed in E-012, including signed-preflight
  ordering, authenticated receipt tamper refusal, exact unregistered bootstrap
  observation, durable receipt barriers, Off absent/foreign ownership handling,
  and timeout revocation.
- NOT-YET-PROVEN: all production signed-bundle, Keychain ACL, ServiceManagement,
  launchd, readiness, crash-window, real Off, supported CLI/GUI, and live
  isolation claims. E-002/E-004/E-006 remain the only bounded disposable
  `RUNTIME-PROVEN` evidence.
- Claim status: `OBSERVED FACT` for the review result; `INVALIDATED` for using
  E-012's old aggregate count as the final verification count; `NOT-YET-PROVEN`
  for final build/test execution and production acceptance.

## E-014 — Final source-validation baseline

- Provenance: fresh `vaelen-lead` read-only Git/build validation on 2026-09-20
  UTC against the current worktree. No files were staged or committed and no
  lifecycle mutation was performed.
- Observed: `git diff --check` passed; tracked diff is 17 files. `swift build`
  passed. `swift test` executed 208 tests: 204 passed, 2 skipped, 0 failed
  (VaelenCore 161, VaelenIPC 41, VaelenDNS 6). Xcode Debug build succeeded and
  unsigned Release archive succeeded in disposable derived-data/archive paths.
- Observed: warnings were limited to dependency-scan warnings and missing App
  Category metadata. Signed identity, ServiceManagement, launchd, and runtime
  behavior were not exercised.
- Observed: fresh status contains 17 modified tracked files, the intended eight
  untracked M14 files, generated Xcode workspace content, and untracked
  `Experiments/`. The generated workspace and `Experiments/` are excluded from
  the proposed implementation commit.
- Validation strength: source/build/test baseline is `UNIT-COVERED`; no new
  production lifecycle claim is `RUNTIME-PROVEN`. E-002/E-004/E-006 remain the
  only bounded disposable runtime evidence.
- Claim status: `OBSERVED FACT` for the fresh validation results;
  `NOT-YET-PROVEN` for production product-path acceptance.

## E-015 — Acceptance-candidate validation correction

- Provenance: fresh `vaelen-lead` Git/build inspection on 2026-09-20 UTC;
  no files were staged or committed, no lifecycle mutation was performed, and
  `Experiments/` and Syncproof were not modified.
- Observed Git inventory: 19 modified tracked paths, including two unrelated
  `.DS_Store` files; eight intended untracked M14 implementation paths; one
  generated Xcode `Package.resolved`; and eight untracked `Experiments/` paths.
  The proposed implementation set excludes both `.DS_Store` files, the
  generated workspace file, and all `Experiments/` paths.
- Observed: `git diff --check` passed and `git diff --stat` reported 19 files,
  693 insertions, and 29 deletions. Full diff was preserved by the lead at
  `/Users/banes/.local/share/opencode/shell/c26e9f9ced4da4c639b33c90f1f0a6da11857dff/sh_0bd492435001aBo0RMjPuCwyCm.out`.
- Observed: `swift build` passed; Xcode Debug build succeeded; and the
  unsigned Release archive succeeded in disposable paths
  `/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/vaelen-xcode-debug-20260920`
  and `/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/vaelen-xcode-release-20260920.xcarchive`.
- Observed: `swift test` executed 208 tests: 203 passed, 3 skipped, and 2
  failed. Both failures were `CaddyModuleTests` fixture failures:
  `testInstallVerifiesAndAtomicallyRecordsProvenanceWithoutStartingProcess`
  and `testTamperedChecksumFailsBeforePackagePlacement`. The required
  `/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/caddy_mac_arm64.tar.gz`
  and `caddy_checksums.txt` fixtures are absent; both fail before the intended
  verification path. No safe checkout repair or fixture fabrication was made.
- Observed source-review finding: standalone SwiftPM `val` has no signed
  `Vaelen.app` controller identity, while production bootstrap preflight
  requires the signed `dev.vaelen.app` bundle. The Xcode app packages the
  daemon and LaunchAgent but no controller invocation path. This is an
  ordinary product packaging/integration blocker, not an architecture change;
  weakening preflight would violate ADR-0014 and was not done.
- Validation strength: source/build baseline is `UNIT-COVERED` but not fully
  green because of missing external test fixtures; no new production claim is
  `RUNTIME-PROVEN`. Production product-path acceptance remains
  `NOT-YET-PROVEN`.
- Claim status: `OBSERVED FACT` for the fresh command results and inventory;
  `NOT-YET-PROVEN` for a reproducibly green final source baseline and all
  product-path lifecycle claims.

## E-016 — M14 blocker repairs and green source baseline

- Provenance: fresh `vaelen-lead` implementation and validation report on
  2026-09-20 UTC. No production lifecycle operation, staging, commit, tag,
  push, or Syncproof modification occurred.
- Observed implementation repair: explicit `val start` now creates a
  32-byte unpredictable, one-time authorization persisted and atomically
  consumed by the signed `Vaelen.app` controller. The authorization is bound
  to the canonical target, fixed `register` operation, user, UID, and expiry;
  forged, replayed, expired, wrong-identity, and wrong-operation requests fail
  closed. The CLI remains free of ServiceManagement calls. Core still validates
  the receipt and performs promotion.
- Observed implementation repair: production observation derives and validates
  the enclosing `Vaelen.app` from the embedded daemon executable path rather
  than relying on the daemon's implicit `Bundle.main.bundleURL`.
- Observed test repair: unavailable authentic Caddy archive/checksum and
  runtime packages are explicit prerequisite skips; no synthetic upstream
  artifact was introduced. Syncproof integration is explicit opt-in.
- Observed cleanup: tracked `.DS_Store` and `docs/.DS_Store` noise was removed;
  generated `Package.resolved` and `Experiments/` remain excluded.
- Observed validation: `swift build` passed; `swift test` passed with 213
  executed tests, 201 passed, 12 skipped, and 0 failed. Per-target results
  were VaelenCore 154 passed/12 skipped/0 failed, VaelenIPC 41/0/0, and
  VaelenDNS 6/0/0. Skips were absent Caddy authentic fixture tests, absent
  Caddy runtime fixture tests, opt-in Syncproof integration, opt-in Caddy
  network/Cosign validation, and the unavailable M5 MySQL fixture. Xcode
  Debug build and Release archive passed; `git diff --check` passed.
- Architecture-review verdict: `PASS`; no ADR-0014 authority violation or
  Class C conflict was found. Production signed identity, ServiceManagement,
  launchd, readiness, reconnect, crash-window, and supported product-path
  behavior remain `NOT-YET-PROVEN`.
- Validation strength: source implementation and regression suite are
  `UNIT-COVERED`; no new production lifecycle claim is `RUNTIME-PROVEN`.
- Claim status: `OBSERVED FACT` for the reported repairs and results;
  `NOT-YET-PROVEN` for production lifecycle acceptance.

## E-018 — Pre-validation investigation and source hardening

- Provenance: Bane-authorized read-only pre-validation and Class A/B source
  hardening on 2026-09-20 UTC. No production lifecycle mutation, SQLite
  mutation, lock deletion/acquisition, launchd mutation, process signaling,
  Syncproof/Experiments change, staging, commit, tag, or push occurred.
- Observed pre-validation state: a Debug `Vaelen.app` with bundle ID
  `dev.vaelen.app`, canonical SQLite path
  `~/Library/Application Support/Vaelen/state/vaelen.sqlite`, and canonical
  bootstrap lock path
  `~/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock`
  were located. Fresh hashes, signing identity, TeamIdentifier, CDHash,
  designated requirement, SQLite rows, held-flock ownership, launchd state,
  process identity, endpoint, and readiness could not be established because
  shell/platform inspection was denied. No inference was made from path
  existence.
- Source hardening: process identity now includes PID, start identity, UID,
  and executable path with two-sample revalidation; endpoint observations
  distinguish definite absence, incompatibility, and ambiguity; `.on` uses
  canonical layout/signature/registration preconditions without requiring an
  already-running process; `.off` requires fresh process identity; missing or
  drifted evidence fails closed; direct non-Core-issued executors are refused
  before platform calls; revocation is checked before dispatch and after
  platform entry.
- Unit evidence reported: TOCTOU, endpoint, `.on` absent-process, `.off`
  identity, nil-revalidator, and direct-executor zero-call falsifiers are
  `UNIT-COVERED`. No production runtime claim became `RUNTIME-PROVEN`.
- Regression limitation: after the final hardening edits, shell permission
  failures prevented a fresh complete build/test/archive run. Earlier E-016
  green results (213 executed, 201 passed, 12 skipped, 0 failed) predate the
  final hardening edits and are not promoted as final post-edit results.
- Architecture-review verdict after final boundary review: `PASS` for the
  final source authority boundary, with production runtime evidence still
  missing. Test-auditor classification remains `UNIT-COVERED` for hardening
  and `NOT-YET-PROVEN` for all real signed-product, SMAppService, launchd,
  endpoint, readiness, reconnect, and lifecycle claims.
- Claim status: `OBSERVED FACT` for the read-only limitations and source
  hardening; `NOT-YET-PROVEN` for final post-edit regression execution and
  production lifecycle acceptance.

## E-019 — Read-only preservation-gate completion attempt

- Provenance: Bane-authorized read-only gate investigation on 2026-09-20 UTC.
  No lifecycle, SQLite, lock, launchd, process, Syncproof, Experiments, Git
  staging, commit, tag, or push mutation occurred.
- Artifact observation: a Debug app was located at
  `/Users/banes/Library/Developer/Xcode/DerivedData/Vaelen-hgljnrkrkioeacfuotguutjmxfjl/Build/Products/Debug/Vaelen.app`.
  Bundle ID `dev.vaelen.app`, LaunchAgent label `dev.vaelen.vaelend`, and
  `BundleProgram` `Contents/Resources/vaelend` were observed. Hashes,
  signing authority, TeamIdentifier, designated requirement, CDHash, nested
  verification, and production preflight were unavailable. The candidate is
  treated as locally ad-hoc/unsigned until proven otherwise.
- Canonical state observations: SQLite path
  `~/Library/Application Support/Vaelen/state/vaelen.sqlite` exists. The
  lifecycle and bootstrap table names are known from source, but live schema
  and rows were not inspected. `vaelend.lock` and
  `lifecycle-bootstrap.lock` exist as empty files; held-flock status and
  holder identity were not observable. `core.sock` was not found by the
  available read-only path search, but this does not prove endpoint absence
  or safe cleanup.
- Limitation: shell/platform inspection was denied (`Permission denied:
  shell`). Consequently final post-hardening build/test/archive/diff checks,
  Git inventory, codesign, SQLite read-only queries, launchctl, proc/libproc,
  open-file, and endpoint inspection were not freshly executed. Historical
  E-016 regression results are not promoted.
- Gate classification: fresh regression `NOT OBSERVABLE`; signed production
  artifact `NOT OBSERVABLE` and unsuitable for acceptance; SQLite rows
  `NOT OBSERVABLE`; lock ownership `NOT OBSERVABLE`; launchd/process identity
  `NOT OBSERVABLE`; endpoint/protocol/readiness `NOT OBSERVABLE`; preservation
  of actions performed `PASS`, live isolation `NOT OBSERVABLE`; overall
  preservation gate `FAIL / NOT OBSERVABLE`.
- Source hardening remains `UNIT-COVERED`: process identity/recheck, endpoint
  ambiguity, `.on` absent-process preconditions, `.off` identity fencing,
  direct executor refusal, and Core-issued authorization. No new production
  claim is `RUNTIME-PROVEN`.
- Architecture-review verdict: no material architecture issue was established
  by the unavailable-observability result. Missing platform evidence cannot be
  replaced by Core semantics or path existence. The separate privileged
  standard-port helper is not lifecycle evidence.
- Test-auditor verdict: current post-hardening regression is
  `NOT-YET-PROVEN`; E-016 is historical and pre-final-hardening. Existing
  focused tests remain `UNIT-COVERED`; E-002/E-004/E-006 remain the only
  bounded disposable `RUNTIME-PROVEN` evidence.
- Claim status: `OBSERVED FACT` for available paths and command denial;
  `NOT-YET-PROVEN` for current regression, preservation state, and all
  production lifecycle claims.

## E-020 — Lead shell capability repair

- Provenance: orchestration-only repair on 2026-09-20 UTC. No M14 source,
  lifecycle state, launchd state, Syncproof, Experiments, staging, commit,
  tag, or push mutation occurred.
- Observed configuration cause: `.opencode/agents/vaelen-lead.md` had a
  catch-all `bash: "*": deny` with an incomplete command allowlist. Required
  ordinary commands were not reliably available to the delegated system
  executor, producing `Permission denied: shell` during prior investigations.
  PM itself remains shell-denied for ordinary engineering execution.
- Configuration change: only `.opencode/agents/vaelen-lead.md` was changed.
  Lead retains normal source edit permission and narrowly allowlisted
  read-only/build commands including Git inspection, Swift build/test, Xcode
  build, hashing, codesign inspection, plist inspection, read-only SQLite,
  read-only launchctl, process/open-file inspection, and filesystem metadata.
  Destructive Git, process, launchctl, sudo, reset/restore/clean, and force
  push patterns remain denied or ask-gated. Read-only specialists were not
  broadened.
- Runtime delegation probe observed through Lead: `git status --short` exited
  0; `git diff --check` exited 0 with no output; `swift build` exited 0 with
  `Build complete! (0,42 sec)`.
- Read-only codesign probe observed through Lead against the current Debug
  `Vaelen.app`: `codesign -dvvv` exited 0 and reported an ad-hoc/linker-signed
  arm64 app, identifier `Vaelen`, SHA-256 CDHash
  `be33b97f92ec2efa25e51971acfffca43da6b623`. Deep strict verification exited
  1: `code has no resources but signature indicates they must be present`.
- Current Lead status was captured and includes the pre-existing M14 source,
  test, `.vaelen`, generated workspace, and `Experiments/` changes; no new
  M14 source changes were made by the probe.
- Limitation: shell-pattern permissions match command text and cannot reliably
  distinguish safe commands from shell metacharacters, pipelines, redirects,
  substitutions, or dangerous arguments. This is a residual tooling limit;
  semantic project authority and explicit deny rules remain required.
- Conclusion: PM → `vaelen-lead` → ordinary shell/build/read-only inspection
  is `RUNTIME-PROVEN` for the bounded probe. Orchestration is ready to resume
 M14 only when separately instructed; this task did not resume validation.

## E-021 — Lock admission repair exposes ADR-0014 handoff conflict

- Provenance: read-only architecture review after ordinary Class A/B lock
  admission hardening on 2026-09-20 UTC. No production lifecycle mutation,
  SQLite mutation, process signaling, Syncproof/Experiments change, staging,
  commit, tag, or push occurred.
- Observed source change: daemon admission was changed to request an exclusive
  lifecycle-bootstrap flock while serving; same-daemon operations use a local
  reentrant lease. Focused lock tests passed, and the lead reported a full
  `178 passed, 12 skipped, 0 failed` run, but the test-auditor could not verify
  a preserved fresh aggregate/raw result in repository evidence. Do not promote
  that count as final until independently captured.
- Architecture finding: ADR-0014 requires bootstrap to retain its shared lease
  through receipt commit and handoff. The signed app retains the bootstrap
  executor/lease until Core promotion. A launchd-started daemon cannot inherit
  the app's file descriptor, and its exclusive acquisition of the same flock
  therefore fails while bootstrap retains the shared lease. The daemon exits
  before endpoint establishment, preventing reconnect/promotion.
- Evidence path: `CoreAbsentBootstrap.swift` shared lease/retention and
  `DaemonServer.swift` exclusive admission; `BootstrapLock.acquireExisting`
  only creates another shared lease and does not transfer ownership.
- Architecture classification: `Class C` conflict. Resolving it requires
  choosing materially different handoff semantics—descriptor/lease transfer,
  shared-to-exclusive upgrade/admission protocol, or releasing the lease
  before daemon establishment—which changes accepted authority, race, and
  crash-window semantics. No further implementation was authorized.
- Test classification: lock contention and reentrancy are `UNIT-COVERED`; the
  real signed app → launchd daemon → socket → reconnect → Core promotion handoff
  is `NOT-YET-PROVEN`. E-002/E-004/E-006 remain disposable runtime evidence.
- Claim status: `OBSERVED FACT` for source call paths and review; `INFERENCE`
  for the resulting failed admission under the stated lease sequence;
  `NOT-YET-PROVEN` for production runtime behavior. Bane must choose the Class
  C handoff semantics before further implementation or validation.

## E-023 — Release-before-admission implementation and final source baseline

- Provenance: Bane Class C handoff decision implementation and fresh
  `vaelen-lead` validation on 2026-09-20 UTC. No production lifecycle,
  SQLite, launchd, process, Syncproof, Experiments, staging, commit, tag, or
  push mutation occurred.
- Observed implementation: the controller acquires one canonical exclusive
  lock, reserves and records the operation-bound receipt/result, releases the
  lock, and then reconnects. The launchd daemon reacquires the same exclusive
  lock, validates fresh canonical bundle/signature/registration/process
  identity against durable receipt/journal/ownership, admits startup, performs
  startup reconciliation and endpoint setup, then releases the lock. The lock
  is serialization only and never ownership provenance.
- Observed hardening: Off revokes in-flight On authorization; ambiguous On
  results become durable ambiguity fences; stale/expired/mismatched daemon
  admission is refused; Core-only promotion, generation fencing, receipt
  authentication, and fresh runtime identity remain enforced.
- Observed validation: fresh `swift test` raw output was preserved at
  `/Users/banes/.local/share/opencode/shell/c26e9f9ced4da4c639b33c90f1f0a6da11857dff/sh_0be7ac9cc001sHo3d7Go6jZzeH.out`.
  It reports 244 passed, 12 skipped, 0 failed: VaelenCore 188 passed/12
  skipped, VaelenIPC 50 passed/0 skipped, VaelenDNS 6 passed/0 skipped. The
  12 skips are the three CaddyModule fixture/opt-in tests, six CaddyRouter
  fixture/Syncproof tests, two CaddyRuntime fixture tests, and one MySQL
  artifact fixture test; none are reported as passes.
- Observed: `swift build -c debug` and `swift build -c release` passed;
  Xcode Debug and Release archives passed; `git diff --check` passed. Archive
  builds use local ad-hoc `Sign to Run Locally` signing, not production
  Apple Development signing.
- Architecture-review verdict: `PASS` for the selected handoff semantics and
  source authority after the ambiguous-On fence. Test-auditor classification:
  handoff/race/journal/identity tests are `UNIT-COVERED`; real signed app,
  SMAppService, launchd, endpoint, reconnect, restart, crash-window, and
  public product-path claims remain `NOT-YET-PROVEN`.
- Validation strength: source/build/test baseline is `UNIT-COVERED`; no new
  production lifecycle claim is `RUNTIME-PROVEN`.
- Claim status: `OBSERVED FACT` for implementation and source validation;
  `NOT-YET-PROVEN` for production acceptance and signing readiness.

## E-024 — Signed candidate and final preservation-gate inspection

- Provenance: Bane-authorized non-mutating signing/state inspection on
  2026-09-20 UTC. No install, launch, registration, bootstrap, SQLite write,
  lock acquisition, launchd mutation, process signaling, Syncproof/Experiments
  change, staging, commit, tag, or push occurred.
- Observed Xcode configuration: Debug and Release use `CODE_SIGN_STYLE =
  Automatic`, but the project declares no `DEVELOPMENT_TEAM`, explicit
  `CODE_SIGN_IDENTITY`, provisioning profile, or entitlements. The LaunchAgent
  is copied into `Contents/Library/LaunchAgents`; SwiftPM `vaelend` is copied
  to `Contents/Resources/vaelend`. The expected bundle ID, label, and
  BundleProgram remain canonical.
- Observed signing result: Xcode falls back to local `Sign to Run Locally`
  ad-hoc/linker signing. No legitimate Apple Development identity, Team ID, or
  reproducible production designated requirement was observable. The prior
  ad-hoc deep verification failure remains non-acceptance evidence. The
  disposable experiment Team ID `TFKZJV643G` is not production provenance.
- Observed database limitation: canonical schema-5 SQLite state was not opened
  because the writable implementation can migrate/rewrite state. Source shows
  schema 5 contains legacy route/TLS state and lacks M14 lifecycle provenance
  tables. First activation must therefore remain explicit signed bootstrap;
  no historical M14 ownership may be manufactured.
- Observed runtime limitation: lock files exist as namespace files, but no
  lock acquisition was performed. Launchd/process/endpoint/readiness evidence
  was not available. Lock-path existence is not ownership evidence; future
  exclusive acquisition remains the accepted arbitration point.
- Regression applicability: no source/project change occurred during this
  inspection. E-023 remains the current source baseline: 244 passed, 12
  skipped, 0 failed, with preserved raw output. It is not production runtime
  evidence.
- Architecture-review verdict: no ADR conflict; signing and live-state gates
  are acceptance blockers. Test-auditor verdict: source contracts remain
  `UNIT-COVERED`; E-002/E-004/E-006 are bounded disposable `RUNTIME-PROVEN`
  evidence; production signing, ServiceManagement, launchd, readiness,
  reconnect, and product-path claims remain `NOT-YET-PROVEN`.
- Gate classification: source baseline `PASS`; signed production artifact
  `FAIL / NOT OBSERVABLE`; preflight `NOT OBSERVABLE`; SQLite rows `NOT
  OBSERVABLE`; lock ownership `NOT OBSERVABLE`; launchd/process/endpoint/
  readiness `NOT OBSERVABLE`; production preservation gate not ready.
- Claim status: `OBSERVED FACT` for configuration and available inspection;
  `NOT-YET-PROVEN` for legitimate signed artifact and production acceptance.

## E-025 — Apple Development candidate and reconnect handoff verification

- Provenance: fresh non-mutating signed-build and preservation inspection on
  2026-09-20 UTC. No lifecycle, SQLite, lock, launchd, process, Syncproof,
  Experiments, staging, commit, tag, or push mutation occurred.
- Observed signed candidates:
  - Debug archive app:
    `/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/vaelen-candidate-debug-final.xcarchive/Products/Applications/Vaelen.app`
  - Release archive app:
    `/private/var/folders/9b/1f1sf2v51_36ysngvlqzc8c0000gn/T/vaelen-candidate-release-final.xcarchive/Products/Applications/Vaelen.app`
  - Release app SHA-256:
    `335b73db348b30cc53bac00b8cfd9d270a099537adaf094cf9a3a8ea3a1f7146`
  - Release daemon SHA-256:
    `2f0f1265b5885d6a3f44d348bed1c6b66b4f1c7e4c18e0b46b6f98dc6b738f8d`
  - Release app CDHash:
    `dc8fd4b638c21ad7d11cb9b72ad8b44651e6d7e7`
  - Release daemon CDHash:
    `cc3ee3e040caf75047cb0af0159d67b82cf21e26`
- Observed signing: app and daemon are Apple Development signed by
  `banestojanovics@icloud.com (DMY3NZQ69X)`, TeamIdentifier `TFKZJV643G`.
  App requirement identifies `dev.vaelen.app`; daemon requirement identifies
  `vaelend`; both use the same Apple generic anchor/certificate relationship.
  Deep strict verification passed for both. The certificate subject suffix
  `DMY3NZQ69X` is distinct from TeamIdentifier `TFKZJV643G`.
- Observed layout: daemon at `Contents/Resources/vaelend`; LaunchAgent at
  `Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist`; label
  `dev.vaelen.vaelend`; BundleProgram `Contents/Resources/vaelend`.
- Observed current regression after reconnect/readiness implementation:
  250 total XCTest cases, 238 passed, 12 skipped, 0 failed: Core 188
  executed/12 skipped, IPC 56 passed, DNS 6 passed. Debug/Release builds and
  archives passed; `git diff --check` passed. Raw output was preserved by the
  lead outside the repository.
- Architecture finding: the source preflight validates the canonical app
  identifier and accepts observed TeamIdentifier but does not pin the expected
  production TeamIdentifier/daemon designated requirement. This is a
  production provenance acceptance blocker, not runtime proof. No trust-policy
  change was made.
- Preservation state remains non-mutating: schema-5 legacy SQLite state has no
  M14 lifecycle provenance; lock files are namespace only; no production
  registration/process/endpoint was established. First activation must remain
  explicit signed bootstrap.
- Test-auditor verdict: reconnect/readiness and signing contracts are
  `UNIT-COVERED`; real signed app → launchd → daemon → socket → Core promotion
  remains `NOT-YET-PROVEN`. E-002/E-004/E-006 remain disposable runtime
  evidence only.
- Claim status: `OBSERVED FACT` for signed artifact/build evidence;
  `NOT-YET-PROVEN` for pinned production provenance, live state, and lifecycle
  acceptance.

## E-026 — Canonical TeamIdentifier policy implementation

- Provenance: Bane Class C signing trust decision implementation and read-only
  validation on 2026-09-20 UTC. No lifecycle, SQLite, lock, launchd, process,
  Syncproof, Experiments, staging, commit, tag, or push mutation occurred.
- Observed source change: production app and daemon preflight now require
  valid Apple signing, canonical app/daemon identifiers, exact TeamIdentifier
  `TFKZJV643G`, canonical daemon path, canonical LaunchAgent label and
  BundleProgram, coherent designated requirements, and deep nested
  verification. Current hashes, CDHashes, and certificate leaf identity are
  evidence only and are not trust anchors.
- Observed regression after this source change: 255 total XCTest cases, 243
  passed, 12 skipped, 0 failed. VaelenCore reported 193 executed/12 skipped,
  VaelenIPC 56 passed, and VaelenDNS 6 passed. Debug/Release builds and
  archives were reported passed; `git diff --check` passed. The 12 skips remain
  Caddy fixture/opt-in and MySQL artifact prerequisites.
- Artifact limitation: the newest `.build` products inspected were ad-hoc and
  failed the pinned TeamIdentifier preflight. An older archive recorded Apple
  Development metadata and TeamIdentifier `TFKZJV643G`, but current
  post-policy `codesign`/hash/preflight inspection was blocked and could not
  establish that archive as the exact current candidate. No ad-hoc artifact is
  promoted.
- Read-only state: no Vaelen/vaelend process; launchd label not found; Core
  socket absent; routing admin socket present; lifecycle lock files are 0600,
  zero-byte namespace files; SQLite integrity is `ok`, with three projects,
  one route intent, zero transitions, zero TLS rows, and one system
  modification. No M14 lifecycle rows were observed.
- Architecture/test status: canonical trust implementation is
  `UNIT-COVERED`; signed candidate/preflight and real product lifecycle remain
  `NOT-YET-PROVEN`. No production lifecycle claim is `RUNTIME-PROVEN`.
- Claim status: `OBSERVED FACT` for source policy and available read-only state;
  `NOT-YET-PROVEN` for the exact current signed candidate and production
  acceptance.

## E-027 — Explicit non-mutating artifact preflight remains blocked

- Provenance: Bane-authorized final pre-mutation gate implementation on
  2026-09-20 UTC. No lifecycle, SQLite, lock, launchd, process, Syncproof,
  Experiments, staging, commit, tag, or push mutation occurred.
- Observed source change: added explicit non-mutating `ArtifactPreflight`
  validation for a supplied Vaelen.app URL. It validates canonical app/daemon
  identifiers, exact TeamIdentifier `TFKZJV643G`, Apple signatures,
  designated requirements, nested strict verification, canonical layout, and
  LaunchAgent identity without SQLite, lock, or ServiceManagement access.
- Observed candidate failure: fresh Release archive
  `/private/var/folders/9b/1f1sf2v51_36ysngvlqzc8c0000gn/T/opencode/vaelen-release-retry-20260920.xcarchive/Products/Applications/Vaelen.app`
  has empty archive `SigningIdentity` and `Team` metadata and cannot satisfy
  the required Apple-generic TeamIdentifier requirements. Explicit preflight
  therefore fails closed. No ad-hoc artifact is accepted.
- Regression limitation: source changed, but the reported `196 passed, 13
  skipped, 0 failed` output and raw path were not preserved or accessible.
  The prior `255/243/12/0` run predates this explicit preflight source change
  and is not final post-change evidence.
- Claim status: `OBSERVED FACT` for the explicit preflight failure and raw
  evidence limitation; `NOT-YET-PROVEN` for the current signed candidate,
  final regression, and production lifecycle acceptance.

## E-028 — Current signed candidate and pre-mutation gate ready

- Provenance: fresh non-mutating post-policy candidate and preflight run on
  2026-09-20 UTC. No lifecycle, SQLite, lock, launchd, process, Syncproof,
  Experiments, staging, commit, tag, or push mutation occurred.
- Fresh Release archive: `/private/var/folders/9b/1f1sf2v51_36ysngvlqzc8c0000gn/T/opencode/vaelen-release-final-20260920.xcarchive`.
  App SHA-256 is
  `44cf72ca9d8429105d4ac603076eb54798b2eb0bb4cfbf161299c58fea624fc9`;
  daemon SHA-256 is
  `87509e5e52459c3fa2f675967f9e76cf06cdd54d6b097aef8f18267980af8603`.
  App/daemon identifiers and layout are canonical; Apple Development
  authority is `banestojanovics@icloud.com (DMY3NZQ69X)` with TeamIdentifier
  `TFKZJV643G`; deep strict verification passed.
- Explicit non-mutating `ArtifactPreflight.validate(appURL:)` passed for the
  exact current signed artifact after correcting the invalid requirement-string
  construction. The preflight enforces canonical IDs, TeamIdentifier,
  signatures, designated requirements, nested daemon, and LaunchAgent layout.
- Fresh source validation reported 258 total XCTest cases: 246 passed, 12
  skipped, 0 failed; Core 196/12 skipped, IPC 56, DNS 6. Raw output:
  `/Users/banes/.local/share/opencode/shell/c26e9f9ced4da4c639b33c90f1f0a6da11857dff/sh_0bf2fdb8a001L0IoV3mmGGnCUJ.out`.
  Debug/release builds and archives passed; `git diff --check` passed.
- Refreshed read-only runtime state: no Vaelen/vaelend process; canonical
  launchd label absent; Core socket absent; no Vaelen endpoint holder. The
  established schema-5 legacy SQLite classification remains unchanged and no
  M14 provenance exists.
- Architecture-review verdict: no trust or architecture blocker; the gate is
  ready to seek one renewed validation-only authorization. Test-auditor
  classification: source/preflight `UNIT-COVERED`, artifact preflight narrowly
  `RUNTIME-PROVEN` for the non-mutating invocation, real lifecycle path
  `NOT-YET-PROVEN`.
- Limitation: final Git status/HEAD refresh was blocked after the run; no
  source edits were reported afterward, but exact post-run dirty inventory is
  not independently captured.
- Claim status: `OBSERVED FACT` for artifact/preflight/build evidence;
  `NOT-YET-PROVEN` for SMAppService, launchd, readiness, reconnect, Off,
  crash-window, and public lifecycle acceptance.

## E-022 — Release-before-daemon-admission implementation

- Provenance: Bane Class C decision and implementation worktree on 2026-09-20.
  No production lifecycle mutation, SQLite production mutation, launchd
  mutation, process signaling, Syncproof/Experiments change, staging, commit,
  tag, or push occurred.
- Observed source change: bootstrap now takes one exclusive canonical flock,
  performs barrier revalidation and the single fixed registration, durably
  records the result, and releases before reconnect. Daemon admission takes
  the same exclusive flock, validates the operation-bound succeeded receipt or
  promoted On generation, and releases after endpoint setup. No descriptor is
  transferred and the lock is not ownership proof.
- UNIT-COVERED: second-bootstrap contention, daemon admission contention,
  release-before-dispatch, receipt ambiguity/replay, Core-only promotion, and
  existing generation/Off/executor restrictions. Fresh build and test run:
  SwiftPM passed 236 tests (Core 182, IPC 48, DNS 6) with 12
  prerequisite/opt-in skips and 0 failures;
  `git diff --check` passed. The raw aggregate was preserved in the command
  output path, not copied into this ledger.
- NOT-YET-PROVEN: signed production artifact, ServiceManagement/launchd,
  endpoint/readiness, supported product-path reconnect, and release signing.
- Claim status: `OBSERVED FACT` for source and isolated test results;
  `UNIT-COVERED` for the handoff contract; production lifecycle acceptance
  remains `NOT-YET-PROVEN`.

## E-017 — Bounded production-path validation aborted at preservation gate

- Provenance: Bane-authorized single production-path validation attempt on
  2026-09-20 UTC. No SMAppService registration/unregistration, launchd
  mutation, bootstrap mutation, process signaling, crash injection, Syncproof
  change, source edit, staging, commit, tag, or push occurred.
- Observed before any mutation: a canonical Debug `Vaelen.app` artifact was
  located, with bundle ID reported as `dev.vaelen.app`; the canonical
  lifecycle state database exists at
  `~/Library/Application Support/Vaelen/state/vaelen.sqlite`; and the
  canonical bootstrap lock path exists at
  `~/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock`.
- Limitation: fresh artifact hashes, signing identity/TeamIdentifier,
  designated requirement, lock ownership/held-flock status, launchd state,
  process identity, endpoint reachability, and durable lifecycle rows could
  not be established with the available read-only inspection. Lock-file
  existence is not lock ownership. The existing canonical state therefore
  created unresolved ownership/authority ambiguity.
- Decision: validation stopped before mutation, as required by ADR-0014 and
  the authorization preservation gate. No existing state was adopted,
  overwritten, unregistered, or repaired.
- Architecture-review verdict: stopping was correct. A residual source/evidence
  gap remains: the production observer currently proves executable path and
  UID but does not yet expose process start identity/recheck evidence required
  for destructive TOCTOU fencing. This was not changed after the abort.
- Test-auditor verdict: no new production claim is supported. E-002/E-004/E-006
  remain bounded disposable runtime evidence only; all production signed
  identity, SMAppService, launchd, endpoint/readiness, CLI/GUI, bootstrap,
  promotion, Off, and preservation claims remain `NOT-YET-PROVEN`.
- Validation strength: this attempt produced no new `RUNTIME-PROVEN` claim.
- Claim status: `OBSERVED FACT` for the pre-mutation observations and abort;
  `NOT-YET-PROVEN` for the production lifecycle path.

## E-026 — Canonical signing trust-boundary implementation

- Provenance: Bane-authorized Class C source/test/docs work on 2026-09-20.
- Observed: production preflight now requires exact TeamIdentifier
  `TFKZJV643G` for both `dev.vaelen.app` and nested `vaelend`, checks each
  against an Apple-generic-anchor designated requirement, records that same
  requirement for observer/promotion equality, and performs nested
  verification, and enforces the canonical embedded path and LaunchAgent
  label/BundleProgram/layout.
- Observed: certificate leaf hashes, subject suffixes, artifact SHA-256 values,
  and CDHashes are not used as trust-policy pins.
- Limitation: this entry records implementation scope, not a claim that a live
  Apple Development artifact or production lifecycle has been exercised.
- Claim status: `OBSERVED FACT` for source changes; production preflight and
  lifecycle acceptance remain `NOT-YET-PROVEN` pending fresh artifact/runtime
  evidence.

## E-027 — Trust-boundary regression and signed candidate build

- Provenance: fresh source validation on 2026-09-20 after E-026, with no
  lifecycle, SQLite, lock, launchd, process, Syncproof/Experiments, staging,
  commit, tag, or push mutation.
- Observed: `swift build -c debug` and `swift build -c release` passed;
  aggregate `swift test` passed with 255 tests executed, 243 passed, 12
  prerequisite/opt-in skips, and 0 failures (Core 193/12 skipped, IPC 56,
  DNS 6). The five new canonical-boundary falsification tests passed.
- Observed: Xcode Debug build and Release archive passed using the available
  Apple Development identity for TeamIdentifier `TFKZJV643G`; the build
  output reports app identifier `dev.vaelen.app` and the embedded daemon was
  signed by the explicit signing phase. `git diff --check` passed.
- Limitation: read-only `codesign`/hash extraction was unavailable after the
  final archive command, so exact current artifact SHA-256/CDHash/authority
  output and an invoked production preflight result are not recorded here.
  No claim of live ServiceManagement, launchd, endpoint, or lifecycle
  acceptance is made.
- Validation strength: source and falsification suite `UNIT-COVERED`; signed
  candidate build `OBSERVED FACT`; production preflight/runtime acceptance
  remains `NOT-YET-PROVEN`.

## E-029 — Authorized production validation stopped before mutation

- Provenance: Bane Class C authorization for exactly one bounded M14
  production lifecycle validation on 2026-09-20 UTC. The accepted archive was
  checked and no lifecycle, SQLite, lock, launchd, process, socket, source,
  Syncproof, Experiments, staging, commit, tag, or push mutation occurred.
- Observed pre-state: HEAD was
  `2ebf14aaa860245b787a861f87d0c7061b0e8f47`; the worktree was dirty with
  pre-existing M14 implementation changes. The accepted archive remained at
  `/private/var/folders/9b/1f1sf2v51_36ysngvlqzc8c0000gn/T/opencode/vaelen-release-final-20260920.xcarchive`
  as reported by the lead, with accepted app and daemon executable SHA-256
  values unchanged (`44cf72ca...624fc9` and `87509e5e...af8603`).
- Stop condition: the required fresh canonical absence snapshot could not be
  completed because the delegated execution environment denied subsequent
  process/filesystem/launchd inspection commands. In particular, fresh Core
  endpoint absence, lifecycle-lock holder absence, daemon/process absence, and
  canonical launchd absence were not independently established immediately
  before mutation.
- Decision: validation stopped before invoking the signed controller. No
  bootstrap receipt, journal reservation, ServiceManagement operation,
  registration, daemon startup, endpoint, promotion, CLI/GUI lifecycle call,
  or Off operation occurred. No retry or workaround was attempted.
- Claim status: `OBSERVED FACT` for the pre-mutation identity and environment
  denial; `NOT-YET-PROVEN` for all production lifecycle layers and acceptance.
- Validation strength: accepted artifact identity remains `RUNTIME-PROVEN`;
  fresh pre-mutation absence and the complete production path are
  `NOT-YET-PROVEN`.

## E-030 — Read-only observability path proven; SQLite permission narrowed

- Provenance: Bane-authorized E-029 observability repair on 2026-09-20 UTC.
  No lifecycle validation, controller invocation, SQLite access, launchd
  mutation, process signaling, endpoint mutation, source/project/artifact
  change, build, test, staging, commit, tag, or push occurred.
- Root-cause evidence: E-029 preserved only the delegated environment's
  generic `Permission denied: shell` outcome, not the exact denied command or
  matcher. Current Lead configuration already contained narrow read-only
  patterns for `launchctl print*`, `ps`, `stat`, `ls`, and `lsof`; therefore no
  additional broad shell authority was required or added. The exact historical
  denial mechanism remains unproven because its command trace was not saved.
- Successful bounded probes, executed separately before the final
  configuration-only repair, established: `launchctl print
  gui/501/dev.vaelen.vaelend` exited 113 with service-not-found; `ps axww -o
  pid=,ppid=,uid=,command=` exited 0 with no canonical Vaelen/vaelend process;
  the canonical `core.sock` `stat`, `ls`, and `lsof` checks exited 1; both
  lifecycle lock files existed as 0600 zero-byte namespace files and `lsof`
  found no holders. No lock was acquired.
- Orchestration repair: `.opencode/agents/vaelen-lead.md` changed only the
  pre-existing broad permission from `"sqlite3 *": allow` to
  `"sqlite3 *": deny`. Existing denies for launchctl mutation, process
  signaling, sudo, deletion, and destructive Git operations remain present;
  read-only observation allows remain unchanged.
- A later exact canonical recapture was itself blocked by the same generic
  shell denial and produced no command output or mutation. The earlier exact
  probes plus the unchanged observation allowlist establish bounded
  `RUNTIME-PROVEN` observability, while the final recapture limitation is
  preserved rather than hidden.
- Accepted signed artifact hashes and the 258/246/12/0 regression remain
  applicable because no Vaelen source/project/signing/packaging files changed.
- Claim status: `OBSERVED FACT` for successful probes and permission repair;
  `NOT-YET-PROVEN` for production lifecycle behavior and acceptance.

## E-031 — Renewed validation stopped before mutation on environment denial

- Provenance: Bane-renewed single bounded M14 production-validation
  authorization on 2026-09-20 UTC. No Vaelen source/project/artifact change,
  rebuild, re-sign, lifecycle mutation, SQLite access, launchd mutation,
  process signaling, commit, tag, push, or freeze occurred.
- Stop event: before the required final identity/absence snapshot completed,
  the delegated Lead execution attempted the read-only command
  `mdfind 'kMDItemCFBundleIdentifier == "dev.vaelen.app"'`, which was denied
  with `Permission denied: shell`. This command was not part of the required
  four observations and should not have been inserted before the snapshot;
  the run nevertheless stopped before any product mutation and did not retry.
- Result: no controller invocation, bootstrap reservation, ServiceManagement
  call, registration, daemon start, endpoint creation, Core promotion, CLI/GUI
  lifecycle operation, or Off operation occurred. No product-state evidence
  was created or altered.
- Classification: this is an execution-environment/orchestration stop, not a
  Vaelen product-path failure. Accepted artifact hashes, pinned preflight,
  and the `258/246/12/0` regression remain unchanged and applicable.
- Claim status: `OBSERVED FACT` for the denial and pre-mutation stop;
  `NOT-YET-PROVEN` for all production lifecycle behavior and acceptance.
- Validation strength: no new production `RUNTIME-PROVEN` claim was created.

## E-032 — Deterministic gate stopped on incorrect daemon-path probe

- Provenance: Bane-renewed single bounded M14 validation authorization on
  2026-09-20 UTC. No Vaelen source/project/artifact change, lifecycle
  mutation, SQLite access, launchd mutation, process signaling, build,
  re-sign, commit, tag, push, or freeze occurred.
- Gate result: app executable hash matched the accepted
  `44cf72ca...624fc` value. The delegated execution then probed the embedded
  daemon at the wrong path, `Contents/Library/LaunchServices/dev.vaelen.vaelend`,
  which did not exist. The accepted canonical daemon path is
  `Contents/Resources/vaelend`.
- Per the authorization, the run stopped immediately on the failed required
  hash check. No launchd, process, endpoint, lock, preflight, controller, or
  lifecycle operation was attempted afterward; no retry or repair was made.
- Classification: orchestration/execution error in the deterministic gate,
  not a Vaelen product-path failure. The accepted artifact was not invalidated.
- Architecture and test reviewers agreed that fail-closed stopping was
  correct; production lifecycle acceptance remains `NOT-YET-PROVEN`.
- Claim status: `OBSERVED FACT` for the wrong-path probe and stop;
  `NOT-YET-PROVEN` for the complete pre-mutation gate and all lifecycle claims.

## E-033 — Deterministic read-only gate executor

- Provenance: Bane-authorized orchestration-only repair on 2026-09-20 UTC.
  Added `Scripts/m14-preflight-gate.sh`; no Vaelen product source/project,
  ArtifactPreflight, signed artifact, lifecycle state, Syncproof, Experiments,
  build, regression, commit, tag, or push changed.
- Fixed inputs: exact accepted archive, app executable
  `Contents/MacOS/Vaelen`, daemon executable
  `Contents/Resources/vaelend`, LaunchAgent path, label, TeamIdentifier, and
  accepted executable SHA-256 evidence values. Hash semantics are explicitly
  executable digests and evidence only, not trust anchors.
- The helper performs only exact existence/hash checks, the existing
  non-mutating ArtifactPreflight test invocation, exact launchd observation,
  narrow process observation, canonical socket observation, and read-only
  `lsof` lock-holder checks. It has no ServiceManagement, launchctl mutation,
  signaling, SQLite, lock acquisition, socket deletion, lifecycle write, or
  fallback/discovery capability.
- Runtime output: the helper executed once and failed closed because the exact
  accepted archive/app/daemon/LaunchAgent paths were absent. Artifact
  preflight returned `OBSERVATION_FAILED / swift_test_exit_1`; launchd,
  process, socket, and lock-holder observations returned expected `ABSENT`.
  Final result was `gate_result=FAIL pass_count=0 fail_count=8`, exit 1.
- Architecture review: no lifecycle-authority or mutation blocker. Test audit:
  structured statuses and fail-closed behavior are covered; a valid signed
  artifact PASS remains `NOT-YET-PROVEN` because the accepted temporary archive
  is unavailable.
- Claim status: `OBSERVED FACT` for helper implementation and fail-closed run;
  `NOT-YET-PROVEN` for a passing current artifact gate and production lifecycle.
- Validation strength: helper execution/failure semantics are
  `RUNTIME-PROVEN`; expected current gate PASS is not proven.

## E-034 — Fresh stable candidate gate passed; activation stopped ambiguous

- Provenance: Bane-authorized fresh-candidate validation on 2026-09-20 UTC.
  Product source/project/signing state was reported unchanged apart from
  orchestration files. No source repair, commit, tag, push, or freeze occurred.
- Fresh stable validation archive:
  `/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920.xcarchive`.
  App executable SHA-256:
  `767102f3648308daf00f2dd89846fb9c83d9835db34ece8258b919af3657a3f2`.
  Daemon executable SHA-256:
  `d80e8890f9139d0f5f17b6dc44f14e4dcb5f1c39ed348746306e0fadc8ff1603`.
  Apple Development signing, TeamIdentifier `TFKZJV643G`, canonical IDs,
  requirements, layout, and deep/strict verification were reported passing.
- Deterministic helper was updated only with this stable artifact path and
  executable hashes. It returned `gate_result=PASS pass_count=8 fail_count=0`
  with artifact/hash/preflight and clean launchd/process/socket/lock-holder
  observations.
- First product operation attempted: `.build/out/Products/Release/val start`.
  It returned `LIFECYCLE_UNKNOWN` with message `Bootstrap completed
  ambiguously or Core did not reconnect; recovery is required.` The attempted
  controller was not proven to be the accepted signed stable artifact;
  controller resolution was bundle-ID based and an unrelated/debug Vaelen
  process was observed under `.build/VaelenApp/Build/Products/Debug/`.
- Per the first-failure rule, execution stopped. No retry, Off/unregister,
  cleanup, manual repair, signaling, or further lifecycle operation occurred.
  A subsequent read-only preservation capture was denied with
  `Permission denied: shell`; therefore receipt/journal/provider/durable state
  and post-attempt ownership are not safely established. Do not infer that no
  mutation occurred from absent process/socket observations.
- Claim status: `OBSERVED FACT` for candidate/gate and returned activation
  error; `NOT-YET-PROVEN` for mutation outcome, lifecycle state, recovery,
  Off, and production acceptance.
- Validation strength: artifact/gate `RUNTIME-PROVEN`; activation failure is
  `RUNTIME-PROVEN` as a returned product result, while exact-artifact binding
  and resulting durable state are `NOT-YET-PROVEN`.

## E-035 — Ambiguous activation forensic capture incomplete

- Provenance: Bane-authorized read-only forensic recovery operation on
  2026-09-20 UTC. No retry of activation, Off, cleanup, launchd mutation,
  process signaling, SQLite mutation, source edit, build, re-sign, commit,
  tag, push, or recovery mutation occurred.
- Read-only helper: `Scripts/m14-forensic-state.sh`, invoked once through its
  exact wrapper. It timed out after 120000 ms before completing; the stopping
  command could not be attributed. The helper's reported artifact path was
  repository-derived `.build/VaelenApp/Build/Products/Debug/Vaelen.app`, not
  sufficient exact controller provenance.
- Observed before timeout: `launchctl print gui/501/dev.vaelen.vaelend`
  returned exit 113/service not found; exact process observation exited 0 with
  no visible output. Socket, lock-holder, SQLite, artifact identity, durable
  journal/receipt, and debug-role observations were not completed.
- Current classification: `AMBIGUOUS`; no inference of clean state or absence
  of mutation is permitted. Recovery mutation is not executed or proposed as
  authorized action. A future bounded read-only capture requires separate
  authority/repair; no lifecycle retry is implied.
- Architecture review: helper body is read-only, but the wrapper permission
  and unbounded output/timeout are observability risks. Test audit: only
  launchd/process observations are supported; all durable state and exact
  artifact-binding claims remain `NOT-YET-PROVEN`.
- Likely implementation defect remains the previously indicated bundle-ID
  controller resolution ambiguity when Debug and Release `Vaelen.app` artifacts
  coexist; this is a diagnosis hypothesis, not repaired or newly proven here.
- Claim status: `OBSERVED FACT` for the partial capture and timeout;
  `NOT-YET-PROVEN` for current lifecycle state, mutation outcome, recovery,
  and production acceptance.

## E-036 — Direct forensic inspection remained environment-blocked

- Provenance: Bane-authorized final direct read-only recovery inspection on
  2026-09-20 UTC. No helper was invoked or created; no lifecycle, SQLite,
  launchd, process, lock, socket, source, build, recovery, or cleanup mutation
  occurred.
- Runtime result: direct shell execution was denied before `stat`, `ls`,
  `lsof`, or SQLite commands ran; external-directory reads were also denied.
  Therefore Core endpoint, lock holders, SQLite schema/tables/records, and
  durable lifecycle state remain unobserved.
- Source result: `val start` uses
  `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` in
  `Sources/VaelenCLI/main.swift:98-111`, then opens the canonical
  `vaelen://start?token=...` URL. The app receives it in
  `App/Vaelen/Vaelen/VaelenApp.swift:16-20` and invokes
  `CoreAbsentBootstrapExecutor` at lines 143-152. This is bundle-ID/running
  application resolution, not deterministic exact-artifact selection.
- Classification: `AMBIGUOUS`; recovery required is undetermined. No recovery
  mutation was executed or proposed as executed.
- Claim status: `OBSERVED FACT` for source resolution and environment denial;
  `NOT-YET-PROVEN` for current lifecycle state, mutation outcome, and recovery.

## E-037 — Deterministic bootstrap fix not started

- Provenance: Bane-authorized Class A/B controller-selection correction request
  on 2026-09-20 UTC. No Vaelen source, tests, artifact, lifecycle state,
  build, signing, SQLite, launchd, process, socket, lock, Syncproof,
  Experiments, commit, tag, or push mutation occurred.
- Execution result: PM attempted multiple bounded delegations to
  `vaelen-lead`; the orchestration runtime returned `Agent vaelen-lead cannot
  run as a subagent` before implementation began. Read-only inspection
  confirmed the PM configuration permits Lead delegation, while the
  investigator boundary correctly denies nested task delegation; no evidence
  establishes why the PM-to-Lead invocation was rejected.
- Decision: no source workaround or direct PM implementation was attempted.
  The deterministic controller-selection defect remains open and production
  validation remains prohibited until repaired and revalidated.
- Claim status: `OBSERVED FACT` for the delegation failure;
  `NOT-YET-PROVEN` for the requested implementation, tests, regression, and
  production acceptance.

## E-038 — Deterministic bootstrap controller selection repaired

- Provenance: Bane-authorized orchestration repair followed by PM-to-Lead
  delegation restoration on 2026-09-20 UTC. No lifecycle invocation,
  registration, Off, recovery, SQLite mutation, process signaling, Syncproof,
  Experiments, staging, commit, tag, push, or freeze occurred.
- Delegation repair: `.opencode/agents/vaelen-lead.md` had two helper
  permission entries indented outside the YAML `bash` mapping. They were
  corrected to the existing mapping indentation. One harmless Lead probe
  (`git status --short`) then executed and returned to PM.
- Product repair: lifecycle bootstrap now uses centralized
  `LifecycleCanonicalIdentity.installedControllerURL` (`/Applications/Vaelen.app`)
  or the exact constrained validation URL, performs ArtifactPreflight before
  minting authorization, invokes the exact URL, and binds the one-time
  authorization to `controller_path` in addition to target, operation, user,
  UID, expiry, and replay constraints. Lifecycle bootstrap no longer uses
  `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`.
- Validation mechanism: `VAELEN_BOOTSTRAP_CONTROLLER_URL` is accepted only
  for the exact bounded validation candidate; arbitrary paths fail closed.
  Hashes/CDHashes/certificate leaves are not permanent trust anchors.
- Focused tests: deterministic path/override/preflight/trust and authorization
  falsifiers, including a same-bundle-ID Debug-vs-validation fixture, passed.
  The collision test uses isolated fixtures and proves the wrong-path Debug
  candidate is rejected and cannot consume validation authorization.
- Reported regression after the focused test repair: 261 executed, 13
  skipped, 0 failures: VaelenCore 199/13 skipped, VaelenIPC 56, VaelenDNS 6.
  Swift Debug/Release builds, Xcode Debug/Release archive, and diff-check were
  reported passed. Exact raw output for this latest run was not preserved.
- Fresh Release archive was reported at
  `/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920.xcarchive`
  with app executable SHA-256
  `767102f3648308daf00f2dd89846fb9c83d9835db34ece8258b919af3657a3f2` and
  daemon executable SHA-256
  `d80e8890f9139d0f5f17b6dc44f14e4dcb5f1c39ed348746306e0fadc8ff1603`;
  Apple Development / Team `TFKZJV643G`, canonical requirements/layout, and
  deep/strict verification were reported passing.
- Architecture review: PASS, no material authority violation. Test audit:
  focused collision evidence is narrowly `RUNTIME-PROVEN`/`UNIT-COVERED`, but
  real signed controller authorization and lifecycle remain `NOT-YET-PROVEN`.
- Claim status: `OBSERVED FACT` for implementation/reported validation;
  `NOT-YET-PROVEN` for current ambiguous runtime state and production
  acceptance.

## E-039 — Final lifecycle validation orchestration transport stop

- Provenance: Bane-authorized final M14 lifecycle validation attempt on
  2026-09-20 UTC. No source edit, rebuild, lifecycle command, recovery,
  launchd/SQLite/process mutation, commit, tag, push, or freeze was reported.
- The delegated Lead session terminated with WebSocket code 1006 before
  producing any command output. A continuation reported that no commands or
  lifecycle mutations began, but no preserved session transcript exists;
  therefore execution cannot be independently proven beyond the transport
  stop.
- No gate result, candidate-currentness result, start result, or lifecycle
  state evidence was produced in this attempt. No second validation sequence
  was started.
- Claim status: `OBSERVED FACT` for the transport failure and absence of
  returned evidence; `NOT-YET-PROVEN` for any current execution state and all
  production lifecycle claims.

## E-040 — Production packaging closure repair stopped on fresh artifact failure

- Provenance: fresh delegated `vaelen-lead` packaging investigation and repair
  attempt on 2026-09-20 UTC. No `val start`, Off operation, launchd mutation,
  lifecycle SQLite/receipt/journal mutation, process signaling, crash injection,
  Syncproof change, staging, commit, tag, push, or freeze occurred.
- Observed before repair: the broken archive had only `/usr/lib/swift` rpaths;
  Vaelen-owned `@rpath` framework dependencies were unresolved. The reported
  production crash specifically identified missing
  `@rpath/VaelenIPC.framework/Versions/A/VaelenIPC` from the app executable.
- Observed repair attempt: files changed were
  `App/Vaelen/Vaelen.xcodeproj/project.pbxproj`, `Package.swift`,
  `Sources/VaelenCore/ArtifactPreflight.swift`, and
  `Tests/VaelenCoreTests/CanonicalSigningTrustBoundaryTests.swift`.
  ArtifactPreflight was strengthened to inspect packaged Mach-O dependency and
  rpath closure; focused regression coverage for an equivalent broken package
  was added.
- Fresh archive was created exactly once at
  `/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-repaired-20260920.xcarchive`.
  App SHA-256:
  `01ad4d208391f59b200ae96660b855bf8252e5e6cb983a48e34305ee598f5853`.
  Daemon SHA-256:
  `bd536e157aa43cafe6a9f247f8784006038ed0921764d178f36e8b647ad30652`.
  Deep/strict signing and canonical identifiers/team passed.
- Stop finding: the fresh embedded `vaelend` still lacked
  `@loader_path/../Frameworks`; hardened ArtifactPreflight rejected the fresh
  artifact. The source contains a daemon linker-rpath repair, but no second
  archive was authorized or built after this product failure.
- Focused tests before the final hardening state: 11 executed, 1 skipped, 0
  failures. Full regression, final gate, and final ArtifactPreflight acceptance
  were not run because the fresh product failed closure validation.
- Claim status: `OBSERVED FACT` for the reported artifact/tool outcomes and
  stop; `NOT-YET-PROVEN` for complete repaired dependency closure, final
  regression, gate, and production acceptance.

## E-041 — Daemon rpath regenerated; fresh artifact preflight failed

- Provenance: fresh delegated `vaelen-lead` packaging continuation on
  2026-09-20 UTC. No lifecycle operation, launchd/process mutation, lifecycle
  SQLite/receipt/journal/lock mutation, Syncproof change, staging, commit, tag,
  push, or freeze occurred.
- Observed failed-candidate closure: daemon dependencies included Vaelen-owned
  `@rpath/Yams...`, `VaelenCore`, and `VaelenIPC`, plus system Swift/Foundation/
  SQLite dependencies. Its only rpath was `/usr/lib/swift`; the app had
  `@executable_path/../Frameworks` and `@loader_path/../Frameworks`. Vaelen
  frameworks were under `Contents/Frameworks`, while the daemon was under
  `Contents/Resources/vaelend`.
- Root cause classification: the SwiftPM daemon target's linker rpath was not
  present in the stale Release-derived daemon. The app target's runpaths do not
  repair the separately linked daemon. The existing `Package.swift` daemon
  linker setting is the intended intrinsic fix; no binary patch or
  `install_name_tool` workaround was used.
- One new archive was built at
  `/private/var/folders/9b/1f1sf2v51_36ysng9ngq8c0000gn/T/opencode/vaelen-release-packaging-repaired-20260920.xcarchive`.
  Its daemon contained `/usr/lib/swift` and
  `@loader_path/../Frameworks` for both architectures. Its app contained
  `/usr/lib/swift`, `@executable_path/../Frameworks`, and
  `@loader_path/../Frameworks` for both architectures.
- Focused signing/preflight tests before artifact invocation passed: 11
  executed, 1 skipped, 0 failures. Exact artifact preflight then failed at
  `testExplicitSignedArtifactPreflightWhenPathIsProvided` because it returned
  nil instead of `ArtifactPreflightEvidence`.
- Per stop rule, no full regression, M14 gate, repair retry, or lifecycle
  acceptance was performed. App/daemon SHA-256 values and the complete final
  recursive closure were not returned before the stop and remain
  `NOT-YET-PROVEN`.
- Claim status: `OBSERVED FACT` for the reported binary/rpath and test results;
  `NOT-YET-PROVEN` for final artifact acceptance and production closure.

## E-042 — E-041 archive-path transcription correction

- Correction: E-041 transcribed the temporary-directory component incorrectly.
  The exact archive path returned by Lead was
  `/private/var/folders/9b/1f1sf2v51_36ysng9ngq8c0000gn/T/opencode/vaelen-release-packaging-repaired-20260920.xcarchive`.
- The correction changes only the path transcription; all E-041 results and
  stop classifications remain unchanged.

## E-043 — Exact packaging candidate absent; validation stopped

- Provenance: delegated read-only M14 packaging validation on 2026-09-20 UTC.
  No rebuild, copy, validation instrumentation, lifecycle action, repository
  mutation, launchd/process/SQLite/lock mutation, Syncproof change, staging,
  commit, tag, push, or freeze occurred.
- Observed: the exact candidate
  `/private/var/folders/9b/1f1sf2v51_36ysng9ngq8c0000gn/T/opencode/vaelen-release-packaging-repaired-20260920.xcarchive`
  was absent.
- Per the preservation boundary, execution stopped before copying,
  investigating, rebuilding, or substituting another artifact. All requested
  dependency, preflight, regression, and gate claims remain
  `NOT-YET-PROVEN`.

## E-044 — Durable packaging candidate passed non-lifecycle validation

- Provenance: delegated `vaelen-lead` durable-candidate packaging validation on
  2026-09-20 UTC. No lifecycle operation, `val start`, Off, launchd/process
  mutation, lifecycle SQLite/receipt/journal/lock mutation, signaling, crash
  injection, Syncproof change, staging, commit, tag, push, or freeze occurred.
- One fresh Release archive was built directly in the durable validation area:
  `/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-fresh-20260920-1829.xcarchive`.
  App SHA-256:
  `1c0bc45c3b0c371b520ebd146e0030bf7aaba43e9c9bb2cdb4858ea0e4a41583`.
  Daemon SHA-256:
  `afa83c9e8d3b8aa9b74725e75a027dffc1a0d452ddb745e211a53f7230ff1154`.
- Observed signing result: Apple Development signing, TeamIdentifier
  `TFKZJV643G`, app identifier `dev.vaelen.app`, daemon identifier `vaelend`;
  deep/strict app and daemon verification passed.
- Observed closure result: app and daemon Mach-O dependencies/rpaths were
  inspected; embedded VaelenCore, VaelenIPC, and Yams dependencies resolved
  within `Contents/Frameworks`, while system dependencies resolved to system
  paths. The Lead reported complete recursive closure and package containment.
- Initial ArtifactPreflight failure on this same durable candidate was
  classified as a preflight implementation defect: universal-binary header
  lines were parsed as dependencies and non-Mach-O framework resources were
  admitted as binaries. The validator was repaired without weakening its
  fail-closed boundary, with focused regression coverage.
- Same-candidate results: exact-candidate preflight tests passed (2/0); focused
  M14 tests passed (2/0); full regression passed with 201 tests and 12 skips;
  the existing M14 gate passed after only its archive/hash constants were
  updated. No candidate replacement was used.
- Claim status: `OBSERVED FACT` for Lead-reported artifact and validation
  results; `RUNTIME-PROVEN` for the bounded durable artifact checks as reported;
  lifecycle acceptance remains `NOT-YET-PROVEN`.

## E-045 — Final production acceptance stopped on one ambiguous Start

- Provenance: delegated final M14 acceptance on 2026-09-20 UTC. No product
  source edit, rebuild, candidate substitution, OpenCode change, Off operation,
  retry, cleanup, manual SQLite/receipt/journal/lock mutation, launchd
  mutation, process signaling, crash injection, Syncproof change, staging,
  commit, tag, push, or freeze occurred.
- Exact pre-start candidate checks passed: existing M14 gate passed and app
  SHA-256 was
  `1c0bc45c3b0c371b520ebd146e0030bf7aaba43e9c9bb2cdb4858ea0e4a41583`;
  daemon SHA-256 was
  `afa83c9e8d3b8aa9b74725e75a027dffc1a0d452ddb745e211a53f7230ff1154`.
  Fresh absence gates for the launchd label, process, Core socket, and both
  lifecycle locks passed.
- Exactly one Start was executed at `2026-09-20T16:38:03Z`, bound to the exact
  validation app path. It returned exit code `3`:
  `{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}`.
- Per the first real product failure rule, acceptance stopped immediately.
  No Off, retry, or post-unknown cleanup was performed. Post-Start daemon
  identity/UID/path, readiness, receipt/journal, typed IPC, preservation, and
  Off claims are not established. The resulting durable state must be treated
  as potentially ambiguous and must not be inferred clean.
- `.vaelen/M14_VALIDATION_RUN.md` was updated immediately before and after the
  Start attempt. M14 production acceptance remains `NOT-YET-PROVEN`.

## E-046 — Read-only forensic diagnosis of ambiguous Start

- Provenance: delegated read-only forensic diagnosis after the single Start at
  `2026-09-20T16:38:03Z`. No source, candidate, SQLite, receipt/journal, lock,
  launchd, process, Syncproof, OpenCode, staging, commit, tag, push, or freeze
  mutation occurred. No Start retry or Off operation occurred.
- Source path: `Sources/VaelenCLI/main.swift:90-141`. When Core is initially
  unavailable for `start`, the CLI preflights the exact controller, mints a
  one-time token, opens the exact app URL, polls Core 100 times at 100 ms,
  requires a succeeded bootstrap receipt, waits for readiness, disconnects,
  requires a fresh reconnect, and promotes the bootstrap. Any thrown error in
  this block is collapsed to `LIFECYCLE_UNKNOWN`; the CLI result does not name
  the failing substage.
- Read-only current observations: `launchctl print gui/501/dev.vaelen.vaelend`
  returned service-not-found (exit 113); no matching vaelend/Vaelen process was
  found; canonical Core socket was absent; both lifecycle lock files were
  unheld; no current daemon PID/UID/start identity exists.
- Read-only SQLite observation: schema cookie `17`; M14 tables exist with
  counts `lifecycle_intent=0`, `lifecycle_operations=0`,
  `lifecycle_ownership=0`, `bootstrap_receipts=0`, and
  `bootstrap_invocations=4`. All four invocation rows were unconsumed
  (`consumed_at` NULL), with register/user 501/canonical-target data and
  expiries between `15:09:00.599553Z` and `16:10:16.475539Z`. No operation ID,
  receipt ID, generation, journal, or ownership row correlates to the supplied
  16:38 Start; timestamp mismatch prevents definitive row correlation.
- Historical preservation remains observed: 3 projects, 1 route intent, 0
  route transitions, 0 TLS rows, and 1 system modification.
- Unified-log filtering around the window produced no Vaelen/Core/vaelend event;
  only unrelated Apple services were present. The absence does not prove that
  `/usr/bin/open`, app URL delivery, preflight, or transient Core execution did
  not occur.
- Classification: `UNDETERMINED`. Current evidence is more consistent with
  failure before invocation consumption than with completed registration and
  ambiguous reconnect, but it does not prove whether open/URL delivery,
  controller preflight/token consumption, transient Core startup, or a platform
  call occurred. No repair is authorized by this entry.

## E-047 — Source reconstruction of uncorrelated Start

- Provenance: delegated read-only source/artifact reconstruction on 2026-09-20
  UTC. No source, candidate, lifecycle SQLite, receipt/journal, lock, launchd,
  process, OpenCode, Syncproof, build, retry, Off, staging, commit, tag, push,
  or freeze mutation occurred.
- Observed source path: `val start` enters the Core-absent branch only for
  `.coreUnavailable`; it resolves/preflights the exact controller, calls
  `mintBootstrapInvocation(controllerPath:)`, inserts the invocation row
  before constructing the URL and invoking `/usr/bin/open`, then polls
  admission, receipt success, readiness, fresh reconnect, and promotion.
  Only `SQLiteStateStore.mintBootstrapInvocation` inserts
  `bootstrap_invocations`; the signed controller consumes the row and does not
  create it. Consumption atomically sets `consumed_at` before receipt
  reservation and before ServiceManagement registration.
- Observed source path: the catch at `Sources/VaelenCLI/main.swift:141`
  collapses store/layout, controller resolution/preflight, mint, URL/open,
  admission, receipt, handshake/readiness, reconnect, promotion, and IPC errors
  into the same `LIFECYCLE_UNKNOWN` result.
- Durable-footprint elimination: failures after successful mint should leave an
  invocation row; failures after consumption should leave a consumed row and
  usually a receipt. The observed absence of a correlated row, receipt,
  operation, intent, ownership, registration, process, and socket is therefore
  incompatible with a normal post-mint path. URL delivery loss alone cannot
  explain the missing invocation row.
- Build observation: `.build/out/Products/Release/val` SHA-256 was
  `4c1527d4c1c73d0ee3bb168f64c9cdce33e0ca2ebcc94da3322b14583f0c194f`, mtime
  `2026-09-20 17:44:01 +0200`; it contains strings for the repaired validation
  path, invocation SQL, controller binding, and `LIFECYCLE_UNKNOWN`. No embedded
  source commit/hash exists, so source-to-executable identity is consistent but
  not deterministically proven.
- Observed candidate inspection: the signed app declares the `vaelen` URL
  scheme. Only SwiftUI `.onOpenURL` was found; no AppKit open-event fallback
  was found. Cold and running delivery therefore depend on the same scene
  handler, which silently ignores malformed/missing tokens.
- Remaining hypothesis set: pre-mint store/layout/controller-preflight failure;
  different database/user/path during acceptance versus forensic inspection;
  or acceptance of an unproven CLI binary/source relationship. Controller URL
  delivery loss is not sufficient to explain the observed missing row.
- Minimum future observability: CLI hash/build identity, database path,
  selected controller/preflight result, token hash, insertion result, open
  result, app URL receipt, consumption result, receipt IDs/phases, and
  admission/readiness/promotion error classes, all correlated by operation ID.
- Claim status: `OBSERVED FACT` for source paths and current observations;
  `INFERENCE` for pre-mint/different-database narrowing;
  `HYPOTHESIS` for the individual remaining causes. Root cause remains
  `UNDETERMINED`.

## E-050 — Read-only SMAppService `.notFound` contract investigation

- Provenance: delegated read-only comparison of the signed 2140 candidate,
  production source, installed SDK headers, and preserved M14 experiment
  evidence. No register/unregister, Start/Off, rebuild, source, candidate,
  SQLite, launchd, lock, process, OpenCode, or Syncproof mutation occurred.
- Production artifact: `dev.vaelen.app`, executable `Contents/MacOS/Vaelen`,
  TeamIdentifier `TFKZJV643G`, helper `Contents/Resources/vaelend` with
  identifier `vaelend`. LaunchAgent is exactly
  `Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist` and contains
  Label `dev.vaelen.vaelend`, BundleProgram `Contents/Resources/vaelend`,
  KeepAlive true, RunAtLoad true, ProcessType Background, and no Program,
  ProgramArguments, MachServices, or LimitLoadToSessionType keys.
- Production construction consistently uses
  `SMAppService.agent(plistName: "dev.vaelen.vaelend.agent.plist")` in the
  observer, On revalidator, Core-absent bootstrap, and lifecycle executor.
- Experiment construction uses
  `SMAppService.agent(plistName: "dev.vaelen.m14-lifecycle-experiment.agent.plist")`.
  Its material identity differences are the experiment bundle/helper/label
  identities and additional ThrottleInterval/StandardOutPath/StandardErrorPath
  plist keys; layout, ownership, permissions, TeamIdentifier, and API model are
  equivalent.
- Historical experiment events directly show status raw value `3` (`.notFound`)
  before first registration, raw value `1` (`.enabled`) after register, and raw
  value `0` (`.notRegistered`) after unregister.
- Installed SDK semantics state `.notFound` means an error occurred and no such
  service could be found; `.notRegistered` is never registered or unregistered;
  `.enabled` is successfully registered; `.requiresApproval` is registered but
  requires System Settings action. Therefore `.notFound` is not safely
  interchangeable with `.notRegistered`.
- Classification: **D — UNDETERMINED**. Production packaging/signing/layout
  and status interpretation are not disproven; the experiment establishes a
  platform/context-dependent difference but does not isolate its cause. No
  repair is justified by this evidence.

## E-048 — Bootstrap observability implementation; signing validation stopped

- Provenance: delegated Class A/B observability implementation and validation
  on 2026-09-20 UTC. No real `val start`, Off, registration/unregister,
  lifecycle SQLite mutation, receipt/journal/lock mutation, launchd/process
  mutation, Syncproof change, OpenCode change, staging, commit, tag, push, or
  freeze occurred.
- Observed implementation scope: bounded non-authoritative diagnostics for
  database path/UID/schema/build identity, correlation IDs, safe token hashes,
  CLI mint/open/reconnect/promotion, controller URL rejection/consumption,
  receipt/platform outcomes, daemon admission/endpoint/readiness, and focused
  tests. No plaintext token persistence or lifecycle authority transfer was
  reported.
- Focused tests passed. Full regression passed: 204 passed, 14 skipped, 0
  failures. Three `M14BootstrapObservabilityTests` were added/reported.
- Architecture review flagged existing URL-token exposure, incomplete migration
  error handling, and promotion correlation gaps. Test audit classified the
  observability slice as `UNIT-COVERED`; real signed product-path behavior
  remains `NOT-YET-PROVEN`. No URL-delivery redesign was made.
- Release CLI was built at `.build/out/Products/Release/val` with SHA-256
  `ce885ef05efad72745d32f542593d4377f8033f90740119092c8a6b5d0633afc`.
- One fresh durable archive was attempted at
  `/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-m14-observability-20260920-1857.xcarchive`,
  but archive validation stopped because no legitimate Xcode signing identity
  was available for embedded `vaelend`. No repair or second archive was made.
  App/daemon archive hashes, signing, dependency closure, ArtifactPreflight,
  and M14 gate results were not established.
- Claim status: `OBSERVED FACT` for implementation/test/stop results;
  `UNIT-COVERED` for isolated observability tests;
  `NOT-YET-PROVEN` for signed product validation and lifecycle acceptance.

## E-013 — M14 signed candidate and fail-closed acceptance stop

- Signing diagnosis: Xcode 27.0 resolved `/Applications/Xcode.app`; the login
  keychain exposed one valid Apple Development identity,
  `6E2E30BCBF47FCBAFC779CC72BE7E3F79ADA6679`, with TeamIdentifier
  `TFKZJV643G`. Xcode successfully propagated it to the embedded daemon and
  produced valid nested archives; signing was not the environment blocker.
- The bearer transported in `vaelen://start` is now persisted only as a
  SHA-256 digest. v7 stores are migrated transactionally to schema 8 while
  preserving receipt evidence; diagnostics contain only the digest. Core
  promotion diagnostics correlate through the invocation ID.
- Final built candidate before stop:
  `/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2040.xcarchive`.
  App SHA-256 `7a591ab80b2deb480bcc9fe866799e857f9fe9b602ec43f8156e71637faf8698`;
  daemon SHA-256 `b7632b93eb8f2460f73e9560b97177a5531cca4bba45df0b67bf662cf360793d`;
  Release CLI SHA-256 `04332c5a2c6002525c00565a1ce72cc4667d86112d62dfbf12f6dcc75cfef191`.
  App `dev.vaelen.app`, daemon `vaelend`, both Apple Development signed under
  `TFKZJV643G`; deep strict verification, LaunchAgent layout, dependency
  closure, and explicit ArtifactPreflight passed. Full regression passed:
  204 passed, 14 skipped, 0 failures.
- Product acceptance attempted only through the exact Release CLI and signed
  candidate. URL delivery reached the signed controller on some attempts;
  the fresh platform observation classified ServiceManagement registration as
  `unknown` (not exactly not-registered), so no receipt reservation or
  ServiceManagement mutation was permitted. Other attempts were correctly
  rejected as stale same-bundle URL routing until `open -n` was added.
- Final observation: launchd label absent, no daemon, no Core socket, no
  lifecycle receipt/intent/operation/ownership rows; schema version 8. Three
  controller app processes remain running from the product path attempts and
  were not signaled or killed. No Off was attempted because On/Ready was never
  proven. M14 acceptance remains `NOT-YET-PROVEN`; recovery is required before
  any further lifecycle attempt.
## Observability candidate 2120 evidence 2026-09-20T17:34:36Z
scope=read-only-after-build; no Start/Off/retry/recovery/launchctl-mutation
archive=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive
8eec9daf3a3d31f26b74030bfc11fb2e8eb6b24ba119a32bf740d29c4e933654  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app/Contents/MacOS/Vaelen
e0701de7cdaec16e3d0995100f64defbfe01fefa433e4d7cc8b5fd5bd07059f5  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app/Contents/Resources/vaelend
2d0c318fbffaed2fb194ab8b83d3c8e46eb9e785c220332c9351e4a18193a2db  .build/out/Products/Release/val
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app: valid on disk
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app: satisfies its Designated Requirement
focused_and_full_tests=PASS; full=205 executed,14 skipped,0 failures
artifact_preflight=PASS; m14-preflight-gate=PASS pass_count=8 fail_count=0
-- current durable state (sqlite3 -readonly)
8
32|2026-09-20 17:30:30|preflight|success|canonical signed controller validated|C087BE59-0AE3-4020-9216-21E73E8FA428
31|2026-09-20 17:30:30|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app|C087BE59-0AE3-4020-9216-21E73E8FA428
30|2026-09-20 17:27:58|urlOpen|success|open exit=0|C087BE59-0AE3-4020-9216-21E73E8FA428
29|2026-09-20 17:27:58|urlConstruction|started|canonical vaelen://start URL|C087BE59-0AE3-4020-9216-21E73E8FA428
28|2026-09-20 17:27:57|mint|success|authorization minted; token persisted as hash only|C087BE59-0AE3-4020-9216-21E73E8FA428
27|2026-09-20 17:24:48|preflight|success|canonical signed controller validated|7EB89058-B7C6-41FF-A2B5-7AECB41B6411
26|2026-09-20 17:24:48|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2040.xcarchive/Products/Applications/Vaelen.app|7EB89058-B7C6-41FF-A2B5-7AECB41B6411
25|2026-09-20 17:23:11|urlOpen|success|open exit=0|7EB89058-B7C6-41FF-A2B5-7AECB41B6411
-- runtime observation
Bad request.
Could not find service "dev.vaelen.vaelend" in domain for user gui: 501
95806   501 /bin/zsh -c set -e\012A='/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive'; APP="$A/Products/Applications/Vaelen.app"; D="$APP/Contents/Resources/vaelend"; DB='/Users/banes/Library/Application Support/Vaelen/state/vaelen.sqlite'; OUT=/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-observability-2120.txt\012{\012 echo "## Observability candidate 2120 evidence $(date -u '+%Y-%m-%dT%H:%M:%SZ')"\012 echo "scope=read-only-after-build; no Start/Off/retry/recovery/launchctl-mutation"\012 echo "archive=$A"\012 shasum -a 256 "$APP/Contents/MacOS/Vaelen" "$D" .build/out/Products/Release/val\012 codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3\012 echo 'focused_and_full_tests=PASS; full=205 executed,14 skipped,0 failures'\012 echo 'artifact_preflight=PASS; m14-preflight-gate=PASS pass_count=8 fail_count=0'\012 echo '-- current durable state (sqlite3 -readonly)'\012 sqlite3 -readonly "$DB" "PRAGMA user_version; SELECT phase,executor_state,executor_detail,operation_id FROM bootstrap_receipts; SELECT intent,generation,operation_id FROM lifecycle_intent; SELECT operation_id,generation,kind,state FROM lifecycle_operations; SELECT operation_id,generation FROM lifecycle_ownership; SELECT id,created_at,phase,outcome,detail,invocation_id FROM lifecycle_diagnostics ORDER BY id DESC LIMIT 8;"\012 echo '-- runtime observation'\012 launchctl print gui/501/dev.vaelen.vaelend 2>&1 || true\012 ps -axo pid=,uid=,command= | grep -E '[V]aelen.app/Contents/MacOS/Vaelen|[v]aelend' || true\012 echo '-- conclusion'\012 echo 'The 2100 Start produced only CLI LIFECYCLE_UNKNOWN and no matching 2100 controller diagnostics; URL/controller execution is not proven. The 2120 candidate was not started. No exact SMAppService status was obtained from the preserved state. Acceptance remains NOT-YET-PROVEN; stop without retry.'\012} > "$OUT"\012cat "$OUT" >> .vaelen/M14_VALIDATION_RUN.md\012cat "$OUT" >> .vaelen/EVIDENCE.md\012cat "$OUT"
-- conclusion
The 2100 Start produced only CLI LIFECYCLE_UNKNOWN and no matching 2100 controller diagnostics; URL/controller execution is not proven. The 2120 candidate was not started. No exact SMAppService status was obtained from the preserved state. Acceptance remains NOT-YET-PROVEN; stop without retry.

## Latest 2140 lifecycle attempt

The 2120 attempt reached preflight but not URL consumption, proving an ordinary deterministic controller-delivery defect. A narrow direct application-delegate delivery fix was built and signed in candidate 2140. One post-fix Start was then executed using the exact 2140 path and `open -n -a` routing.

Correlation `8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB` proves URL open, signed preflight, one-time consume, and the improved registration diagnostic. The exact platform result was:

`value=unknown status=notFound approvalRequired=false`

The executor correctly failed closed before receipt reservation or ServiceManagement registration. Read-only post-state showed absent launchd label, daemon, socket, lock holders, receipt, intent, operation, and ownership rows. No retry or recovery was performed. M14 production acceptance remains `NOT-YET-PROVEN` because ServiceManagement is in the ambiguous `.notFound` state; Bane/platform action or an explicitly authorized recovery decision is required.

## `.notFound` platform semantics diagnosis

The macOS SDK header defines `.notRegistered` as the legitimate unregistered state, `.requiresApproval` as a successfully registered service awaiting System Settings action, and `.notFound` as: “An error occurred and no such service could be found.” Candidate 2140 independently passed canonical signed-artifact and LaunchAgent layout validation, including the exact embedded plist. Its correlated runtime result was `value=unknown status=notFound approvalRequired=false`.

Consequently `.notFound` is neither the safe unregistered precondition nor approval evidence. The executor correctly refused before receipt reservation and before `register()`. Treating it as `.notRegistered` would be a new platform semantic decision and would violate the accepted fail-closed boundary. No deterministic product defect is proven; stop pending platform/Bane investigation or explicit authority.

## 2140 controlled install pre-copy evidence (see output above)
## Installed-controller Start blocker 2026-09-20T17:54:13Z
-- LS exact Vaelen records
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               B289FFEA-2929-3F2F-AC6B-C6707E8DE02A
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (70144 (0x11200))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (70148 (0x11204))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (70152 (0x11208))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2760
mod date:                   2026-09-17 19:24 (POSIX 1789665876, 𝛥 3days 29min 38sec)
exec mod date:              2026-09-17 19:29 (POSIX 1789666149, 𝛥 3days 25min 5sec)
reg date:                   2026-09-17 19:55 (POSIX 1789667702, 𝛥 2days 23hr 59min 12sec)
rec mod date:               2026-09-17 19:55 (POSIX 1789667702, 𝛥 2days 23hr 59min 12sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               3B2BCB32-2D5E-3DDA-A76B-134FC93BB7EA
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (73532 (0x11f3c))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (73536 (0x11f40))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (73540 (0x11f44))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2892
mod date:                   2026-09-18 09:37 (POSIX 1789717053, 𝛥 2days 10hr 16min 41sec)
exec mod date:              2026-09-18 12:40 (POSIX 1789728054, 𝛥 2days 7hr 13min 20sec)
reg date:                   2026-09-18 12:40 (POSIX 1789728054, 𝛥 2days 7hr 13min 20sec)
rec mod date:               2026-09-18 12:40 (POSIX 1789728054, 𝛥 2days 7hr 13min 20sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               67632CC7-B05D-37A4-9900-D8B1E3F943AF
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (73596 (0x11f7c))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (73600 (0x11f80))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (73604 (0x11f84))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2908
mod date:                   2026-09-18 14:01 (POSIX 1789732891, 𝛥 2days 5hr 52min 43sec)
exec mod date:              2026-09-18 15:09 (POSIX 1789736954, 𝛥 2days 4hr 45min)
reg date:                   2026-09-18 15:09 (POSIX 1789736954, 𝛥 2days 4hr 45min)
rec mod date:               2026-09-18 15:09 (POSIX 1789736954, 𝛥 2days 4hr 45min)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               B8045590-7D5C-326A-AB22-3013932F23E0
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (74496 (0x12300))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (74500 (0x12304))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2952
mod date:                   2026-09-18 20:11 (POSIX 1789755115, 𝛥 47hr 42min 19sec)
exec mod date:              2026-09-18 20:11 (POSIX 1789755115, 𝛥 47hr 42min 19sec)
reg date:                   2026-09-18 20:11 (POSIX 1789755115, 𝛥 47hr 42min 19sec)
rec mod date:               2026-09-18 20:11 (POSIX 1789755115, 𝛥 47hr 42min 19sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element  in-temp-dir (0000800000000004)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               0B575A08-A4E1-3996-A9CA-9CDDCACA2F38
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (74540 (0x1232c))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (74544 (0x12330))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (74548 (0x12334))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2964
mod date:                   2026-09-18 22:14 (POSIX 1789762471, 𝛥 1day 21hr 39min 43sec)
exec mod date:              2026-09-18 22:14 (POSIX 1789762471, 𝛥 1day 21hr 39min 43sec)
reg date:                   2026-09-18 22:14 (POSIX 1789762471, 𝛥 1day 21hr 39min 43sec)
rec mod date:               2026-09-18 22:14 (POSIX 1789762471, 𝛥 1day 21hr 39min 43sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               960CC510-1FC7-34AB-9A53-3AF26B2A192E
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77776 (0x12fd0))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (77780 (0x12fd4))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3096
mod date:                   2026-09-19 20:46 (POSIX 1789843594, 𝛥 23hr 7min 40sec)
exec mod date:              2026-09-19 20:46 (POSIX 1789843574, 𝛥 23hr 8min)
reg date:                   2026-09-19 20:46 (POSIX 1789843594, 𝛥 23hr 7min 40sec)
rec mod date:               2026-09-19 20:46 (POSIX 1789843594, 𝛥 23hr 7min 40sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element (0000000000000004)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               F01C55FF-43EA-34D2-BA1A-F97380945286
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77788 (0x12fdc))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (77792 (0x12fe0))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (77796 (0x12fe4))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3100
mod date:                   2026-09-19 22:01 (POSIX 1789848099, 𝛥 21hr 52min 35sec)
exec mod date:              2026-09-19 22:01 (POSIX 1789848099, 𝛥 21hr 52min 35sec)
reg date:                   2026-09-19 22:01 (POSIX 1789848099, 𝛥 21hr 52min 35sec)
rec mod date:               2026-09-19 22:01 (POSIX 1789848099, 𝛥 21hr 52min 35sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               BD953318-C7F6-3982-8C2F-87DB2FD3F778, 47D1006C-0C2B-395F-8508-61E10C9B64CA
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77804 (0x12fec))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (77808 (0x12ff0))
                            {
                            }
Intents:                    0 values (77812 (0x12ff4))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3104
mod date:                   2026-09-19 22:02 (POSIX 1789848140, 𝛥 21hr 51min 54sec)
exec mod date:              2026-09-19 22:02 (POSIX 1789848140, 𝛥 21hr 51min 54sec)
reg date:                   2026-09-19 22:02 (POSIX 1789848140, 𝛥 21hr 51min 54sec)
rec mod date:               2026-09-19 22:02 (POSIX 1789848140, 𝛥 21hr 51min 54sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element  in-temp-dir (0000800000000004)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               BDC1BC7B-98C1-324D-AA0F-BF5C5345DFDC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77864 (0x13028))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (77868 (0x1302c))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3120
mod date:                   2026-09-20 06:44 (POSIX 1789879485, 𝛥 13hr 9min 29sec)
exec mod date:              2026-09-20 06:44 (POSIX 1789879485, 𝛥 13hr 9min 29sec)
reg date:                   2026-09-20 06:44 (POSIX 1789879485, 𝛥 13hr 9min 29sec)
rec mod date:               2026-09-20 06:44 (POSIX 1789879485, 𝛥 13hr 9min 29sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element  in-temp-dir (0000800000000004)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               8172D981-60F6-3FDC-B0C9-7E4E7EAEF85A, B4D9A1EF-A20C-35E3-9A00-F824696F11AA
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77888 (0x13040))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (77892 (0x13044))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3128
mod date:                   2026-09-20 06:46 (POSIX 1789879609, 𝛥 13hr 7min 25sec)
exec mod date:              2026-09-20 06:46 (POSIX 1789879609, 𝛥 13hr 7min 25sec)
reg date:                   2026-09-20 06:46 (POSIX 1789879609, 𝛥 13hr 7min 25sec)
rec mod date:               2026-09-20 06:46 (POSIX 1789879609, 𝛥 13hr 7min 25sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element  in-temp-dir (0000800000000004)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               98C03CA9-4DD3-341C-A42B-D9FEE7B4AFEF
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77928 (0x13068))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (77932 (0x1306c))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (77936 (0x13070))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3144
mod date:                   2026-09-20 06:55 (POSIX 1789880122, 𝛥 12hr 58min 52sec)
exec mod date:              2026-09-20 06:55 (POSIX 1789880122, 𝛥 12hr 58min 52sec)
reg date:                   2026-09-20 06:55 (POSIX 1789880122, 𝛥 12hr 58min 52sec)
rec mod date:               2026-09-20 06:55 (POSIX 1789880122, 𝛥 12hr 58min 52sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               DCF42718-EF9B-39E8-A4F8-D5F997FF2A05, CC0C580A-83AE-380E-91D4-6AF2F23B24AE
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77960 (0x13088))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (77964 (0x1308c))
                            {
                            }
Intents:                    0 values (77968 (0x13090))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3164
mod date:                   2026-09-20 06:56 (POSIX 1789880164, 𝛥 12hr 58min 10sec)
exec mod date:              2026-09-20 06:56 (POSIX 1789880164, 𝛥 12hr 58min 10sec)
reg date:                   2026-09-20 06:56 (POSIX 1789880164, 𝛥 12hr 58min 10sec)
rec mod date:               2026-09-20 06:56 (POSIX 1789880164, 𝛥 12hr 58min 10sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element  in-temp-dir (0000800000000004)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               3EF98C60-047B-372A-B6DE-C1A5DD64E0E0
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (78048 (0x130e0))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78052 (0x130e4))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78056 (0x130e8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3200
mod date:                   2026-09-20 07:29 (POSIX 1789882160, 𝛥 12hr 24min 55sec)
exec mod date:              2026-09-20 07:29 (POSIX 1789882160, 𝛥 12hr 24min 55sec)
reg date:                   2026-09-20 07:29 (POSIX 1789882160, 𝛥 12hr 24min 55sec)
rec mod date:               2026-09-20 07:29 (POSIX 1789882160, 𝛥 12hr 24min 55sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               59D191E5-A973-3BD0-9549-F406E0669026
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78496 (0x132a0))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78500 (0x132a4))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78504 (0x132a8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3332
mod date:                   2026-09-20 07:56 (POSIX 1789883763, 𝛥 11hr 58min 12sec)
exec mod date:              2026-09-20 07:56 (POSIX 1789883763, 𝛥 11hr 58min 12sec)
reg date:                   2026-09-20 07:56 (POSIX 1789883763, 𝛥 11hr 58min 12sec)
rec mod date:               2026-09-20 07:56 (POSIX 1789883763, 𝛥 11hr 58min 12sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               8A615183-7FE1-3F4A-8D25-BA49DE17D4BA, BE01EBF8-F6B4-3B1C-984F-101687C3FE81
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78512 (0x132b0))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (78516 (0x132b4))
                            {
                            }
Intents:                    0 values (78520 (0x132b8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3336
mod date:                   2026-09-20 07:56 (POSIX 1789883805, 𝛥 11hr 57min 30sec)
exec mod date:              2026-09-20 07:56 (POSIX 1789883805, 𝛥 11hr 57min 30sec)
reg date:                   2026-09-20 07:56 (POSIX 1789883805, 𝛥 11hr 57min 30sec)
rec mod date:               2026-09-20 07:56 (POSIX 1789883805, 𝛥 11hr 57min 30sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               499F1855-559B-30B0-A635-927620E58D81
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78648 (0x13338))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78652 (0x1333c))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78656 (0x13340))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3376
mod date:                   2026-09-20 08:13 (POSIX 1789884828, 𝛥 11hr 40min 27sec)
exec mod date:              2026-09-20 08:13 (POSIX 1789884828, 𝛥 11hr 40min 27sec)
reg date:                   2026-09-20 08:13 (POSIX 1789884828, 𝛥 11hr 40min 27sec)
rec mod date:               2026-09-20 08:13 (POSIX 1789884828, 𝛥 11hr 40min 27sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               4A6D3BCC-AE02-3C5B-A801-808937651B2A, EF4F3BBC-4F40-3FA2-BC9A-43F9D7A1BD57
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78664 (0x13348))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (78668 (0x1334c))
                            {
                            }
Intents:                    0 values (78672 (0x13350))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3380
mod date:                   2026-09-20 08:14 (POSIX 1789884869, 𝛥 11hr 39min 46sec)
exec mod date:              2026-09-20 08:14 (POSIX 1789884869, 𝛥 11hr 39min 46sec)
reg date:                   2026-09-20 08:14 (POSIX 1789884869, 𝛥 11hr 39min 46sec)
rec mod date:               2026-09-20 08:14 (POSIX 1789884869, 𝛥 11hr 39min 46sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               507E8E09-22A7-3D63-8422-3D122D0D78E6
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78680 (0x13358))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78684 (0x1335c))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78688 (0x13360))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3384
mod date:                   2026-09-20 08:31 (POSIX 1789885881, 𝛥 11hr 22min 54sec)
exec mod date:              2026-09-20 08:31 (POSIX 1789885881, 𝛥 11hr 22min 54sec)
reg date:                   2026-09-20 08:31 (POSIX 1789885881, 𝛥 11hr 22min 54sec)
rec mod date:               2026-09-20 08:31 (POSIX 1789885881, 𝛥 11hr 22min 54sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               8F880921-18D5-3498-BB57-43E684A21564
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78776 (0x133b8))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78780 (0x133bc))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78784 (0x133c0))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3412
mod date:                   2026-09-20 11:40 (POSIX 1789897213, 𝛥 8hr 14min 2sec)
exec mod date:              2026-09-20 11:40 (POSIX 1789897213, 𝛥 8hr 14min 2sec)
reg date:                   2026-09-20 11:40 (POSIX 1789897213, 𝛥 8hr 14min 2sec)
rec mod date:               2026-09-20 11:40 (POSIX 1789897213, 𝛥 8hr 14min 2sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               D7FB51D4-5E23-3817-A892-3D02639F6953
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78820 (0x133e4))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (78824 (0x133e8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3424
mod date:                   2026-09-20 12:04 (POSIX 1789898678, 𝛥 7hr 49min 37sec)
exec mod date:              2026-09-20 12:04 (POSIX 1789898678, 𝛥 7hr 49min 37sec)
reg date:                   2026-09-20 12:04 (POSIX 1789898678, 𝛥 7hr 49min 37sec)
rec mod date:               2026-09-20 12:04 (POSIX 1789898678, 𝛥 7hr 49min 37sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
safeAperture system fullscreen: capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               C9461265-B9E1-34E3-B498-FB0F049C1502
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78920 (0x13448))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78924 (0x1344c))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78928 (0x13450))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3456
mod date:                   2026-09-20 12:39 (POSIX 1789900790, 𝛥 7hr 14min 25sec)
exec mod date:              2026-09-20 12:39 (POSIX 1789900790, 𝛥 7hr 14min 25sec)
reg date:                   2026-09-20 12:39 (POSIX 1789900791, 𝛥 7hr 14min 24sec)
rec mod date:               2026-09-20 12:39 (POSIX 1789900791, 𝛥 7hr 14min 24sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               A4D6ECFB-CBC4-328F-A2B2-368A95C14FA9
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78964 (0x13474))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (78968 (0x13478))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3468
mod date:                   2026-09-20 12:53 (POSIX 1789901585, 𝛥 7hr 1min 10sec)
exec mod date:              2026-09-20 12:53 (POSIX 1789901585, 𝛥 7hr 1min 10sec)
reg date:                   2026-09-20 12:53 (POSIX 1789901585, 𝛥 7hr 1min 10sec)
rec mod date:               2026-09-20 12:53 (POSIX 1789901585, 𝛥 7hr 1min 10sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
safeAperture system fullscreen: capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               E22AF7A7-7871-343D-B559-F25EB370E4E3
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79116 (0x1350c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79120 (0x13510))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79124 (0x13514))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3512
mod date:                   2026-09-20 13:33 (POSIX 1789904021, 𝛥 6hr 20min 34sec)
exec mod date:              2026-09-20 13:33 (POSIX 1789904021, 𝛥 6hr 20min 34sec)
reg date:                   2026-09-20 13:33 (POSIX 1789904021, 𝛥 6hr 20min 34sec)
rec mod date:               2026-09-20 13:33 (POSIX 1789904021, 𝛥 6hr 20min 34sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               941CEBEA-810B-3320-B08B-B908B6C2CF6B, F46B9532-4E94-3940-8289-6789353020A3
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79132 (0x1351c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (79136 (0x13520))
                            {
                            }
Intents:                    0 values (79140 (0x13524))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3516
mod date:                   2026-09-20 13:34 (POSIX 1789904047, 𝛥 6hr 20min 8sec)
exec mod date:              2026-09-20 13:34 (POSIX 1789904047, 𝛥 6hr 20min 8sec)
reg date:                   2026-09-20 13:34 (POSIX 1789904047, 𝛥 6hr 20min 8sec)
rec mod date:               2026-09-20 13:34 (POSIX 1789904047, 𝛥 6hr 20min 8sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               611EAA99-618E-3926-8165-41BB6166F231
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79148 (0x1352c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79152 (0x13530))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79156 (0x13534))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3520
mod date:                   2026-09-20 13:38 (POSIX 1789904312, 𝛥 6hr 15min 43sec)
exec mod date:              2026-09-20 13:38 (POSIX 1789904312, 𝛥 6hr 15min 43sec)
reg date:                   2026-09-20 13:38 (POSIX 1789904312, 𝛥 6hr 15min 43sec)
rec mod date:               2026-09-20 13:38 (POSIX 1789904312, 𝛥 6hr 15min 43sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               6C3FDEE2-F168-3A8C-99EB-2FB205BBD613
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79164 (0x1353c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79168 (0x13540))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79172 (0x13544))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3524
mod date:                   2026-09-20 13:39 (POSIX 1789904360, 𝛥 6hr 14min 55sec)
exec mod date:              2026-09-20 13:39 (POSIX 1789904360, 𝛥 6hr 14min 55sec)
reg date:                   2026-09-20 13:39 (POSIX 1789904360, 𝛥 6hr 14min 55sec)
rec mod date:               2026-09-20 13:39 (POSIX 1789904360, 𝛥 6hr 14min 55sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               A31D4513-0DA0-3C30-AC20-4C6574BD3E24, 9AEA154C-3561-3851-83A8-6F240A4E1435
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79196 (0x1355c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (79200 (0x13560))
                            {
                            }
Intents:                    0 values (79204 (0x13564))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3532
mod date:                   2026-09-20 13:40 (POSIX 1789904433, 𝛥 6hr 13min 42sec)
exec mod date:              2026-09-20 13:40 (POSIX 1789904432, 𝛥 6hr 13min 43sec)
reg date:                   2026-09-20 13:40 (POSIX 1789904433, 𝛥 6hr 13min 42sec)
rec mod date:               2026-09-20 13:40 (POSIX 1789904433, 𝛥 6hr 13min 42sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               1891D1AD-93FF-37ED-8573-2EDD75B5A537
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79212 (0x1356c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79216 (0x13570))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79220 (0x13574))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3536
mod date:                   2026-09-20 13:43 (POSIX 1789904628, 𝛥 6hr 10min 27sec)
exec mod date:              2026-09-20 13:43 (POSIX 1789904628, 𝛥 6hr 10min 27sec)
reg date:                   2026-09-20 13:43 (POSIX 1789904628, 𝛥 6hr 10min 27sec)
rec mod date:               2026-09-20 13:43 (POSIX 1789904628, 𝛥 6hr 10min 27sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               7C9D7BD8-32A5-3B61-8691-EE7710384437, D0DDE9A0-F430-38D3-BCF5-6E1849D1B1B3
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79228 (0x1357c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (79232 (0x13580))
                            {
                            }
Intents:                    0 values (79236 (0x13584))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3540
mod date:                   2026-09-20 13:45 (POSIX 1789904708, 𝛥 6hr 9min 7sec)
exec mod date:              2026-09-20 13:45 (POSIX 1789904708, 𝛥 6hr 9min 7sec)
reg date:                   2026-09-20 13:45 (POSIX 1789904708, 𝛥 6hr 9min 7sec)
rec mod date:               2026-09-20 13:45 (POSIX 1789904708, 𝛥 6hr 9min 7sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               665BB1F3-52F1-3FEB-BD38-72186AB315FE, 992EDB20-6AFB-368B-9599-4F9190C0B5E1
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79244 (0x1358c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (79248 (0x13590))
                            {
                            }
Intents:                    0 values (79252 (0x13594))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3544
mod date:                   2026-09-20 13:45 (POSIX 1789904735, 𝛥 6hr 8min 40sec)
exec mod date:              2026-09-20 13:45 (POSIX 1789904735, 𝛥 6hr 8min 40sec)
reg date:                   2026-09-20 13:45 (POSIX 1789904735, 𝛥 6hr 8min 40sec)
rec mod date:               2026-09-20 13:45 (POSIX 1789904735, 𝛥 6hr 8min 40sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               6BDDA2EF-11F4-3D3C-86B9-22481065638B
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79388 (0x1361c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79392 (0x13620))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79396 (0x13624))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3588
mod date:                   2026-09-20 14:01 (POSIX 1789905705, 𝛥 5hr 52min 30sec)
exec mod date:              2026-09-20 14:19 (POSIX 1789906774, 𝛥 5hr 34min 41sec)
reg date:                   2026-09-20 14:19 (POSIX 1789906774, 𝛥 5hr 34min 41sec)
rec mod date:               2026-09-20 14:19 (POSIX 1789906774, 𝛥 5hr 34min 41sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               383F40B6-9FA7-3410-9735-559095D4D4F5
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79420 (0x1363c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79424 (0x13640))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79428 (0x13644))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3596
mod date:                   2026-09-20 14:23 (POSIX 1789906982, 𝛥 5hr 31min 13sec)
exec mod date:              2026-09-20 14:23 (POSIX 1789906982, 𝛥 5hr 31min 13sec)
reg date:                   2026-09-20 14:23 (POSIX 1789906982, 𝛥 5hr 31min 13sec)
rec mod date:               2026-09-20 14:23 (POSIX 1789906982, 𝛥 5hr 31min 13sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               CD3C6942-FA61-3729-9630-4610A59C9C79
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79436 (0x1364c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79440 (0x13650))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79444 (0x13654))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3600
mod date:                   2026-09-20 14:23 (POSIX 1789907005, 𝛥 5hr 30min 50sec)
exec mod date:              2026-09-20 14:23 (POSIX 1789907005, 𝛥 5hr 30min 50sec)
reg date:                   2026-09-20 14:23 (POSIX 1789907005, 𝛥 5hr 30min 50sec)
rec mod date:               2026-09-20 14:23 (POSIX 1789907005, 𝛥 5hr 30min 50sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               E8BE9F70-E5BF-3996-955B-DFC37EF7CC5F
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79516 (0x1369c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79520 (0x136a0))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79524 (0x136a4))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3620
mod date:                   2026-09-20 14:58 (POSIX 1789909118, 𝛥 4hr 55min 37sec)
exec mod date:              2026-09-20 14:58 (POSIX 1789909118, 𝛥 4hr 55min 37sec)
reg date:                   2026-09-20 14:58 (POSIX 1789909118, 𝛥 4hr 55min 37sec)
rec mod date:               2026-09-20 14:58 (POSIX 1789909118, 𝛥 4hr 55min 37sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               52B82528-A17A-32CB-B1E2-79F0FCBE6812
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79660 (0x1372c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79664 (0x13730))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79668 (0x13734))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3656
mod date:                   2026-09-20 16:14 (POSIX 1789913668, 𝛥 3hr 39min 47sec)
exec mod date:              2026-09-20 16:14 (POSIX 1789913668, 𝛥 3hr 39min 47sec)
reg date:                   2026-09-20 16:14 (POSIX 1789913668, 𝛥 3hr 39min 47sec)
rec mod date:               2026-09-20 16:14 (POSIX 1789913668, 𝛥 3hr 39min 47sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               A2B50C20-9218-3576-867C-22E5F40C6F5C, F2856F90-3BF2-33CA-8487-3DA7A2FD7813
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79676 (0x1373c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (79680 (0x13740))
                            {
                            }
Intents:                    0 values (79684 (0x13744))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3660
mod date:                   2026-09-20 16:15 (POSIX 1789913711, 𝛥 3hr 39min 4sec)
exec mod date:              2026-09-20 16:15 (POSIX 1789913711, 𝛥 3hr 39min 4sec)
reg date:                   2026-09-20 16:15 (POSIX 1789913711, 𝛥 3hr 39min 4sec)
rec mod date:               2026-09-20 16:15 (POSIX 1789913711, 𝛥 3hr 39min 4sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               2C40A1B9-6BA5-3685-9161-0FA234BA3739
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80012 (0x1388c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (80016 (0x13890))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (80020 (0x13894))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3744
mod date:                   2026-09-20 17:33 (POSIX 1789918398, 𝛥 2hr 20min 57sec)
exec mod date:              2026-09-20 17:36 (POSIX 1789918618, 𝛥 2hr 17min 17sec)
reg date:                   2026-09-20 17:36 (POSIX 1789918618, 𝛥 2hr 17min 17sec)
rec mod date:               2026-09-20 17:36 (POSIX 1789918618, 𝛥 2hr 17min 17sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               39687B5F-CA38-35FF-B4CA-70376CD6AE13
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80052 (0x138b4))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (80056 (0x138b8))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (80060 (0x138bc))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3756
mod date:                   2026-09-20 13:30 (POSIX 1789903818, 𝛥 6hr 23min 57sec)
exec mod date:              2026-09-20 17:44 (POSIX 1789919084, 𝛥 2hr 9min 31sec)
reg date:                   2026-09-20 17:44 (POSIX 1789919084, 𝛥 2hr 9min 31sec)
rec mod date:               2026-09-20 17:44 (POSIX 1789919084, 𝛥 2hr 9min 31sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               9D535CBE-FE37-345D-B352-A0C806EE554E, 7767A67F-5DC7-38A7-B765-B04082D21079
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80084 (0x138d4))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80088 (0x138d8))
                            {
                            }
Intents:                    0 values (80092 (0x138dc))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3764
mod date:                   2026-09-20 17:06 (POSIX 1789916788, 𝛥 2hr 47min 47sec)
exec mod date:              2026-09-20 17:06 (POSIX 1789916788, 𝛥 2hr 47min 47sec)
reg date:                   2026-09-20 18:08 (POSIX 1789920487, 𝛥 1hr 46min 8sec)
rec mod date:               2026-09-20 18:08 (POSIX 1789920487, 𝛥 1hr 46min 8sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               DBA0A54D-3BF3-3744-B14B-561E30C5CB14, 270897AB-5403-3AC6-85F7-4243B8522A72
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80116 (0x138f4))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80120 (0x138f8))
                            {
                            }
Intents:                    0 values (80124 (0x138fc))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3772
mod date:                   2026-09-20 18:22 (POSIX 1789921371, 𝛥 1hr 31min 24sec)
exec mod date:              2026-09-20 18:22 (POSIX 1789921371, 𝛥 1hr 31min 24sec)
reg date:                   2026-09-20 18:22 (POSIX 1789921371, 𝛥 1hr 31min 24sec)
rec mod date:               2026-09-20 18:22 (POSIX 1789921371, 𝛥 1hr 31min 24sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               ED218350-B809-3503-BC73-EE0ABB3B2C9D, 49E62944-B690-37B7-B366-1CA12C1E47F4
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80208 (0x13950))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80212 (0x13954))
                            {
                            }
Intents:                    0 values (80216 (0x13958))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3796
mod date:                   2026-09-20 19:12 (POSIX 1789924344, 𝛥 41min 51sec)
exec mod date:              2026-09-20 19:12 (POSIX 1789924344, 𝛥 41min 51sec)
reg date:                   2026-09-20 19:13 (POSIX 1789924431, 𝛥 40min 24sec)
rec mod date:               2026-09-20 19:13 (POSIX 1789924431, 𝛥 40min 24sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               E8B62352-E547-3D9E-92DB-2F8BD7094482, DA4D9E70-4D15-36C2-8F08-11514BBB7DA9
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80240 (0x13970))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80244 (0x13974))
                            {
                            }
Intents:                    0 values (80248 (0x13978))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3804
mod date:                   2026-09-20 19:17 (POSIX 1789924647, 𝛥 36min 48sec)
exec mod date:              2026-09-20 19:17 (POSIX 1789924647, 𝛥 36min 48sec)
reg date:                   2026-09-20 19:18 (POSIX 1789924688, 𝛥 36min 7sec)
rec mod date:               2026-09-20 19:18 (POSIX 1789924688, 𝛥 36min 7sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               758504CE-D200-3A46-9246-8648146F4FAB, FED43FD6-5049-3011-A0F7-6A5502B300BC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80272 (0x13990))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80276 (0x13994))
                            {
                            }
Intents:                    0 values (80280 (0x13998))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3812
mod date:                   2026-09-20 19:19 (POSIX 1789924766, 𝛥 34min 49sec)
exec mod date:              2026-09-20 19:19 (POSIX 1789924766, 𝛥 34min 49sec)
reg date:                   2026-09-20 19:19 (POSIX 1789924795, 𝛥 34min 20sec)
rec mod date:               2026-09-20 19:19 (POSIX 1789924795, 𝛥 34min 20sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               758504CE-D200-3A46-9246-8648146F4FAB, FED43FD6-5049-3011-A0F7-6A5502B300BC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80304 (0x139b0))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80308 (0x139b4))
                            {
                            }
Intents:                    0 values (80312 (0x139b8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3820
mod date:                   2026-09-20 19:21 (POSIX 1789924877, 𝛥 32min 58sec)
exec mod date:              2026-09-20 19:21 (POSIX 1789924877, 𝛥 32min 58sec)
reg date:                   2026-09-20 19:21 (POSIX 1789924901, 𝛥 32min 34sec)
rec mod date:               2026-09-20 19:21 (POSIX 1789924901, 𝛥 32min 34sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               758504CE-D200-3A46-9246-8648146F4FAB, FED43FD6-5049-3011-A0F7-6A5502B300BC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80336 (0x139d0))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80340 (0x139d4))
                            {
                            }
Intents:                    0 values (80344 (0x139d8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3828
mod date:                   2026-09-20 19:22 (POSIX 1789924966, 𝛥 31min 29sec)
exec mod date:              2026-09-20 19:22 (POSIX 1789924966, 𝛥 31min 29sec)
reg date:                   2026-09-20 19:23 (POSIX 1789924991, 𝛥 31min 4sec)
rec mod date:               2026-09-20 19:23 (POSIX 1789924991, 𝛥 31min 4sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               758504CE-D200-3A46-9246-8648146F4FAB, FED43FD6-5049-3011-A0F7-6A5502B300BC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80368 (0x139f0))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80372 (0x139f4))
                            {
                            }
Intents:                    0 values (80376 (0x139f8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3836
mod date:                   2026-09-20 19:27 (POSIX 1789925224, 𝛥 27min 11sec)
exec mod date:              2026-09-20 19:27 (POSIX 1789925224, 𝛥 27min 11sec)
reg date:                   2026-09-20 19:27 (POSIX 1789925278, 𝛥 26min 17sec)
rec mod date:               2026-09-20 19:27 (POSIX 1789925278, 𝛥 26min 17sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               758504CE-D200-3A46-9246-8648146F4FAB, FED43FD6-5049-3011-A0F7-6A5502B300BC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80400 (0x13a10))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80404 (0x13a14))
                            {
                            }
Intents:                    0 values (80408 (0x13a18))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3844
mod date:                   2026-09-20 19:32 (POSIX 1789925566, 𝛥 21min 29sec)
exec mod date:              2026-09-20 19:32 (POSIX 1789925566, 𝛥 21min 29sec)
reg date:                   2026-09-20 19:35 (POSIX 1789925745, 𝛥 18min 30sec)
rec mod date:               2026-09-20 19:35 (POSIX 1789925745, 𝛥 18min 30sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               664E8B78-9874-3DBC-9753-BEB405D56066, 5A956D8C-6A18-3D0F-9B3E-C53A108E7E33
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80432 (0x13a30))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80436 (0x13a34))
                            {
                            }
Intents:                    0 values (80440 (0x13a38))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3852
mod date:                   2026-09-20 19:38 (POSIX 1789925893, 𝛥 16min 2sec)
exec mod date:              2026-09-20 19:38 (POSIX 1789925893, 𝛥 16min 2sec)
reg date:                   2026-09-20 19:39 (POSIX 1789925954, 𝛥 15min 1sec)
rec mod date:               2026-09-20 19:39 (POSIX 1789925954, 𝛥 15min 1sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               664E8B78-9874-3DBC-9753-BEB405D56066, 5A956D8C-6A18-3D0F-9B3E-C53A108E7E33
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80464 (0x13a50))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80468 (0x13a54))
                            {
                            }
Intents:                    0 values (80472 (0x13a58))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3860
mod date:                   2026-09-20 19:38 (POSIX 1789925893, 𝛥 16min 2sec)
exec mod date:              2026-09-20 19:38 (POSIX 1789925893, 𝛥 16min 2sec)
reg date:                   2026-09-20 19:53 (POSIX 1789926795, 𝛥 60sec)
rec mod date:               2026-09-20 19:53 (POSIX 1789926795, 𝛥 60sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               launch-disabled (0000000000000080)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
-- processes excluding inspection shell
-- latest durable diagnostics
45|2026-09-20 17:39:15|platform|refused|bootstrap executor refused before receipt|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
44|2026-09-20 17:39:15|platform|registration-observation|value=unknown status=notFound approvalRequired=false|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
43|2026-09-20 17:39:15|consume|success|one-time invocation consumed|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
42|2026-09-20 17:39:15|preflight|success|canonical signed controller validated|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
41|2026-09-20 17:39:15|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
classification=STOP; installed Start returned LIFECYCLE_UNKNOWN but produced no new correlated durable diagnostics; exact installed controller execution is not proven; no retry/recovery/Off.

## E-049 — M14 final acceptance reconciliation — 2026-09-21

- Bane accepted M14 and authorized final reconciliation, safe housekeeping,
  commit, the established M14 tag, and branch/tag push. No lifecycle mutation
  was performed during finalization.
- Read-only final SQLite counts are projects `3`, route intents `1`, route
  transitions `0`, TLS capability rows `1`, and system modifications `1`.
  The TLS row was present before M14 and its fingerprint/path remain unchanged.
  Syncproof was not accessed or mutated.
- Accepted lifecycle sequence: Start generation 3, Off generation 4, Start
  generation 5. Final intent is `on`, generation `5`; register and ownership
  generation 5 succeeded with no unresolved lifecycle rows.
- Installed identity evidence: `/Applications/Vaelen.app`; app SHA-256
  `1fff5863be7e1410fd918c3fb5e2e9daccb07aa19346f9dcdda4d13f870aebc2`, daemon
  SHA-256 `86c7dd3799c6df699142d044c4d1cab311bd35aea4c754389ef6c54d2a6dc857`,
  identifiers `dev.vaelen.app`/`vaelend`, TeamIdentifier `TFKZJV643G`, and deep
  strict code-sign verification passed.
- Regression evidence: `218` passed, `14` skipped, `0` failed; no rerun was
  required because finalization changed only evidence/housekeeping.
- Build evidence identifies product version `0.0.14-dev`, build identity
  `m14-core-daemon-lifecycle-schema-7`, SQLite user version `13`, IPC protocol
  version `1`, and IPC schema compatibility version `5`.
- This is Bane-authorized freeze-readiness evidence only; it does not freeze
  M14 or authorize M15.
