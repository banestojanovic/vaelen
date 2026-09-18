# ADR-0009: Project Environment Observation and Activation Boundary

* **Status:** Accepted
* **Date:** 2026-09-18
* **Decision owners:** Vaelen maintainers

## Context

M6 dogfooding proved that Vaelen can provide the infrastructure for a real
project, but it cannot yet distinguish project intent, application
configuration, and observed runtime state. Project activation would also
cross important ownership and mutation boundaries.

## Decision

Registered projects have durable environment ownership through their existing
stable `ProjectID`. Discovered projects remain ephemeral: they may be
inspected read-only, but do not receive durable environment state, generated
credentials, database ownership, project demand, or project-scoped processes.

Project environment information is separated into `desired`, `configured`,
`observed`, `derived`, and `secret` state. `UNKNOWN` is used when evidence is
insufficient.

`vaelen.yml` is project-owned, portable desired-state configuration.
`.env` and framework configuration caches remain application-owned. Vaelen may
inspect selected non-secret `.env` values, but does not own or rewrite them.
Passive inspection must not execute arbitrary project or framework code.

Database contents remain developer-owned. Database credentials are secret
state and never appear in normal status, JSON, logs, or GUI output. Mailpit
remains a shared global/default-instance service.

Future activation may reconcile Vaelen-owned infrastructure only within an
explicit mutation boundary. It must not implicitly create databases or users,
rewrite `.env`, reveal or generate credentials, clear framework caches, run
migrations or arbitrary framework commands, modify external processes, or
delete developer data.

Project unlink preserves developer data and shared service state. External
conflicts remain external and are never killed or adopted.

`val up` is deferred until reconciliation semantics are sufficiently
complete.

## Consequences

M7 diagnostics must preserve provenance instead of collapsing state into one
health value. Desired state, application configuration, runtime observation,
derived conclusions, and secret availability are reported separately.

Project inspection is non-mutating. Activation and reconciliation require a
future architectural decision and explicit user-facing operations.
