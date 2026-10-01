# Current development notes

## PHP Settings

Accepted and integrated into `dev` on 2026-10-01. Shared and version-specific
PHP settings now use reusable grouped forms with inline numeric validation,
save/reset feedback, and expandable directive details. Runtime lists sort
numerically newest first; default stars and update indicators are distinct
from selection highlighting.

Trusted catalog checks run when due every 12 hours, with a manual Check for
Updates action, persisted check/error state, and last-valid-cache preservation.
Separate operation polling stays responsive during package work. Downloads
report measured incremental bytes across both CLI and FPM archives. Unknown
totals show bytes, not fabricated percentages; verification and installation
are separate phases, not download completion.

The final 2026-09-30 suite had **484 outcomes: 482 passed, 0 failed, 2 skipped**
(Core 288, IPC 97, DNS 6, CLI 93, including skips). Focused PHP and dispatcher
runs passed 23 and 53 tests respectively. Coverage includes production local
HTTP transfers with known/unknown lengths, aggregation, transfer failure and
cleanup, and progress over a separate Unix IPC client. The final signed
candidate passed installed smoke, including PHP/FPM, MySQL, routing, DNS,
ports 80/443, and trusted HTTPS. These results are reused: the committed diff
exactly matches the reviewed final diff and integration changed no product
content; the installed signed app/Core hashes still match that candidate.

No live PHP packages were installed, updated, or removed for acceptance.
**Successful live PHP package updating was not exercised.** Captures and bulk
evidence remain outside the source commits.

## Settings usability

Settings Services now distinguishes confirmed package installs, confirmed
availability, pending reads, and unknown observations using Core status plus
installed-version evidence. Counts match the visible groups and explicitly
include built-in Services capabilities in Installed. Selection remains stable
while reads are pending and follows confirmed inventory transitions. Focused
presentation tests cover classification, counts, tab changes, refresh-like
pending observations, and successful/failed operation selection outcomes.

Isolated Settings UI fixtures are compiled only with the app Debug build's
`VAELEN_SETTINGS_FIXTURES` condition; Release does not define it. Fixture mode
does not start Core monitoring, refresh project relationships, or route package
fixture operations through Core. General Core-backed service and PHP actions
are blocked in fixture mode. Fixture operations mutate only the in-memory
fixture model. Captures live outside the source commit in
`artifacts/settings-usability/final/`.

Rendered review covered Services, PHP, Projects, Network & Security, and
General in light/dark appearance with empty, pending, unavailable, and partial
inventory fixtures. Install success/failure and removal success/confirmation
were exercised in the isolated fixture. The rendered failed-removal error
state remains **unverified**; do not claim that visual check passed.

On 2026-09-30, focused inventory tests passed: 5 XCTest methods, 0 failures.
The complete invocation `swift test --package-path .` exited 0 after the final
fixture-isolation commit `d26c3aa` (start 12:38:37, finish 12:41:40). Its
per-target results, counting skipped tests separately, were:

| Test target | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| VaelenCoreTests | 279 | 0 | 4 |
| VaelenIPCTests | 95 | 0 | 0 |
| VaelenDNSTests | 6 | 0 | 0 |
| VaelenCLITests | 93 | 0 | 0 |
| **Total** | **473** | **0** | **4** |

The earlier 194 aggregate was erroneous: it added IPC (95), DNS (6), and CLI
(93), omitting the Core target. The preceding full-suite total of 472 included
278 Core test outcomes (274 executed, 4 skipped); the final run has five more
Core test outcomes because it includes `SettingsInventoryPresentationTests`.
The final inventory class has five XCTest methods, confirmed by both focused
logs and the full log. The earlier “six tests” figure was a count error; a
method's multiple classification assertions are not separate XCTest methods.

The four final skips were the Caddy official artifact/cosign integration, two
MySQL lifecycle acceptance tests requiring canonical ports/processes to be
inactive, and the PHP-FPM isolation regression requiring normal PHP-FPM to be
stopped. The integrated `dev` build passed `./Scripts/vaelen-dev-update` and
`./Scripts/vaelen-dev smoke`; its signed installed embedded Core is schema 7.
The rendered failed-removal error banner remains unverified visually.
