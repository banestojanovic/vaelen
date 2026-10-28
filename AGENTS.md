# Vaelen agent instructions

Read `docs/HANDOFF.md`, this file, and the relevant section of `docs/NEXT-PLAN.md` at the start of a task. `docs/ARCHITECTURE.md` owns product boundaries. Preserve unrelated user changes; inspect `git status` before editing and stage only files belonging to the task.

For queue work, invoke the shared workflow through `/shift N` in Claude Code or the `$shift` skill in Codex. `/auto-shift N` and `$auto-shift` run the unattended Claude-session loop; it requires the Claude CLI.

## Execution

Use the workflow in `docs/WORKFLOW.md`. One writer per checkout; do routine work in the current context. Do not fan out work or create explorer/verification agents automatically. A feature, refactor, or bounded bug fix gets one focused loop and self-review. Use exactly one fresh, read-only independent reviewer only for risky persistence, migration, recovery, export, process ownership, privileged system changes, or subtle concurrency work. Multiple reviewers are an exceptional measure for a genuinely complex integration or major bottleneck; explain the concrete reason first.

Never push, release, sign, modify credentials, or make privileged changes unless the user authorized that action. Do not run installed-app mutation helpers without a task that authorizes those effects. Preserve project data and user changes. Tests and verification use disposable fixtures. Do not clean unknown temporary or harness paths without inspecting their contents and ownership first.

## Vaelen verification

- Run focused Swift tests through `Scripts/test.sh --skip-update --disable-automatic-resolution --filter <SuiteOrTest>`.
- Run `Scripts/test.sh` once before each code commit. The wrapper keeps successful output quiet and retains failure logs under `.audit/test-failures/`.
- Use `.agents/skills/verify-vaelen/SKILL.md` and its affected feature recipe for bounded CLI/Core changes. Retain evidence and state simulated or unverified boundaries.
- For native app UI changes, use `.agents/skills/verify-vaelen-app/SKILL.md` with isolated Debug fixtures. For DNS lifecycle changes, use `.agents/skills/verify-dns-lifecycle/SKILL.md`.
- Run `git diff --check` and review the complete task diff before committing. A green test or build proves only the exercised behavior.

## Product and data guardrails

Vaelen is a native macOS PHP development environment and project runtime. Keep macOS conventions, reversible operations, clear ownership, and explicit consent for project or system changes. Do not rewrite project files, alter global services, trust certificates, DNS, firewall rules, ports, or installed app state without the feature's explicit user-facing action and authorized verification. Prefer exact identities and ownership checks; failed cleanup or recovery must preserve uncertain state.
