# Current development notes

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

The accepted signed candidate passed `./Scripts/vaelen-dev-update` and
`./Scripts/vaelen-dev smoke` on 2026-09-30. Any subsequent fixture-safety source
changes require focused and full Swift tests; if they change installed product
content, rebuild/update/sign and smoke the integrated candidate before claiming
the installed app matches it.
