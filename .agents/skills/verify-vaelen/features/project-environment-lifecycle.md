# Activate and stop a project environment

Read this journey before changing V2 project reconciliation, project service claims, or route association.

## Focused checks

Run the planner, dispatcher, adoption, PHP-selection, and PostgreSQL project lifecycle checks through `Scripts/test.sh`:

```sh
Scripts/test.sh --filter 'ProjectReconciliationTests|ProjectAdoptionApplyTests|ProjectAdoptionCLIParsingTests|PostgreSQLServiceLifecycleEndToEndTests|DispatcherTests|ProjectActivation'
Scripts/test.sh --filter testOfficialCaddyIdentitySurvivesPrivateTmpPathAlias
Scripts/tests/val-service-lifecycle-test.sh
Scripts/tests/valkey-service-lifecycle-test.sh
Scripts/tests/val-project-route-lifecycle-test.sh
Scripts/tests/val-project-service-bindings-test.sh
Scripts/tests/core-project-service-restart-recovery-test.sh
```

The focused suites cover exact and family PHP selection, exact Node selection, honest V2 route/TLS and managed-service planning, project claim reconciliation, `up`/`down`/`up` for stopped PostgreSQL and Valkey instances, service alias rename, retired-instance identity failure retaining the old claim, manual-owner preservation, route target/TLS changes during activation, and Core startup recovery for project-claimed services. The PostgreSQL and Valkey package fixtures invoke the built `val` child over private Core for project up/down and named service lifecycle commands. They check claim transitions, data retention, health, and process identity. The Valkey fixture uses the exact `valkey-9.1.2` local archive and verifies repeated up/down, alias rename, shared manual ownership, final-owner stop, and identity failure retaining the project claim. The route fixture invokes the built `val project adopt`, `project up`, and `project down` children over private Core with copied installed Caddy and PHP-FPM package roots. It adopts one HTTP and one HTTPS route from separate reviewed V2 manifests, checks real PHP responses, route ownership retention across down/up, and `.env` byte preservation. The project-service binding fixture copies the installed Mailpit package into a private support root, invokes actual `val project up/status/down` children through private Core, stops Mailpit with its claims intact, triggers startup recovery, and checks healthy observations for both aliases, unchanged claims, and a disabled global Mailpit intent. A separate dispatcher reconstruction test creates a new Core dispatcher over the same SQLite claims and verifies Mailpit recovery. The core project service restart runner verifies the local service package manifest, reads installed MySQL 8.4.11 without modifying it, and extracts verified local PostgreSQL 18.6 and Valkey 9.1.2 archives. Each test opens a fresh SQLite store and service module, verifies package identity, starts and stops the service, then reconstructs Core and verifies exact record/claim retention, a changed healthy PID, global MySQL intent off, and verified cleanup. All three packages must produce success records; skipped or missing fixture cases fail the runner. These checks never download packages or resolve dependencies online.

## Safety checks

Project `up` must revalidate exact package/catalog identity and live health before mutation. The desired complete service claim set is reconciled only after preflight. Retired final-owner PostgreSQL is stopped and verified before its claim is removed; identity or stop failure retains ownership. `down` releases only this project and stops PostgreSQL only when no manual or other project claim remains. Route metadata association is restricted to a unique unchanged host/target/root/TLS observation and is rejected if that host set changes during the async report.

## Coverage limits

The project `up/down` sequences run the actual built CLI child against private Core and isolated SQLite. The route fixture injects DNS, standard-port, and trust observations. It does not verify system DNS, PF, privileged ports, Keychain trust, or certificate validation against the local CA. It skips when installed Caddy 2.11.4, a usable installed PHP-FPM package, or the exact installed Mailpit package is absent. The Caddy identity regression runs from `/private/tmp` and checks process ownership across macOS's `/tmp` path alias. Controlled runtime tests cover project startup recovery for MySQL, Mailpit, PostgreSQL, and Valkey. Package-backed recovery through fresh Core dispatchers and reopened SQLite is verified for MySQL, PostgreSQL, and Valkey; installed Mailpit recovery is exercised through actual `val` children while startup recovery is triggered in private Core. These tests do not restart the Core process executable or invoke `val` after a Core process restart. Native Settings interaction, installed-app acceptance, app restart/update recovery, and package distribution gates remain open.
