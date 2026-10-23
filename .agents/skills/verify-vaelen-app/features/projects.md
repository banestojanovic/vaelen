# Projects

## Sub-features

- Browse known projects and their settings.
- Search linked projects by name, full path, detected framework, or resolved PHP version, including case and surrounding whitespace variations.
- Read each linked project's resolved PHP version and whether it uses the shared default or a project override; distinguish an unavailable default, a pending report, and unavailable Core state.
- Read each linked project's exact Node pin or inherited invocation PATH state, including an unavailable pinned package, and select only catalog-reviewed releases.
- Keep workspace folder management separate from linked-project search and results.
- Inspect available project actions.
- Link a project directly from the status popover when the confirmed project list is empty.

## How to get to it (user POV)

Open Vaelen Settings and choose **Projects** in the Workspace section.

## Driving it with CUA

Launch the `partial` Debug fixture, choose **Projects**, and capture the page. Record whether the fixture presents an empty or populated state; require the Projects heading and the fixture marker. With a populated linked-project inventory, search by a project name, full path, framework, and resolved PHP version, checking case-insensitive matching and that surrounding whitespace is ignored. Check a query with no result and verify the empty state; verify selection moves to the first match when the selected row is filtered out. Confirm workspace folders and their Add/remove actions remain in their separate section. Inspect the PHP version and inheritance/override label, including pending and unavailable states where fixture/Core data can provide them. For the Node selector, use the `node-settings-selected`, `node-settings-unpinned`, and `node-settings-unavailable` fixtures to inspect an available project pin, inherited invocation PATH, and unavailable pinned runtime. Inspect the selector accessibility value and confirm it includes the current title and detail. When switching between populated live projects, confirm the selected details group is labeled `Selected project details for <name>` and its path, site, routes, PHP, and MySQL facts update with the selected project. The fixtures contain no Core-backed mutation path. Do not choose an install or pin action. Do not open folders, editors, routes, or external applications.

The fixture launcher accepts `VAELEN_SETTINGS_FIXTURE` and `VAELEN_SETTINGS_PAGE` environment variables. For example, use `VAELEN_SETTINGS_FIXTURE=node-settings-unavailable VAELEN_SETTINGS_PAGE=projects` to launch the unavailable Node state directly.

## Gotchas

Fixture projects are not a live project registry. The `partial` fixture may have no linked projects or reports, so it cannot prove populated search matching or PHP status distinctions. For a linked project with no report, the compact row distinguishes Core connecting, report loading, and Core unavailable. For a report with no resolved or overridden version, it distinguishes an available shared default from a missing default. Node selector fixtures prove visible state only. They do not prove release installation, pin persistence, IPC behavior, or invocation PATH resolution. When the Settings window becomes key again, live project relationship and Node selection refreshes run in sequence; fixtures cannot verify externally changed pins being observed. If Node was requested before Core became available, a successful initial Core bootstrap retries the selection read while Projects Settings remains visible. This is not repeated by the service monitor's lightweight refresh. This navigation check does not prove linking, route status, editor launching, or Core refresh behavior. If the fixture does not satisfy a journey precondition, report that rather than seeding real user projects.

The status popover only shows its **Link Project…** empty-state action after Core is running and reports no projects. Verify it on a confirmed-empty live state; the Settings fixture does not cover this popover journey. Do not select or link a real folder during visual verification.

## Live PHP override journey

Use `.agents/skills/verify-vaelen-app/scripts/projects-php-core` for the isolated Core-backed acceptance lane. The command contract is `prepare`, `inspect --expect default|override`, `restart`, and `cleanup`; the helper owns one persisted `ProjectsPHPUIRun` manifest under a unique `/private/tmp/vpu-XXXXXXXX` root, while CUA alone changes the selection in Settings. The helper has no PHP-selection write operation. Build the Debug app first and pass its absolute app bundle path. Pass exact locally installed CLI/FPM paths and versions. For example, use Herd PHP 8.3.33 and Vaelen-managed PHP 8.4.24 only after both versions pass the helper's production eligibility check.

```sh
run=artifacts/verification/projects-php-<unique-run-id>
.agents/skills/verify-vaelen-app/scripts/projects-php-core prepare \
  --evidence "$PWD/$run" --app /absolute/path/to/Vaelen.app \
  --override-cli "/Users/you/Library/Application Support/Herd/bin/php83" \
  --override-fpm "/Users/you/Library/Application Support/Herd/bin/php83-fpm" \
  --override-version 8.3.33 \
  --default-cli "/Users/you/Library/Application Support/Vaelen/packages/php/8.4.24/php" \
  --default-fpm "/Users/you/Library/Application Support/Vaelen/packages/php/8.4.24/php-fpm" \
  --default-version 8.4.24
```

Run `prepare` only with an absolute Debug app path and two installed, locally available CLI/FPM pairs. The override and default must be different exact stable versions and both PHP CLI/FPM binaries must pass production eligibility checks. This lane does not download packages, install packages, or alter global PHP configuration. It refuses a running Vaelen app/Core/DNS responder/FPM/MySQL/Caddy process before creating evidence or scratch roots. After that preflight, failures retain an evidence pointer to the token and scratch path; a partial scratch root is removed only when this run created it and no child launch was attempted. Ambiguous or symlinked ownership, nonempty private routes/parked paths, service intent, or `web.secure` project settings also refuse the run. It records DNS and PF ownership from the prepared Core baseline and requires later observations to match, including when the host already has external ownership. Use a fresh evidence directory for every run.

After prepare, use CUA to open the exact task-owned app and select the linked Storefront project's PHP override. Then run `inspect --expect override`. The successful report must include the exact project ID/path, SQLite override and effective versions, production IPC selection, healthy FPM observation, empty routes, and unchanged seeded default bytes. Run `restart`, confirm the same override in native Settings, and run `inspect --expect override` again. The persisted journey checkpoints require this order before cleanup. Select **Use Default** through CUA, then run `inspect --expect default`. Require a nil override, the original shared default, healthy FPM after the mutation, unchanged shared-default bytes, empty private routes/parked paths, and unchanged DNS/PF ownership from the prepared baseline.

`restart` sends TERM only to the recorded app PID after executable and start-time checks, captures the live private FPM master and complete descendant identities, asks Core to perform its typed private shutdown over IPC, then independently verifies every captured PID/start identity/executable is absent or reused and checks private process records and FPM sockets are gone. Typed PHP-FPM component success alone does not prove worker exit. If the master is already dead before capture, the process table cannot be enumerated completely, or a captured worker remains, the helper preserves the root. It never signals captured FPM workers. It reads the override from a fresh SQLite connection while Core is stopped and launches a new Core and app. The helper does not drive the UI or write a project selection. Cleanup requires the persisted baseline, override, restarted override, and Use Default checkpoints. It rechecks private capability state while Core is running and checks the nil override with a fresh SQLite connection before deleting. FPM proof is persisted only for the captured generation and is invalidated by a later selection observation or launch. `PHPModule.stop` remains the graceful shutdown request; the captured process scan is its independent exit proof. The helper removes a root after prepare failure only when it created that exact canonical root and no owned child launched; otherwise the evidence retains its full path. It never terminates another Vaelen app or process by name. A missing/disconnected private Core must fail closed before helper registration or Core startup. This is a live production-path check, not a static Settings fixture; if prerequisites or the UI driver are unavailable, report **NOT VERIFIED** and retain the evidence.
