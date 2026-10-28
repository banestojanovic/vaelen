# Reviewed project connection setup

## Phase A. Frame

- [x] Read the Principles section of the poteto-mode skill.
- [x] Define the falsifiable completion predicate.
- [x] Record the exact scope, rough effort, and blockers surfaced by grounding.
- [x] Create an isolated worktree from the pushed database provisioning feature.
- [x] Capture the focused baseline before implementation changes.
- [x] Preserve and account for uncommitted work in other Vaelen worktrees.

## Phase B. Design the workflow

- [x] Ground the existing `.env` inspection, linked-project resolution, database receipt/Keychain, Core IPC, CLI, Settings, and atomic file-write paths.
- [x] Compare byte-preserving `.env` editing with a generated connection include file; reject the include because Laravel does not load it without bootstrap changes.
- [x] Compare two independent transaction designs and have one read-only Sol judge score them against the shared rubric.
- [x] Select one data shape for preview, approval, apply, and recovery before implementation.
- [x] Record stale-file, duplicate-key, malformed-file, symlink, permissions, crash, and concurrency behavior, including the unavoidable final-writer limit.
- [x] Record the throughput checkpoint and ordered implementation phases.
- [x] Prototype same-volume `RENAME_SWAP` and prove captured-file recovery under ordinary and injected failure cases before committing to its implementation.

## Phase C. Implement in verified units

- [x] Add behavior tests for preview and a byte-preserving dotenv transformation.
- [x] Add tests for duplicate or malformed target assignments, quoting, comments, CRLF/LF, missing keys, and stale file identity.
- [x] Add Core-owned preview and single-use apply confirmation bound to the linked project, ready receipt, exact service target, Keychain bytes, and `.env` snapshot.
- [x] Add safe recovery from interrupted apply and explicit restore only when the applied file still matches the recorded result.
- [x] Add typed IPC and CLI review/apply/status/restore/discard commands over the same Core operation.
- [x] Add compact native Settings review and apply/recovery controls without displaying the password.
- [x] Verify with isolated Laravel Settings fixtures and an actual provisioned MySQL database; full Laravel bootstrap remains a release follow-up.

## Phase D. Keep the audit trail

- [x] Append decisions and verification results to `.audit/project-connection-setup.tsv` as work progresses.
- [x] Run the required deslop review and inspect the complete diff.
- [x] Complete one fresh read-only Sol review and resolve actionable findings.

## Phase E. Verify and hand back

- [x] Check every completion predicate against Core, CLI, Settings, exact file bytes, and live database behavior.
- [x] Confirm passwords do not appear in arguments, diagnostics, persistent receipt metadata, or ordinary IPC/UI output; review output and live receipt journey use secret canaries.
- [x] Confirm project source, unrelated `.env` lines, permissions, and existing database data remain intact in disposable verification fixtures.
- [x] Write a detailed handoff with evidence, limitations, and next remaining release work.
- [x] Commit the accepted feature locally; publish the feature branch after confirming the remote branch state.

## Completion predicate

Implementation, verification, handoff, and local commit are complete. See `.audit/handoffs/project-connection-setup-2026-10-28.md` and `.agents/skills/verify-vaelen/features/project-connection-setup.md` for current evidence and coverage limits.


A developer can select a ready MySQL or PostgreSQL provisioning receipt for a linked project, review the exact Laravel database environment changes, and explicitly approve their application. Core refuses an expired or already-used confirmation, changed project/service/receipt identity, changed `.env` file, symlink target, malformed or ambiguous target keys, unsafe permissions, or an unverifiable recovery state. The edit preserves unrelated bytes and file permissions. A crash or an explicit restore can recover the previous environment without overwriting later user edits. Project unlink is blocked while any recovery artifacts remain so the linked-project recovery path cannot be orphaned. CLI and native Settings agree on operation state. Password bytes stay out of persistent metadata and ordinary output.

This goal does not add automatic edits during provisioning or `project up`, credential import, database deletion, application migrations, or broad dotenv normalization.

## Initial scope and risk

The work crosses Core parsing/file operations, durable recovery evidence, service receipt validation, IPC, CLI, and Settings. Expected effort is about 3–5 hours if Laravel dotenv syntax and restore semantics fit a bounded design; add 2–4 hours if parser or recovery behavior forces a redesign. The main risks are overwriting concurrent edits, leaking an existing or generated password into backup/log/output paths, and claiming atomic recovery without verifying the file system behavior.

The first throughput checkpoint is a pure byte-preserving transform plus file-snapshot test suite. Do not wire Core or UI until duplicate/malformed target handling, CRLF/LF preservation, secret redaction, and stale-snapshot refusal are demonstrated.

## Phase list

1. Ground existing project selection, dotenv inspection, database receipt and Keychain access, IPC, CLI, Settings, and file creation conventions.
2. Establish baseline focused test results and dotenv fixture behavior.
3. Compare a byte-preserving targeted edit with a generated include-file design, then record the chosen domain types and file transaction model.
4. Build the pure preview transform and filesystem snapshot harness first.
5. Add Core preview, approval, apply, and recovery around the exact linked project and ready database receipt.
6. Expose the flow through typed IPC, `val`, and compact Settings.
7. Verify actual Laravel database connectivity, crash/stale-file safety, secret boundaries, and byte preservation on disposable fixtures.
8. Run one independent review, resolve findings, update the decision trail, and write the handoff.

## Architecture arena checklist

- [x] Frame: define the artifact and score candidates for byte preservation, crash recovery, secret handling, and interface depth.
- [x] Fan out: produce two structurally distinct designs in separate output directories.
- [x] Cross-judge: one read-only judge scored both candidates against the same rubric.
- [x] Pick: choose the occupant-preservation transaction boundary based on the data-loss risk.
- [x] Graft: use the smaller Core owner and review presentation from A, combined with B's evidence-derived recovery states.
- [x] Verify: prototype the synthesized single-swap protocol and check it against official Laravel behavior and existing Core APIs.
