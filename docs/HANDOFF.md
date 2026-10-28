# Agent handoff

Read the Current block, then `AGENTS.md`, `docs/NEXT-PLAN.md`, and the relevant verification skill. Preserve unrelated working-tree changes and inspect the branch before writing.

## Current

Updated 2026-10-28 by Codex.
Done: Ported Yuva's single-writer shift and auto-shift workflow to Vaelen; replaced project-local agent-routing setup and added Vaelen-specific verification rules. Commit `4159a1a`.
Checked: `bash -n Scripts/auto-shift.sh`, Python syntax parse for the context guard, JSON parse for Claude settings, `git diff --check`; all passed. No product tests run because this changes only workflow/docs/config.
Unverified: Auto-shift was not launched; no Vaelen product behavior changed.
Next: Resume the service lifecycle recovery priority; inspect its current code/test diff and `.audit/project-service-environments.todo.md`, then run focused lifecycle fixtures.
Traps: `.audit/` contains active TODOs. The cleanup tool rejected removal of retained failure logs and the orphaned service fixture directory; do not retry those paths using another deletion method. Private-temp harnesses remain too.

## Standing

- Work one item at a time and keep one writer per checkout.
- Full product tests: `Scripts/test.sh`; focused tests: `Scripts/test.sh --skip-update --disable-automatic-resolution --filter <SuiteOrTest>`.
- Keep verification evidence and state simulated or unverified coverage explicitly.
- Do not mutate an installed app or real project without specific authorization.
