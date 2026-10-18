# List linked projects

A user runs `val links` to see registered projects and effective PHP and route information.

## Sub-features

- `links.names` lists six registered project names through the production CLI and Core.
- `links.php` has an optional synthetic selection companion.
- `links.checker` rejects an expected project absent from actual successful CLI output.
- `links.ownership` bounds CLI execution and verifies owned-child termination without killing an unrelated child.

## How to get to it (user POV)

Run `val links` in a terminal. Linked-project GUI entry points require a separate manual review.

## Driving it with Swift XCTest

Preconditions: build and discover using the [skill](../SKILL.md). Run `.agents/skills/verify-vaelen/scripts/prove-links.sh` from the task worktree.

The harness seeds a disposable registry, starts private Core, handshakes and reads status, and drives the actual worktree `.build/debug/val links` child. Require six project names and exit zero for every invocation. Inspect the warmup transcript and cleanup lines in the retained `drive.log`.

The controlled mismatch requires `deliberately-absent-project`; the outer test must pass by detecting that specific missing output. Inspect the logged disagreement and actual CLI transcript.

Optional synthetic companion, only with a local PHP CLI already available:

```bash
swift test --skip-build --filter 'LinkedProjectsPerformanceTests.testHumanLinksEndToEndSixProjectsWithSyntheticPHPSelection'
```

Require one passed test and zero skips. This companion is outside the initial proof.

## Gotchas

The integrated `.projectPHPSelections` batch supplies selection information. Do not reuse older notes about per-project connections as current evidence. Router call counts are asserted, but the printed IPC request counts are partly inferred from source.

Router status and routes, DNS responder, TLS trust, and privileged ports are test boundaries. Synthetic PHP uses fabricated metadata, hashes, and a default with a local CLI binary as both CLI and FPM paths. It never starts FPM. No timing from this fixture proves installed-product performance. Pre-seeded registry listing does not prove the `val link` command or GUI behavior.
