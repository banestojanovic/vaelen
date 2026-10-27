# Handoff: MySQL and Mailpit project bindings

## Status

The MySQL and Mailpit project-binding slice passed focused acceptance and one independent Sol review. It was committed in `257341c` as part of the adopted project environment lifecycle. The global pstack model routing and project sync command were committed separately in `5f45e12`. The larger Herd-replacement goal remains active.

V2 projects can claim only the exact installed default MySQL or Mailpit instance observed by Core. Project activation validates package identity and health. Multiple aliases share one instance. Project down releases project ownership and leaves these legacy singleton processes running. Package removal is blocked while a project claim exists. The native Settings flow and CLI report the same exact binding without exposing secrets.

## Verification

The parent run passed:

- `Scripts/test.sh --scratch-path /private/tmp/vaelen-mailpit-identity-review-fix-r2-20261027 --parallel --num-workers 1 --filter 'MailpitModuleTests|ProjectServiceBindingsEndToEndTests|DispatcherTests/testProjectActivationStartsOneMailpitForMultipleAliasesAndReusesIt'`
- `Scripts/tests/val-project-service-bindings-test.sh`, evidence in `artifacts/verification/project-service-bindings-20261027T061517Z-64023/`
- `git diff --check`

The private-Core journey invoked the built `val` child. It verified project up/down/up for two Mailpit aliases, exact catalog ownership, unchanged `.env` bytes, unchanged installed Mailpit executable bytes, and fixture cleanup. No test processes remained afterward.

A live Debug Settings run verified the exact Mailpit binding, explicit start, refreshed satisfied plan, project-only claim release, and the same healthy Mailpit process after release. Its record is `artifacts/verification/project-mysql-mailpit-settings-20261027/result.txt`.

One fresh read-only Sol review found two defects. `identityCommand` now waits for process exit and stdout EOF, returns within a bounded timeout, and retains its Process and pipe reader until the termination callback can clean them up. The Mailpit unit and dispatcher tests now stop their exact owned service before removing fixture roots. The same reviewer found no remaining issue in the final change. The forced post-SIGKILL timeout branch was not directly induced because a local process cannot reliably reproduce an unreapable kernel state.

## Limits and next work

This slice does not create named MySQL or Mailpit instances, initialize MySQL, create databases or users, or migrate database contents. It does not close the Herd-replacement goal.

The PostgreSQL lifecycle XCTest fixture no longer assumes a machine-specific package path. It skips package-dependent tests when the package root is unset, errors on an explicitly invalid path, and verifies owned services are stopped before deleting fixture roots. Parent runs passed both without the package (with expected skips) and with the extracted PostgreSQL 18.6 package; one read-only Sol review found no findings. This isolated fixture correction is tracked separately from the feature commit.

Next, verify service ownership and runtime recovery after Core restart for MySQL, Mailpit, PostgreSQL, and Valkey. Then define and test data-safe backup, restore, update, and removal behavior. Complete the signed installed-app adoption-to-working-site journey and the package provenance, legal, signing, repeatability, and macOS 14 release gates.

The canonical checkout remains dirty with unrelated work. Preserve it. Stage only the coherent feature files for the authorized commit. Do not reset, stage broadly, or remove the preserved failure roots recorded in the historical handoff.
