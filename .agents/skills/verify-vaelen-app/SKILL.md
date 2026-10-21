---
name: verify-vaelen-app
description: Drive and inspect the native Vaelen macOS menu bar app and Settings UI with isolated Debug fixtures; use for app UI changes or desktop acceptance checks.
---

# Verify the Vaelen app

Use this skill for the native SwiftUI menu bar app and its Settings window. Vaelen also has a CLI and Core; their isolated journeys live in [verify-vaelen](../verify-vaelen/SKILL.md). The app journey here verifies Settings navigation and fixture rendering only. It does not prove live Core behavior, package operations, or the installed signed app.

## Launch

Prerequisites: macOS, Xcode, an available Apple Development signing identity (the project embeds a privileged helper), and the repository's already verified pinned PHP runtime. Do not allow `prepare-bundled-php.py` to fetch assets as part of this UI proof. Check it offline first:

```bash
python3 Scripts/prepare-bundled-php.py --offline
```

Create a fresh evidence directory under `artifacts/verification/` and launch the Settings fixture:

```bash
mkdir -p artifacts/verification/vaelen-app-$(date -u +%Y%m%dT%H%M%SZ)
.agents/skills/verify-vaelen-app/scripts/launch-fixture.sh \
  artifacts/verification/vaelen-app-<run-id>
```

The helper builds `Vaelen.xcodeproj`, scheme `Vaelen`, configuration `Debug`, into a unique `/private/tmp` DerivedData directory. It launches the app bundle through LaunchServices with `--settings-fixture=php-settings --settings-page=services`. The fixture skips Core monitoring and uses fixture-only paths. Service and PHP operations are guarded by `AppModel.isSettingsFixture`; do not use this mode to claim that production operations work. Build readiness is the helper's `BUILD SUCCEEDED` and `LAUNCHED` records; UI readiness is the visible Settings window and its `UI fixture · php-settings` marker.

Before launch, check that no Vaelen app instance is already running. Do not launch a second copy alongside an installed or development instance. If an instance exists, stop and ask the user to close it before retrying. The bundle identifier is shared by development and installed builds.

## Doctor

Run the read-only identity check before driving:

```bash
.agents/skills/verify-vaelen-app/scripts/doctor-fixture.sh artifacts/verification/vaelen-app-<run-id>
```

Save its successful output as `doctor.txt` in the evidence directory.

It checks the PID recorded by the launch helper, the exact executable path, its fixture arguments, bundle identifier, and built app bundle. Then use CUA to confirm the Settings window and fixture marker in accessibility output. A running process by itself is not ready. If identity or fixture state is ambiguous, stop without interacting.

## Drive

Use the native CUA surface (`mcp__cua_repl`) for every app interaction and observation. Do not use AppleScript, `osascript`, AX scripting libraries, or coordinate automation outside CUA. Open the exact built app path recorded in `run.txt` if needed. Capture the accessibility state and screenshot before each action, select a visible sidebar row by its label, perform one action, then capture fresh state and screenshot.

For the initial mapped journey, use the PHP Settings fixture:

1. Confirm the Settings window is visible on **Services** and the fixture marker says `php-settings`.
2. Capture the before state.
3. Select **PHP** in the sidebar.
4. Capture the after state. Confirm the page header is PHP, installed versions include `8.3.22`, `8.4.23`, and `8.5.0`, and the fixture marker remains visible.
5. Do not click install, update, remove, refresh, or editor preference controls. Record any missing label or blocked transition as a failure.

The source assigns these values in `App/Vaelen/Vaelen/AppModel.swift`; verify them through the rendered UI, not by invoking model methods. The fixture's PHP paths are synthetic `/fixture/...` values and no package is changed.

## Evidence

Keep one directory per run under `artifacts/verification/`. Preserve `run.txt`, `build.log` on failure, `launch.log`, `doctor.txt`, and a `ui/` directory containing before and after CUA screenshots plus the corresponding accessibility snapshots. `launch.log` is LaunchServices output, not the app's runtime log. Record the action, expected labels, observed labels, exit status, and fixture boundary in `result.txt`. Evidence must survive cleanup.

This is a real user navigation through the native Settings sidebar, but the data is fixture-only. It verifies the visible page transition and sample state. It does not verify Core communication, live inventory, persistence, package changes, General preferences (which read user preferences), or the signed installed product. Never describe fixture output as live service behavior.

## Cleanup

Quit the app from its app menu or use the helper below, which sends TERM only to the PID recorded by this run after confirming its command still points to the exact executable in `run.txt`:

```bash
.agents/skills/verify-vaelen-app/scripts/cleanup-fixture.sh artifacts/verification/vaelen-app-<run-id>
```

The helper removes the task-owned DerivedData directory after the process exits and keeps `run.txt`, `cleanup.txt`, and other evidence. It never removes the evidence directory. If the PID has been reused, the command differs, or exit cannot be confirmed, it leaves both process and scratch files alone and exits non-zero. Never kill Vaelen by process name.

## Feature map

Read [the feature map](features/README.md), then the affected journey. Update the map when user-visible Settings behavior changes. For broader CLI/Core checks use [verify-vaelen](../verify-vaelen/SKILL.md).

## Maintenance

Use `pstack:maintain-verification-skill` to audit the map when the Settings surface changes.
