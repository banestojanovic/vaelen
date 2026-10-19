# pstack model configuration for OpenCode2

Native agent models enforce these choices. OpenCode2 subagent calls select an agent ID, not a model argument. Foreground subagent results return to the calling parent. Use the published skills with native runtime tools. This project sheet overrides Claude defaults only for OpenCode2.

feature, refactoring: openai/gpt-6-luna
bug-fix: openai/gpt-6.1-sol
perf-issue: openai/gpt-6.1-sol
hillclimb: openai/gpt-6.1-sol
judgment and prose: openai/gpt-6.1-sol
strongest judgment: openai/gpt-6.1-sol
how explorer: openai/gpt-6-luna
how explainer: openai/gpt-6.1-sol
why investigators: openai/gpt-6-luna
why synthesizer: openai/gpt-6.1-sol
reflect tooling: openai/gpt-6-luna
reflect judgment, divergent, synthesizer: openai/gpt-6.1-sol
arena runners: openai/gpt-6.1-sol, openai/gpt-6.1-sol, openai/gpt-6.1-sol, openai/gpt-6.1-sol
arena cross-judge pool: openai/gpt-6.1-sol
swarm workers: openai/gpt-6-luna
architect runners: openai/gpt-6.1-sol, openai/gpt-6.1-sol, openai/gpt-6.1-sol, openai/gpt-6.1-sol
interrogate reviewers: openai/gpt-6-luna, openai/gpt-6-luna, openai/gpt-6-luna, openai/gpt-6-luna

default effort: session

Fresh independent review uses vaelen-reviewer on Luna. Panels have reduced model diversity and do not count repeated model entries as diverse families. Do not invent model or effort parameters. Required unavailable panels stay blocked. Sol makes architecture and difficult decisions in the parent. This minimal workflow does not configure nested Sol panels.
