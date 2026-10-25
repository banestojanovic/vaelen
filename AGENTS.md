# Vaelen agent instructions

## Pstack in Codex

Use the installed pstack plugin's Codex mapping at `docs/harness/codex.md` relative to its plugin root. Use Codex's native `spawn_agent` and `wait_agent` tools for pstack delegation.

Do not create explorer or verification subagents automatically. Implementation and review subagents are created only as the Codex model routing below describes.

### Model routing

- The lead chat designs and judges. A cheaper model writes routine code. The lead uses `gpt-6.1-sol` for planning, architecture, and judgment.
- The lead owns the plan, data shape, test list, review of every diff, and the real-surface check. It does not write a feature, bug fix, or refactor implementation.
- All routine code implementation, including features, refactors, UI polish, and bug fixes, goes to one fresh `pstack:poteto-agent` subagent on `gpt-6-luna` with medium reasoning. Pass `model: gpt-6-luna` and `reasoning_effort: medium` explicitly.
- Sol writes implementation only when the lead judges the bug genuinely difficult and high-risk, such as a subtle data-loss, security, or concurrency defect that exceeds a scoped Luna fix. Merely touching SQLite, package lifecycle, IPC, DNS/TLS, routing, or privileged-system code does not automatically route implementation to Sol. Sol remains the model for planning, architecture, bottleneck investigation, and independent review. Pass `model: gpt-6.1-sol` and `reasoning_effort: medium` explicitly when Sol implementation is justified.
- The delegate's brief gives file paths, the named data shape, tests to write first, commands to run, and clear completion criteria. The delegate does not commit.
- The lead reads the full diff, reruns focused tests itself, and checks the real surface. For bounded CLI and Core changes, follow `.agents/skills/verify-vaelen/SKILL.md` and its affected feature recipe. For an app UI change, run the app and inspect the changed flow. A fix round goes to a fresh delegate with the previous report and review findings.
- The lead edits implementation inline only when the change is a few lines in one file. The lead may edit tests, docs, and configuration inline.
- Review uses one fresh, read-only Sol subagent that did not write the change. Use additional reviewers only for a genuinely complex integration or a major bottleneck where independent opinions materially reduce risk. State that reason before creating a panel and use the smallest panel that can address it. The lead judges the findings.

### Tests

Run tests through `Scripts/test.sh`. It keeps successful output quiet and retains the full log only when a run fails.
