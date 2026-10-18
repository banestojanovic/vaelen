# Browse Settings inventory

A user switches between installed and available items and expects counts and selection to reflect confirmed Core state.

## Sub-features

- `settings.classification` distinguishes installed, available, unknown, and pending evidence.
- `settings.counts` preserves unknown and pending indicators instead of fabricated zeros.
- `settings.selection` follows confirmed inventory changes and selects a visible item after tab switches.

## How to get to it (user POV)

Open Settings and switch Installed and Available tabs. A Core-backed GUI run requires separate manual review under authorization for the installed application.

## Driving it with Swift XCTest

Preconditions: compile tests in the isolated worktree as in the [skill](../SKILL.md).

```bash
swift test --skip-build --filter SettingsInventoryPresentationTests
```

Require five passed tests, zero skips, and no failures. These invoke production presentation model functions for classification, counts, failed install/removal observations, selection reconciliation, and empty-tab selection.

## Gotchas

This is pure model coverage. Neither these functions nor a rendered Settings fixture prove a Core-backed GUI interaction. Visual layout, actual Core refresh, user clicks, and package operations remain unverified by this recipe. Do not build or install the signed app to fill that gap under this skill.
