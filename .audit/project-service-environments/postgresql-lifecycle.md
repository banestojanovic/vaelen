# Named PostgreSQL instance lifecycle slice

## User outcome

Create and run a named, Vaelen-owned PostgreSQL 18.6 instance on loopback, inspect its verified health and connection endpoint, and stop it without touching any other process or database. Core is the only lifecycle owner. `val` reads and controls the same instance catalog as Core.

## Data contract

- Identity is exactly `ServiceInstanceID(kind: .postgresql, name: ProjectInstanceName)`.
- Package identity is exactly `postgresql-18.6`; package files live separately from instance data.
- The requested loopback port and data directory are recorded in `ServiceInstanceRecord` only after package validation and successful cluster initialization.
- `manual_service_claims` represents an explicit manual run request. Project claims remain untouched by this slice.
- Status is an observation, not a stored start flag. Health must be demonstrated by the exact package's `psql` reporting the expected data directory and server version over the recorded loopback endpoint.

## Safety invariants

- Bind only to `127.0.0.1`; reserve and recheck the port before starting. A conflict is reported and its listener is never signaled or adopted.
- Use a per-instance cluster, socket, log, process record, and runtime paths. A nonempty partial cluster is preserved and blocks reinitialization.
- Start records include executable identity, exact arguments, PID start identity, data path, and port. After Core restart, stop only a process whose identity matches all recorded fields; ambiguous live processes remain untouched and keep their evidence.
- `stop` is graceful and targets only the verified instance. Failure to prove termination is reported without deleting its process record or data.
- `remove` releases the manual claim and catalog entry only when stopped and unclaimed; it preserves the data directory. Destructive data deletion is out of scope.
- Package install verifies the generated checksummed manifest, archive identity, and exact package-root inventory before publishing files. Instance data is never inside a package directory.
- Existing MySQL and Mailpit defaults and their lifecycle remain unchanged.

## Core and CLI contract

Add exact-instance create, inspect/status, start, stop, and non-destructive remove actions through Core IPC and `val service postgresql ...`. Inventory reports package identity, loopback endpoint, data location, ownership, and observed health without exposing secrets. Reject ambiguous names, unsupported versions, invalid ports, and attempts to replace an existing instance record with different data.

Package acquisition source for end-user releases is still an open gate. Keep package installation injectable for fixture verification and do not claim release readiness until signed/checksummed distribution is available.

## Verification contract

Use a unique isolated support root, generated PostgreSQL package output, and dynamically chosen loopback port. Verify create/init, `SELECT 1`, expected server version and data directory, stop, restart persistence, exact process re-observation after Core restart, and real `val` child inventory/start/status/stop. Also verify archive tampering, port conflict without affecting the foreign listener, second initialization refusal with unchanged data snapshot, wrong process identity refusal, failed shutdown evidence retention, and non-destructive remove. Snapshot `.env`, unrelated support paths, project claims, and unrelated listeners before/after.

The fixture proves local runtime behavior for the generated arm64 package on this host. It does not prove signed release distribution, macOS 14, native Settings UI, update lifecycle, Valkey, adoption/apply, project `up/down`, or final Herd replacement acceptance.
