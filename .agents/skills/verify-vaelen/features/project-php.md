# Choose project PHP

A user inspects inherited or explicitly pinned PHP versions for linked projects.

## Sub-features

- `php.selection` compares batch selections with single-project observations.
- `php.unavailable` preserves healthy entries when another project has unavailable metadata.
- `php.errors` rejects a missing project without breaking a subsequent batch.

## How to get to it (user POV)

Run `val project php`, inspect PHP in `val links`, or run `val isolated [--json]` to list explicit PHP overrides. The focused tests below cover the Core client and dispatcher behind those entry points.

## Driving it with Swift XCTest

Preconditions: use an isolated worktree and compile tests as in the [skill](../SKILL.md). The wire batch case additionally requires a local PHP CLI and can skip.

```bash
swift test --skip-build --filter ProjectPHPCLIParsingTests
swift test --skip-build --filter ProjectPHPSelectionsTests
```

Require six discovered and passed tests for each filter, record the counts, and report any skips. The CLI tests cover strict `--json` parsing, sorted output, inherited exclusion, unavailable selections, the empty result, and batch error propagation. They call the output helper directly and do not launch a CLI child. `testBatchUsesClientWireAndKeepsHealthySelectionsWhenOtherProjectsAreBad` uses the real client codec and dispatcher over `InMemoryTransport`. It compares selections, excludes the removed directory, and checks that observation does not mutate default bytes or stale process metadata. `testMissingSingleProjectErrorDoesNotPreventFollowingBatch` requires `.projectNotFound` followed by an empty successful batch.

## Gotchas

This is isolated protocol, dispatcher, and CLI output-helper coverage, not `val isolated` child-process acceptance or GUI acceptance. Core's batch includes available linked directories and excludes missing directories. Package metadata and hashes are synthetic, and a local `php -v` only validates version observation. No PHP-FPM environment is established. Do not refresh packages to make a missing prerequisite disappear.
