# Vaelen agent instructions

## Pstack in Codex

Use the installed pstack plugin's Codex mapping at `docs/harness/codex.md` relative to its plugin root. Use Codex's native `spawn_agent` and `wait_agent` tools for pstack delegation.

Do not create explorer or verification subagents automatically. Implementation and review subagents are created only as the Codex model routing below describes.

<!-- pstack-model-routing:begin -->
Pstack model defaults. Read `/Users/banes/.codex/pstack-models.md` before choosing a model or reasoning effort. Rerun `~/.codex/bin/pstack-sync-project --apply <project>` to refresh this block.
- `feature, refactoring`: `gpt-6-luna`
- `bug-fix`: `gpt-6.1-terra`
- `perf-issue`: `gpt-6.1-sol`
- `hillclimb`: `gpt-6.1-sol`
- `judgment and prose`: `gpt-6.1-terra`
- `strongest judgment`: `gpt-6.1-sol`
- `how explorer`: `gpt-6-luna`
- `how explainer`: `gpt-6.1-terra`
- `why investigators`: `gpt-6-luna`
- `why synthesizer`: `gpt-6.1-terra`
- `reflect tooling`: `gpt-6-luna`
- `reflect judgment, divergent, synthesizer`: `gpt-6.1-terra`
- `arena runners`: `gpt-6.1-sol @medium, gpt-6.1-sol @high, gpt-6.1-sol @xhigh, gpt-6.1-sol @max`
- `arena cross-judge pool`: `gpt-6.1-sol`
- `swarm workers`: `gpt-6-luna`
- `architect runners`: `gpt-6.1-sol @medium, gpt-6.1-sol @high, gpt-6.1-sol @xhigh, gpt-6.1-sol @max`
- `interrogate reviewers`: `gpt-6.1-sol @medium`
- `Default reasoning effort`: `medium`
- `Session hook`: `on`
Reviewer policy: use exactly one fresh, read-only reviewer by default. Multiple reviewers are reserved for genuinely exceptional, very complex integrations or major bottlenecks where independent opinions materially reduce risk. A configured panel or workflow example does not justify extra reviewers; state the concrete reason before adding any.
<!-- pstack-model-routing:end -->

### Model routing

- The lead uses Terra for scoped bug fixes, ordinary judgment and prose, and defined computer-use tasks. The lead uses Sol for architecture, strongest judgment, difficult correctness work, bottleneck investigation, and independent review.
- The lead owns the plan, data shape, test list, review of every diff, and the real-surface check. It does not write a feature, bug fix, or refactor implementation.
- Feature, refactor, and UI polish implementation goes to one fresh `pstack:poteto-agent` subagent on Luna with medium reasoning. Pass `model: gpt-6-luna` and `reasoning_effort: medium` explicitly.
- Scoped bug fixes go to one fresh `pstack:poteto-agent` subagent on Terra with medium reasoning. Pass `model: gpt-6.1-terra` and `reasoning_effort: medium` explicitly.
- Sol writes implementation only when the lead judges the bug genuinely difficult and high-risk, such as a subtle data-loss, security, or concurrency defect that exceeds a scoped Terra fix. Merely touching SQLite, package lifecycle, IPC, DNS/TLS, routing, or privileged-system code does not automatically route implementation to Sol. Sol remains the model for architecture, bottleneck investigation, and independent review. Pass `model: gpt-6.1-sol` and `reasoning_effort: medium` explicitly when Sol implementation is justified.
- The delegate's brief gives file paths, the named data shape, tests to write first, commands to run, and clear completion criteria. The delegate does not commit.
- The lead reads the full diff, reruns focused tests itself, and checks the real surface. For bounded CLI and Core changes, follow `.agents/skills/verify-vaelen/SKILL.md` and its affected feature recipe. For an app UI change, run the app and inspect the changed flow. A fix round goes to a fresh delegate with the previous report and review findings.
- The lead edits implementation inline only when the change is a few lines in one file. The lead may edit tests, docs, and configuration inline.
- Review uses one fresh, read-only Sol subagent that did not write the change. Use additional reviewers only for a genuinely complex integration or a major bottleneck where independent opinions materially reduce risk. State that reason before creating a panel and use the smallest panel that can address it. The lead judges the findings.

### Tests

Run tests through `Scripts/test.sh`. It keeps successful output quiet and retains the full log only when a run fails.
