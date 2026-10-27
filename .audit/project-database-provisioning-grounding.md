# Project database provisioning grounding

Vaelen already models MySQL as the default service and PostgreSQL as named service instances. `ProjectServiceBinding` maps a project alias to an exact kind and instance. `ProjectServiceBindings` owns the service-instance catalog and project claims. The project manifest and `.env` parser are separate, and the environment inspector reports configured database values without writing them.

`MySQLModule` owns the default instance. It initializes a local root account with an empty password and stores that local client configuration in a mode-0600 file. Its client helper passes SQL in a process argument today, so provisioning SQL containing a new password must use a different input path. MySQL DDL is not transactionally grouped with role creation and grants, so partial completion must be represented and must never lead to deleting a database as compensation.

`PostgreSQLServiceModule` owns named instances and starts PostgreSQL on loopback with an instance-specific Unix socket. `initdb` creates the cluster, and the module's health check uses `psql` over loopback. The normal instance currently uses local trust authentication. Provisioning can use the exact selected instance's admin connection, but generated credentials must not enter argv, logs, or project configuration.

`CoreRequestDispatcher` is an actor that receives typed Vaelen IPC requests. It already owns project reconciliation and delegates exact service records to `ProjectServiceBindings`. `VaelenCoreClient` serializes typed request/response models. The CLI calls Core over this client. `AppModel` also calls Core and the selected project details render in `ProjectsViews.swift` and `VaelenApp.swift`.

`ProjectDatabaseViewerAction` is a read-only projection that can open an eligible MySQL database in TablePlus. It deliberately accepts no credential. It is not a provisioning path and should remain separate.

`TLSCapability` demonstrates Security framework access in VaelenCore, but its `LocalCAKeychain` stores private keys and certificates, not generic passwords. New app credentials need a separate injected password-store boundary that Core owns. The IPC contract should return password material only for an explicit reveal or copy request. Status and creation results should contain metadata only.

The native Settings app already has a selected-project detail. A compact setup control can live there without adding a project window. Existing verification skills cover CLI/Core fixtures and native Settings fixtures. The native app fixture skips Core and cannot prove production persistence, so live Core and app checks must be reported separately.

## Baseline observations

- Current committed revision: `d66ccfab87c4e09c5ce89eb5fd1ce45a37a5ddcc`.
- Canonical checkout has unrelated staged, modified, and untracked work. This feature uses a separate worktree and leaves it untouched.
- `Scripts/test.sh --help` returned `tests passed (full log discarded)` before feature edits. The command appears not to implement a help mode; treat it only as a baseline suite run, not as command syntax documentation.
- Prior local package fixture directories exist at `/Users/banes/.codex/worktrees/vaelen/service-data-backup-recovery-fixtures/packages` (37 MB) and `.../extracted` (102 MB). Their contents and provenance still need a read-only identity check before live use.
- Existing project lifecycle and PostgreSQL recipes are in `.agents/skills/verify-vaelen/features/project-environment-lifecycle.md` and `service-instance-lifecycle.md`.
