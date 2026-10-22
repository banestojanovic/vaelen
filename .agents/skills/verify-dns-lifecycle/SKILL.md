---
name: verify-dns-lifecycle
description: Verify Vaelen DNS resolver ownership across saved startup, retry, and quit recovery. Use when changing DNSCapability lifecycle transitions or durable resolver ownership recovery.
---

# Verify DNS lifecycle ownership

Use this check when editing `DNSCapability` lifecycle operations or resolver ownership recovery. The property is: after saved DNS startup overlaps a user retry, Core must acquire the resolver once and quit must restore the preimage while retaining authorization for a later launch. A violation can leave the resolver directed at an unowned responder or discard the evidence needed for safe reacquisition.

## Covered code and sync point

- `Sources/VaelenCore/DNSCapability.swift`: `DNSCapability.install`, `remove`, `shutdownForQuit`, `withLifecycleGate`, and `DNSLifecycleGate.acquire/release`.
- `Tests/VaelenIPCTests/DispatcherTests.swift`: `testSavedDNSAutostartAndConcurrentRetryAcquireOnceAndRecoverOnQuit`.
- Sync commit: `60b8b470b81d5cd279a721ade05aa73fd03b31d7`.

Move the sync commit forward only after reviewing the covered code and confirming this check still describes its behavior. If a change affects the property or its fixture, update this skill and the focused check together.

## Run

From the repository root, run the focused XCTest without fetching dependencies:

```bash
swift test --skip-update --disable-automatic-resolution --scratch-path .build-dev --filter DispatcherTests/testSavedDNSAutostartAndConcurrentRetryAcquireOnceAndRecoverOnQuit
```

Require the selected test to pass. It starts saved DNS during Core startup, waits until resolver inspection is underway, races a user retry against it, and asserts that the retry succeeds with exactly one resolver acquisition. It then quits Core and checks that the resolver preimage is restored, the durable record is `.resolverRestored`, and the saved service intent remains enabled for the next launch.

## Failure sensitivity

To confirm failure sensitivity after changing the fixture or recovery code, temporarily change `shutdownForQuit()` to call `restoreResolverAndStopResponder(retainingAuthorization: false)`, run the command above, and restore the source immediately. The `.resolverRestored` assertion should fail; the `dns` intent assertion should continue to pass, confirming quit preserved the user's saved startup choice. Never keep this mutation. The test does not reliably detect a gate bypass by itself; it exercises the startup/retry overlap and checks one acquisition, but production install logic is also idempotent in this scenario.

## Scope and limits

No model checker is installed in this environment, so this skill uses the repo's deterministic integration test and a real-code failure injection rather than claiming a mathematical proof. The check covers the saved-startup/user-retry/quit journey only; it is not an exhaustive model check of every task schedule and does not prove all install/remove/quit interleavings. It does not exercise the privileged production helper, system resolver files, launchd, or process shutdown. The test uses disposable fixture state and controlled helper/responder actors. Treat a passing result as evidence for this scenario only; retain any failing logs and report the observed counterexample in these code terms.
