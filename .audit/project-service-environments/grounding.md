# Project service environments grounding

## User outcome

Developers can create isolated PostgreSQL and Redis-compatible instances, bind a project to exact instances in `vaelen.yml`, inspect instance health and connection details in `val` and the native app, and activate requested services without overwriting `.env` or deleting data.

## Current implementation facts

- `MySQLModule` owns package acquisition and lifecycle. Its internal initializer accepts an instance name and port, and its state files use the instance name. The public initializer chooses `default`, and the production daemon constructs one MySQL provider.
- `MailpitModule` owns package acquisition and lifecycle. It accepts custom ports but uses the fixed `default` data and process paths.
- `ServiceIntentStore` stores enabled state in a string-to-boolean JSON map. The dispatcher currently writes and restores literal `mysql` and `mailpit` keys.
- IPC methods and CLI actions are service-specific singletons. They do not take instance identifiers.
- `ProjectEnvironmentInspector` reads `vaelen.yml` and `.env`. `ProjectDesiredEnvironment` currently has `mysql` and `mailpit` booleans. Project observation carries one optional MySQL status and one optional Mailpit status.
- Endpoint comparison already covers MySQL and Mailpit. A prior explorer described it as MySQL-only; direct inspection of `ProjectEnvironment.swift` shows database and mail endpoint comparisons. Do not repeat the incorrect description.
- `ProjectReconciliationPlanner` can plan MySQL and Mailpit operations. MySQL service start remains deferred. Mailpit start is actionable. The activation executor runs a subset of actions and re-inspects state.
- Existing reports do not return secret values. Project activation does not edit `.env`.
- MySQL package removal preserves its data directory. Keep package data separate from service instance data.
- Project database UI recognizes PostgreSQL aliases in presentation only. There is no PostgreSQL runtime or project-instance selector.

## Relevant files

- `Sources/VaelenCore/MySQLModule.swift`
- `Sources/VaelenCore/MailpitModule.swift`
- `Sources/VaelenCore/ServiceIntentStore.swift`
- `Sources/VaelenCore/VaelenFilesystem.swift`
- `Sources/VaelenCore/ProjectEnvironment.swift`
- `Sources/VaelenCore/ProjectReconciliation.swift`
- `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift`
- `Sources/VaelenDaemon/main.swift`
- `Sources/VaelenIPC/Protocol/ProtocolModels.swift`
- `Sources/VaelenIPC/Client/VaelenCoreClient.swift`
- `Sources/VaelenCLI/main.swift`
- `Sources/VaelenCLI/ServiceInventoryOutput.swift`
- `App/Vaelen/Vaelen/AppModel.swift`
- `App/Vaelen/Vaelen/ServiceSettingsView.swift`
- `App/Vaelen/Vaelen/ProjectsViews.swift`

## Package research so far

- The official Postgres.app download page lists PostgreSQL 18.6 as a universal macOS package, requires macOS 10.15, and lists a 123 MB download for the single-version package. Its repository license page contains the PostgreSQL permissive license. This establishes a viable arm64-capable artifact candidate, not a redistribution or extraction policy for Vaelen.
- Redis's official macOS guide documents Homebrew installation and its source-build guide supports macOS builds from official source. The official licensing page says Redis 8 is offered under AGPLv3, RSALv2, or SSPLv1. The package format and redistribution path need a deliberate choice.
- Valkey is a BSD-licensed Redis-compatible alternative with official source releases. Its official macOS instructions describe Homebrew and source installation. The user asked for Redis-compatible behavior; if Vaelen uses Valkey, the UI and docs must name it explicitly.
- Redis's official source-build guide supports macOS. The official `redis-hashes` repository publishes digests for source tarballs. Redis 8 is tri-licensed, including AGPLv3. A Vaelen package lane must select and comply with one license option.
- The existing product architecture rejects relying on Homebrew runtime dependencies. Any final package lane must be independently installable and verifiable by Vaelen.

## Design questions to resolve

- Whether `(service kind, validated immutable instance name)` is the durable identity or whether each instance needs an opaque ID plus a project-facing name.
- How the project manifest names exact service bindings while remaining readable and portable across developers' machines.
- How activation records desired run state when multiple projects share one instance, and how `down` avoids stopping a service still required elsewhere.
- Whether the service package install/remove lifecycle needs a common domain contract or service-specific managers behind a shared instance catalog.
- How Redis artifacts will be built, pinned, licensed, and delivered without requiring Homebrew or a local compiler.
