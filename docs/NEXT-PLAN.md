# Next plan

Queue owner: the project owner. A queue item is not approval for destructive, privileged, installed-app, or real-project actions. Use one small item per commit; preserve unrelated checkout changes.

## Current priorities

Items below are ordered by the owner through current development work and tracked audit TODOs. Confirm scope and acceptance before implementation when a note is exploratory.

1. **Finish project-service lifecycle recovery** — close the active PostgreSQL and Valkey restart/recovery slice; inspect the current lifecycle tests and `.audit/project-service-environments.todo.md`, then run the focused lifecycle and recovery fixtures.
2. **Complete service package lane** — inspect `.audit/project-service-package-lane.todo.md`; define acceptance and bounded tests before changing package resolution or installation.
3. **Review recent PHP artifact and metadata redirects** — inspect `.audit/php-artifact-redirect.todo.md` and `.audit/php-metadata-redirect.todo.md`; reproduce current behavior, document any real user-visible gap, then scope a fix.
4. **Validate schema 9 update compatibility** — inspect `.audit/schema9-update.todo.md`; use isolated update fixtures and preserve rollback/recovery guarantees.
5. **Continue Herd replacement acceptance** — after the above, choose the next user-facing gap from `docs/ARCHITECTURE.md` and the current acceptance records; write explicit observable criteria before implementation.

Do not process the whole list in one unattended run unless the owner names that scope. Stop at the requested shift size or when a product decision is required.
