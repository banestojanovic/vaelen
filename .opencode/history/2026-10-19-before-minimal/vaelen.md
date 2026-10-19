# Vaelen Shared Instructions

## Frozen Baseline

- M12 is frozen at `v0.0.13-m12`.
- Frozen commit: `e76e260b69b6b1e0216fdc8985ce13cfa4c79964`.
- ADR-0012 and all earlier accepted ADRs are authoritative.
- Do not casually reopen frozen architecture.
- Concrete implementation evidence may expose a defect or contradiction. Stop
  and report it rather than silently redesigning frozen architecture.

## Core Invariants

- Off means off.
- Installed does not mean running.
- Resource state must remain honest and observable.
- Privilege is a capability, not a runtime mode.
- Prove what Vaelen owns before destructive mutation.
- Core-managed services must not silently adopt external services.
- Persisted desired state and observed provider/runtime state are distinct
  sources of truth.
- Ambiguity and conflict fail closed.
- Do not infer provider/runtime state merely because persisted state says it
  should exist.
- Tests must coexist safely with live Vaelen through isolated ports, sockets,
  runtime directories, process ownership, and temporary state.
- Required product-path acceptance must use the actual supported product path.
- Internal diagnostic ports and paths cannot substitute for required public
  acceptance.

## Milestone Discipline

- Work only inside the explicitly authorized active milestone.
- Do not expand scope opportunistically.
- Do not refactor unrelated code or introduce speculative abstractions.
- Prefer the smallest mechanism satisfying proven requirements.
- Implementation success does not freeze architecture.
- ADR and release freeze occur only after explicit acceptance.
- Task-scoped local branch creation and commits may proceed when the current
  task authorizes them. Inspect the entire staged path list first. Stage only
  owned paths and use a path-limited `git commit --only` to preserve unrelated
  staged changes. Tag, push, freeze, history rewriting, and integration into
  existing branches require separate explicit user instruction.
- M13 must not start until explicitly authorized.
- The Sol orchestrator assigns explicit path ownership. Native children share
  the active working directory. Use one scoped writer at a time in that checkout.
  Parallel writers require separately proven native worktree isolation.

## Worktree and operation coordination

- Delegate through the native OpenCode2 `subagent` tool. Foreground calls return
  the child result to the parent. Collect every required result before finalizing.
  Use fresh Luna children for scoped implementation, exploration, verification,
  and independent review. Sol retains architecture and difficult decisions.
  Never launch detached workers or use `Scripts/vaelen-agents` for orchestration.
  Verify the active working directory, Git root, branch, and local changes.
- Live operations require explicit user authorization. The Sol orchestrator
  names one operation owner. Only one named session at a time may use the
  installed app, installed CLI, service controls, or runtime-mutating harness
  operations. The orchestrator coordinates the exclusive operation owner and
  explicit handoff; parallel writers do not
  use those paths or mutate live projects, routes, services, certificates, or
  databases.
- Keep `./Scripts/vaelen-dev clean-install` restricted to its existing exact
  `restored-m13-product` branch and golden commit guard. It is not the `dev`
  update path. On `dev`, use the signed `./Scripts/vaelen-dev-update` for an
  explicitly authorized installed-app update; for CLI-only installation use
  the guarded `./Scripts/install-cli.sh`. These installed operations require
  the exclusive slot above.

## Evidence Discipline

- Distinguish observed evidence from assumptions.
- Do not claim runtime behavior from code inspection alone when runtime proof
  is required.
- Do not claim public acceptance from internal diagnostic paths.
- Preserve exact identities wherever authority depends on them.
- Treat failure, restart, and crash paths as first-class behavior.
- If evidence contradicts the current plan, stop and investigate before
  continuing.

Detailed architectural rules remain in the ADRs; this file is the shared
operating boundary, not a replacement for them.
