# ADR-0011: Project Route Ownership and Association

* **Status:** Accepted
* **Date:** 2026-09-18
* **Decision owners:** Vaelen maintainers

## Decision

Durable route/project ownership is established by an exact persisted
`ProjectID` reference from a valid `RouteIntent` to a currently registered
linked project.

The ownership facts remain separate:

* SQLite storage ownership means the route exists in Vaelen state;
* project association means the route references a stable `ProjectID`;
* target ownership means the current runtime target is Vaelen-managed;
* provider ownership means the active router is the Vaelen-managed provider.

Only durable project association is the project identity prerequisite for
future project route mutation. Target and provider ownership remain separate
prerequisites for target or provider changes.

## Evidence Semantics

Persisted `projectID` is the strongest project identity evidence.

Persisted `projectPath` is canonicalized compatibility metadata, migration
evidence, and diagnostic context. A path-only match is not mutation authority.

Document-root inference is observation, diagnostic, and migration evidence. It
never becomes mutation authority by itself.

Association classification evaluates all candidates rather than selecting the
first OR-matching route. Ambiguity, hostname conflicts, orphaned IDs, and
identity contradictions fail closed.

One linked project may own multiple routes. Operations requiring one route must
identify an exact route ID or have exactly one unambiguous candidate.

## Explicit Association

Existing legacy route metadata may be attached through the typed operation:

```text
route.project-association.attach
```

The operation accepts an exact route ID and an exact linked project ID. Core
re-observes all evidence at execution time.

The operation may change only:

* `route_intents.project_id`;
* `route_intents.project_path` as the canonical path snapshot at first attach.

It preserves route ID, hostname, target, document root, and TLS. It does not
call the router, reload Caddy, issue TLS certificates, modify DNS, change PHP,
or mutate project files.

Repeated association of the same route and project is a no-op. Existing
association to another project is never overwritten.

## Lifecycle

Daemon startup never silently associates legacy routes. Unreadable route state
fails closed before route reconciliation; a repository failure is never
interpreted as an empty route set.

Unlink removes project registration but preserves route association metadata.
The route then becomes orphaned and mutation-blocked until the association is
explicitly restored or otherwise resolved.

## Consequences

Legacy routes can remain operational while truthfully reporting that they are
not yet mutation-authorized. Explicit association provides a narrow,
non-destructive path to durable ownership without coupling metadata repair to
Caddy or runtime convergence.

Route target convergence remains a separate future milestone and requires
durable project association plus independent target and provider ownership
proof.
