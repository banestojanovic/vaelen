# pstack model configuration

OpenCode2 2.0.32 project overrides. Model IDs were checked in this project's live model catalog. The exact `Muse Spark 1.3 Free` model was absent, so there is no worker model fallback configured. OpenCode2 has no automatic provider-error fallback setting. A Sol judgment failure returns to the Luna parent for recovery; a Luna worker failure stops unless the parent can safely reconcile and continue on Luna.

feature, refactoring: openai/gpt-6-luna @medium
bug-fix: openai/gpt-6-luna @medium
perf-issue: openai/gpt-6.1-sol @medium
hillclimb: openai/gpt-6.1-sol @medium
judgment and prose: openai/gpt-6.1-sol @medium
strongest judgment: openai/gpt-6.1-sol @medium
how explorer: openai/gpt-6-luna @medium
how explainer: openai/gpt-6.1-sol @medium
why investigators: openai/gpt-6-luna @medium
why synthesizer: openai/gpt-6.1-sol @medium
reflect tooling: openai/gpt-6-luna @medium
reflect judgment, divergent, synthesizer: openai/gpt-6.1-sol @medium
arena runners: openai/gpt-6-luna @medium
arena cross-judge pool: openai/gpt-6.1-sol @medium
swarm workers: openai/gpt-6-luna @medium
architect runners: openai/gpt-6.1-sol @medium
interrogate reviewers: openai/gpt-6-luna @medium

default effort: medium
