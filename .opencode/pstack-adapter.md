# pstack on OpenCode2

Upstream: `cursor/plugins@0b8e952052d482ee6de06deebf14d590d77b1b34`,
pstack `0.15.26` (MIT). `Scripts/vaelen-agents bootstrap` materializes this exact
revision in ignored `.build/agent-tools/pstack`; it does not install a JavaScript
OpenCode plugin, alter global configuration, or touch authentication.

This adapter supplements `.opencode/instructions/vaelen.md`. The current user's
instructions and Vaelen ownership/preservation rules override upstream autonomy,
automatic PR/commit/push, screenshots, and cloud defaults. Existing `vaelen-pm`
remains the sole installed-product operator. The orchestrator owns planning and
delegation; the named integrator alone owns integration writes.

## Native mapping

| Upstream Cursor concept | OpenCode2 mapping |
| --- | --- |
| `/poteto-mode` and routed skills | Read `.build/agent-tools/pstack/pstack/skills/poteto-mode/SKILL.md`, then the selected playbook and referenced skills. No invented slash commands. |
| `Task` for read-only investigation | OpenCode2 2.0.32 native `subagent` tool with `agent: vaelen-reviewer`, `description`, and `prompt`; include complete scope and report shape. |
| `Task` for a code writer | `Scripts/vaelen-agents create`, then `launch --execute`; a separate native `opencode2 run --standalone --agent vaelen-worker` process with a private server in that unit's worktree. Task has no working-directory/worktree parameter. |
| `poteto-agent` | `vaelen-worker`, which reads this mapping and the relevant upstream playbook. |
| Independent verifier | Fresh `vaelen-reviewer` task; or `launch --role reviewer --execute` in the unit checkout when isolated tests are required. It must not be the implementation session. |
| `environment: cloud`, `cloud_base_branch` | Local Git worktree at a named committed base. Vaelen needs macOS/Xcode; no claim of cloud parity. |
| `run_in_background` | Separate run managed by the helper; `collect` ingests completion receipts. Native subagent background behavior follows the actual tool schema only. |
| Model defaults / `/setup-pstack` | Omit model fields and `--model`; use current configured OpenAI model. Never invent Grok/Claude entitlement. Different-model review is optional only when independently authorized and available; disclose same-model review. |
| AskQuestion / TodoWrite | Native question/todowrite when available; otherwise concise questions and durable task state. |
| Cursor store / `orch` | Ignored `.build/agent-orchestration/<program>/board.json`, briefs, run receipts, exact-SHA ledger, handoff. Helper handles bookkeeping, not reasoning. |
| Bugbot, Cursor Automations, Cursor cloud UI, Cursor computer-use | Unavailable here. Name the omitted capability. Use existing local harness only when appropriate and PM-owned. Never fabricate Cursor API calls. |

The installed CLI accepts the legacy `task` permission key and normalizes it
to the `subagent` permission action. Local agent discovery verified the
reviewer allowlist and deny-all rules. Tool calls themselves use the actual
`subagent` schema; do not invent a `subagent_type` or worktree field.

## Execution contract

Keep the full workflow: coordinator -> scoped workers in separate worktrees ->
independent review/verification -> one integration owner. Read upstream
`playbooks/orchestrate.md` for multi-day programs; smaller work still delegates
implementation using the matching feature/bug playbook. Pilot a real unit before
fan-out. Keep a rolling window (default three concurrent workers), refill on
completion, and route upstream facts into downstream briefs. No same-checkout
parallel writers. Arena experiments get separate units and worktrees too.

Every brief must contain GOAL, SCOPE, CONTEXT, ACCEPTANCE, VERIFY, TIMEBOX,
FORBIDDEN, REPORT, and STANDING sections. Scope lists literal owned file/directory
paths, never glob patterns; acceptance is
observable; verification names focused commands. Include dependency reports and
the authoritative base SHA. Workers cannot see sibling conversations.

Coordinator edits no product source. It may use the helper to create worktrees,
write briefs/state, inspect outcomes, and delegate. Reviewer edits no source.
Worker writes only its assigned worktree/scope, never canonical `dev` or sibling
paths. Shell permission is not a filesystem sandbox: independently check scope.
All roles avoid secrets and inherited auth stores. Helpers do not read them.

Use focused tests, incremental builds, and manual visual review. No full suite,
routine screenshots/videos, live CLI/app operations, or signed installation in
workers. PM alone schedules any necessary installed validation and releases the
existing exclusive operation slot afterward. Worktrees do not isolate the live
database, services, ports, TLS, or installed app.

Commit permission is not implied by delegation. Workers return uncommitted work
when no commit approval exists; independent review can inspect it, but the helper
will not issue a passing exact-SHA receipt for a dirty tree. After an explicitly
authorized snapshot commit, verify that immutable SHA. Only the named integrator
lands verified commits; publishing/tagging/force-push need separate authorization.
A new commit or changed integration result invalidates previous verification.

Do not treat exit code zero, reviewer agreement, or a ledger row as product
acceptance. Record exact checks and remaining uncertainty. Human acceptance is
separate. The helper's integration command is fast-forward-only; non-linear work
goes to the integrator for explicit reconciliation and fresh verification.

## Resuming and switching engines

Run `status` and `handoff` before stopping. Retain briefs, branches, exact heads,
actual tests, failures, and runtime-slot ownership. A new session reconstructs
from these files and Git, not presumed transcript access. Do not resume an idle
worker merely to query status. Inspect its receipt; stale/missing receipts mean
unknown, not success. No automatic killing or pruning of unknown sessions.

OpenCode and OpenCode2 use the existing project configuration unchanged. Future
Cursor uses the same pinned upstream `pstack` directory with its native loader;
Claude Code uses upstream's generated `harness/pstack` plugin and
`docs/harness/claude-code.md`. Their tool/model adapters differ; branches, briefs,
checks, and exact-SHA receipts remain transferable. Keep credentials and billing
native to each engine; never copy OAuth tokens between tools.
