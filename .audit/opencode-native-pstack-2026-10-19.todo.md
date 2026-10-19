# OpenCode2 native pstack replacement

- [x] Read the Principles section of the poteto-mode skill.
- [x] Phase A: Frame. Ground first, then commit. Don't start the run until you can state the definition of done, scope, blockers, and rigor level.
- [x] Phase B: Design the workflow. Decompose into atomic, independently-landable units. Sequence riskiest-unknown-first. Scaffold and verification come before features.
- [x] Phase C: Run the loop. Each unit is an experiment. State the hypothesis, make the smallest change, measure against the predicate on the real artifact, keep it if it advanced, revert it if it didn't.
- [x] Phase D: Keep the audit trail. Log the run via the show-me-your-work skill.
- [x] Phase E: Verify and hand back. Check the whole against the Phase A predicate on the real product, not just the harness.

Definition of done: the normal OpenCode2 TUI loads a small V2-only project workflow, a Luna primary owns the task, native children run and return recorded results, permissions permit routine scoped development while preserving approvals for high-impact operations, the focused Swift command works without a prompt, and fallback/notification claims match observed runtime support. Full acceptance requires actual model records, two overlapping workers, controlled failure behavior, and a completion notification.

Scope: replace the root OpenCode2 project configuration and project pstack model/instruction files, archive the prior active config and profiles, add the smallest supported local TUI completion hook, validate through a fresh normal TUI session, and make a path-limited local commit. Do not edit Vaelen product code, global or Codex configuration, credentials, runtime services, or unrelated staged and untracked files.

Rigor: high for permission and fallback behavior because the same shared project configuration controls future autonomous edits; moderate for reversible prose and model-sheet mappings.

Designed phases:

1. Record the installed runtime, V2 docs, model list, merged configuration, global and agent permission layers, and pre-change Git state.
2. Archive old active configuration and discovered profiles, then replace them with a compact V2 project policy and pstack role map.
3. Validate schema, merged permissions, exact model variants, worktree path, plugin loading, and no V1 adapter or board remains active.
4. Reload the shared OpenCode service, open a fresh normal TUI session, and run focused acceptance prompts. Export only task-related session records and extract model IDs, parent relationships, and timestamps.
5. Review the exact diff and preserved index/worktree state, then create a path-limited local commit without push or tag.

### Phase C units

- [x] Establish installed runtime, V2 API shape, models, and current merged configuration.
- [x] Preserve the prior active setup and install the minimal project configuration.
- [x] Verify config schema and effective permissions.
- [ ] Verify native interactive work, overlapping children, results collection, and exported model identities. Two Luna Medium children overlapped, completed, and their exported results were collected after the parent TUI was interrupted. The parent did not collect them itself. Exported primary variant is `default`, despite merged agent config specifying `medium`.
- [ ] Exercise focused Swift permission, correction on a failing check, failure recovery, and completion notification. Focused Swift check ran 14 tests without a permission prompt. The failure and notification paths were not proven; provider-error fallback is unsupported by this runtime.
- [x] Inspect diff and preservation evidence.
- [x] Create the scoped local commit and capture its identity: `ed7e11f` (`Replace OpenCode2 orchestration with native pstack`).

### Phase D trail

- [x] Keep decision records in `.audit/opencode-native-pstack-2026-10-19.tsv`.
- [x] Reconcile each row against actual command output and OpenCode session exports.
- [ ] Cross-model review is not available through the normal OpenCode TUI harness in this configuration task; record if no independent OpenCode reviewer can run.

### Limits

- Automatic provider-error fallback has not been found in OpenCode2 2.0.32. The approved judgment fallback is parent-session recovery on Luna. The exact free Muse Spark model is absent from the installed catalog.
- Skip any fallback plugin or wrapper. A fallback gap must remain visible and must not become a hidden model substitution.
