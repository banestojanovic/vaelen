# Project environment replacement workflow

## User outcome

A developer can move a PHP project from Herd to Vaelen, review the discovered setup, and use Vaelen as the normal local environment. Project setup is portable; runtime state and service data remain local to each Mac. The CLI, Core, and native Settings describe the same environment. The menu bar stays compact.

## Current evidence

- Vaelen already has native PHP and Node version management, project PHP and Node selections, Caddy routing, local DNS/TLS, MySQL, Mailpit, a CLI, project inspection, and partial project reconciliation.
- The version-1 `vaelen.yml` describes PHP, HTTPS, and MySQL/Mailpit booleans. It cannot name an exact service instance or fully describe a project environment.
- Service inventory and lifecycle are currently singleton-shaped at IPC and CLI boundaries. Production Core creates one MySQL and one Mailpit module.
- Project inspection reads `.env` without returning secrets and never edits it. Project activation defers MySQL startup and currently has only singleton service observations.
- `SQLiteStateStore` owns the project registry and evolves via transactional schema migrations through schema 8. A project/service claim in that same database can be changed transactionally with the project environment record; service process data remains outside SQLite.
- Herd's current public product description covers PHP, Node, project-level settings, HTTPS, workspaces, and multiple service families. The public overview advertises `herd.yml`, but the exact current schema and a supported automated migration API were not established in this research. Do not read or mutate undocumented Herd private state as an import contract.

## Selected architecture

Use the current Core and SQLite state store as the single authority for project identity, managed service instances, and durable ownership claims. Keep concrete service lifecycle behavior in engine-specific managers. Project reconciliation calls a closed set of typed manager operations. There is no extensible plugin runtime and no second service lifecycle writer.

The domain shape is:

```swift
enum ServiceKind { case mysql, postgresql, redis, valkey, mailpit }
struct InstanceID { let kind: ServiceKind; let immutableName: InstanceName }
struct ProjectServiceBinding { let alias: BindingAlias; let instance: InstanceID }
enum RunOwner { case manual; case project(ProjectID) }
struct InstanceDescriptor { let id: InstanceID; let packageID: ExactPackageID; let endpoint: LoopbackEndpoint; let dataLocation: URL }
struct ProjectEnvironmentSpec { let php: PHPRequirement?; let node: NodeRequirement?; let web: WebRequirement?; let services: [ProjectServiceBinding] }
struct ProjectEnvironmentSnapshot { let desired: ProjectEnvironmentSpec?; let configured: ProjectConfiguredEnvironment; let observations: [BoundServiceObservation]; let diagnostics: [ProjectDiagnostic] }
```

The version-2 `vaelen.yml` shape is:

```yaml
version: 2
php: "8.4"
node: "22"
web:
  host: shop.test
  documentRoot: public
  secure: true
services:
  database:
    kind: postgresql
    instance: shop-db
    version: "18.6"
  cache:
    kind: valkey
    instance: shop-cache
    version: "9.1.2"
  mail:
    kind: mailpit
    instance: default
```

Service aliases are unique project roles. `kind` names the concrete engine, so Valkey never pretends to be Redis. `instance` resolves to one local instance identity. Optional exact `version` is a compatibility requirement; if omitted for an existing legacy service, the local catalog is authoritative. If an instance is absent and the version is absent, `up` must stop and ask for a concrete choice rather than picking latest. `web.host` and `documentRoot` are requested intent only; route conflicts and document-root evidence must be resolved before mutation. Version 1 retains its existing field set and read semantics.

Names in a project file identify the intended local instance. Exact package identity and port allocation are recorded in Vaelen's local catalog. Health is an observation, never inferred from a persisted start request. Version-1 booleans continue to map to `mysql/default` and `mailpit/default`; reading v1 does not rewrite it. Version 2 names typed bindings and rejects unknown or ambiguous fields.

Store catalog entries and the complete project claim set in the existing `vaelen.sqlite`, in one Core-owned transaction. This avoids splitting project and service ownership across independently committed stores. Keep package archives immutable and separate from instance data. Preserve current default MySQL and Mailpit paths. A service package cannot be removed while any instance references it. Do not migrate data directories just to normalize paths.

For `up`, parse the project file, resolve every exact dependency, preflight package availability, data compatibility, ports, and process ownership, then atomically replace the project's claim set. Only after the preflight succeeds may Core reconcile instances. Partial starts keep the desired claim so retries and restart recovery converge. `down` releases only that project's claims; manual or other project claims keep shared instances running. Both operations reobserve and report actual state. Never kill a listener based only on its port.

## Adoption boundary

Adoption is inspect, plan, confirm, reconcile. Inspect project files and publicly supported Vaelen/Herd interchange only. Report framework evidence, PHP/Node requirements, route and TLS state, and `.env` endpoints while redacting secret values. Let the user confirm local names and service mappings. Do not modify `.env`, import passwords, take over an existing route, select an alternate runtime or service, or alter databases. If Herd's project settings are not available through a documented interchange, present the discovered project facts and let the user enter the missing selection in Vaelen.

## Package decisions

- Build PostgreSQL and Valkey as Vaelen-owned, pinned arm64 macOS artifacts from official source releases. Do not make Homebrew a user prerequisite. Generate Vaelen's own checksummed package manifest and keep package archives separate from service data. Prototype both builds and audit bundled dependency licenses before shipping artifacts.
- Prefer PostgreSQL to Postgres.app as the source lane. PostgreSQL's license permits redistribution with its notices, while Postgres.app publishes large universal bundles that include PostGIS and additional extensions not needed for a first database instance. Postgres.app remains a useful reference for version support and user behavior, not a runtime dependency.
- Use Valkey as the first Redis-compatible implementation. Its project describes the server as BSD-3-Clause; official macOS installation currently points users to Homebrew or MacPorts, while the official download page lists Linux binaries. Vaelen must build and own a macOS artifact. Keep Redis a distinct product because Redis 8 is tri-licensed under RSALv2, SSPLv1, or AGPLv3.
- Always name Valkey as Valkey in Settings, CLI, project configuration, package metadata, and connection examples. Do not silently substitute it for a Redis declaration.
- The compatibility contract may describe `redis-compatible`, while each instance declares its concrete implementation. App/framework config examples must distinguish exact environment variables and password behavior.

This source-lane choice is based on the [PostgreSQL license](https://www.postgresql.org/about/licence/), [Postgres.app downloads](https://postgresapp.com/downloads.html) and [build notes](https://github.com/PostgresApp/PostgresApp), [Valkey installation guide](https://valkey.io/topics/installation/), [Valkey downloads](https://valkey.io/download/), and [Redis licensing](https://redis.io/legal/licenses/) checked on 2026-10-26. Local arm64 build and runtime feasibility is now verified in `package-build-spike.md`. Reproducible packaging, dependency-license notices, authenticated provenance, and signed release artifacts remain gates.

## Delivery sequence

1. **Manifest and adoption model.** Define the version-2 portable project specification above, bounded project discovery, redacted preview/plan, v1 compatibility, and a stable `val project up/down` user contract. No service data changes in this slice.
2. **Catalog and claims.** Migrate SQLite schema, add strict catalog records and atomic project/manual claim replacement, keep existing singleton behavior as adapters, and preserve current paths and intents.
3. **PostgreSQL lifecycle.** Choose and pin package lane, create isolated instances, observe exact process ownership and health, expose connection examples, and prevent package removal while referenced.
4. **Redis-compatible lifecycle.** Choose an explicitly named implementation/package lane, add isolated instances and truthful compatibility/auth/persistence observations.
5. **Project orchestration and CLI.** Wire instance inventory/create/status and project plan/up/down through IPC and `val`; reconcile shared ownership and report partial failure.
6. **Native macOS workflow.** Add the same instance and project actions in Settings and existing project surfaces. Keep the menu bar for quick actions and preserve macOS navigation/conventions.
7. **Migration and recovery.** Provide reviewable Herd/project adoption, restart recovery, safe update/removal behavior, export/backup guidance, and diagnostics. Never inspect undocumented Herd secrets or write `.env` automatically.
8. **Product acceptance.** Walk one existing Laravel/PHP project through inspection, review, activation, serving, CLI/toolchain use, database/cache/mail integration, restart, down, and recovery. Run the exact installed app/CLI fixture path, review evidence independently, and audit all requirements before calling the goal complete.

Each unit must leave the product closer to that same end-to-end workflow. Package lanes are a blocking unknown before service lifecycle code, not a reason to replace the user outcome with a service inventory feature.

## Verification bar

For each slice, use an isolated support root, isolated ports, fixture projects, and exact before/after snapshots. Assert that no `.env` byte changes, unrelated listeners remain untouched, claims survive Core restart, a failed operation reports incomplete readiness rather than success, and service data survives package removal/update. Final acceptance requires the real signed installed app and installed `val` on an isolated fixture plus one manual workflow on a representative PHP project. Historical suite reports do not establish current behavior.

## Choices and principles

- **Foundational Thinking** set the project manifest and ownership model before adding service code.
- **Model the Domain** changed the design from booleans and singleton methods to typed project bindings, instance identities, owners, and observations.
- **Redesign from First Principles** keeps project claims and service catalog changes under one Core authority while preserving the old manifest and data paths.
- **Experience First** makes adoption reviewable and keeps routine project management in the compact macOS surfaces rather than opening a window per project.
- **Make Operations Idempotent** requires restart recovery to reconcile desired owners with process observations, not replay stale actions.
- **Never Block on the Human** permits routine reversible product decisions; it does not authorize destructive migration or silent runtime/service substitution.

## Open gates

- Define precedence between portable declarations and existing local PHP/Node overrides. The default should be explicit and consistent in CLI, app, and shell resolution.
- Complete PostgreSQL and ICU package contents, acquisition, and redistribution notice review.
- Audit Valkey's linked/distributed bundled dependencies and verify the release commit signature with available tooling.
- Define and implement the reproducible checksummed artifact manifest and package/update lane.
- Establish the supported Herd adoption input. Public marketing mentions `herd.yml`, but this research did not confirm its schema or a migration API.
- Choose one real PHP project fixture for final installed-app acceptance without changing the user's project data.
