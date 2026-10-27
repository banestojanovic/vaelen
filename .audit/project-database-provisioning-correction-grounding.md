# Provisioning correction grounding

## Current ownership

`ProjectDatabaseProvisioner.create` owns the receipt transitions and engine sequence. `ProjectDatabaseReceiptRepository` persists the immutable request and its operation ID. The CLI and Settings generate a new operation ID for every Create action. Core resolves the current project, claim, service record, health, and endpoint before handing the request to the owning service module.

The operation can return `failedBeforeDDL` when Keychain or target preflight fails before an engine write. The receipt keeps its database and username reservation. The domain accepts `.prepared` from `failedBeforeDDL`, but `ProjectDatabaseProvisioner.create` only records `.prepared` when the original state was `.reserved`. The existing callers generate a new operation ID, so a failed attempt cannot reuse its reservation.

The status IPC handler finds a receipt by operation ID and verifies the current project binding and service record. It passes no expected record to the target validator and does not compare the live engine identity with the receipt's saved `clusterIdentity`. Password reveal performs a stronger check through the service module.

Before correction, PostgreSQL password-bearing SQL prepended session settings for ordinary statement and duration logging, but did not disable error-statement or sampling logs or read settings back. The correction uses a same-session SQL gate that fails before the password statement when readback differs or hooks are active.

Settings renders Reveal and Copy only when `projectDatabaseAttempts[project.path]` contains a ready attempt. Both current Settings fixtures seed a service binding but no ready receipt. The fixture therefore cannot render those actions. The launch fixture allowlist and cleanup fixture allowlist must stay in sync.

## Current tests and live evidence

`ProjectDatabaseProvisioningTests` covers receipt transitions, collisions, and uncertain effects. It does not cover a successful retry from `failedBeforeDDL`, a repeated pre-DDL failure, or a collision discovered on retry.

The MySQL live fixture verifies an existing database collision. Its current result label also claims an existing-user collision check. The PostgreSQL fixture verifies both database and role collision refusal.

Earlier live MySQL and PostgreSQL evidence is in `/private/tmp/vaelen-project-database-evidence.By7AZg` and `/private/tmp/vaelen-project-database-postgresql-evidence.Qf3CzU`. The Settings app built and launched, but CUA did not connect. No screen observation was made.

## Constraints

- Reuse the same immutable operation ID and request for a pre-DDL retry.
- Never retry a pending or uncertain engine effect.
- Reject a stale service record or cluster before returning status or retrying.
- Suppress and verify every PostgreSQL server log channel that could persist password-bearing SQL. Refuse active audit configuration the implementation cannot control.
- Keep generated passwords out of args, environment values, named files, routine logs, and fixture output.
- Preserve existing database and username refusal. Never roll back or delete engine objects.
- Keep CLI and Settings on the same Core operation.
- The Settings fixture may show a ready receipt's metadata, but fixture mode must disable create, reveal, and copy operations.
