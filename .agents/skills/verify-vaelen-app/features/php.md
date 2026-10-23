# PHP runtimes

## Sub-features

- Browse installed and available PHP runtimes.
- Inspect runtime configuration and default selection.
- Review update status using the [official release and package notice journey](php-update.md).
- Inspect the separate project-default row and grouped secondary removal action.

## How to get to it (user POV)

Open Vaelen Settings and choose **PHP** under Development.

When the trusted PHP catalog reports an installable update, the menu bar popover also shows a compact **PHP update available** card with the installed and target patch versions. Its **Update** button uses the existing PHP update operation and stays disabled while a PHP request is in flight. The card is absent when there is no installable update. This is an in-app popover prompt and does not request notification permission.

## Driving it with CUA

Launch the `php-settings` Debug fixture on Services, capture the before state, choose **PHP** in the sidebar, and capture the resulting page. Require the PHP page header, versions `8.3.22`, `8.4.23`, and `8.5.0`, and the `php-settings` fixture marker. Do not use mutation controls.

For the menu bar prompt, launch `--settings-fixture=php-update-review --settings-page=php` and inspect **StatusView** in the menu bar popover. The synthetic catalog should show **PHP update available**, `8.4.24 → 8.4.27`, and an **Update** action. `php-settings` provides the no-update case and should not show the card. The update-review fixture routes the action through the fixture-only `updatePHP` simulation; after success it removes the replaced source, transfers its PHP settings and default/running state to the target, and selects the target. It does not install a package or prove live Core behavior. In production, the card appears only when the verified catalog has a newer installable patch. The current live provider may not have prepared binaries for a version such as `8.4.27`, so the fixture does not imply that this version is available in production.

## Gotchas

The paths and runtime state are synthetic and use `/fixture/...`. Update/install/remove actions are guarded in fixture mode. A visible configuration does not prove a PHP binary was installed, configuration was persisted, or FPM was restarted.
