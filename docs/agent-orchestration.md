# Vaelen agent orchestration

Use OpenCode2 with the existing OpenAI provider/login. This adds project-local
orchestration without changing `opencode.json`, the default PM, credentials,
global plugins, or subscription routing. Both installed CLI names report
2.0.32; commands below use `opencode2`. No Cursor subscription is needed.

The workflow is pstack's coordinator, isolated implementation owners,
independent verification, and a single integration owner. It retains the full
workflow rather than only borrowing three skills. Upstream's current tool names
and cloud defaults are adapted to Vaelen's actual native Mac environment.

## Roles

| Agent | Responsibility |
| --- | --- |
| `vaelen-orchestrator` | Frame work, read upstream playbooks, scope units, delegate, drain a rolling queue, maintain handoffs. No product source edits. |
| `vaelen-worker` | Own one bounded implementation in a separate Git worktree. Run focused isolated checks. |
| `vaelen-reviewer` | Independently inspect/verify a unit. No source edits. Same-model review is disclosed. |
| `vaelen-integrator` | The PM-designated sole integration writer. Land only a clean verified head with authorization. |
| Existing `vaelen-pm` | Product decisions and exclusive installed-app/CLI/runtime validation slot. Unchanged. |

Agent definitions omit a fixed model. Native subagents inherit the invoking
model; separately launched sessions use existing project model configuration.
No script sets API keys, switches provider, reads auth files, or adds paid
models. Existing ChatGPT/OpenAI integration remains as configured. Parallel
sessions consume that account's applicable usage; they are not free workers.

## Bootstrap and start

From the designated integration checkout:

```sh
./Scripts/vaelen-agents bootstrap
opencode2 --standalone --prompt 'Use vaelen-orchestrator for this task. Read .opencode/pstack-adapter.md first.'
```

Select `vaelen-orchestrator` in the interface, or use the explicitly selected
headless entry when desired:

```sh
opencode2 run --standalone --agent vaelen-orchestrator 'Read .opencode/pstack-adapter.md. Plan and delegate the requested feature; keep commits and installed operations approval-gated.'
```

Bootstrap fetches only the pinned Git revision
`0b8e952052d482ee6de06deebf14d590d77b1b34`, verifies the checked-out SHA and
plugin version `0.15.26`, and preserves unexpected dirty upstream state.
Files live in ignored `.build/agent-tools/pstack`. This is not `opencode plugin
add`: that command expects OpenCode JavaScript plugins, not a Cursor manifest.
Bootstrap needs network but consumes no model usage.

The first prompt is read by the existing default agent unless the operator
selects the orchestrator. The headless `--agent` example selects it explicitly.
Do not assume a prompt silently overrides `default_agent`.

## One real unit, then a rolling queue

Commit the adapter and approved starting product snapshot before creating write
units, so every new checkout contains the agent definitions. No worker starts
until its committed base, write scope, acceptance, and focused verification
recipe are known. A pilot validates the complete path before fan-out.

```sh
./Scripts/vaelen-agents --program php-polish init --integration-owner vaelen-integrator --authorization commits-forbidden --window 3
```

The coordinator writes a brief under
`.build/agent-orchestration/php-polish/` with these sections:

```text
GOAL: One observable outcome.
SCOPE: Exact owned paths; forbidden paths; assigned unit.
CONTEXT: Source pointers and upstream unit reports; no sibling chat assumptions.
ACCEPTANCE: Observable behavior, failures, and preservation requirements.
VERIFY: Exact relevant commands using isolated state.
TIMEBOX: A bounded effort budget; return partial findings on expiry.
FORBIDDEN: No live services, commits without approval, publishing, broad cleanup.
REPORT: Branch, exact heads, changed paths, checks, verdict, gaps.
STANDING: Current user preferences and preservation/runtime-slot rules.
```

```sh
./Scripts/vaelen-agents --program php-polish create progress-copy --scope App/Vaelen/Vaelen/VaelenApp.swift --brief .build/agent-orchestration/php-polish/progress-copy.md
./Scripts/vaelen-agents --program php-polish launch progress-copy
./Scripts/vaelen-agents --program php-polish launch progress-copy --execute
./Scripts/vaelen-agents --program php-polish wait
./Scripts/vaelen-agents --program php-polish status
./Scripts/vaelen-agents --program php-polish status --human
```

The default `status` output remains JSON. `status --human` prints the program,
integration owner, concurrency window, and each unit's observed state and next
action. Missing observations stay `Unknown`; a unit without a recorded run says
`Not started`. The empty queue says `no units yet`.

Read the selected pinned playbook at
`.build/agent-tools/pstack/pstack/skills/poteto-mode/playbooks/feature.md`.

`create` makes a branch and worktree in ignored `.build/agent-worktrees` from
an exact committed base. Scopes are literal repository-relative file/directory
paths; glob patterns are rejected so overlap checks remain reliable. It refuses
duplicate units, invalid briefs, path escapes, and overlapping unfinished scope.
It does not modify the integration
index or checkout. The scope audit later checks committed and uncommitted
changes, including untracked files.

`launch` is a preview unless `--execute` is present. Execution uses an actual
separate `opencode2 run --standalone --agent vaelen-worker` process, with its cwd
fixed to that worktree and a private server rather than an existing background
server's session/directory state. It never passes auto-approval or invents a native worktree flag.
The helper observes a bounded concurrent window and timebox. Output goes to
one per-run log and completion receipt. An expired run is terminated only
through the process group this runner created. No unknown sessions are killed.

`wait` is a foreground bounded collection operation. It waits for the next
receipt, reconciles the board, and returns control to the initiating coordinator
turn. A coordinator must use it rather than end its turn after dispatch.
`collect` is nonblocking. Process return means needs-review, never verified.
Worker and reviewer retries are counted separately and prior runs remain in the
ledger. Refill ready work as each unit completes; do not wait for the slowest
whole batch. Status also reconciles receipts so it cannot leave a completed run
marked running.

Read-only native `subagent` delegation is supported for investigation/review. Writers
must use separate sessions because the native `subagent` tool has no cwd/worktree
argument. Do not run write-enabled native subagents in the integration checkout.

## Independent verification and integration

Have a fresh `vaelen-reviewer` inspect the actual unit. For isolated tests:

```sh
./Scripts/vaelen-agents --program php-polish launch progress-copy --role reviewer
./Scripts/vaelen-agents --program php-polish launch progress-copy --role reviewer --execute
./Scripts/vaelen-agents --program php-polish collect
```

The board's explicit authorization is copied into each brief and role prompt.
Under `commits-forbidden`, no worker commits. Under
`task-local-commits-authorized`, scoped task-local commits are permitted. A
passing immutable receipt still requires a clean worktree and exact SHA. Put the
reviewer's actual source SHA and checks in a report, then record it using the
real SHA, not the placeholder below:

```sh
./Scripts/vaelen-agents --program php-polish record progress-copy --head EXACT_SHA --reviewer REVIEW_SESSION_ID --report /absolute/path/review.md --check 'actual focused command and outcome' --verdict unit-test-verified
./Scripts/vaelen-agents --program php-polish integrate progress-copy --owner vaelen-integrator
```

Only the named integration session uses `integrate ... --execute`, with the
board authorization. Clean independent commits can be integrated with an
explicit non-fast-forward merge, avoiding a fast-forward-only dead end. The
result remains `integrated-needs-check` until `accept-integration` records focused
checks and an exact combined SHA. Conflicts remain the integrator's explicit
decision. Push, tag, release, and publication are never authorized here.

Delegate this to a separate native session from the designated integration
checkout, rather than editing as coordinator:

```sh
opencode2 run --standalone --agent vaelen-integrator 'Read .opencode/pstack-adapter.md. You are the named owner for php-polish. Inspect the progress-copy exact-SHA receipt, preview integration, and land only with the explicit authorization supplied for this unit.'
```

This separate session uses the integration checkout intentionally; it is the
only product writer there. The coordinator remains read-only for product code.

The ledger is a local coordination record, not a security attestation. It cannot
prove that a human/agent report is honest, prevent a process from escaping its
cwd, enforce filesystem isolation, or measure acceptance by itself. Runtime
operation ownership still belongs exclusively to PM. Never use worktree
isolation as permission to run installed Vaelen, shared ports, or live data.

## Pause, handoff, and engine switching

```sh
./Scripts/vaelen-agents --program php-polish handoff
./Scripts/vaelen-agents --program php-polish abandon progress-copy --reason 'Stopped; preserve findings for a later unit'
```

Abandon only stopped non-integrated units; it preserves the branch/worktree.
There is no automatic worktree or build cleanup command. Missing receipts or
worktrees are uncertainty to investigate, not proof of success or safe deletion.

The durable board, briefs, exact heads, verification reports, and run receipts
remain under `.build/agent-orchestration/<program>/`. It is ignored local state:
back it up or summarize it into an approved tracked handoff before deleting
build storage or switching machines. Git contains committed source, not local
agent sessions. Handoff explicitly names the PM/runtime-slot state.

Keep OpenCode/OpenCode2 installed and their auth unchanged. Cursor can later
load the pinned upstream `pstack` directory with its native plugin loader;
Claude uses the pinned `harness/pstack` tree plus its supplied Claude adapter.
These are optional future paths, not installed by this helper. Model/tool
configuration differs, but the Git units and evidence transfer. Never copy
OAuth credentials between engines.

## Verification for this adapter

```sh
python3 Tests/AgentOrchestrationTests.py
```

These tests create disposable repositories and use a fake native CLI. They do
not consume model usage, alter real Git refs/index, build/install Vaelen, or
invoke its services. The approved read-only native delegation trial is recorded below. A real
implementation pilot remains necessary before scaling write workers.

References: [upstream pstack](https://github.com/cursor/plugins/tree/0b8e952052d482ee6de06deebf14d590d77b1b34/pstack),
[OpenCode agents](https://opencode.ai/docs/agents/),
[permissions](https://opencode.ai/docs/permissions/),
[CLI](https://opencode.ai/docs/cli/). The installed 2.0.32 `run --help` and
`api --help` are authoritative when website syntax differs.

## Initial setup evidence — 2026-10-18

- Pinned upstream bootstrap succeeded at the commit/version above.
- OpenCode2 2.0.32 local agent discovery recognized all four added roles.
- The eleven focused bookkeeping tests passed using disposable repositories and
  a fake CLI. The seven bundled-PHP preparation regressions also passed.
- After specific user approval for source access, a native coordinator run
  successfully called one separate `vaelen-reviewer` through OpenCode2's actual
  `subagent` tool. The reviewer inspected the PHP update decoder and returned a
  source-based report. Reviewed head: `4eeb959`.
- Coordinator session: `ses_eb1c308f3ffeQzxQ4xjfAghm19`; completed reviewer:
  `ses_eb1c2e23effeisJ5ZEAb6hIgLc`. The checkout remained clean after the trial.
  Local logs and a checksum-bearing result are under
  `.build/agent-orchestration/read-only-trial/`.
- Local discovery confirms legacy `task` permission keys normalize to
  `subagent` actions, preserving the configured allowlists and deny rules.
- A real implementation pilot and end-to-end agent integration remain to be
  verified. Read-only delegation and fixture tests do not establish those.
- No full Swift suite, installed-product update, live runtime operation, push,
  or tag was performed for this setup. Canonical dev and its local changes were
  preserved.
