# PHP release and package notices

## User-visible behavior

Official php.net releases and available Vaelen packages are separate observations. An installed PHP family can show a security release notice when no matching package is available. Existing package updates retain their own Update action.

Open Settings and choose **PHP**. Release notices appear above the runtime list and in the installed runtime detail. The menu bar popover also presents official release notices independently of its existing package update card.

## Fixtures

Build Debug using the parent app skill's offline PHP preparation and Apple Development signing prerequisites. Launch the resulting app through LaunchServices with one fixture below and `--settings-page=php`. Use only one Vaelen instance. Record the exact fixture arguments in `run.txt`, then follow the parent skill's identity check, CUA capture and cleanup requirements.

The current `launch-fixture.sh` helper fixes its arguments to `php-settings` and `services`. A release-notice run must launch the task-owned built bundle with the arguments below and record the matching fixture and page in its evidence. Do not describe the helper's default launch as release-notice acceptance.

| Fixture | Expected PHP state |
| --- | --- |
| `--settings-fixture=php-release-security` | Installed PHP 8.4.24. PHP 8.4.27 security release dated 21 Oct 2026. No matching package and no PHP Update action. |
| `--settings-fixture=php-release-coexist` | Installed PHP 8.4.24. PHP 8.4.27 security notice plus an independently available PHP 8.4.26 package update. No Update action targeting 8.4.27. |
| `--settings-fixture=php-release-stale` | Last confirmed PHP 8.4.27 security notice remains visible with a failed official release check warning. No package update. |

## CUA acceptance

1. Confirm the Settings fixture marker matches the requested fixture.
2. Capture the PHP page. Require installed PHP 8.4.24, the PHP 8.4.27 security notice, the official release date and the php.net release-notes link.
3. Require the message that a PHP 8.4.27 Vaelen package is not currently available.
4. In `php-release-security` and `php-release-stale`, confirm no PHP Update action appears. In `php-release-coexist`, confirm the package Update action targets 8.4.26 and the official notice still targets 8.4.27.
5. Select installed PHP 8.4.24 and capture the detail. Confirm its family advisory and source health agree with the list.
6. Open the menu bar popover and capture the independent notice and package action state for the same fixture.
7. For `php-release-stale`, require the last confirmed release warning and the per-family check error.

Do not click package mutation controls. A release-notes link points to `https://www.php.net/releases/8_4_27.php`. Inspect its destination without using a successful navigation as proof of Core refresh behavior.

## Coverage boundary

These modes initialize fixture-only catalog reports and synthetic runtime paths. They verify presentation and action targeting. They do not fetch php.net, refresh the provider catalog, install PHP, validate downloaded packages, persist advisory state or exercise IPC. Core tests cover parsing, cache retention and independent report projection. A fixture run cannot replace those checks.
