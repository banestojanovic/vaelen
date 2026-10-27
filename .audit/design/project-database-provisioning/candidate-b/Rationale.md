# Problem

Vaelen needs to create a database and dedicated user for one exact project-owned service, then retain its generated password in Keychain. Existing service identity and claim ownership must remain authoritative. Both engines have a nontransactional database-creation boundary. Local SQLite cannot atomically commit with engine DDL. An interrupted command cannot be declared ours merely because its requested name now exists.

# Usage

Call `createProjectDatabase` once with project ID, full binding, validated database/user names and a stable operation ID. Creation returns an ordinary nonsecret receipt. Call `projectDatabasePassword` separately with explicit reveal or copy intent. The README shows CLI, Settings and credential call sites. A receipt is an outcome of an operation, never permission to adopt an existing database.

# Shape

A single Core provisioner owns create-once attempts and secret access. A metadata receipt ledger records intent before each irreversible engine effect and acknowledgement afterward. The operation either completes, refuses an existing object without touching it, fails before engine writes, or retains a partial result. That sum type replaces ambiguous success booleans per Model the Domain and Type System Discipline. Only the resolver constructs `VerifiedDatabaseTarget`; engine, port and socket are never trusted from IPC per Boundary Discipline. Internal concrete MySQL and PostgreSQL adapters hide different administrative paths and quoting. The public surface has three capabilities, creation, receipt inspection and explicit credential access. It hides preflight, Keychain ordering, DDL sequencing, process safety and crash classification. Callers never coordinate stages.

The dispatcher remains the sole production writer. Each receipt and Keychain account is independently keyed by operation ID. Database and username reservations are shared per exact service because those namespaces truly conflict. SQLite uniqueness serializes those reservations per Separate Before Serializing Shared State. Same-operation retries return the existing receipt, with no second write, per Make Operations Idempotent. Incomplete engine writes converge to a stable retained outcome instead of pretending creation can always be resumed. Keeping the lifecycle hook, concrete engine adapter and receipt coordinator within Core limits the normal trace to caller, dispatcher and provisioner, with engine detail only when needed, per Minimize Reader Load.

# Synthesis decision

Candidate B is submitted independently. The parent synthesis owns base selection and graft decisions.

# Tradeoffs accepted

- We accept a retained partial database or disabled user after interruption in exchange for never dropping data or taking over uncertain resources.
- We accept requiring fresh names after an uncertain attempt in exchange for no human “accept ownership” escape hatch that can overwrite an unrelated database.
- We accept a small SQLite metadata migration in exchange for transport retry safety and honest recovery after Core restarts.
- We accept no password rotation or deletion API in this slice. Keychain loss becomes an unavailable credential, not automatic role alteration.

# Alternatives considered

A declarative desired-database reconciler would store desired resources and resume stage-by-stage after restarts, backed by engine-side ownership markers. It hides more recovery from callers, but a MySQL database and its marker cannot be created as one transaction. The crash window before the marker still needs an ambiguous terminal state. Adding reconciliation also introduces resource drift, ownership transfer and lifecycle rules this feature does not need. Its interface looks small while its state space is much larger. B keeps the create-only product promise explicit.

A shell-command facade would let CLI and Settings call engine-specific “create user”, “create database” and “grant” methods. It is implementation-simple but shallow. It leaks ordering, recovery and secret-handling obligations into both callers and loses the single Core operation requirement.

# Open questions and risks

Can users accept choosing fresh names after an interrupted creation? This is the explicit product tradeoff of B. Can the actual packaged engines enforce the required no-password logging path, including error paths and enabled audit plugins? The first engine proof must answer this before creation is exposed. Is preserving the current PostgreSQL local-trust policy acceptable for this slice? B keeps it explicit in connection metadata. A separate SCRAM fixture proves password correctness without claiming production trust rejects incorrect passwords.

# Next implementation step

Build and prove a Core-only create-once MySQL operation with a fake Keychain store, receipt reopen tests and fault injection around every engine write before connecting CLI or Settings.
