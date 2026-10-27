# Service instance inventory through Core and `val`

## Feature playbook

- [x] `how` over the affected subsystem. The lead traced the repository, dispatcher, protocol, client, and CLI paths directly because project `AGENTS.md` prohibits automatic explorer subagents.
- [x] `architect` for parallel design exploration. skip: project `AGENTS.md` limits delegation to implementation and review, and the existing architecture already names the catalog record and claim types this read-only adapter exposes.
- [x] Write the throughput checkpoint as four todo items.
- [x] Delegate code-writing to one Luna implementation owner in an isolated worktree.
- [x] Verify on the matching surface. The parent reran catalog/IPC and CLI filters and exercised the actual `val` child against a private Core.
- [ ] Rebase into small, ordered commits. skip: the canonical worktree contains the user's pre-existing uncommitted changes, and this slice remains part of the active multi-slice feature.
- [x] If the design is contested, `interrogate` before shipping. skip: no contested design arose.
- [ ] Run `Opening a PR`. skip: the full Herd replacement workflow remains open, and the canonical worktree is not a clean PR base.

## Throughput checkpoint

- [x] **Blocking first steps.** The catalog/claim schema and PostgreSQL/ICU and Valkey build feasibility already exist in the canonical worktree; this slice is read-only inventory and does not start services.
- [x] **Independent workstreams.** n/a. Protocol, Core dispatch, client, and CLI form one request path and need one owner.
- [x] **Shared mutable state.** The canonical worktree contains preserved user changes. The implementation uses a separate worktree with only the required current changes overlaid; the main checkout stays untouched until review.
- [x] **Smallest safe decomposition.** One Luna implementation owner will add one read-only catalog inventory request end to end. It will expose durable identity, endpoint, data directory, and ownership claims without inferring runtime health or adding lifecycle controls.

## Contract

The Core response shape is `ServiceInstanceInventorySnapshot`, containing a deterministic array of `ServiceInstanceInventoryEntry`. Each entry contains the existing typed `ServiceInstanceRecord` and its typed manual/project claims. The IPC wire model projects the record and claims into Codable values. `val service instances [--json]` renders the same records and labels them as catalog data, not process health.

## Work

- [x] Ground the existing persistence, dispatcher, IPC, client, and CLI paths.
- [x] Implement one read-only Core request and typed response.
- [x] Add `val service instances [--json]` with strict parsing and human/JSON output.
- [x] Add repository, IPC, and CLI behavior tests for empty and populated catalogs, deterministic ordering, and manual/project claims.
- [x] Rerun focused parent tests, inspect the complete diff, and get one fresh read-only Sol review. Fold the no-comments check into that single review because project `AGENTS.md` and the user's standing instruction allow one reviewer for this routine slice.
- [x] Integrate the reviewed diff into the canonical checkout and update the project-environment audit trail.

## Status

Implemented and verified on 2026-10-26. The service package spike passed feasibility checks, but package acquisition, licensing, provenance, and release packaging remain open in `.audit/project-service-environments/package-build-spike.md`.
