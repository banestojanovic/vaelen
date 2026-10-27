# Service instance catalog and ownership claims

## Throughput checkpoint

- **Blocking first steps.** Preserve the canonical dirty checkout; use the integrated typed manifest and adoption preview as the API contract; record the schema 8 baseline and migration tests before implementation.
- **Independent workstreams.** None. The migration, catalog model, repository transactions, and behavior tests define one shared persistence contract.
- **Shared mutable state.** Keep all catalog and claim writes in `SQLiteStateStore`; one owner changes the schema and repository together. Do not write runtime files or start services.
- **Smallest safe decomposition.** One Luna implementation owner is appropriate because SQLite constraints, claim replacement semantics, and compatibility migration must agree. The lead owns the data shape, tests, review, and main-checkout verification.

## Data shape

An instance is identified by `(ProjectServiceKind, ProjectInstanceName)`. Its catalog record carries an opaque exact package identifier, service-specific loopback endpoints, and the existing data directory path. Ownership is an enum with either the manual owner or a `ProjectID`. A project binding additionally carries its manifest alias. SQLite stores instances, manual claims, and project claims; instance and project claims are constrained by foreign keys. Replacing one project's entire claim set is one transaction. Empty replacement releases that project's claims. This slice does not remove instances or touch service data.

## Hypothesis

Durable typed identity and transactional claims are sufficient groundwork for safe service lifecycle work while leaving existing singleton processes and data paths unchanged.

## Completion evidence

- Schema migration from version 8 preserves projects, routes, TLS state, and project overrides, and reopen remains idempotent.
- Repository tests prove exact identity, typed endpoints, missing-instance rejection, project claim replacement rollback, isolation between manual and project owners, persistence across reopen, and retention of unclaimed instance records.
- Focused Core tests and `git diff --check` pass in the implementation worktree and the integrated checkout.
- One fresh read-only Sol review has no unresolved high-confidence findings.
- No claim is made that services start, stop, or migrate. Those remain later lifecycle work.
