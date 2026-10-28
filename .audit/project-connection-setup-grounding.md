# Project connection setup grounding

## Overview

Vaelen currently inspects Laravel project environment settings but does not write them. Project adoption is explicitly reviewed and single-use. Database provisioning creates a ready receipt for one linked project and stores the generated password in Keychain. The connection setup feature must compose those existing boundaries without expanding provisioning or project activation.

## Key concepts

- `ProjectEnvironmentInspector` reads `.env` as UTF-8 text and derives configured database facts. It never returns secret values.
- `ProjectDatabaseReceiptRepository` stores the immutable project, database, user, and service target in SQLite. The password is referenced separately and loaded from Keychain.
- Core revalidates the linked project and exact managed service identity before revealing a provisioning password. The existing reveal operation is explicit.
- `CoreRequestDispatcher` is an actor. Adoption uses a 30-second in-memory session, a single-use confirmation token, and fresh evidence checks at apply time.
- `ProjectAdoptionManifestWriter` creates a new `vaelen.yml` through a synchronized temp file and an exclusive hard link. There is no equivalent writer for an existing user `.env`.
- CLI and Settings already use typed Core IPC. Project Settings are selected within a compact shared window, and `AppModel` keeps transient project state by project path.

## How it works today

1. CLI or Settings selects a linked project. Core resolves the project identity and gathers observations.
2. `ProjectEnvironmentInspector` reads `.env`, parses recognized assignments, and produces redacted configured values and diagnostics.
3. Database provisioning validates the exact project binding and managed service target, writes an operation receipt to SQLite, and stores generated password bytes in Keychain.
4. `val project db password reveal` and the native Reveal action use a separate explicit request. Core validates that the receipt is ready and still refers to the same linked project and service target.
5. Adoption has its own review token and apply command. It writes only a new manifest; it deliberately leaves `.env` unchanged.

## Where things live

- `.env` read and redacted project report: `Sources/VaelenCore/ProjectEnvironment.swift`.
- Database receipt and Keychain password boundary: `Sources/VaelenCore/ProjectDatabaseProvisioning.swift`.
- Exact project and database service validation, adoption sessions, and IPC dispatch: `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift`.
- Typed request/result models: `Sources/VaelenIPC/Protocol/ProtocolModels.swift`.
- Core IPC client: `Sources/VaelenIPC/Client/VaelenCoreClient.swift`.
- CLI project and database command parsing/dispatch: `Sources/VaelenCLI/main.swift` and `Sources/VaelenCLI/CLIDocumentation.swift`.
- Project detail and database setup controls: `App/Vaelen/Vaelen/VaelenApp.swift` and `App/Vaelen/Vaelen/AppModel.swift`.
- Existing read behavior tests: `Tests/VaelenCoreTests/ProjectEnvironmentTests.swift`.
- Provisioning behavior and actual engine fixtures: `Tests/VaelenCoreTests/ProjectDatabaseProvisioningTests.swift` and `Tests/VaelenIPCTests/ProjectDatabaseProvisioning*EndToEndTests.swift`.

## Gotchas

- The existing parser is read-only and intentionally small. It trims whitespace, skips comments, strips matching outer quotes, and assigns duplicate keys last-wins. That behavior is unsuitable for mutation because it cannot report ambiguity or preserve byte layout.
- A generated include file is not automatically equivalent to Laravel's conventional `.env` file. It would need bootstrapping changes or an extra load mechanism, expanding the scope and changing the app's runtime.
- An apply can race with an editor outside Core. Actor isolation only serializes Core requests; stale file identity and bytes need a fresh check immediately before replacement.
- The password belongs only in Core memory during proposal construction and in the approved `.env` after apply. It must not enter preview results, diagnostics, command arguments, logs, or SQLite metadata.
- A recoverable before-image contains user environment values. Its path, permissions, retention, restore eligibility, and explicit discard behavior need one owner and tests.
- The provisioning and Settings features already prove that MySQL, PostgreSQL, and their databases can be created. This feature should consume only a ready receipt and must not run migrations or start unrelated services.

## Scope and completion predicate

Implement one explicit database connection review for an existing regular `.env` file of a linked Laravel project. The developer previews the proposed `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, and `DB_PASSWORD` values, then approves the exact proposal. Core rejects changed project, receipt, service, or file evidence; ambiguous target assignments; unsafe file types/permissions; and stale confirmations. The edit preserves unrelated bytes and permissions. An interrupted apply can be reconciled, and an explicit restore never overwrites later edits. CLI and Settings agree. The password does not appear in persistent metadata or ordinary output.

Do not create `.env` during this slice, import credentials, edit files during provisioning or `project up`, change bootstrapping, run migrations, or alter database/service ownership.

Expected effort is 3–5 hours if the parser and restore model fit the existing architecture; 2–4 hours more if file transaction or Laravel syntax behavior requires redesign. The main blockers to resolve before implementation are byte-accurate assignment recognition, external editor races, and secure recovery-copy retention.

## Design alternatives

1. Patch the six target assignments in place while preserving all other bytes, with a Core-owned approval session and protected before-image/recovery record. It fits Laravel's existing `.env` loading behavior but requires careful parsing and recovery ownership.
2. Write a separate generated connection file and ask Laravel to load it. It avoids editing existing lines but changes the project's bootstrap/runtime conventions and expands scope, so it must demonstrate a clear user benefit before selection.

## Laravel runtime caveat verified 2026-10-28

Laravel loads the project's configured environment file during bootstrap only when configuration is not cached. With `bootstrap/cache/config.php` present, its environment bootstrap returns without loading `.env`; the official docs say `.env` is not loaded for requests or Artisan commands while configuration is cached. Therefore a successful file apply cannot promise that the running app will use the new connection. The feature must detect a cached config and surface that state, or at minimum word success as “file updated” and explain the cache condition. It must not silently clear/rebuild Laravel's config cache as a side effect. Sources: Laravel's [`LoadEnvironmentVariables`](https://github.com/laravel/framework/blob/13.x/src/Illuminate/Foundation/Bootstrap/LoadEnvironmentVariables.php) and [configuration caching docs](https://github.com/laravel/docs/blob/13.x/configuration.md).

Laravel's default database configuration reads connection values from `DB_*` environment values, so the six-key proposal matches the default app structure. Projects can customize this behavior; a successful default `.env` edit only configures the conventional Laravel path, not every custom bootstrap.
