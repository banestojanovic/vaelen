---
name: shift
description: Work the next N Vaelen queue items using the one-writer workflow in docs/WORKFLOW.md. Use for /shift, /shift 3, a named goal, or "work the queue".
---

Run `docs/WORKFLOW.md`. Read `AGENTS.md`, `docs/HANDOFF.md`, and the relevant item in `docs/NEXT-PLAN.md` first. Argument N (default 3) means that many queue items; any other text is one named goal.

Rules:
- Work directly in this context as the single writer. No fan-out or routine subagents.
- Exactly one fresh, read-only reviewer only for the risky categories in the workflow. Do not add a panel except for a genuinely exceptional integration or bottleneck, and explain why first.
- Tests first. Use focused checks while working and the full suite once before each code commit. Use the Vaelen verification skill for the changed surface.
- Preserve unrelated edits and stage only the item. Do not push unless the owner authorized it.
- Never mutate installed app state, real projects, shared services, DNS, TLS trust, firewall or ports without authorization.
- Stop at N, after two failed attempts at one test, or when blocked on an owner decision. Rewrite the Current block after each commit.
- End with at most six lines: done, commits, checks, unverified, next, and effort.
