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
```

The focused suites cover exact and family PHP selection, exact Node selection, honest V2 route/TLS and managed-service planning, project claim reconciliation, `up`/`down`/`up` for stopped PostgreSQL and Valkey instances, service alias rename, retired-instance identity failure retaining the old claim, manual-owner preservation, and route target/TLS changes during activation. The PostgreSQL and Valkey package fixtures invoke the built `val` child over private Core for project up/down and named service lifecycle commands. They check claim transitions, data retention, health, and process identity. The Valkey fixture uses the exact `valkey-9.1.2` local archive and verifies repeated up/down, alias rename, shared manual ownership, final-owner stop, and identity failure retaining the project claim. The route fixture invokes the built `val project adopt`, `project up`, and `project down` children over private Core with copied installed Caddy and PHP-FPM package roots. It adopts one HTTP and one HTTPS route from separate reviewed V2 manifests, checks real PHP responses, route ownership retention across down/up, and `.env` byte preservation.

## Safety checks

Project `up` must revalidate exact package/catalog identity and live health before mutation. The desired complete service claim set is reconciled only after preflight. Retired final-owner PostgreSQL is stopped and verified before its claim is removed; identity or stop failure retains ownership. `down` releases only this project and stops PostgreSQL only when no manual or other project claim remains. Route metadata association is restricted to a unique unchanged host/target/root/TLS observation and is rejected if that host set changes during the async report.

## Coverage limits

The project `up/down` sequences run the actual built CLI child against private Core and isolated SQLite. The route fixture injects DNS, standard-port, and trust observations. It does not verify system DNS, PF, privileged ports, Keychain trust, or certificate validation against the local CA. It skips when installed Caddy 2.11.4 or a usable installed PHP-FPM package is absent. The Caddy identity regression runs from `/private/tmp` and checks process ownership across macOS's `/tmp` path alias. Project-level MySQL/Mailpit/Valkey, native Settings interaction, installed-app acceptance, app restart/update recovery, and package distribution gates remain open.
