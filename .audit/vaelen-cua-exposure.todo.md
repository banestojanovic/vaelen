# Vaelen Computer Use app registration fix

## Bug fix playbook

1. Reproduce it yourself on the matching surface via the control skill (Non-negotiables), even when a debug or instrumentation protocol says to ask the user to reproduce. Ask the user only with a stated, specific reason the control surface cannot reach the target, and only after driving it as far as it goes. If it won't reproduce directly, synthesize the trigger, tighten conditions, or instrument until it fires.
2. Binary-search the cause. Form the candidate hypotheses, then rule them out until one survives. Seed them with `how` over the affected subsystem and the **why** skill for regression history. Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. When program state is unclear, add instrumentation or logging and read it as the code runs. Don't guess. Drive a long or stubborn hunt with Cursor's `/loop` command. Confirm the surviving *mechanism* with runtime evidence before the step-3 architect/interrogate fan-out.
3. Plan the fix. If it crosses a function boundary, `architect` first. Delegate implementation to a subagent using your configured bug-fix model (default `grok-4.7-xhigh-fast`) with a specific scope.
4. Verify on the same surface. The original repro now passes. "Inconclusive" or wrong-surface is not a pass. Flag it. Unit tests show branch behavior, not bug absence.
5. Stage the commits so the failing repro lands before the fix in git history. See the **tdd** skill for the failing-test-first cadence when the test has a cheap local test path. Skip it when the test would be expensive, integration-heavy, or unclear.
6. Run **Opening a PR**.

## Throughput checkpoint

- Blocking first steps: Reproduce via CUA and inspect app registration settings. Done: CUA can attach to Finder, Vaelen process is running, and both app configurations set `LSUIElement=YES`.
- Independent workstreams: n/a. One Xcode build setting controls app registration.
- Shared mutable state: Serialize the installed app replacement and restart because it has one bundle identifier and one shared process.
- Smallest safe decomposition: One Luna implementation delegate changes the registration setting; the lead reviews, builds, installs, and verifies CUA access.

## Task-specific steps

- [x] Trace why the app is hidden and record installed-process constraints: Debug and Release both set `LSUIElement=YES`; the installed app was already running but lacked normal app registration/window activation for CUA.
- [x] Delegate the minimal registration change to Luna: Debug and Release now set `LSUIElement=NO`.
- [x] Review the full diff and build the app: signed Release candidate built and passed the safe updater's code-signing, schema, route-preservation, and enabled-service readiness checks.
- [x] Update the installed app and confirm CUA can attach: `/Applications/Vaelen.app` now opens Settings through CUA after updater launch.
- [x] Exercise project Node isolation in a disposable linked project: Node 24.22.1/npm 11.19.1 resolved in the project root and child directory, persisted across app/Core restart, then returned to invocation PATH (Node 24.16.0/npm 11.13.0) after clearing the pin. The temporary project was unlinked and deleted.
- [x] Fresh independent Sol review: no actionable findings; stale-Core recovery remains limited to status exit 3, embedded schema 7, and absent installed Core process/socket.

## Remaining limits

- `LSUIElement=NO` gives Vaelen a Dock entry so the app is normally registered and addressable by Computer Use.
- The project Node operation was verified through Settings and `val node exec`. Optional shell integration was not installed or tested; `.zshrc` was not changed.
- The reviewed Node 24.22.1 package remains installed in Vaelen's managed package store; no project pin remains.
