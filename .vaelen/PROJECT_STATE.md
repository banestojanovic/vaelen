# Vaelen Project State

This file is durable project-management state, not an ADR. Frozen ADRs and
accepted milestone records remain authoritative for architecture.

## Frozen baseline

- M0–M13 are frozen.
- M12: tag `v0.0.13-m12`; freeze commit
  `e76e260b69b6b1e0216fdc8985ce13cfa4c79964`.
- M13: tag `v0.0.14-m13`; freeze commit
  `534da3618895717624cb9d4bf7dd685f5dfd571b`.
- ADR-0013 is accepted and frozen.
- Do not reopen frozen architecture without Bane's Class C decision.

## Active milestone

- Milestone: M14 — Core Daemon Installation and Lifecycle.
- Phase: production implementation and evidence development; milestone remains
  active and unfrozen.
- Production M14 implementation: **authorized by Bane's Class C decision**;
  production acceptance and runtime proof remain incomplete.
- ADR-0014: **accepted**; M14 is not accepted or frozen.
- The single authorized repaired-A crash/recovery mutation was executed once on
  2026-09-19; no further crash/recovery mutation is authorized by this state
  record.
- Accepted architecture: per-user `SMAppService.agent` plus launchd
  supervision, with Core as sole semantic lifecycle authority.
- ADR: `docs/adr/ADR-0014-core-daemon-installation-and-lifecycle.md`.
  Production implementation and evidence remain incomplete and
  NOT-YET-PROVEN where recorded by the ADR.
- Class C decision: Core owns lifecycle intent, authorization, provenance,
  reconciliation, fail-closed destructive decisions, and GUI/CLI results. A
  platform executor, if needed for ServiceManagement context, is only a
  constrained Core-issued side-effect executor and is not a second authority.
- Additional Class C decisions: the signed app/controller may perform only the
  fixed, explicit Core-absent bootstrap operation as a constrained executor;
  replacement, updater, rollback, version handoff, and old-bundle cleanup are
  deferred beyond minimum M14. The bootstrap reservation/handoff contract is
  recorded in accepted ADR-0014; its implementation and product evidence remain
  NOT-YET-PROVEN.
- Architecture status: ADR-0014 accepted by Class C decision. M14 remains active
  and unfrozen; production implementation is authorized, while production
  acceptance remains NOT-YET-PROVEN.

## Established M14 facts

- Per-user `SMAppService.agent` registration succeeded on the test Mac.
- The tested registration did not present administrator authentication.
- Registration status, launchd job presence, process presence, endpoint
  reachability, and application readiness are distinct observations.
- The helper has been observed launchd-owned with PPID 1 and UID/EUID 501/501.
- `BundleProgram` resolves the embedded helper.
- Repaired-A passed exact `proc_pidpath` validation and produced stable
  heartbeats.
- Repaired-A helper signing identifier is
  `dev.vaelen.m14-lifecycle-experiment.agent`.
- Repaired-A TeamIdentifier is `TFKZJV643G`.

Evidence references: E-002 (stable baseline), E-004 (path repair), E-006
(single bounded crash/recovery observation), and E-012 (implementation
foundation and isolated validation).

## Invalidated or unresolved

- No valid controlled B artifact or B evidence exists.
- The signing-identifier causal hypothesis is untested.
- Do not claim that changing the helper CodeDirectory identifier caused the
  historical launch-admission difference.
- The historical launch-constraint discrepancy remains unresolved.
- A stable repaired-A baseline alone does not establish crash/recovery behavior;
  the bounded recovery observation is recorded in E-006.

Acceptance gates are `RUNTIME-PROVEN` for this bounded repaired-A launchd
crash/recovery observation, replacement PID/generation, registration
continuity, and observed post-recovery identity/ownership. They remain
`NOT-YET-PROVEN` for universal macOS guarantees, broader failure modes, public
product acceptance, and any production M14 implementation. No state in this
file authorizes milestone acceptance or freeze.

## Current authorized boundary

- The single Bane-authorized M14 production lifecycle validation attempt on
  2026-09-20 stopped before mutation because a fresh canonical absence
  snapshot could not be completed in the delegated environment. No product
  controller was invoked and no lifecycle state was changed. Any further
  production validation requires explicit current authority and a working
  read-only pre-mutation inspection path.

The single repaired-A launchd recovery observation has been executed. Production
source, migrations, typed IPC/API changes, tests, and minimum packaging
integration are authorized within accepted ADR-0014. New destructive real-system
lifecycle experiments remain unauthorized.

The authorization for exactly one bounded repaired-A `terminate-agent`
crash/recovery experiment is **CONSUMED**. The controller recorded and issued
SIGKILL once to verified PID 6130; no second termination was performed.

Implementation must preserve M0-M13 and the accepted ADR boundary. Syncproof,
milestone freeze, release, tag, and push remain out of scope; commit authority
is not granted by this state record.

## Canonical signing trust boundary

- Exact TeamIdentifier `TFKZJV643G` is required for canonical app
  `dev.vaelen.app` and nested daemon `vaelend`.
- Valid Apple signatures, designated requirements, nested verification, and
  canonical app/LaunchAgent layout are required; hashes, CDHashes, certificate
  leaves, and subject suffixes remain non-pinned evidence only.

## Delegation-preparation observations

- Observed: PM -> `vaelen-lead` delegation works.
- Observed: nested Lead -> `investigator` delegation works.
- Observed: Investigator -> Lead -> PM result propagation works.
- Observed: native read-only repository inspection works through that chain.
- Observed: `opencode.json` retains `default_agent: vaelen-pm` and
  `experimental.subagent_depth: 2`.
- Observed: `vaelen-lead` retains `mode: subagent` and corrected YAML
  indentation. Controlled before/after evidence strongly supports malformed
  indentation as the cause of the prior rejection; parser normalization was
  not directly observed.
- Observed: the disposable delegation probe and failed shell/Git acceptance
  attempts were transport/permission failures, not invalidating delegation
  evidence. The final cleanup pass was completed through shell-free file
  inspection and bounded edits.

## Human authority required

Bane must decide Class C matters: frozen architecture or ADR changes,
security/trust/privilege changes, ownership or destructive semantics,
milestone scope expansion, milestone freeze, irreversible migrations, and
release/commit/tag/push authorization.

## M14 final acceptance reconciliation — 2026-09-21

Bane accepted M14 and explicitly authorized final evidence reconciliation, safe
housekeeping, commit, the established M14 tag, and branch/tag push. The final
read-only preservation baseline is 3 projects, 1 route intent, 0 route
transitions, 1 pre-existing unchanged TLS capability row, and 1 system
modification. Syncproof remains untouched.

The accepted runtime sequence is Start generation 3, Off generation 4, and
Start generation 5. Final durable intent is `on`, generation 5, with successful
register/ownership evidence and no unresolved lifecycle rows. Final regression
evidence is 218 passed and 14 skipped (0 failures).

Build evidence: product version `0.0.14-dev`; build identity
`m14-core-daemon-lifecycle-schema-7`; SQLite user version `13`; IPC protocol
version `1`; IPC schema compatibility version `5`. Installed/running identity
remains `/Applications/Vaelen.app` with the accepted signed `vaelend` under
`dev.vaelen.vaelend`.

This records Bane's acceptance and M14 freeze-readiness for the authorized
finalization boundary. It does not independently freeze M14 or authorize M15.
