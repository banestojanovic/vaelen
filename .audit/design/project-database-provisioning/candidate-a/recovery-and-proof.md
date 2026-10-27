# Recovery and proof plan

This is a proposed behavior and verification plan. No engine commands were run to validate these proposals in this architecture pass.

## Operation ordering

1. Parse the request into domain names. Resolve the current full project binding and verify the exact current project claim.
2. Compare catalog package, endpoint, and data directory with module-owned runtime evidence. Refuse stopped or unverifiable services. Provisioning never silently starts a service or adopts a claim.
3. Match any existing operation ID to the entire immutable request. Return ready metadata for completed duplicates. Return the same attention result for interrupted duplicates. Reject ID reuse with different names or target.
4. Reserve database and username for the exact service in SQLite. Check both engine namespaces before generating a password. Refuse any existing object without touching it.
5. Add the generated password to Keychain. Commit the prepared attempt with the password reference. A generated password exists only in process memory and Keychain. The reference derives from the already reserved operation ID, so a crash after Keychain add can recover that same item. Never overwrite it with a newly generated password. No engine write is authorized until the prepared transition commits. Never sweep Keychain by name prefix as a recovery shortcut.
6. Before every engine side effect, persist its pending state. Perform that single effect with a fixed success parser. Commit the confirmed result before starting another effect.
7. Verify access and persist ready. Return metadata. Do not fetch or serialize a password in this response.

The initial implementation uses a single serialized Core mutation path. SQLite uniqueness is also enforced for correctness after restart and to prevent different project aliases selecting the same service resources. The engine's create-only DDL remains the final arbiter against external clients. Do not use `IF NOT EXISTS`, `CREATE OR REPLACE`, password reset, or grant-on-name-match as collision recovery.

## MySQL path

Use the MySQL module's package and inode-verified owned Unix socket for root admin access. Continue using its existing local root configuration only for admin authentication. Never put generated application credentials into `client.cnf`.

Check `information_schema.SCHEMATA` and every `mysql.user` row matching the requested username. Case and identifier behavior must be checked against the actual server settings, including `lower_case_table_names`. Restrict suggested identifiers to lowercase. Refuse system databases and reserved accounts.

Create one account restricted to the exact app endpoint host, proposed as `user@127.0.0.1`. Grant no global privileges or grant option. Create the database without accepting an existing database. Grant only application database privileges on that exact database. Escape wildcard characters in database privilege patterns, including `_`, so a name such as `shop_dev` cannot grant access to `shopXdev`. Prove host matching against the actual app TCP connection rather than relying on reverse-DNS assumptions.

Send SQL on an anonymous stdin pipe. No secret-bearing SQL goes through the existing `runClient(...arguments:)` helper, `--execute`, shell interpolation, environment variables, or temporary files. Run clients without history and without user defaults that could enable command echo. Bound execution time and drain pipes while the child runs.

Before sending a password statement, establish and verify a supported no-plaintext-log session policy. Disable binary logging for this admin session if supported and required. Require supported general, slow, and audit logging conditions. Session `sql_log_off` and sanitized local stderr alone do not prove that server logs are safe. The package-specific test must exercise successful and failed password-bearing statements and scan every retained engine log. Unsupported logging policy causes refusal before secret SQL. Never change a shared server's global logging policy as an incidental part of provisioning.

The authenticated proof transport needs a spike. Prefer passing client authentication configuration through a dedicated inherited descriptor that contains an anonymous pipe, if the supported mysql client accepts it. The descriptor path is a nonsecret argv value. Do not silently fall back to `MYSQL_PWD`, an on-disk defaults file, or an argv password. If the shipped client rejects a pipe, choose a narrow native client-library adapter after checking package and distribution availability. That is an explicit implementation gate.

## PostgreSQL path

Select the exact named instance and package. Connect to its owned admin Unix socket with the cluster bootstrap administrator, rather than MySQL's root configuration. Disable `.psqlrc` and command echo. Send statements over stdin with stop-on-error behavior. Parse catalog outputs into fixed fields and reject unexpected data.

Check database names in `pg_database` and role names in `pg_roles`. Create a LOGIN role with no superuser, role-creation, database-creation, replication, bypass-RLS, or inherited membership privileges. Create the database with that role as its owner. Restrict new database and public-schema privileges to the app's intended use. PostgreSQL database creation is outside a transaction block, so PostgreSQL also uses the durable journal. A transaction around role creation does not eliminate the commit-to-journal uncertainty window.

Establish and verify session logging settings before secret-bearing SQL. Prevent statement, duration, sampled statement, and error-statement logging from retaining the plaintext password. Do not propagate raw psql output or SQL into errors. Generate a SCRAM verifier locally if doing so proves simpler and compatible with the selected package, but do not treat that as permission to log credential material.

Existing managed PostgreSQL starts with trust authentication. A successful password-supplied connection under trust does not prove that the generated password works. Production metadata must report `localTrust` while that remains the instance policy. Prove the password with an isolated SCRAM fixture, including a wrong-password rejection. Do not silently rewrite the whole instance's `pg_hba.conf` for this feature. If the product requires production password enforcement, design a separate instance-scoped authentication policy change and review its impact on existing clients before implementation.

PostgreSQL authenticated proof can use the chosen native library or a verified secret-input mechanism. `PGPASSWORD` and a password file are not fallbacks in this candidate. The exact transport is gated by the same first spike as MySQL.

## Crash and partial failure table

| Durable state at restart | Possible engine state | Recovery behavior |
| --- | --- | --- |
| Reserved, Keychain item absent | No engine write authorized | Refuse safely. Keep metadata sufficient to explain failure. |
| Prepared | No engine write authorized | The same explicit operation may continue after exact identity and collision rechecks. |
| Creating account | Account absent or created, reply lost | Report attention. Inspect read-only. Never reset or adopt that username. |
| Account created | Known account created, database absent at last check | Report partial account. Do not roll back the account or proceed automatically after restart. |
| Creating database | Database absent, created, or external collision | Report uncertain database and confirmed account. Do not assume a database with that name belongs to the attempt. |
| Database created | Database and account created, privileges incomplete | Report partial database. No automatic drop or password rotation. |
| Granting access | Grants absent, partial, or complete | Report partial or uncertain access. No automatic replay after restart. |
| Verifying | Resources may be complete | Read-only verification may explain state, but cannot infer MySQL database ownership solely from names. Keep attention unless the ready transition was durable. |
| Ready | Prior provisioning completed | Return prior metadata. Recheck current target and credential availability for display. Do not mutate drifted engine objects. |

A live, non-crashed operation can finish confirmed stages in order. Once a subprocess has an indeterminate result, the operation stops and records uncertainty. A known create collision is a refusal with any already-created resources reported separately. For example, an external database creation racing after preflight may leave the newly created account. The external database receives no grants and no writes from Vaelen after the create collision.

This design does not promise automatic completion after every crash. Its idempotent behavior is stable refusal or attention without additional mutation. The user can select fresh names for a new attempt. Manual repair and any database deletion stay outside this feature.

## Secret boundaries

The password store is injected into Core. Its default uses Security generic-password APIs, add-only item creation, a Vaelen-specific service, and an attempt-specific account. Items are device-local and are not synchronized. There is no fallback to SQLite or disk when Keychain denies access.

Only the explicit-disclosure IPC response contains a plaintext password. Give that response variant redacted descriptions and exclude its payload from request and response logging. Reject disclosure if the requesting project and exact binding no longer match the attempt's current authorized ownership. An IPC caller can request disclosure explicitly, just as it can request creation. These local IPC checks do not claim a new cross-user authentication boundary.

A copy response goes directly to NSPasteboard through the app or CLI native adapter. Reveal requires an explicit button or flag, clears its UI state on project change or view dismissal, and does not cache the value in AppModel's persistent project state. Do not manufacture a connection URL until an explicit copy-details action exists. Status, diagnostics, crash annotations, and equality failure dumps never include secret bytes.

If Keychain becomes unavailable after an account exists, retain the partial receipt and resources. Do not generate a replacement password and alter the account. If the Keychain item is missing after ready, report credential unavailable. Do not rotate automatically.

## Tests to write first

- A fake password store proves that locked or denied Keychain produces no engine mutations, while a saved item can be retrieved only by the explicit-disclosure operation.
- A recording engine proves that both preexisting-name refusals send no mutating command. MySQL host variants and PostgreSQL cluster roles count as collisions.
- Two aliases and two project IDs using the same exact service cannot reserve the same database or username. Different named PostgreSQL instances can use the same names.
- Exact binding, version, claim, endpoint, data directory, and runtime identity changes all refuse before SQL. Claims are byte-for-byte unchanged after success and every failure.
- Durable crash injection after each pending write, engine commit, and confirmation write proves the table above. Restart never sends DROP, ALTER-password, or a compensating deletion.
- Repeating the same request ID returns the prior result. Reusing it for a different request refuses. A lost client response does not create a second account.
- A password sentinel never occurs in create/status serialization, SQLite pages, stderr, argv, logs, project files, human output, JSON output, or diagnostics. Explicit reveal output is the sole stdout exception.
- A fake child emitting secret SQL on stderr produces a fixed safe error. Raw child output is never attached to an error.
- MySQL database names containing underscores do not broaden grants. App account cannot create another database, access another fixture database, or grant privileges.
- PostgreSQL app account owns the created database, can create and use application tables, and cannot create roles or databases.

Run tests through `Scripts/test.sh` with the focused filters supported by the existing script. The lead should inspect the script before prescribing filter syntax.

## Actual engine proof

Use isolated fixture roots and a real Core process. Verify the package identity and provenance of the grounding document's existing archive directories before using them. Install fresh fixtures if their identity cannot be established. Keep evidence in the parent feature audit directory, without credentials.

Run a real `val project database create` against the managed MySQL default service and one named PostgreSQL service. Keep another PostgreSQL instance and an unrelated project as sentinels. Assert exact instance and claim selection through catalog snapshots and independent engine queries. Prove existing database content and preexisting account credentials stay unchanged after refused requests.

Inspect child argv while the password-bearing operation is in flight. Capture Core, client, engine, and fixture log files. Search for the generated sentinel inside the fixture process without printing it or storing an extra copy. Record only pass or fail and paths. Scan SQLite and project files. Reveal and copy each require their own explicit command. Validate clipboard content without echoing it.

For PostgreSQL, run a second fixture with SCRAM enforcement, prove correct-password login and wrong-password rejection, and mark the ordinary trust fixture honestly. For MySQL, prove actual TCP account matching and positive and negative privilege checks. A mocked SQL executor is insufficient for those claims.

Drive the selected-project Settings controls with the app verification skill. Its fixture validates layout and explicit intent. It does not prove production Core persistence or Keychain behavior. Also run a real signed app connected to the isolated Core for end-to-end create, status after restart, and explicit reveal or copy.

## First implementation slice

First prove secure client input, safe errors, and server logging with disposable engine fixtures. Do not expose a create control before that gate passes. Then implement the durable journal, injected password store, and one MySQL Core request end to end with preexisting-name refusal and a crash after account creation. Extend the same domain operation to named PostgreSQL, then add CLI and compact Settings adapters. No slice includes database deletion or automatic `.env` changes.
