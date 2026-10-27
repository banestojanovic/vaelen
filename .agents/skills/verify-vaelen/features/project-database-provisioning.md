# Provision a project database

## Scope

`val project db create <database> <user> [project] [--json]` creates a database and dedicated application account for the one healthy, claimed MySQL or PostgreSQL service binding in a linked project's `vaelen.yml`. Core verifies the binding against its persisted claim, service record, endpoint, package, health, and server identity before it runs engine commands.

Core stores generated passwords in macOS Keychain. The SQLite receipt records operation state and the Keychain reference, not the password. Creation refuses an existing database or account. If an engine reports an uncertain partial DDL result, the receipt records `needsAttention`; Vaelen does not remove or roll back database objects.

`val project db status <operation-id> [project]` returns receipt metadata only after matching the saved exact service record and live cluster identity. It does not load credentials or mutate the engine. `val project db password reveal <operation-id> [project]` writes a ready operation's password to stdout. `val project db password copy <operation-id> [project]` copies it to the system clipboard. Native Settings exposes the same Core creation and reveal operations. Neither entry point edits `.env`.

`val project db retry <operation-id> [project] [--json]` retries only a `failedBeforeDDL` attempt with no pending, confirmed, or uncertain engine effects. Core reloads the saved immutable request and revalidates the exact service record and live cluster identity. Settings shows Retry only for a failed-before-DDL receipt.

## Focused checks

Run the receipt, protocol, and CLI parsing tests through `Scripts/test.sh`:

```sh
Scripts/test.sh --skip-update --disable-automatic-resolution --filter 'ProjectDatabaseProvisioningTests|ProtocolTests|ProjectRelationshipCLIParsingTests'
```

Run the live MySQL fixture:

```sh
Scripts/tests/val-project-database-provisioning-test.sh
```

Run the live PostgreSQL fixture:

```sh
Scripts/tests/val-project-database-provisioning-postgresql-test.sh
```

The MySQL fixture verifies database and user collision refusal and confirms the existing account grants remain unchanged. The PostgreSQL fixture verifies role attributes, wrong-password rejection, and suppression of password SQL while aggressive statement and sampling logging is enabled. Both fixtures verify provisioning, neighboring-database isolation, a PDO migration, persistence through service and Core restarts, unchanged project `.env` bytes and service claims, and exact Keychain-item cleanup. They use extracted local engine packages and private Core and project roots. The scripts print the retained evidence directory on success.

Run the Settings fixture after checking that no Vaelen process is running:

```sh
python3 Scripts/prepare-bundled-php.py --offline
VAELEN_SETTINGS_FIXTURE=project-database VAELEN_SETTINGS_PAGE=projects .agents/skills/verify-vaelen-app/scripts/launch-fixture.sh artifacts/verification/<run-id>
```

Use `project-database-postgresql` to render a PostgreSQL binding and ready receipt. Use `project-database-retry` to render a failed-before-DDL receipt and Retry. Run `doctor-fixture.sh` for each evidence directory, then inspect the visible window with CUA. Fixture handlers disable create, retry, status, reveal, and copy even when their buttons render. Fixtures prove rendering only, not Core behavior. Use `cleanup-fixture.sh` after inspection.

## Coverage limits

The live engine scripts verify CLI and Core behavior, not a user's installed signed app. The Settings fixture requires a separate visible CUA check. Neither fixture tests migration compatibility for every framework or database driver. Password copy and reveal require a ready receipt and a user action.
