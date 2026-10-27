# Project database provisioning Settings fixtures

## Ready receipts

Launch `project-database` for MySQL and `project-database-postgresql` for PostgreSQL. Each fixture includes deterministic metadata for a ready receipt so the card renders Reveal and Copy actions.

## Retry receipt

Launch `project-database-retry` to render a `failedBeforeDDL` receipt and Retry action. It uses fixed operation and receipt identifiers and contains no password.

All three fixtures disable create, retry, status, reveal, and copy in both the controls and model action handlers. They prove rendering only. They do not exercise Core, Keychain, or engine behavior.
