# Project database provisioning design

## Decision

Use candidate A's journaled create-once operation as the base. Add candidate B's disabled-account ordering and module-owned service lifecycle critical sections. Candidate A scored 18/20 and candidate B scored 16/20 under the saved rubric. The independent design judge selected A because it looks up the immutable request before collision checks, has clearer secret disclosure authorization, and identifies the unresolved secure-authentication transport as a release gate. The full scorecard is in `.audit/design/project-database-provisioning`.

The first slice is a Core-only MySQL create path with injected Keychain storage, durable receipts, collision refusal, and fault injection. A real MySQL proof must validate stdin transport and logging before either UI or CLI can create an account. PostgreSQL follows on the same domain operation. Then the CLI and selected-project Settings controls call Core.

## Caller usage

The developer enters a database name and application username. `val project db create` and the selected-project Database section send the same typed create request. The CLI requires exactly one healthy, claimed MySQL or PostgreSQL binding. Neither caller supplies a password. Results contain operation and receipt IDs, binding, database, username, state, and effect metadata. They do not contain host/port fields or a Keychain-saved indicator.

The developer calls `val project db password reveal` or chooses **Reveal Password** to display it. Copy is a separate explicit action. `val project db status` returns metadata. `val project db retry <operation-id> [project] [--json]` retries only a saved `failedBeforeDDL` attempt with no pending, confirmed, or uncertain effects. Ordinary status, creation, inventory, and JSON responses never contain the password. The feature never writes `.env`.

## Named domain shape

`DatabaseProvisionAttempt` binds an immutable project request to the exact verified service record, cluster identity, Keychain item reference, and current state. It records confirmed engine effects separately from the pending or uncertain effect.

The request contains an operation ID, project ID, full `ProjectServiceBinding`, validated `DatabaseName`, and validated `DatabaseUserName`. The boundary accepts only the default managed MySQL instance or a named managed PostgreSQL instance. Core resolves the current project declaration and requires its full binding, catalog record, live module identity, endpoint, data directory, package identity, cluster identity, and project claim to agree.

The receipt state is a closed enum. It distinguishes reserved, prepared, pending effect, confirmed partial, ready, refused, and needs-attention states. A different request cannot reuse an operation ID. Repeating the same operation before its first DDL may continue after revalidation. After any DDL intent, a crash, timeout, or lost child response becomes a retained read-only needs-attention result. Vaelen never resumes uncertain DDL, adopts objects by name, or drops resources as compensation.

Names use lowercase ASCII letters, digits, and underscore, start with a letter, and are limited to 32 bytes. The common grammar fits both engines and avoids silent truncation and case folding. The boundary also rejects system database and reserved account names.

## Ownership and storage

`ProjectDatabaseProvisioner` owns name reservations, attempt transitions, Keychain ordering, disclosure checks, and the single engine operation. `ProjectDatabaseReceiptRepository` stores metadata and nonsecret operation state in SQLite schema 10. It never stores a password, verifier, SQL statement, client output, or connection string containing a password. Reservations are unique by exact service identity plus database name and by exact service identity plus username, even when a project binds the same service under another alias.

`KeychainProjectDatabasePasswordStore` stores a cryptographically random password in a generic-password item keyed by the immutable operation ID. It uses add-only creation and never overwrites an item. Keychain denial or a locked store stops the operation before DDL. If creation has already begun, missing Keychain data does not trigger password rotation.

The password exists only in a scoped secret type, Keychain, and a bounded pipe to the database client. Engine input does not use argv, shell text, process environment, SQL files, client history, or project files. Engine errors map to fixed diagnostic codes and discard raw output. A dedicated explicit-disclosure IPC response is the only ordinary API response allowed to carry password bytes. IPC logging and error formatting must redact it.

## Engine behavior

MySQL uses its verified managed Unix socket and the existing root configuration only for administration. It creates the new application account locked, creates the requested database, grants database-scoped privileges without grant option, and unlocks the new account last. It refuses a database or any account with that username at any host. The actual MySQL package must prove that a database name cannot broaden a `GRANT` through `%` or `_` pattern behavior. Before password SQL, the operation disables and reads back session general, slow, and binary logging controls on the same connection. It also refuses when an active audit plugin or unchangeable log path could retain the statement. It does not change the shared server's global logging settings.

PostgreSQL uses the verified socket for the selected named instance. It creates a `NOLOGIN` role with no elevated role attributes, creates a database owned by that role, revokes `PUBLIC` access on only that new database, adds a database-and-role-specific `scram-sha-256` loopback rule at the start of `pg_hba.conf`, and enables login last. The scoped authentication rule makes the generated password meaningful while preserving the current policy for other databases and roles. The module writes the managed rule atomically and records the change before applying it. It does not rewrite unrelated rules or modify any other database. It reports the actual authentication mode.

Before password SQL, PostgreSQL sets and reads back statement, duration, error, sampling, and bind-parameter logging controls in the same psql session. It stops before secret SQL if any setting is unavailable or differs. It also refuses nonempty preload libraries and an installed pgaudit extension. This covers the configured PostgreSQL logging channels, not arbitrary third-party code. PostgreSQL role and database operations cannot share one transaction because `CREATE DATABASE` is forbidden inside a transaction block. The receipt therefore records each DDL intent and acknowledgement independently.

Both engine modules expose a closure-shaped internal admin capability. It verifies the exact instance and holds the service lifecycle critical section through preflight, creation, and final identity check. The dispatcher also keeps the first implementation synchronous, so project `up`, `down`, unlink, and rebinding cannot interleave at actor suspension points. Core's operation has a 30-second total deadline, and database child processes have shorter individual timeouts. Keychain calls set `kSecUseAuthenticationUIFail` so they do not wait for a user prompt. No SQLite transaction remains open while Core calls Keychain or an engine process.

Before returning `ready`, Core authenticates as the new app user with the saved password over the exact application endpoint and checks the new database. It uses an anonymous descriptor for the client credential configuration and stdin for SQL. The server log policy is checked on that same session. The operation persists the stable cluster identity and compares it before later status or disclosure. A different cluster at the same path makes the receipt stale and blocks disclosure.

## IPC and user experience

Core exposes create, receipt status, operation-ID-only retry, and explicit password access. Retry loads the immutable request from the saved attempt. Status compares its saved `ServiceInstanceRecord` and cluster identity with current values under the owning module lock, without loading credentials or mutating the engine. Plain result types cannot carry password data. The secret response type is separate and has redacted descriptions.

The CLI provides `val project db create`, `status`, `retry`, and `password reveal|copy`. `--json` is allowed for nonsecret metadata only. Reveal and copy require explicit actions. The CLI writes clipboard data through a stdin pipe, never as a process argument.

The native project control lives in the existing selected-project detail. It does not open another project window. It lists eligible bindings and shows service identity before creation. The view loads only receipt metadata. Reveal and Copy each require a deliberate action, and a project change or dismissal clears displayed password text.

Unlinking a project does not delete its receipts, Keychain items, databases, or accounts. The retained receipt does not authorize use from another project. Database deletion, overwrite, password rotation, migration rollback, and automatic `.env` edits remain outside this feature.

## Verification order

1. Capture the failing behavior with domain, receipt repository, Keychain fake, and Core IPC tests. Prove collision refusal, ID reuse refusal, all pre-DDL failures, and read-only recovery after each DDL interruption.
2. Prove secret input, output draining, timeout handling, fixed errors, and session log policy against the actual installed MySQL 8.4.11 package in a disposable support root.
3. Run MySQL provisioning through private Core and the actual `val` child. Prove app-user authentication, least privilege, exact host matching, Laravel migration, restart persistence, collision refusal, and unchanged project `.env`, claims, existing databases, and unrelated app data.
4. Run the same acceptance against an isolated named PostgreSQL 18.6 instance. Prove the scoped SCRAM rule, correct-password success, wrong-password rejection, least privilege, migration, restart persistence, and unchanged neighboring databases and service state.
5. Exercise selected-project Settings with the app verification skill. Treat fixture-only UI evidence separately from production Core and Keychain proof.
6. Run one fresh read-only Sol review over the full diff and audit trail. Fix issues through a fresh Luna delegate, then rerun every affected check.

The final predicate is not satisfied by compile success or fixture-only Settings rendering. It requires actual MySQL and PostgreSQL engine evidence, restart persistence, secret-boundary scans, file and claim preservation, and one clean independent review.
