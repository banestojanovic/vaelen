# Persist service instances and claims

For process management after the catalog is established, read [Manage an exact service instance](service-instance-lifecycle.md).

## Scope

`SQLiteStateStore` schema 9 stores typed service instances, manual ownership, and project bindings in the existing Core database. Project claim replacement is atomic. Unlinking a project releases its project claims while preserving service instances and manual claims. The repository lists instances in stable kind/name order. `val service instances [--json]` reads that catalog through Core IPC and reports exact package identity, loopback endpoints, data directory, and owners without inferring process health. This layer does not start, stop, install, update, or remove a service.

## Focused checks

Run through `Scripts/test.sh`:

```sh
Scripts/test.sh --filter ServiceInstanceCatalogTests
Scripts/test.sh --filter ServiceInstanceInventoryTests
Scripts/test.sh --filter ServiceInventoryOutputTests
Scripts/test.sh --filter ProjectRegistryTests
Scripts/test.sh --filter NodeSelectionTests
Scripts/test.sh --filter NodeCLIIntegrationTests
Scripts/test.sh --filter RoutingTests
Scripts/test.sh --filter TLSCapabilityTests
```

The catalog tests use temporary SQLite databases to cover all service kinds, exact identity, endpoint validation, deterministic listing, claims across multiple owners, rollback on invalid replacement, and reopen persistence. Registry, routing, TLS, and Node tests cover project unlink and old schema migration paths.

Run `Scripts/tests/val-service-list-test.sh` to build the actual `val` child and exercise `val service instances` against a private Core and disposable SQLite database. The same fixture checks legacy MySQL/Mailpit status and versions. It does not use the installed app or a signed installed CLI.

## Coverage limit

These checks prove catalog persistence, IPC serialization, CLI formatting, and the real CLI/private-Core request path. They do not exercise a live service process, package acquisition, service health, UI, or project `up/down`.
