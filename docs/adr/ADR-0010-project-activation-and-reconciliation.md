# ADR-0010: Project Activation and Reconciliation

* **Status:** Accepted
* **Date:** 2026-09-18
* **Decision owners:** Vaelen maintainers

## Decision

Project activation is an explicit operation for registered, linked projects
only. Discovered projects remain read-only. Activation reconciles only
Vaelen-owned infrastructure toward declared project intent; it does not try to
make the application functional at any cost.

Core constructs a typed reconciliation plan from a fresh project environment
report before performing any mutation. Application mutations, developer-data
mutations, external conflicts, package installation, and privileged capability
mutations are blockers or deferred operations, never implicit activation.

Healthy resources are not restarted or reinstalled unnecessarily. Successful
independent operations remain applied if a later operation fails. Retry
recomputes from observed reality. Background observation and daemon restart
remain passive and do not activate projects merely because `vaelen.yml`
declares services. Manual stops are respected by background and restart
behavior; an explicit project activation may start a desired stopped service
for that request only.

Shared lifecycle automation will eventually require reason-based demand rather
than raw reference counts. M8 Slice 1 does not persist project demand.

`route_intents` remain operational routing state. Deactivation and garbage
collection are separate future concerns. Secrets never appear in plans,
results, IPC, logs, JSON, or GUI output.

## Consequences

The first executable reconciliation operation is intentionally narrow: an
explicit activation may start an already-installed, initialized, stopped,
Vaelen-owned Mailpit default instance after rechecking its preconditions and
then verifying health. MySQL, PHP installation, routes, DNS, TLS, standard
ports, application configuration, and developer data remain planning-only or
blocked until separate policy is established.
