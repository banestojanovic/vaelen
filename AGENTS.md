# Vaelen agent instructions

## Pstack in Codex

Use the installed pstack plugin's Codex mapping at `docs/harness/codex.md` relative to its plugin root. Use Codex's native `spawn_agent` and `wait_agent` tools for pstack delegation.

Do not create explorer or verification subagents automatically. Implementation and review subagents are created only as the Codex model routing below describes.

### Model routing

- The lead chat designs and judges. A cheaper model writes routine code. The lead uses `gpt-6.1-sol` for planning, architecture, and judgment.
- The lead owns the plan, data shape, test list, review of every diff, and the real-surface check. It does not write a feature, bug fix, or refactor implementation.
- Routine implementation goes to one fresh `pstack:poteto-agent` subagent on `gpt-6-luna` with medium reasoning for features, bugs, UI polish, and refactors. This project override keeps code-writing on the cheaper model even where the global Codex `bug-fix` row selects Sol. Pass `model: gpt-6-luna` and `reasoning_effort: medium` explicitly.
- High-risk implementation goes to one fresh `pstack:poteto-agent` subagent on `gpt-6.1-sol` with medium reasoning. High-risk areas include SQLite state and migrations, route or resolver ownership, DNS/TLS and privileged system changes, PHP package lifecycle and possible data loss, concurrency, IPC compatibility, and the privileged helper. Pass `model: gpt-6.1-sol` and `reasoning_effort: medium` explicitly.
- The delegate's brief gives file paths, the named data shape, tests to write first, commands to run, and clear completion criteria. The delegate does not commit.
- The lead reads the full diff, reruns focused tests itself, and checks the real surface. For bounded CLI and Core changes, follow `.agents/skills/verify-vaelen/SKILL.md` and its affected feature recipe. For an app UI change, run the app and inspect the changed flow. A fix round goes to a fresh delegate with the previous report and review findings.
- The lead edits implementation inline only when the change is a few lines in one file. The lead may edit tests, docs, and configuration inline.
- Review uses fresh, read-only subagents on the models configured for `interrogate reviewers` in the global Codex `pstack-models.md`. The lead judges their findings.

### Tests

Run tests through `Scripts/test.sh`. It keeps successful output quiet and retains the full log only when a run fails.
