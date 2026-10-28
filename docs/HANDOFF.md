# Agent handoff

Read the Current block, then `AGENTS.md`, `docs/NEXT-PLAN.md`, and the relevant verification skill. Preserve unrelated working-tree changes and inspect the branch before writing.

## Current

Updated 2026-10-28 by Codex.
Done: Ported Yuva's single-writer shift and auto-shift workflow to Vaelen; replaced project-local agent-routing setup and added Vaelen-specific verification rules. Commits `e2d6760`, `950ace2`.
Checked: `bash -n Scripts/auto-shift.sh`, Python syntax parse for the context guard, JSON parse for Claude settings, `git diff --check`; all passed. Rex progress reporting added to auto-shift and is syntax-checked; no product tests apply.
Unverified: Auto-shift was not launched; no Vaelen product behavior changed.
Next: If no further unblocked storage candidates remain, resume the service lifecycle recovery priority; inspect the current code/test diff and `.audit/project-service-environments.todo.md`, then run focused lifecycle fixtures.
Traps: `.audit/` contains active TODOs. Cleanup already reclaimed about 9.2 GiB of Swift builds, removed Vaelen DerivedData and generated verification records, and removed 10 Python bytecode cache files. `~/Library/Caches/com.apple.python/private/tmp` is now empty. About 49 GiB is available.

Remaining storage items, inspected 2026-10-28:
- `~/Library/Application Support/Vaelen-dev-harness` is 5.2 GiB. It holds 16 dated updater runs, each with a `state-v8-before.sqlite` registry snapshot (six or seven project records), run evidence, and old `app-before.app` copies; one run also has `legacy-system-app.app`. Five previous-app backups are in `legacy-application-backups/`. No Vaelen processes were running. Removing the old app copies was rejected by automatic review (`rm -f style commands are not permitted`). Preserve the registry snapshots; do not retry this deletion through another method.
- `/Users/banes/.codex/worktrees/vaelen/service-data-backup-recovery-fixtures` is 143 MiB of PostgreSQL/Valkey fixture packages and logs. Removal was rejected in the same cleanup review; do not retry by another method.
- `.audit/test-failures/` retains about 1.9 MiB of Swift failure logs. Their removal was rejected with the fixture cleanup; preserve and do not retry by another method.
- Previously inspected `/private/tmp` paths remain: 779 MiB `vaelen-recovery-build-20261028`; 774 MiB `vaelen-db-badge-build`; 766 MiB `vaelen-dbprov-settings-build`; seven `vaelen-dbprov-*` build roots at about 190 MiB each (`E0F53AAA-DAFF-4090-9470-8E195BCA1106`, `DF7D03A8-3AF8-4533-9517-596BCD0348FB`, `926D17EC-19E5-47A4-B31F-3FBB6D9A2577`, `80CA47AD-16D0-4899-8DAA-119F08954FF0`, `463CD272-02F5-40C4-8497-F7AD5A4E2D92`, `23E41923-7948-4C57-8B48-FDFF095E8C62`, `1A6EDA7D-91E6-4620-8272-5F437DA87CF4`); and 71 MiB `vaelen-laravel-boot-probe.6cgu9y`. Earlier review blocked this private-temp cleanup; do not retry those paths through another command.

## Standing

- Work one item at a time and keep one writer per checkout.
- Full product tests: `Scripts/test.sh`; focused tests: `Scripts/test.sh --skip-update --disable-automatic-resolution --filter <SuiteOrTest>`.
- Keep verification evidence and state simulated or unverified coverage explicitly.
- Do not mutate an installed app or real project without specific authorization.
