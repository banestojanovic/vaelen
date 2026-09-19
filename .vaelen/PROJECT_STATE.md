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
- Phase: disposable platform/lifecycle validation and evidence review.
- Production M14 implementation: **not authorized**.
- ADR-0014: not accepted or frozen.
- No M14 crash/recovery mutation is currently authorized by this state record.

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

Evidence references: E-002 (stable baseline) and E-004 (path repair).

## Invalidated or unresolved

- No valid controlled B artifact or B evidence exists.
- The signing-identifier causal hypothesis is untested.
- Do not claim that changing the helper CodeDirectory identifier caused the
  historical launch-admission difference.
- The historical launch-constraint discrepancy remains unresolved.
- A stable repaired-A baseline does not establish crash/recovery behavior.

Acceptance gates currently remain `NOT-YET-PROVEN` for launchd crash/recovery,
replacement PID/generation, and any production M14 implementation. No state in
this file authorizes milestone acceptance or freeze.

## Current authorized boundary

The next bounded M14 step may be planned as a single repaired-A launchd
recovery observation, but it requires explicit authorization before
`terminate-agent` is executed. Until then, only read-only inspection and
documentation are authorized.

Any implementation must remain disposable and experiment-only. Production
Vaelen, Syncproof, frozen ADRs, milestone freeze, release, commit, tag, and
push remain out of scope.

## Human authority required

Bane must decide Class C matters: frozen architecture or ADR changes,
security/trust/privilege changes, ownership or destructive semantics,
milestone scope expansion, milestone freeze, irreversible migrations, and
release/commit/tag/push authorization.
