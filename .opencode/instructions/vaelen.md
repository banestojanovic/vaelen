# Vaelen Shared Instructions

## Frozen Baseline

- M0–M13 are frozen. M12 is frozen at `v0.0.13-m12` and commit
  `e76e260b69b6b1e0216fdc8985ce13cfa4c79964`; M13 is frozen at
  `v0.0.14-m13` and commit `534da3618895717624cb9d4bf7dd685f5dfd571b`.
- ADR-0013 and all earlier accepted ADRs are authoritative.
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
- Commit, tag, push, and freeze require explicit user instruction.
- M14 is currently validation-only; production M14 implementation and
  ADR-0014 are not authorized or frozen.
- Only `vaelen-lead` normally edits the checkout.

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
