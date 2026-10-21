# Services inventory

## Sub-features

- Browse the Installed and Available package tabs.
- Inspect service status and available controls.
- Open managed service logs before using the page-level refresh action.
- Inspect contextual **More** menus for package removal.

## How to get to it (user POV)

Open Vaelen Settings and choose **Services** in the Workspace section.

## Driving it with CUA

Launch the isolated Debug fixture with `--settings-fixture=partial --settings-page=services`. Capture the initial page, switch between **Installed** and **Available**, and capture each resulting state. Do not activate install/remove/start/stop controls. Require the Services header and the fixture marker in each capture.

## Gotchas

The `partial` model is simulated. These actions do not prove Core inventory, service health, install/remove behavior, or log delivery. Refresh is now a single page-level action shared by service inventory and status reads; the DNS/Ports diagnostic detail is available through row help. Use the CLI/Core skill for isolated production-entry checks.
