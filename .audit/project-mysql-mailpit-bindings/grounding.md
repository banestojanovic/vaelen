# Grounding: project bindings to legacy MySQL and Mailpit

## User-facing shape

```yaml
version: 2
services:
  database:
    kind: mysql
    instance: default
    version: mysql-8.4.11
  mail:
    kind: mailpit
    instance: default
    version: mailpit-1.31.1
```

`val project plan/up/down` and native Settings must agree on the selected local instances. `.env` remains an observation only. Applying or releasing project ownership does not rewrite project files or move service data.

## Current implementation evidence

- `ProjectServiceKind` and `ServiceInstanceEndpoint` already represent MySQL and Mailpit. `ServiceInstanceRecord` stores exact package identity, endpoints, and data path.
- SQLite schema 9 requires each project claim to reference a catalog row. `ServiceInstanceRepository` owns catalog and claim writes.
- `ProjectManagedServiceKind` and `ProjectManagedServiceDriver` currently accept only PostgreSQL and Valkey. Planner, project report, activation, and deactivation share that closed set.
- `CoreRequestDispatcher.projectEnvironmentReport` reads V2 service observations from the catalog. Missing catalog rows produce `missing`; unsupported kinds cannot activate.
- V1 `services.mysql` and `services.mailpit` still read as default service requirements. The legacy planner uses global `MySQLStatus` and `MailpitStatus`; MySQL start is deferred, Mailpit start is actionable.
- `MySQLModule` and `MailpitModule` each use one production `default` instance. MySQL status exposes installed version, TCP port, and data directory. Mailpit status exposes installed version, SMTP/UI ports, and message DB path. Existing start and stop APIs take no instance ID.
- Project down already releases unsupported legacy claims without stopping the runtime. The generic managed path stops final-owner PostgreSQL/Valkey.
- `mysqlRemove` and `mailpitRemove` currently stop the singleton and remove its package without checking project claims.
- Native adoption inventory currently filters to PostgreSQL and Valkey in `AppModel.swift` and `VaelenApp.swift`.
- Existing roadmap decisions require preserving legacy data paths, not editing `.env`, exact package identity, and no runtime stop on project down for MySQL/Mailpit.

## Boundary constraints

- Only `instance: default` is valid for MySQL/Mailpit until their modules own named isolated instances.
- An installed but uninitialized MySQL package is not healthy and must remain blocked. Project activation must not initialize it silently.
- Mailpit may start from its installed state because its existing `start()` creates only its own default message store. Its data path remains the current default path.
- An active project claim prevents removing the package. Explicit manual stop remains a service action and is not changed by project down.
- Never stop or adopt an external process based on endpoint alone. Preserve each module's current process identity and readiness checks.
- Adoption can select a singleton only when the local package inventory and current exact record are available. The portable declaration may omit a local package version only if current catalog identity supplies it.

## Candidate design test

Compare the catalog-backed singleton binding with a V2-only legacy observation path. Grade each on exact identity, compatibility with existing V1/global behavior, transactional claims, package-removal safety, adoption/UI consistency, and call-chain size. A separate generic lifecycle registry is an alternative only if it materially reduces duplicated policy without turning the closed service set into a plugin system.

The design judge scores each criterion from 1 to 5 and rejects any design that weakens exact process identity, silently changes the MySQL endpoint, initializes an uninitialized MySQL instance, migrates service data, stops MySQL/Mailpit on project down, or exposes credentials. The final interface must keep package identity, endpoint evidence, and the existing data directory derived from one module-owned snapshot.
