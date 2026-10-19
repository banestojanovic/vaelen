# Native pstack workflow

The normal OpenCode2 TUI is the entry point. Use the installed pstack skills through the project's `skills` setting. Do not run nested OpenCode CLIs, detached agents, `Scripts/vaelen-agents`, another orchestrator, or unconfigured model IDs.

`vaelen-primary` owns each task’s delegation, result collection, verification, correction, and final reporting. GPT-6 Luna is the default, but the primary must honor the model selected for the active TUI session if the user changes it with the model picker. Report the actual model used. Keep small tasks direct. For a larger task, it may start two independent Luna workers with disjoint read-only scopes or isolated worktrees. Collect every child result before reporting completion. Do not use concurrent writers in one working tree.

Use `vaelen-judgment` on GPT-6.1 Sol Medium for architecture, ambiguity, and difficult decisions. The Luna parent is the approved recovery if that child fails. Workers and fresh reviewers use GPT-6 Luna Medium. `vaelen-reviewer` is read-only. Panels are reduced to one worker or reviewer by the model sheet.

OpenCode2 2.0.32 provides native `subagent` foreground and background calls. Use the direct tool. Background calls return a child session ID and notify the parent when complete; collect all results by waiting for each child. The default child nesting depth is one. Do not use `execute` as a substitute when its catalog does not expose `subagent`.

There is no configured automatic provider-error fallback. Do not invent a fallback key, silently switch models, or claim that provider availability proves fallback. `Muse Spark 1.3 Free` was not in the live catalog. If a call fails, report the actual model and last completed action. Before retrying any operation that might have changed state, inspect the repository or runtime and reconcile its result. If a Sol judgment call fails, Luna may make the decision. If a Luna worker or parent request fails, stop and report unless Luna can safely continue after reconciliation.

The local TUI plugin uses OpenCode's supported attention notification API once for a visible root-session completion, error, or required permission decision. Keep the final report in the parent session. Do not claim a notification unless the returned runtime event confirms it.

Routine project reads, edits, worktree creation, builds, and focused checks are allowed by the project policy. The reviewed Swift check is `swift test --filter VaelenCoreTests.ProjectSiteURLTests`; `swift build` is also allowed. Other shell commands require approval. Credentials, privileged actions, live Vaelen changes, publishing, pushes, destructive cleanup, and unrelated external paths stay approval-gated. Permission rules cannot infer semantic ownership, so use only paths assigned by the Luna parent.

Use only the current task's session IDs when exporting records. Confirm actual model IDs and parent relationships from OpenCode session exports, not agent self-reports. Never include credential files or unrelated session data in evidence.
