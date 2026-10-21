# PHP runtimes

## Sub-features

- Browse installed and available PHP runtimes.
- Inspect runtime configuration and default selection.
- Review update status.

## How to get to it (user POV)

Open Vaelen Settings and choose **PHP** under Development.

## Driving it with CUA

Launch the `php-settings` Debug fixture on Services, capture the before state, choose **PHP** in the sidebar, and capture the resulting page. Require the PHP page header, versions `8.3.22`, `8.4.23`, and `8.5.0`, and the `php-settings` fixture marker. Do not use mutation controls.

## Gotchas

The paths and runtime state are synthetic and use `/fixture/...`. Update/install/remove actions are guarded in fixture mode. A visible configuration does not prove a PHP binary was installed, configuration was persisted, or FPM was restarted.
