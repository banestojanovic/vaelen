---
name: shift
description: Run the next N Vaelen work-queue items using the project handoff and one-item workflow. Use for /shift, $shift, "run a shift of N", or one named goal.
---

Follow `docs/WORKFLOW.md`. At the start, read `docs/HANDOFF.md`, `AGENTS.md`, and the relevant item in `docs/NEXT-PLAN.md`; inspect branch, HEAD, and the full working-tree status before editing.

Argument N (default 3) means that many queue items. Any other argument is one named goal. Work directly in this Codex context as the single writer. Do not create routine subagents. Use exactly one fresh, read-only Sol reviewer only for the risky categories listed in `docs/WORKFLOW.md`; extra reviewers are exceptional and require a stated complex integration or bottleneck.

For each item, state the outcome and acceptance criteria, add or update focused tests first, implement within scope, run the focused check and required full check before a code commit, and review the complete diff. Preserve unrelated edits and stage only the item. After every commit, rewrite the Current block in `docs/HANDOFF.md` using the format in `docs/WORKFLOW.md`, including checks, limits, and the next concrete step. Never push unless the user authorized it.

Stop at N items, after two failed attempts at one test, or when a required owner decision or external blocker prevents safe progress. End with at most six lines: done, commits, checks, unverified, next, effort.
