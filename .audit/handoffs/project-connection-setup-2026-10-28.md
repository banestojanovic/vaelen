# Handoff: reviewed project connection setup

## Goal for tomorrow

Build a safe, explicit workflow that takes a ready project database provisioning receipt and prepares the Laravel project's database connection settings. Vaelen must show the proposed `.env` changes first, require the developer's approval, preserve unrelated file contents, refuse stale-file writes, avoid secret leakage, and support recovery. CLI and native Settings should use the same Core-owned operation and show consistent state.

Do not add `.env` edits to database provisioning, project `up`, or any other silent/background operation.

## Starting point

- Project: `/Users/banes/Code/apps/vaelen`
- Provisioning feature branch: `codex/project-database-provisioning-20261027`
- Provisioning implementation commit before this handoff: `71e1f5ec7eb209a6a34b47d9914998efd61a89df`
- The feature has been pushed to `origin`.
- Read `.audit/project-database-provisioning-handoff.md` for current behavior and acceptance evidence.
- Read `.audit/project-service-environments.todo.md` for the wider Herd-replacement goal and known release gates.

The provisioning receipt already binds an exact project, managed service, database, user, and Keychain password. It does not change `.env`. Database provisioning acceptance passed for MySQL and PostgreSQL, including real migration/restart checks, focused tests, and native Settings fixtures. The unfiltered test suite was inconclusive due to concurrent test/cache failures; do not claim it passed.

## Completion predicate

A developer can:

1. Select a ready provisioning receipt for a linked Laravel project.
2. Preview the exact connection keys and values Vaelen proposes to change, with password masked and existing-value conflicts clearly shown.
3. Approve the exact reviewed proposal.
4. Have Vaelen apply it only if the `.env` file identity/content still matches the preview.
5. Confirm unrelated lines, comments, ordering, line endings, permissions, and file identity are preserved as designed.
6. Recover from an interrupted or explicitly reverted operation without losing either the prior file or the approved new settings.
7. See the same result and state in `val` and native Settings.

All paths must keep passwords out of process arguments, logs, diagnostics, SQLite receipts, and ordinary UI text. No mutation occurs during preview. Symlinks, duplicate keys, malformed syntax, permission changes, and concurrent edits must fail safely or have an explicitly designed behavior. Never replace the entire `.env` with a normalized rewrite unless the design proves byte preservation for unrelated content.

## Suggested session plan

1. **Ground current behavior.** Read `AGENTS.md`, `/Users/banes/.codex/pstack-models.md`, the installed pstack Codex mapping, and the relevant `poteto-mode` skill. Inspect existing project adoption, database receipt/Keychain, `.env` discovery/redaction, CLI IPC, Settings, and file-write abstractions. Use the existing Rex session and avoid opening extra tabs unless useful.
2. **Frame and design.** Record baseline tests and exact `.env` parser behavior. Compare a byte-preserving targeted edit with a separately generated include file. Decide where approved before-images and recovery state live, how confirmation binds to file hash/inode/project/receipt, and how secret values are passed without process arguments. Select the narrowest design that works for Laravel's expected dotenv syntax.
3. **Implement and verify in slices.** Start with Core preview/confirmation/apply/recovery state and tests. Cover quoted values, comments, duplicate keys, missing keys, CRLF/LF, no trailing newline, conflicts, symlinks, file permission changes, concurrent edits, interrupted atomic replacement, and secret redaction. Then add CLI and Settings over the same IPC operation.
4. **Independent review.** Use exactly one fresh read-only Sol reviewer by default. Fix actionable findings with one correctly routed implementation delegate. Do not use a review panel unless a genuinely complex integration or bottleneck justifies it.
5. **Live acceptance.** Use disposable Laravel project directories and actual provisioned fixture databases. Capture before/after byte hashes; verify a real PDO/Laravel connection, refusal of stale proposals, recovery from injected write interruptions, and agreement between CLI and Settings. Clean only fixture-owned state after confirming processes are gone.
6. **Handoff.** Update a dedicated `.audit` tracker, document coverage limits and any whole-suite failure, commit the accepted feature, and push only if requested for that goal.

## Scope discipline

Target connection environment variables are the standard Laravel database fields required by the receipt, such as `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, and `DB_PASSWORD`, plus any engine-specific fields only if justified by existing Vaelen behavior. Do not add `.env` discovery beyond linked project scope, credential import, database deletion, automatic migrations, or project activation as a side effect.

The expected focused coding and acceptance effort is about 3–5 hours. Add 2–4 hours if dotenv parsing or atomic recovery requires a design change.

## User and workflow preferences

- Keep macOS Settings compact and native; avoid creating persistent project windows.
- Use one reviewer unless the integration is truly complex or a major bottleneck.
- Never start a reviewer panel just because a template recommends one.
- Preserve unrelated work and report limitations plainly.
- No push is implied for the next goal unless the user authorizes it.
