# Project-bound Valkey lifecycle

## Problem

V2 project declarations already name exact service instances, but project reconciliation only supports PostgreSQL. A PHP project cannot yet have `val project up` start and claim its named Valkey instance or have `down` release it safely. The slice must preserve the current manifest, catalog, claim, and IPC shapes, and it must keep PostgreSQL and unsupported legacy service behavior stable.

## Usage

The project keeps the service identity in its portable manifest:

```yaml
version: 2
services:
  - alias: cache
    kind: valkey
    instance: storefront-cache
    version: valkey-9.1.2
```

`val project up --json` should claim and start that exact instance when needed, then report it healthy. `val project down --json` should release this project's claim and stop the instance only when no other project or manual owner remains.

## Shape

Keep `ProjectServiceBinding`, `ServiceInstanceRecord`, and `ProjectServiceBindingObservation` unchanged. Add a closed `ProjectManagedServiceKind` definition for PostgreSQL and Valkey. It owns supported package identity, endpoint key, accepted manifest version, and exact binding-to-observation/catalog matching. A private typed driver in `CoreRequestDispatcher` adapts the existing PostgreSQL and Valkey modules to one status shape and forwards start and stop. It does not store claims or process evidence.

Keep `CoreRequestDispatcher` as the sole project lifecycle coordinator and `ServiceInstanceRepository` as the sole durable claim writer. Its actor already serializes project and direct service requests. Keep ownership reads, verified process transitions, and claim writes synchronous inside one request. These boundaries follow Model the Domain, Boundary Discipline, and Make Operations Idempotent.

Planner and execution rules:

1. The planner accepts only a supported exact definition, matching binding, package identity, endpoint, and data directory. Its existing healthy/stopped and claimed/unclaimed disposition table remains unchanged.
2. Activation preflights every desired binding before changing claims. Retirement is grouped by `ServiceInstanceID`; an instance still desired under another alias is not retired. Stop a retired managed instance only after exact record/status verification and only when no outside owner remains. Replace the project claim set only after those checks succeed.
3. Each actionable operation rechecks the live catalog record against the fresh planned observation. Add the exact claim idempotently. Start only for a `.start` operation, then require healthy status for the same complete record. Failed start or verification retains the claim for retry.
4. Deactivation releases only this project's claim when a manual or other-project owner remains. For a final managed owner, verify, stop, verify stopped, and then release. Any identity or stop failure retains the claim. Unsupported legacy service kinds keep their existing release-without-stop behavior.

The driver handles only PostgreSQL and Valkey. It is a closed adaptation boundary, not a generic plugin API or a second lifecycle coordinator. Future managed service kinds require an explicit definition and typed driver case. Mailpit's multiple endpoints will need a richer endpoint identity rule before it can be added.

## Synthesis decision

Candidate A is the base because it preserves the existing operation-driven PostgreSQL behavior and keeps the diff limited to the current project flow. Candidate B's centralized coordinator hides more lifecycle policy and is a plausible later refactor, but its initial `ensureRunning` contract could start an instance during an association operation and would move all PostgreSQL ownership logic in this slice. Candidate A takes Candidate B's retirement grouping by instance identity and explicit synchronous ownership-transition rule. The design judge also required comparing execution against the fresh planned observation before mutation.

## Tradeoffs accepted

- We accept a few exhaustive typed dispatch points in the current planner and dispatcher in exchange for preserving proven PostgreSQL ordering and result behavior.
- We accept that another managed service requires updating the closed definition and driver in exchange for compiler-visible support and no open-ended registration surface.
- We accept process-stop partial progress across different retired instances; existing claims remain durable, and the next `up` retries reconciliation safely.
- We accept the current dispatcher actor as the serialization boundary. This does not make an unrelated future cross-process repository writer atomic with process transitions.

## Alternatives considered

- A central `ProjectServiceLifecycleCoordinator` would put all project claim transitions behind a smaller caller surface, but it broadens the regression surface and needs a planned-action input to preserve association-versus-start behavior. It lost for this bounded slice.
- Repeating PostgreSQL/Valkey conditionals without a shared closed definition would expose package and endpoint policy at each call site. It lost because future service support would require finding and synchronizing more branches.

## Open questions and risks

- Does a future MySQL project binding need to preserve catalog-only legacy health reporting? This slice does not change that behavior.
- A stop can complete before a later retirement fails. The old claim set remains, so a retry observes the stopped exact instance and converges, but the first call may have partially stopped different retired instances.
- Status `stopped` proves verified absence, not package availability. Starting still validates the exact installed package, and a failure retains the claim for retry.

## Next implementation step

Add exact Valkey planning, observation, activation, deactivation, and private-Core CLI acceptance using the existing local Valkey package, while keeping the PostgreSQL fixture unchanged.
