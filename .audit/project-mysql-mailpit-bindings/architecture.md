# Selected architecture: MySQL and Mailpit project bindings

## Decision

Use the existing schema-9 service catalog and project claims for MySQL and Mailpit. Put V2 service binding policy behind one synchronous `ProjectServiceBindings` facade owned by `CoreRequestDispatcher`. Relocate the existing PostgreSQL and Valkey V2 claim, activation, and release sequencing into that facade in the same change, so the dispatcher has one V2 policy path.

Use closed, private runtime adapters. PostgreSQL and Valkey adapters retain their named-instance start/stop behavior. MySQL and Mailpit adapters only inspect their module-owned `default` instance and start it through the existing module API. The singleton adapter exposes no stop operation. Service modules own package, endpoint, storage path, process identity, and readiness checks. `ServiceInstanceRepository` owns catalog and claim SQL.

## Data shape and identity

- A MySQL or Mailpit binding must name `instance: default`.
- A current installed package and module-validated exact descriptor are required. Explicit versions must equal the complete package identifier. An omitted version can use only an exact catalog identity already persisted for that singleton; a prospective inventory record alone cannot supply an omitted version.
- MySQL catalog storage is its existing default data directory. An uninitialized MySQL package is blocked and project activation never initializes it.
- Mailpit catalog storage is its existing default instance directory. The module separately validates the exact `messages.db` path and both ports. After Core restart, missing process ownership evidence remains `identity-unverified` and blocks activation.
- Readiness and process identity remain live observations. They are not persisted in claims or exposed as process tokens over IPC.
- Report and inventory responses may include additive, optional assessed eligibility. Native adoption derives available kinds and instances from this Core assessment and fails closed when the field is absent.

## Operation rules

Inspection adds no catalog, claim, provisioning, or lifecycle mutation. Existing module status cleanup semantics remain unchanged. Inventory may include an exact prospective singleton descriptor only when its package and live module snapshot agree. Activation or adoption materializes that row in the same transaction that creates the project claim.

Before activation, inspect every desired binding again and compare it with the reviewed observation. Reject mismatches, unsupported packages, endpoint drift, uninitialized MySQL, identity uncertainty, and catalog conflicts before changing desired claims. Retire old claims according to existing V2 semantics. Successful isolated-service stops may be partial effects if a later SQL operation fails; do not promise an all-or-nothing runtime transition. Commit exact desired claims and prospective catalog rows atomically. Start each required runtime once and verify fresh module identity and health. Failed starts retain their claims for retry and package protection.

Project down releases stored claims even when a manifest, package, or healthy runtime is missing. It never stops MySQL or Mailpit. Other owners remain. V1 global intent and service controls keep their existing behavior; V2 claims do not create global boot intent. Manual global stop remains available.

Package removal checks project claims and performs the bounded existing intent, stop, and exact-package removal callback while holding the repository's `BEGIN IMMEDIATE` write transaction. Matching singleton catalog and manual-claim metadata is deleted only after the callback succeeds. If stop or package removal takes effect but the callback or SQL commit later fails, SQLite rolls back its metadata changes but cannot reverse the runtime or package effect; the catalog may then be stale and requires later reconciliation. Keep the callback synchronous, bounded by existing module timeouts, and free of nested repository transactions, network work, or async suspension. A busy writer fails closed and can retry. Guard `mysqlUse` against changing the selected identity while a project claims the singleton.

## Rejected alternatives and grafts

Reject V2-only legacy observations because schema 9 requires a catalog row for claims; a second ownership path would split reporting, adoption, and removal protection. Reject a uniform stop-capable driver for all services because MySQL/Mailpit project down has release-only semantics.

Use candidate B's catalog-backed facade and assessed inventory. Graft candidate A's precise module-owned exact-start validation and strict omitted-version rule. Keep Mailpit's `dataDirectory` as a directory and validate the database file inside the module. Preserve candidate B's materialization-on-claim design, but describe inspection as adding no new catalog/lifecycle mutations rather than claiming module status calls are intrinsically side-effect-free. Keep candidate B's removal exclusion only around bounded synchronous removal and explicitly test across repository connections.

## Change boundaries

1. Add module-owned MySQL/Mailpit snapshots and focused identity/readiness tests.
2. Add repository compare-and-swap materialization with claim replacement, plus claim-protected removal; test rollback and two-connection exclusion.
3. Add the V2 facade, migrate dispatcher V2 operations into it, and make project reports use assessed binding availability. Preserve V1 planner behavior.
4. Extend adoption inventory IPC and native selection from assessed Core eligibility; use kind plus name for identity and pin exact package identity.
5. Add lifecycle/adoption/removal tests, then run focused suites, isolated built-`val` acceptance, and native Settings acceptance. Retain `.env`, package/data-path, and cleanup evidence.

## Verification limits

Do not claim project MySQL readiness using a stub package. Use module-owned disposable fixtures for unit boundaries and an installed controlled service for live acceptance. Confirm existing data paths and `.env` bytes remain unchanged. The full Herd-replacement goal remains open after this slice.
