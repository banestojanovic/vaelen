# Current development notes

## Herd replacement project lifecycle — 2026-10-26

`val project up` now applies supported V2 project requirements, with `project activate` retained as an alias. It selects an exact PHP patch or an eligible patch from a declared PHP family, selects an eligible Node package, safely associates a unique unchanged legacy route, and reconciles exact PostgreSQL service claims. `val project down` releases only the project's claims and stops PostgreSQL only when no manual or other project owner remains. Failed identity or stop checks retain the existing claim. Repeated down/up restores the exact PostgreSQL instance.

Reviewed V2 web intent can explicitly request creation of a project-owned FastCGI route. Core resolves the declared document root to an existing canonical directory inside the project, checks case-insensitive host conflicts against persisted routes, proxies, and live routes, and requires a `.test` hostname plus healthy router, DNS, and standard ports. HTTPS creation requires an already trusted Local CA; adoption never changes trust. A failed Caddy reconciliation retains the route ID and ownership so a later `project up` can retry. Live verification compares hostname, target/socket, root, and TLS semantics rather than transient decoder IDs. The private-Core route acceptance fixture invokes built `val project adopt`, `up`, and `down` children for reviewed HTTP and HTTPS routes, serves PHP through copied installed PHP-FPM and Caddy packages, confirms `.env` bytes remain unchanged, and verifies route retention across `down/up`. Parent reran `Scripts/tests/val-project-route-lifecycle-test.sh`, `Scripts/test.sh --filter CaddyRuntimeTests`, and `git diff --check`; all passed. DNS, PF, standard-port readiness, and Local CA trust are injected observations, and HTTPS uses `curl -k`, so system networking or user trust is not verified. The fixture uncovered Caddy process identity rejecting `/private/tmp` executables because `ps` reports the equivalent `/tmp` path; identity now checks the opened executable with symlink resolution. One read-only Sol review found an unbounded curl probe; three-second connect and ten-second request timeouts resolve it.

Parent verification passed `Scripts/test.sh --filter 'ProjectReconciliationTests|ProjectAdoptionApplyTests|ProjectAdoptionCLIParsingTests|PostgreSQLServiceLifecycleEndToEndTests|DispatcherTests|ProjectActivation'`, `Scripts/tests/val-service-lifecycle-test.sh`, and `git diff --check` in both the isolated feature worktree and canonical dirty checkout. One fresh read-only Sol reviewer approved after correction of stopped-instance retry, stale claims, PHP family/exact pin selection, and route-change checks. The unfiltered `Scripts/test.sh` remains red on unavailable/mismatched PHP provider cache fixtures and a release expectation; see `.audit/test-failures/swift-test.ruLvKH` in the isolated worktree.

This does not complete Herd replacement. Project up/down has MySQL/Mailpit bindings for the existing default singletons alongside named PostgreSQL and Valkey instances. A live isolated Debug app/Core run verified Mailpit start-plan review, explicit start, verified state refresh, project-only claim release, and that the singleton remained healthy. Evidence is in `artifacts/verification/project-mysql-mailpit-settings-20261027/`. Core restart/update recovery, signed installed-app workflow, and CLI/app agreement across the complete adoption-to-working-site path remain open. Package acquisition, licensing, provenance, signing/notarization, PostgreSQL repeatability, and macOS 14 execution remain release gates. See `.audit/project-service-environments.todo.md` and the `project-environment-lifecycle.md` verification recipe.

## Five-task installed acceptance and diagnostics — 2026-10-24

Installed checks passed for disposable `val site info`, Settings proxy add/remove, and the native Projects popover. The site-info fixture used a Laravel marker tree and a PHP Artisan stand-in, verifying installed child arguments, cwd, output, nonzero status propagation, unsupported-framework refusal, narrow human output, and zero-route reporting. It did not run a Laravel application. Proxy Settings rows matched `val proxy list --json`; the temporary route was removed. Menu-bar project groups matched CLI linked and discovered project data. Project, route, parked-root, and proxy snapshots matched the preflight files byte-for-byte, and Doctor remained healthy. The records in `docs/cli/manual-test-slice-2a.md` and `docs/cli/manual-test-slice-2b.md` are historical; their supporting generated evidence directory was removed during local cleanup.

The current full-suite failure diagnosis found a repeatable missing prerequisite: `testDiscoveredVersionReusesItsRecordedDigestOnReinstall` cannot run without the verified provider cache entry for PHP 8.4.24 and instructs running `Scripts/refresh-php-catalog-from-provider.sh`. The refresh would download and alter generated package/catalog state, so it was not run against this checkout. Retained prior full-run logs also contain environment-specific cache permission failures and historical service/test failures; they do not establish a current source regression. Safe focused tests for site commands, PHP process isolation, recorded FPM ownership, and the six-route warm/cold switch passed. The complete suite remains **unverified** until the provider artifact prerequisite is supplied and the suite is rerun. The retained direct reproduction is `.audit/test-failures/swift-test.tj4rSh`.

PHP 7.4 remains unavailable. Both configured static-php-cli provider feeds were checked for a compatible prepared macOS arm64 package and returned no PHP 7.4 artifact. Upstream v2 documentation states 7.4 builds are unsupported, and PHP's official lifecycle page records 7.4 end of life on 2022-11-28. Research captures were removed during local cleanup; sources: [static-php-cli v2 guide](https://static-php.github.io/v2-docs/en/guide/) and [PHP supported versions](https://www.php.net/eol.php). No unofficial package was enabled.

The session used disposable project fixtures for installed-command checks without touching a real project; proxy UI mutations were temporary and checked against exact before/after snapshots; read-only research preceded shared-state actions; and a failed first fixture was logged as setup error and corrected before acceptance. No product source code changed.

## Retired OpenCode2 orchestration adapter — 2026-10-18

Accepted PHP/provider/ports work and the reviewed OpenCode2 orchestration setup
were fast-forward integrated on `dev` at
`1fbe36e69df78e1930e5c0afd7195fda561ffd25`. The pinned orchestration bootstrap succeeded
at `0b8e952052d482ee6de06deebf14d590d77b1b34`. Its 13 adapter checks passed at the time; they were not Swift-suite or installed-product
validation. The repo-local OpenCode adapter, configuration, tests, and usage
guide were retired on 2026-10-22 in favor of Codex native delegation described
in `AGENTS.md`. Historical Swift-suite evidence is dated separately below and
in README; it does not validate this integrated source. No build, install,
runtime operation, or full Swift suite was performed for that consolidation.
PHP 7.4 remains the requested family without an established compatible
prepared CLI/FPM source.

## Accepted PHP provider distribution and standard ports

The user accepted the PHP replacement and Settings experience after manual
review on 2026-10-02. This checkpoint records that accepted work and the subsequent
8.0/8.1 addition. Historical `dev` records below remain unchanged; acceptance
does not imply a release, tag, or hosted publication.

### PHP source

Vaelen no longer compiles or publishes PHP. Packages come from the
static-php-cli `v3/php-bin/bulk` channel. Provider configuration is authored once
in `Distribution/PHP/provider.json`; the refresh script and Core read the same
values. See `Distribution/PHP/README.md` for the full description, including why
the maintained `common` channel was rejected (its real macOS binaries omit
`intl`, `mysqli`, and `sodium`) and why Homebrew bottles are unsuitable.

The shipped catalog offers PHP 8.5.9, 8.4.24, 8.3.33, and 8.2.33 from v3, plus
PHP 8.1.34 and 8.0.30 from the generation-separated `archive-v2` bulk source.
PHP 8.0/8.1 are labelled end of life; 8.2 is security support only. PHP 8.5.9
ships inside the app as a bundled CLI/FPM pair with the provider's 63
per-component notices, so first activation needs no download. Bundling starts
nothing.

PHP 7.4 remains unavailable: a compatible, redistributable prepared macOS arm64
CLI/FPM pair satisfying the extension contract has not been established. No
nonfunctional Install option is shown.

Integrity is documented honestly: the provider publishes no signatures, so a
digest recorded from downloaded bytes is a **local integrity record**, not
independent provider authentication. Review-pinned versions keep their pin;
runtime-discovered versions are labelled `digestPinnedByReview: false` and have
their recorded digests honoured on later transfers and reinstalls.

### Standard Ports recovery

The machine this candidate was built on had a byte-correct Vaelen PF anchor whose
`/etc/pf.conf` reference had gone missing. `status()` classified that as a
foreign conflict and `install()` refused before asking the helper, so the
supported `val ports install` command could not repair it. Nothing in the
acquisition path caused it — Vaelen had adopted an already-complete
configuration, and `pf.conf` was later rewritten by something else.

The recovery is deliberately narrow: when the anchor file is byte-identical to
the fixed policy Vaelen writes **and** `pf.conf` contains no directive for that
anchor at all, Core reports `.incomplete` with `repairAvailable`, and the helper
restores only the missing reference without rewriting the anchor. A modified
anchor, a foreign anchor, or a *different* reference directive is still refused.
Ownership checks and ledger usage are unchanged, and nothing is disabled or
flushed globally.

### Update behaviour

An update names the runtime it replaces. Core validates that source before
installing anything — it must be installed, in the target's family, older than
the target, and still present — so a stale or wrong-family selection is rejected
with a specific reason instead of quietly updating another runtime.

Updating a running default hands the default role over, starts the replacement,
and requires it to become healthy. A stopped non-default update starts nothing
and leaves the global default alone.

Before any mutation, an update whose source is still required is refused with
specifics: exact-version pins name the affected projects, and persisted routes
no project owns name the stranded hostnames. Pins are never silently migrated.

After verified convergence the superseded runtime is removed — stopped through
ownership-checked lifecycle control, package and generated artifacts deleted,
start intent retired. Nothing is kept solely for rollback. While the update is
incomplete the working source is preserved, and a failed cleanup is reported
specifically rather than as complete success. Saved settings survive removal and
return on reinstall.

Installation and convergence are reported separately, so an install that did not
finish routing is shown as partial success with a targeted retry rather than as a
completed update.

### Version presentation

The Settings list shows installed runtimes newest first with exact patches,
running state, default role, and project use. The sidebar update indicator is a
per-family claim. Runtime actions (Start/Stop, Update, Make Default, Remove) sit
in one compact row near the selected runtime's header; the progress strip shows
one stage message with a spinner while work is active. The Package card uses the
shared inset-card styling with a faint border for light-mode separation.

### Update response decoding and operation lifecycle

`ResponseResult` encoded `.phpUpdateResult` but had no decoding branch for it, so
a serialized successful update fell through to `.raw`, the client rejected it as
`invalidResponse`, and the interface reported "operation failed" next to a
healthy new default. Decoding now keys on the distinctive `convergence` field.
The existing convergence tests read the dispatcher's in-memory response, so they
could not see this; they now round-trip through the wire encoding, and new
lifecycle tests cover the framed Unix-socket path.

The update operation now stays observably pending through dispatcher-level route
convergence inside one package-operation reservation (new `converging` phase, plus
`startingRuntime`), so shutdown and rival package work cannot race unfinished
convergence. The progress strip shows per-stage activity with a spinner once the
download bar fills, completion messages are kind-specific, a lost connection is
reconciled against Core's own operation record instead of declared failure, and
PHP completions trigger the shared snapshot plus fresh project reports so the
menu-bar popover updates without manual refresh.

### Validation and installed checkpoint

The final focused checks on 2026-10-02 passed: update convergence 12/12,
update lifecycle 9/9, and provider discovery 21/21. Separate focused checks
passed for both legacy packages' real CLI/FPM lifecycle, shipped catalog
digests, support labels, and smoke's authoritative-default selection. No full
suite was run for this final iteration.

The signed update at `product-dev-20261002T135400Z` passed for `dev.vaelen.app`,
Team `TFKZJV643G`; embedded Core SHA-256 was
`d286daecfc5501a275bbebc3d6b759842340ee5388d5d78a866de44bf0eebf2f`.
Installed smoke passed with default PHP 8.4.24, ports 80/443, and trusted
Syncproof HTTPS. These records describe that tested build, not later source
or documentation edits. No new full-suite or installed acceptance is implied.

The authorized Syncproof repair associated its existing route with its linked
project, preserving route identity and TLS settings. Reconciliation returned
HTTPS 200. Obsolete 8.3.29 and 8.4.23 packages and generated instance directories
were removed after dependency checks; saved settings were preserved.

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
were exercised in the isolated fixture. On 2026-10-24, the `remove-failed`
Services fixture rendered the failed MySQL removal as a red error banner below
the package details. The banner is visible after scrolling the details pane to
the bottom; the fixture keeps the package listed and reports that Core
inventory is unchanged. Evidence is in
`artifacts/verification/vaelen-app-remove-failed-20261024T094910Z/`.

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


## MySQL and Mailpit project bindings — 2026-10-27

V2 projects can claim only the exact installed default MySQL or Mailpit singleton already observed by Core. Activation validates exact package identity and health, and repeated aliases reuse one service instance. Deactivation releases only project ownership; it cannot stop these legacy singleton runtimes. Package removal is blocked while a project claim exists. Focused planner, catalog, adoption, dispatcher, inventory, and Mailpit module suites passed. The built `val` child exercised private-Core project `up/down/up` with two Mailpit aliases, exact inventory, `.env` preservation, source package preservation, and cleanup. See `Scripts/tests/val-project-service-bindings-test.sh` and `artifacts/verification/project-service-bindings-20261027T055046Z-20630/`.

The live Debug Settings path was driven against a private Core. The app displayed the exact reviewed Mailpit binding, started it through explicit confirmation, then released only the project claim through the ownership confirmation. Core reported the same process healthy with no owner afterward. The project `.env` and installed Mailpit executable hashes were unchanged, and the app/Core/service processes, listeners, and scratch root were removed. The acceptance record is `artifacts/verification/project-mysql-mailpit-settings-20261027/result.txt`. This does not cover signed installed-app maintenance or Core restart recovery.

The final review found a race between identity-probe process exit and asynchronous stdout drain, plus unsafe fixture cleanup after a failed stop. Both are fixed. Identity probes now wait for stdout EOF and process exit, then return within a bounded timeout while retaining probe handles for eventual termination cleanup. Mailpit test fixtures preserve their roots unless the exact service is confirmed stopped. The final read-only Sol follow-up found no remaining issue. Parent verification passed the Mailpit, private-Core project-binding, and multi-alias dispatcher filters, plus `Scripts/tests/val-project-service-bindings-test.sh`; see `artifacts/verification/mailpit-identity-review-20261027/result.txt`. The forced unreapable-after-SIGKILL branch was not directly exercised.
