# Verification and first slice

No engine behavior was executed for this design-only package. The following are implementation acceptance criteria, not passed checks.

## Concrete first implementation slice

Build only the Core create-once MySQL path and injected password boundary first. Introduce the typed request and receipt, metadata migration, secret-safe process runner and module-owned admin critical section. Add fault injection immediately before and after every write-intent commit, engine acknowledgement and final receipt commit. Do not expose UI or CLI creation until a real MySQL fixture proves the safety contract. Then implement PostgreSQL against the same receipt operation, then wire both callers in one wave. No temporary public engine-specific create commands are needed.

## Unit and integration seams

The fake `ProjectDatabasePasswordStore` records create/load calls and returns opaque deterministic secret bytes. Tests inject Keychain denied, locked, missing, duplicate and write-failure cases. Assert no engine call before durable secret creation. Assert ordinary result encodings and diagnostic encodings never contain the fixture password or verifier. Tests cannot rely on a logger calling `description` on opaque secret wrappers.

The receipt repository uses a temporary real SQLite store. Reopen it at every crash point. Same operation plus identical inputs returns its existing receipt. Same operation plus different inputs fails. Competing operations under two aliases of one instance cannot reserve the same database or username. Two distinct instances can reuse the same names. Project unlink must preserve receipt and credential reference. A retained partial receipt never calls a mutating admin method again.

Use recording engine adapters to assert no mutation after existing-database or existing-user refusal. Test both conflicting namespaces together, case/truncation rejection, reserved names, invalid SQL punctuation and role host ambiguity. Claim/binding changes, renamed aliases, missing projects, instance record mismatch, wrong package, wrong data directory, PID reuse, stopped and unverified health must fail before DDL. Do not rewrite these as tests that only compare generated SQL strings.

The secret-safe runner seam captures argv, environment, stdin, stdout and stderr independently. Assert secrets occur only in the bounded stdin data and dedicated reveal response; no secret files are created. Force stderr to echo the submitted statement and confirm only a fixed error code crosses the adapter. Force large stdout and stderr streams to prove draining and bounds. Force timeout after an engine write and require retained partial.

A test-only Keychain namespace creates one random generic-password item through the real Security framework, reopens it and compares scoped bytes, then removes only that test item during fixture cleanup. The fake is not evidence that production Keychain accessibility, entitlements or caller identity works. Production reveal is verified under the built Core's identity separately from the native fixture app.

## Actual engine proof

Follow `.agents/skills/verify-vaelen/SKILL.md` before independent review and extend its existing service-instance/project recipes. Use verified local MySQL 8.4.11 and PostgreSQL 18.6 packages, private support roots, exact package identities, dynamic loopback ports, private Core sockets, disposable SQLite, and built `val` children. No package download is part of these tests. Preserve failed fixtures and a sanitized evidence manifest.

For each engine, create two managed targets where supported, bind a project to the non-default PostgreSQL target, and create a database with a separate user. Query the exact target's engine catalog as admin and application user. Prove own-database table creation, inserts and reads. Prove no superuser, role-creation, global grant or grant option powers. Check neighboring existing data and users are byte-for-byte or catalog-equivalent unchanged. On MySQL, create a nearby schema matching an underscore-as-wildcard interpretation and prove the new account cannot access it. Verify the precise local account host selected by `CURRENT_USER()`.

For PostgreSQL, query stored role policy and database owner from the exact named cluster. Its normal trust configuration proves role and database behavior only. In a separate disposable cluster, enable scoped SCRAM authentication for the test role and prove the Keychain password succeeds while a wrong password fails. This fixture-only configuration does not count as production password enforcement. Prove the other named cluster has no new database or role.

Preseed a database with sentinel data and separately a user with sentinel privileges, then attempt conflicting creation. Assert no password change, privilege change, object deletion or sentinel mutation. Race a foreign CREATE between preflight and the strict CREATE statement and verify no grant is made to that foreign object. Kill Core after user creation, after database creation, after grant and after login enablement. Restart with the same support root and resend the same operation. Every incomplete attempt must produce retained partial and execute no additional DDL. Kill after final ready commit and require an ordinary ready retry result.

Use a known high-entropy fixture password from the fake store for leak checks, so checking for its presence does not require revealing a real user's credential. Run success, duplicate, syntax-error, permission-error and timeout paths with verbose server logging deliberately enabled. The operation must establish a tested session-safe logging policy or refuse before DDL. Scan all fixture files, server logs, CLI stdout/stderr, Core diagnostics, IPC trace and captured process argv/environment for both the password and verifier. Do not store password-bearing process snapshots as evidence. Real Keychain tests use comparison in memory and print only pass/fail.

Snapshot `.env`, manifest bytes and project claims before creation. Assert exact preservation after success and every failure. Stop/restart the service and reopen Core/SQLite. Assert ready metadata and Keychain lookup survive, then explicitly reveal/copy and verify that only the requested sink receives the password.

Run tests through `Scripts/test.sh` with focused new suites, then the affected existing binding/lifecycle suites. Native Settings verification additionally follows `.agents/skills/verify-vaelen-app/SKILL.md`. Test one selected project with one eligible binding, multiple bindings, no eligible binding, conflict, Keychain denial, pending state, retained partial and ready state. Drive Create, Reveal and Copy. Switching projects must clear revealed text. The fixture app skips Core, so production Core persistence and Keychain remain separate live checks.

## Module map

| Owner | Proposed change |
| --- | --- |
| `Sources/VaelenCore/ProjectDatabaseProvisioning.swift` | Core operation, domain types, receipt interpretation and engine sequencing. |
| `Sources/VaelenCore/ProjectDatabaseReceiptRepository.swift` | Sole metadata ledger writer and name reservations. |
| `Sources/VaelenCore/ProjectDatabasePasswordStore.swift` | Injected password store and Security implementation. |
| `Sources/VaelenCore/DatabaseAdminProcess.swift` | Internal bounded pipe runner and secret-safe diagnostics shared by concrete engine adapters. |
| `Sources/VaelenCore/MySQLModule.swift` | Verified local admin capability and concrete MySQL syntax. Extend lifecycle exclusion consistently. |
| `Sources/VaelenCore/PostgreSQLServiceModule.swift` | Verified named admin capability and concrete PostgreSQL syntax. Preserve generic runner for nonsecret lifecycle work. |
| `Sources/VaelenCore/SQLiteStateStore.swift` | One migration for attempts/reservations, no secret columns. |
| `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift` | Resolve current project declaration and exact claim; inject the sole provisioner; adapt requests and errors. |
| `Sources/VaelenIPC/Protocol/ProtocolModels.swift` | Private-to-transport request and response envelopes, with distinct secret response method. |
| `Sources/VaelenIPC/Client/VaelenCoreClient.swift` | Typed domain-facing create, receipt and explicit password calls. |
| `Sources/VaelenCLI/main.swift` | Parse arguments, call Core once, print nonsecret receipt or intentional password sink. |
| `App/Vaelen/Vaelen/AppModel.swift` | Pending submission ID, receipt state and explicit password action. |
| `App/Vaelen/Vaelen/VaelenApp.swift` | Compact selected-project Database group. |

## Red-flag screen

No caller coordinates preflight and mutation. No public SQL executor, engine stage selection or raw client output is exported. Only one component writes receipts and only the existing binding owner writes claims. No secret is added to the environment report or viewer action. The small public API hides engine policy rather than forwarding the same parameters through multiple public layers. Engine branches are confined to concrete Core adapters. No mirrored engine support list is introduced in CLI or Settings; eligible bindings derive from Core capability projections.
