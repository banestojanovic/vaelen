# Choose project PHP

A user inspects inherited or explicitly pinned PHP versions for linked projects.

## Sub-features

- `php.selection` compares batch selections with single-project observations.
- `php.unavailable` preserves healthy entries when another project has unavailable metadata.
- `php.errors` rejects a missing project without breaking a subsequent batch.

## How to get to it (user POV)

Run `val project php`, inspect PHP in `val links`, or use the project's PHP controls in the app. The focused tests below cover the Core client and dispatcher behind those entry points.

## Driving it with Swift XCTest

Preconditions: use an isolated worktree and compile tests as in the [skill](../SKILL.md). The wire batch case additionally requires a local PHP CLI and can skip.

```bash
swift test --skip-build --filter ProjectPHPSelectionsTests
```

Require discovered nonzero tests, record the exact passed count, and report any skips. `testBatchUsesClientWireAndKeepsHealthySelectionsWhenOtherProjectsAreBad` uses the real client codec and dispatcher over `InMemoryTransport`. It compares selections, excludes the removed directory, and checks that observation does not mutate default bytes or stale process metadata. `testMissingSingleProjectErrorDoesNotPreventFollowingBatch` requires `.projectNotFound` followed by an empty successful batch.

## Gotchas

This is isolated protocol and dispatcher coverage, not CLI mutation or GUI acceptance. Package metadata and hashes are synthetic, and a local `php -v` only validates version observation. No PHP-FPM environment is established. Do not refresh packages to make a missing prerequisite disappear. The links journey separately drives the actual CLI list entry point.
