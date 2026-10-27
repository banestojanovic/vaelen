# Project database provisioning handoff

## Goal

Let a developer create a database and dedicated application login on the exact MySQL or PostgreSQL service bound to a linked project. The CLI and native Settings use one Core operation. Core stores generated passwords in Keychain and exposes them only after an explicit reveal or copy action. Provisioning refuses existing names and records uncertain partial DDL as `needsAttention`. It never edits `.env` or removes engine data.

## Worktree

- Branch: `codex/project-database-provisioning-20261027`
- Base: `d66ccfab87c4e09c5ce89eb5fd1ce45a37a5ddcc`
- Worktree: `/Users/banes/.codex/worktrees/vaelen/project-database-provisioning`
- Acceptance is complete. The feature and handoff are committed on this branch; no push has been made.

The canonical checkout is separate and contains unrelated edits. Keep working in this worktree until review and the UI check are complete.

## Implementation map

- `Sources/VaelenCore/ProjectDatabaseProvisioning.swift` defines validated request values, the receipt state machine, the provisioning engine boundary, and the Keychain password store.
- `Sources/VaelenCore/MySQLModule.swift` binds MySQL work to the exact healthy service instance. It refuses existing database or user names, creates a restricted account, grants exact schema access, verifies TCP authentication, and escapes underscore wildcards in grants.
- `Sources/VaelenCore/PostgreSQLServiceModule.swift` verifies the PostgreSQL cluster system identifier, creates a `NOLOGIN` role and owned database, grants schema access, installs a database-and-user-specific loopback SCRAM rule, sets the password, and verifies TCP login.
- `Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift` verifies linked project identity, manifest binding, persisted claim, service record, endpoint, package, health, and module-owned identity before dispatch.
- `Sources/VaelenIPC/Protocol/ProtocolModels.swift` and `Sources/VaelenIPC/Client/VaelenCoreClient.swift` carry typed create, status, operation-ID-only retry, and explicit password requests.
- `Sources/VaelenCLI/main.swift` implements `val project db create`, `status`, `retry`, `password reveal`, and `password copy`.
- `App/Vaelen/Vaelen/AppModel.swift` and `App/Vaelen/Vaelen/VaelenApp.swift` add compact project Settings controls for one healthy, claimed MySQL or PostgreSQL binding.
- `.agents/skills/verify-vaelen/features/project-database-provisioning.md` documents focused verification and coverage boundaries.

MySQL suppresses query logging for the password-bearing `CREATE USER` command and never passes the generated password in process arguments. PostgreSQL sets and reads back statement, duration, error, sampling, and parameter logging controls in the same psql session before sending password SQL. A SQL guard raises a fixed error before the secret statement if controls differ, preload libraries are active, or pgaudit is installed. These checks cover configured PostgreSQL logging channels, not arbitrary third-party code. Its application login probe passes a mode-0600, immediately unlinked descriptor to libpq because libpq rejects a pipe as a passfile. The durable password remains in Keychain.

Retry uses `val project db retry <operation-id> [project] [--json]`. Core loads the immutable request from the saved attempt and accepts only `failedBeforeDDL` with no pending, confirmed, or uncertain effects. Status checks the exact saved service record and live cluster identity without loading credentials or mutating the engine.

## Verification completed

The live MySQL acceptance command passed:

```sh
Scripts/tests/val-project-database-provisioning-test.sh
```

Evidence: `/private/tmp/vaelen-project-database-evidence.By7AZg`

Earlier evidence confirms MySQL 8.4.11 creation, database collision refusal, wildcard-neighbor denial, PDO migration, persistence after service and Core restart, unchanged `.env` and claims, exact Keychain cleanup, and fixture cleanup. The latest report at `/private/tmp/vaelen-project-database-evidence.FCgNDE` confirms database and existing-user collision refusal, unchanged sentinel account grants, absent requested database, and the earlier MySQL migration, restart, isolation, file-preservation, and cleanup checks.

The live PostgreSQL acceptance command passed:

```sh
Scripts/tests/val-project-database-provisioning-postgresql-test.sh
```

Evidence: `/private/tmp/vaelen-project-database-postgresql-evidence.veFdwM`

Earlier evidence confirms PostgreSQL 18.6 creation, database and role collision refusal, neighboring database denial, PDO migration, persistence after service and Core restart, unchanged `.env` and claims, exact Keychain cleanup, and fixture cleanup. The latest report also confirms aggressive statement, duration, error, sampling, and parameter logging at startup; no marker from a failing password-bearing statement in server logs; refusal with an active preload library; role attributes; wrong-password rejection; stale service-record and replacement-cluster status refusal; and the existing migration, restart, isolation, preservation, and cleanup checks.

The required focused regression filter passed after the UI copy change:

```sh
Scripts/test.sh --skip-update --disable-automatic-resolution --filter 'ProjectDatabaseProvisioningTests|ProtocolTests|ProjectRelationshipCLIParsingTests|ProjectDatabaseProvisioningEndToEndTests|ProjectDatabaseProvisioningPostgreSQLEndToEndTests|DatabaseViewerIntegrationTests|ProjectReconciliationTests|ProjectAdoptionApplyTests'
```

An unfiltered `Scripts/test.sh` attempt failed while another test process was running. The log shows PHP provider-cache/version failures and a concurrent schema migration collision (`project_database_attempts` already exists). Treat that run as inconclusive; do not claim a full-suite pass. The final focused regression filter passed, and separate live MySQL/PostgreSQL acceptance covers actual engine behavior.

## Native Settings acceptance

Three isolated Debug app fixtures were built, launched, checked with the app doctor, inspected via CUA accessibility state and screenshots, then stopped with their owned cleanup helpers. Vaelen was confirmed stopped after cleanup.

- MySQL ready receipt: `artifacts/verification/dbprov-settings-mysql-final-20261027T201027Z/`
- PostgreSQL ready receipt: `artifacts/verification/dbprov-settings-postgresql-final-20261027T200647Z/`
- Failed-before-DDL retry state: `artifacts/verification/dbprov-settings-retry-verified-20261027T202036Z/`

All actions that could mutate a fixture were disabled. The retry badge reads `Failed before DDL`. Screenshots were captured and inspected in the CUA session; the connector did not expose screenshot export to the local artifact directory. These fixtures prove presentation only, not Core behavior.

## Acceptance and remaining release gates

The feature acceptance predicate is met. One fresh read-only Sol review found PostgreSQL password-SQL logging gaps, stale target checks, missing explicit retry, insufficient live cases, and documentation inaccuracies. Those findings were addressed; the correction tests and live fixtures passed. No second reviewer was used.

Remaining work belongs to broader release readiness: signed installed-app acceptance, broader macOS version coverage, and package repeatability/provenance/licensing/signing gates. The unfiltered suite run described above should be rerun in a quiet, isolated environment when pursuing that release work.

The canonical checkout has unrelated edits and remains untouched. The feature is committed in this isolated worktree; no push was made.

## Product boundary and next goal

This feature stops after creating the database and login and revealing or copying credentials. The developer still configures the project environment by hand.

### Proposed next goal: reviewed project connection setup

Let a developer take a ready provisioning receipt and prepare Laravel database settings for that exact project. Vaelen should preview the proposed `.env` key changes, clearly show conflicts with existing database keys, and require explicit approval before writing. The write must preserve unrelated bytes and keys, avoid exposing secrets in logs/arguments, detect a stale file before apply, and leave a recoverable before-image for an interrupted or explicitly reverted operation. CLI and native Settings should share a Core-owned operation and report the same result. Do not add silent `.env` edits to provisioning or project `up`.

Suggested slices: (1) ground dotenv parsing, file identity, and recovery behavior; (2) compare a byte-preserving edit/atomic-replace design with a generated include-file design; (3) implement Core preview/confirmation/apply/undo with tests for comments, quoting, duplicates, conflicts, symlinks, permissions, and concurrent file edits; (4) expose the same review flow in `val` and Settings; (5) verify against disposable Laravel projects with before/after hashes, secrets redaction checks, and interrupted-write recovery. Make the goal complete only when preview, approval, preservation, stale-file refusal, recovery, and CLI/Settings agreement pass on isolated fixtures.

Other release work remains outside this feature: signed installed-app acceptance, broader macOS version coverage, and packaging/provenance checks for supported database engine versions.
