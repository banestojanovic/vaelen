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
