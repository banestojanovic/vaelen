# ADR-0012: Project PHP Route Target Convergence

* **Status:** Accepted
* **Date:** 2026-09-19
* **Decision owners:** Vaelen maintainers

## Context

An associated project can declare a PHP family while its durable route intent,
the live routing provider, and the available PHP-FPM runtime describe different
FastCGI targets. Treating any one of those observations as authoritative can
silently redirect a route, adopt an external runtime, or apply a provider
change without durable recovery information.

M12 establishes a narrow, fail-closed convergence protocol for changing the
PHP target of an existing project route. The protocol is implemented for
linked registered projects with an exact durable route association.

## Decision

SQLite `RouteIntent` is durable desired route truth. Live Caddy is observed
provider/runtime truth. They are separate facts and are not assumed equivalent.
Provider agreement is semantic: supported route behavior, document root, TLS,
and FastCGI transport semantics must agree even when Caddy normalizes its JSON
representation.

The project association must be an exact persisted `ProjectID` reference to a
currently registered linked project. An exact `RouteID` is required for
execution. The project PHP declaration must resolve to an exact eligible
Vaelen-owned PHP package, and both the current and desired FastCGI targets
must have proven Vaelen ownership. The desired PHP-FPM socket must be healthy.
Caddy must be running, healthy, readable, and semantically agreed with the
durable route before mutation.

## Strict No-Op

When the persisted target, observed provider target, and desired target are
equal, and all ownership and health prerequisites pass, `route.php-target` is
satisfied and non-executable. The operation performs:

* no `RouteIntent` write;
* no transition creation;
* no Caddy apply or load;
* no PHP-FPM restart.

M12 live acceptance proved this behavior against an existing official Caddy
instance and PHP-FPM 8.4.23.

## Persist-First Transition

An authorized target transition follows this order:

1. Perform full preflight and fresh provider observation.
2. Re-evaluate the strict no-op condition.
3. Atomically persist the desired route change and transition provenance.
4. Update Core memory.
5. Apply the full desired route configuration to Caddy.
6. Re-read Caddy through the Admin API.
7. Verify exact semantic convergence.
8. Complete the transition only after provider success is verified.

The durable transition records the exact RouteID and ProjectID, previous and
desired route/provider fingerprints, and previous and desired sockets. SQLite
uses schema 5 for this state. The IPC compatibility schema remains 4.

Durable transition provenance is narrowly scoped to authorized PHP route-target
transitions. It is not a generic workflow engine, transaction framework,
rollback mechanism, provider cache, or job framework.

## Failure, Retry, And Restart

If durable persistence fails, the provider is untouched. If persistence
succeeds and the provider apply fails, SQLite remains at the desired target and
the transition remains pending; Core does not blindly roll back the durable
desired state. A retry revalidates current state and applies only the
authorized transition.

On restart, authorized desired/provider divergence may be finalized after full
revalidation when the durable provenance exactly explains it. Divergence
without provenance, or divergence that does not match the recorded previous
and desired state, is blocked. Malformed transition data fails closed. A
successful provider apply followed by a crash can therefore be finalized
without reapplying the provider configuration, but only after the same
identity, ownership, health, and semantic convergence checks.

## Stale And Unexplained State

Stale or contradictory project association, hostname, document root, TLS,
provider, or PHP state blocks mutation. A route target that is external or has
unproven ownership cannot be adopted. Provider state that is stopped,
unhealthy, unreadable, malformed, or semantically unsupported cannot be
mutated. Caddy is never implicitly started for a PHP target operation.

The provider boundary is Caddy Admin HTTP. Chunked HTTP responses are decoded
before JSON parsing. Malformed HTTP or chunked responses fail closed. Supported
Vaelen FastCGI routes can round-trip through Caddy normalization and remain
semantically equivalent when observed again.

## Non-Goals

M12 does not create routes, attach route associations, mutate document roots or
TLS, install PHP, adopt external targets, mutate Laravel or application files,
or stop an old shared FPM runtime merely because a route moves away. DNS,
standard ports, MySQL, Mailpit, and application configuration are separate
capabilities and are not part of route-target mutation authority.

## Consequences

Route changes are conservative and require more evidence than a simple socket
comparison. The system retains a small amount of durable transition metadata
and performs additional provider observations. In exchange, a provider failure
or Core restart cannot silently erase the intended target, repeat an already
successful apply, or authorize an unexplained divergence. Healthy converged
routes remain true no-ops.
