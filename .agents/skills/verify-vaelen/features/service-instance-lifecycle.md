# Manage an exact service instance

Read this journey before changing a named service lifecycle. It extends [Persist service instances and claims](service-instance-catalog.md) from inventory into package-backed process management.

## Focused checks

Run the isolated Core lifecycle tests and actual `val` child fixture:

```sh
Scripts/test.sh --filter 'ServiceInventoryOutputTests|ValkeyServiceLifecycleTests'
Scripts/test.sh --filter PostgreSQLServiceLifecycleTests
Scripts/tests/val-service-lifecycle-test.sh
Scripts/tests/valkey-service-lifecycle-test.sh
```

`Scripts/tests/val-service-lifecycle-test.sh` and `Scripts/tests/valkey-service-lifecycle-test.sh` verify generated package archives against their checksummed manifest, extract them with the builder's traversal and link checks, then inject the extracted roots into private Core processes. Each fixture uses a unique test support root, dynamically selected loopback port, private Core socket, and disposable SQLite store. PostgreSQL checks actual `val` child create/status/start/stop/remove, project up/down ownership, loopback endpoint, observed health, claim release, and retained data. Valkey checks omitted-port create idempotency, manual ownership, nonempty data refusal, exact PID/start/executable and live server version/process/port/bind/data identity, cross-instance PID-spoof refusal, dead-process recovery, evidence-write cleanup, AOF value recovery across stop/start, claim release, and retained data. RDB snapshot settings are enabled but RDB file recovery is not directly asserted. The focused Core tests check SQLite reopen and exact process re-observation, nonempty data refusal, and live PostgreSQL health. On failure, retain fixture roots and package extraction for diagnosis. Snapshot the data directory, `.env`, claims, unrelated support paths, and any unrelated listener before and after.

## Safety checks

The package driver checks archive digest, exact root inventory, and traversal/link safety before extraction. Core accepts only an injected extracted package directory and does not extract archives. Include port conflict, partial/nonempty initialization directory, unverifiable process identity, shutdown timeout, and removal while running or project claimed. Confirm failures preserve data and process evidence and never signal an unrelated PID. A non-destructive remove releases the manual claim and leaves data intact.

## Coverage limits

Normal Core launches read PostgreSQL from `~/Library/Application Support/Vaelen/packages/postgresql/postgresql-18.6` and Valkey from `~/Library/Application Support/Vaelen/packages/valkey/valkey-9.1.2`. Local fixtures may inject verified extracted package roots. Package acquisition, provenance, and signing remain open release gates. These local generated-package fixtures prove runtime behavior on the current Apple Silicon host only. They do not prove signed/notarized release, repeatable PostgreSQL builds, macOS 14, native Settings interaction, package update, project Valkey bindings, installed-app project controls, or full Herd replacement acceptance. The PostgreSQL fixture exercises project-level restoration, startup, alias reconciliation, and final-owner shutdown through the built `val` child and private Core socket.
