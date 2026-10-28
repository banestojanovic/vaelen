# Workflow (Claude Code and Codex)

One small loop, one writer per checkout, short handoffs. `AGENTS.md` wins on any conflict. This adapts the Yuva shift workflow to Vaelen's CLI, Core, macOS app, and isolated verification recipes.

## Roles

| Role | Claude Code | Codex | Does |
|---|---|---|---|
| Coder | Sonnet, medium | Luna, medium | Owns one item end to end. Routine work stays in this context; no subagents. |
| Reviewer | Opus, medium | Sol, medium | Exactly one fresh, read-only review for risky changes only. |

Risky changes are persistence/schema migration, recovery, project file writes, export, process ownership, privileged system changes, and subtle concurrency. Everything else gets the coder's own checklist review. Multiple reviewers are only for an exceptional integration or bottleneck where independent opinions materially reduce risk; explain why before adding any.

## Queue

The queue is `docs/NEXT-PLAN.md` plus the **Next** line in `docs/HANDOFF.md`. The owner assigns a goal by naming it or saying `/shift N` (Claude) or “run a shift of N” (Codex). Default N is 3; any nonnumeric argument is one named goal. Work bugs first, then the next unfinished queue item with acceptance criteria. Do not treat historical `.audit/` notes as approved feature scope; use them as investigation sources only. Never infer permission for system or installed-app mutations from a queue entry.

## Loop (per item)

1. Inspect `git status`, branch and HEAD. Preserve all unrelated edits. Run the full `Scripts/test.sh` once at shift start when the checkout is clean enough to provide a meaningful baseline; do not overwrite or stage owner changes.
2. Read the concise handoff and relevant queue item. State the observable outcome and acceptance criteria in one or two lines.
3. Tests first. Use `Scripts/test.sh --skip-update --disable-automatic-resolution --filter <SuiteOrTest>` while working.
4. Before a code commit, run `Scripts/test.sh` once, the affected Vaelen fixture recipe, and `git diff --check`. For docs or configuration only, use focused checks and do not rerun an unrelated green full suite.
5. Review the exact diff yourself against the checklist below. Risky category: obtain one fresh read-only reviewer; correct valid findings and rerun affected checks. Do not create a second review round unless the correction itself introduces a risky change.
6. Commit one item at a time, staging only its files. Never push unless the owner authorized it. Rewrite the Current block in `docs/HANDOFF.md` after each commit.
7. Continue to the next item or stop at N, two failed attempts on one test, an unresolved blocker, or an owner decision that is required for safe user-visible or irreversible work.

## Self-review checklist

- No unrelated source, project data, preferences, credentials, or user changes were included.
- Ownership and failure paths preserve uncertain state; cleanup only removes resources proven to be owned.
- Tests cover the changed behavior and meaningful failure paths, not only the happy path.
- Native claims are supported by the relevant isolated app or CLI/Core fixture; simulated, manual, and unverified boundaries are named.
- No installed app, real project, shared service, DNS, TLS trust, firewall, or port state was mutated without authorization.

## Keeping checks and context bounded

Use `Scripts/test.sh`; successful output is summarized and failed logs are retained in `.audit/test-failures/`. Never paste raw logs; inspect only relevant failure excerpts. Follow `.agents/skills/verify-vaelen/SKILL.md` for bounded CLI/Core changes, `.agents/skills/verify-vaelen-app/SKILL.md` for native UI changes, and `.agents/skills/verify-dns-lifecycle/SKILL.md` for DNS ownership transitions. Do not claim an installed-app workflow from a fixture-only check.

Claude's context guard is configured in `.claude/settings.json`; it warns at 150k tokens and requests a handoff at 200k and every 50k after. Codex has no equivalent project hook here; write a handoff at each milestone and stop before context obscures the state.

## Unattended shifts

`/auto-shift [rounds]` or `Scripts/auto-shift.sh [rounds]` starts one fresh Claude `-p` `/shift 1` session per item (default 5 rounds). It reports progress to the nearest Rex terminal when available without opening tabs. It stops on STOP, failure, no new commit, a report without CONTINUE, or the round limit. It never pushes. The command allowlist is intentionally bounded; native driving and installed-app mutation are excluded. Logs go to `~/.cache/vaelen-shift`. Do not run unattended shifts while another writer is editing this checkout.

## Handoff block

Keep `docs/HANDOFF.md` under about 60 lines and replace its Current block after each commit; do not append a transcript. Move lasting historical findings to a dated archive only when needed. A new agent reads `docs/HANDOFF.md`, `AGENTS.md`, `docs/NEXT-PLAN.md`, and the relevant verification recipe.

```text
Updated <date> by <tool/model>.
Done: <item>, commit <hash>.
Checked: <commands and outcomes>; native: <none | what>.
Unverified: <coverage limits>.
Next: <item and first step>.
Traps: <specific recovery or safety notes>.
```

## Owner decisions

If a decision is not needed to make safe progress, record a recommended default and status `pending` in the owning plan and continue reversible spec, parser, or test work. Do not ship user-visible behavior or irreversible work that depends on an unconfirmed decision. Ask one concise, batched question when the answer is required.
