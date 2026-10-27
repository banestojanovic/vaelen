# Mailpit identity fix round two

## Bug fix workflow

- [x] Reproduce it yourself on the matching surface via the control skill (Non-negotiables), even when a debug or instrumentation protocol says to ask the user to reproduce. Ask the user only with a stated, specific reason the control surface cannot reach the target, and only after driving it as far as it goes. If it won't reproduce directly, synthesize the trigger, tighten conditions, or instrument until it fires.
- [x] Binary-search the cause. Form the candidate hypotheses, then rule them out until one survives. Seed them with `how` over the affected subsystem and the **why** skill for regression history. Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. When program state is unclear, add instrumentation or logging and read it as the code runs. Don't guess. Drive a long or stubborn hunt with Cursor's `/loop` command. Confirm the surviving *mechanism* with runtime evidence before the step-3 architect/interrogate fan-out.
- [x] Plan the fix. If it crosses a function boundary, `architect` first. Delegate implementation to a subagent using your configured bug-fix model (default `grok-4.7-xhigh-fast`) with a specific scope.
- [x] Verify on the same surface. The original repro now passes. "Inconclusive" or wrong-surface is not a pass. Flag it. Unit tests show branch behavior, not bug absence.
- [x] Stage the commits so the failing repro lands before the fix in git history. Skip: this regression was found during the authorized feature acceptance, and the user authorized one scoped commit after acceptance closes.
- [x] Run **Opening a PR**. Skip: no PR was requested; the accepted feature is being committed in the canonical checkout.

## Task-specific steps

- [x] Preserve exact PID, user, process start, canonical native executable or interpreter-script path, and exact argv identity.
- [x] Make process probes bounded and reap probe children on failure.
- [x] Add native `/private/tmp` and shebang graceful-stop/retry regressions.
- [x] Keep E2E result decoding direct and cleanup evidence explicit.
- [x] Report scratch tests, fixture roots, child/listener cleanup, and acceptance gaps.

## 2026-10-27 acceptance follow-up

- [x] Reproduce the actual `val project up/down` journey through private Core. The project and process checks reached the success marker, but XCTest teardown failed to remove the fixture root.
- [x] Inspect fixture ownership and permissions. No child process remained; the copied package directory was intentionally mode 0555 and blocked removal.
- [x] Preserve the package's read-only mode during the acceptance journey, restore cleanup permissions only after owned processes stop, and prove normal teardown removes the root.
- [x] Rerun the private-Core E2E helper and focused suites; evidence: `artifacts/verification/project-service-bindings-20261027T055046Z-20630/`.
- [x] Complete independent review and update the feature handoff after review. The final Sol follow-up found no issue after the caller timeout became bounded and the termination handler retained the probe process and pipe reader for eventual cleanup.

## Skipped workflow steps

- Skip same-surface GUI control reproduction. This defect is process identity code, not UI behavior; direct targeted process tests exercise the affected surface.
- Skip architect fan-out. Scope changes only private identity observation and its tests, without changing a function boundary or module API.
- Skip separate failing-test and fix commits. The acceptance cleanup regression is part of the feature E2E fixture, and the user authorized a scoped commit after final feature acceptance.
- Skip Opening a PR. No PR was requested; the parent is integrating the feature in the shared checkout.
