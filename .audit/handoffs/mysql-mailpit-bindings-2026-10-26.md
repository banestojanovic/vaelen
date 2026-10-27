# Historical handoff: MySQL and Mailpit project bindings — 2026-10-26

This records the state before the 2026-10-27 acceptance follow-up. The feature is now accepted after the review fixes. See [the current handoff](mysql-mailpit-bindings-2026-10-27.md).

## Stop point

The MySQL/Mailpit project-binding feature is **not accepted or committed**. Core implementation and focused unit coverage are present, the native Settings fixture was inspected, and one fresh read-only Sol review passed the implementation then in scope. The disposable built-`val` journey then exposed a real Mailpit process-identity defect, so the acceptance is still open.

The product failure is reproducible when a fixture is created beneath `/private/tmp`: `ps` reports the child executable as `/tmp/.../mailpit`, while the persisted record contains `/private/tmp/.../mailpit`. Mailpit's previous `processMatches` compared the command line to the stored path and rejected its own child. That left the first alias identity-unverified; the second alias then failed to decode/update the SQLite catalog. Keep the strict identity checks: exact PID, user, process start identity, arguments, and canonical open executable (`lsof -p PID -a -d txt -Fn`). Do not loosen verification to executable basename, prefix, or port checks.

## Work completed before the stop

- Selected and documented a catalog-backed binding architecture in `.audit/project-mysql-mailpit-bindings/architecture.md`.
- Implemented exact `default` MySQL/Mailpit projection, claim-aware lifecycle and package-removal behavior, project inventory/reporting, and eligible-kind selection in native Settings.
- Fixed review findings for duplicate aliases, omitted versions before catalog materialization, singleton stop capability exposure, claim metadata cleanup, and dynamic picker eligibility.
- Focused suites passed before the newly found `/tmp` bug. The native Debug fixture was built and inspected with CUA; its fixture disables mutations, so interactive apply/removal is not verified by that run.
- Added `Tests/VaelenIPCTests/ProjectServiceBindingsEndToEndTests.swift` and `Scripts/tests/val-project-service-bindings-test.sh` for disposable built-`val` acceptance. The helper decoder was corrected to read `ProjectReconciliationExecutionResult` directly; recheck this in the current diff.
- A Sol review of the feature before the `/tmp` defect had no findings. The fresh review after the identity fix is still required.

## Current working-tree caution

The checkout is intentionally dirty with many earlier, unrelated Vaelen changes and artifacts. Do not reset, stage broadly, or commit everything. `HEAD` at stop is `10b980a` on `dev`. Inspect `git status --short` and compare the intended feature files with the prior audit notes before staging. Preserve all unrelated changes.

The first fix-round worker `/root/mailpit_tmp_identity_fix` was interrupted at the user's request. The second fresh Luna fix-round worker `/root/mailpit_identity_fix_round2` also stopped at the requested pause boundary. Its implementation is incomplete and its native `/private/tmp` regression failed; see `.audit/mailpit-identity-fix-round2.todo.md` for the worker's detailed checkpoint.

The shared checkout already contains these partial edits from the first worker:

- `Sources/VaelenCore/MailpitModule.swift`
- `Tests/VaelenCoreTests/MailpitModuleTests.swift`

The first partial change resolves symlinks for `lsof`'s open executable and checks PID/user/arguments/start identity. The second round adds `KERN_PROCARGS2` argv inspection and a bounded identity-command helper in `Sources/VaelenCore/MailpitModule.swift`. Its clean scratch build succeeded, but two serial native `/private/tmp` regression attempts failed because Mailpit did not become healthy within the startup timeout. The process identity predicate is not yet diagnosed. The earlier isolated `MailpitModuleTests` run was interrupted after the strict executable check rejected Python shebang fixtures and left fixture children behind. All exact fixture children from both attempts have since been stopped and their ports verified closed; the second worker reports no test processes or test roots remain. The checkout's default `.build` lock stalled while stale SwiftPM invocations existed; those exact test commands were stopped. Do not treat any of these runs as passing.

## Resume checklist

1. Read this handoff, `.audit/project-mysql-mailpit-bindings.todo.md`, the architecture, `.audit/project-service-environments.todo.md`, and `docs/current-development.md`.
2. Inspect the current `MailpitModule.swift` diff and `.audit/mailpit-identity-fix-round2.todo.md`. Instrument each exact process identity observation for one native child; the last two serial runs failed health readiness.
3. Complete the native binary and shebang fixture identity regressions, with exact PID/argv/open executable/port cleanup verified on failure and success.
4. Run `Scripts/test.sh --filter 'MailpitModuleTests|ProjectServiceBindingsEndToEndTests'` with the environment required by the new tests and without concurrent SwiftPM invocations.
5. Run `Scripts/tests/val-project-service-bindings-test.sh`. Require successful activation for multiple aliases, exact identity/health, claim inventory, down/re-up, release-only singleton behavior, `.env` byte preservation, and clean child/Core shutdown. Preserve logs/evidence.
6. If a generated fixture root cannot be removed by automatic review, do not retry deletion via another command. Verify its child process and ports are stopped, retain it, and document the exact path.
7. Rerun the full focused feature suite:
   `Scripts/test.sh --filter 'ServiceInstanceCatalogTests|ProjectReconciliationTests|DispatcherTests/testProjectActivationStartsOneMailpitForMultipleAliasesAndReusesIt|M13AuthoritySurfaceTests|ProjectAdoptionCLIParsingTests|ServiceInventoryOutputTests|MailpitModuleTests|ProjectServiceBindingsEndToEndTests'`
8. Request one fresh, read-only Sol review of the final feature and Mailpit identity fix. Do not launch a reviewer panel.
9. Update the feature TODO and lifecycle roadmap only with verified results. Recheck the native Settings fixture evidence if the diff changed UI behavior.
10. Run pstack deslop before any commit. The user authorized a commit once acceptance closes; stage only the coherent feature files, and leave unrelated dirty work untouched. If existing mixed changes prevent a safe scoped commit, explain that instead of committing unrelated hunks.

## Known preserved temporary evidence

The first failed acceptance left its exact root at `/private/tmp/vpsb-24ED8B19` because deletion was rejected by automatic safety review. Its exact Mailpit process (PID 94041) was verified from its fixture process record and `lsof`, terminated with SIGTERM, and checked absent with both ports closed. A later interrupted run left `/private/tmp/vpsb-396C01D0`; exact Mailpit PID 95330 was confirmed from its process record and `lsof`, terminated with SIGTERM, and both fixture ports were verified closed. That root is preserved. The interrupted unit run also left unique Python shebang fixtures identified by their exact `/var/folders/.../vaelen-mailpit-owned-UUID/` arguments and their two listening ports; those exact fixture processes were stopped by PID. One had its generated `resist-term` sentinel removed so its signal handler could exit cleanly. No broad cleanup was attempted. Earlier failure evidence is in `artifacts/verification/project-service-bindings-20261026T201015Z-93677/` and `.audit/test-failures/swift-test.hPlpMR`.

## Goal boundary

This feature slice closes only existing default MySQL/Mailpit project bindings. It does not complete the broader Herd-replacement goal, which still includes further database setup/import, package/update recovery, and installed-app acceptance work.
