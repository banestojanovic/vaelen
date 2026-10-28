# Laravel connection acceptance

## Feature workflow

1. `how` over the affected subsystem.
2. `architect` for parallel design exploration.
3. Write the throughput checkpoint as four todo items. A dimension that genuinely does not apply (single file, no fan-out) keeps its item with `n/a: <reason>` rather than being dropped:
   - **Blocking first steps.** Gates run before fan-out.
   - **Independent workstreams.** Disjoint files, services, or layers parallelize. Shared writes serialize.
   - **Shared mutable state.** Default to splitting the target (the **separate-before-serializing-shared-state** principle skill). Serialize only for real invariants.
   - **Smallest safe decomposition.** If one worker is best, name why.
4. Delegate code-writing to a subagent using your configured feature model (default `grok-4.7-xhigh-fast`) with a specific scope (file paths, named data shape and its organizing structure per **principle-model-the-domain**, a state machine over scattered booleans, a table/registry over branching, a typed model over repeated shape assumptions, chosen before the delegate writes logic, and success criteria). Pick each subagent's reasoning level and fast or standard speed for the job, per the Subagents section of the **poteto-mode** skill. When the implementation admits multiple valid shapes (error handling, abstraction layer, test structure), delegate via the **arena** skill instead so the runners surface the alternatives and the cross-judge guards the pick. Mandatory: no skip-with-reason escape, and Laziness Protocol does not override it (the gain is review separation, not lines saved). A subagent forbidden to spawn satisfies this by owning the diff directly with the same review separation. No "standing by" reply that waits on a nested agent. Comments per **Comments**. Surgical edits, re-ground against the source for upstream-derived files. Port shared-primitive improvements to all consumers and verify each. Commit liberally.
5. Verify on the matching surface. "Inconclusive" or wrong-surface is not a pass. Flag it.
6. Rebase into small, ordered commits. Stack follow-ups.
   Use the **sequence-verifiable-units** principle skill, building, verifying, and committing each small unit before the next.
7. If the design is contested, `interrogate` before shipping.
8. Run **Opening a PR**.

## Throughput checkpoint

- [x] Blocking first steps: inspect the existing live provisioning/connection test, identify a compatible installed Vaelen PHP and Composer path, and confirm the pinned Laravel fixture can install and boot before delegation.
- [x] Independent workstreams: n/a, the live fixture's ownership and cleanup require one implementation owner; design candidates remain isolated under separate directories.
- [x] Shared mutable state: one test owner writes the Swift acceptance fixture, shell recipe, and verification map in one worktree; no concurrent code writers.
- [x] Smallest safe decomposition: one Luna implementation worker is best because the acceptance crosses the shell recipe, the same Swift live journey, Composer fixture inputs, and feature documentation as one lifecycle.

## Acceptance predicate

After `val project db connection apply` writes the six approved `DB_*` values into a disposable Laravel project's existing `.env`, real Laravel bootstrap must expose the expected database configuration before and after `php artisan config:cache`. The check must never print the database password, must use the installed Vaelen PHP runtime, and must clean up all temporary framework/build output while retaining a small evidence record.

## Phases

- [x] Ground the private-Core journey and installed PHP/Composer environment.
- [x] Compare two whole-shape acceptance designs and select one against the criteria in `.audit/design/laravel-acceptance/rubric.md`.
- [x] Implement the selected acceptance lane.
- [x] Verify real Laravel bootstrap in uncached and cached modes.
- [x] Update the verification map and handoff with coverage limits.
- [x] Review the complete diff once with one fresh read-only Sol reviewer.
- [x] Commit and push the isolated feature branch. Commit `a4fb244` is on `origin/codex/project-laravel-acceptance-20261028`.
- [ ] Run Opening a PR. skip: neither `gh` nor `origin` is installed, and no browser surface is available; use the GitHub compare link in the handoff.

## Execution checkpoint

- Focused XCTest suites passed through `Scripts/test.sh`.
- The Laravel recipe passed with Composer 2.9.8, PHP 8.4.27, Laravel 13.39.0, and phpdotenv 5.8.0. Both phases booted Laravel, compared all six expected values, and queried MySQL. The wrong-port and absent-cache controls failed as required.
- The standard package-backed MySQL recipe passed with no Laravel variables.
- Retained evidence: `/private/tmp/vaelen-laravel-connection-evidence.S8xOyO` and `/private/tmp/vaelen-project-database-evidence.Bs72Bk`.
- One first-run permission assertion exposed Laravel's cache file mode `0700`. The test now explicitly chmods it to `0600` and verifies that mode; the corrected run passed.
- The fresh Sol review found a false-pass case when a successful Artisan child printed the credential. `LaravelChildResult` now separates status, redacted output, and credential detection. Its success predicate requires status zero and no detected credential. A zero-exit credential-emission negative control passes.
- Lead reruns passed for the focused suite and the complete Laravel recipe. Final evidence is at `/private/tmp/vaelen-laravel-connection-evidence.UPgcZY`; its recorded Swift hash matches the final file.
- `git diff --check` flags three whitespace-only lines in the verified upstream Laravel welcome view. The exact upstream snapshot is preserved. Authored files pass the check.
- Review found no other actionable provenance or comment issues. Commit `a4fb244` is pushed; PR creation is pending because this session lacks a forge CLI and browser surface.
- Cleanup removed seven measured Swift `.build` trees (9,632,688 KiB total), Vaelen DerivedData (30 MiB), and `Scripts/__pycache__` (60 KiB). The filesystem reported 39 GiB available before and 48 GiB after.
- No worktree was removed because chat ownership is unknown and three worktrees contain uncommitted project work. Previously rejected `/private/tmp` deletion targets remain untouched. Historical verification artifacts and the initial failure log remain available.

## Design selection

Candidate B is the base because its committed Laravel fixture and Composer lock make dependency inputs explicit and reproducible. Candidate A contributes mandatory permission, child teardown, and safe-diagnostic constraints. The cross-judge scored both 24/25; see `.audit/design/laravel-acceptance/synthesis.md`.
