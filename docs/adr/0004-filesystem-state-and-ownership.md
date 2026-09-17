# ADR-0004: Filesystem, State, and Ownership Model

* **Status:** Proposed
* **Date:** 2026-09-17
* **Decision owners:** Vaelen maintainers

## Context

Vaelen manages several fundamentally different kinds of data:

* application binaries;
* upstream module packages;
* mutable service data;
* generated configuration;
* project registry state;
* runtime process state;
* sockets and locks;
* downloaded artifacts;
* logs;
* certificates;
* secrets;
* user-owned project files.

These categories have different lifecycle and safety requirements.

A package may be safely deleted and downloaded again.

A MySQL database may contain irreplaceable developer data.

A socket is meaningful only while a process exists.

A trusted certificate modifies macOS state outside Vaelen's normal application directory.

A project directory belongs to the developer and must never become Vaelen-owned merely because it was linked.

Vaelen therefore requires an explicit filesystem and ownership model.

The primary rule is:

> Vaelen must know what it owns before it is allowed to delete it.

---

# Decision

Vaelen will separate data according to **purpose, persistence, ownership, and recoverability**.

The primary filesystem roots are:

```text id="v4ufxe"
/Applications/Vaelen.app

~/Library/Application Support/Vaelen/

~/Library/Caches/Vaelen/

~/Library/Logs/Vaelen/
```

Sensitive secrets should use macOS Keychain where appropriate.

System modifications such as resolver configuration and certificate trust are tracked explicitly by Vaelen but are not treated as ordinary application files.

User project directories remain user-owned.

---

# 1. Data classification

Every Vaelen-managed artifact belongs to one of the following conceptual classes:

```text id="v1m6c7"
APPLICATION
PACKAGE
CONFIGURATION
STATE
USER_DATA
RUNTIME
CACHE
LOG
SECRET
SYSTEM_MODIFICATION
PROJECT
```

This classification determines:

* where the artifact lives;
* whether it can be regenerated;
* whether Vaelen may automatically delete it;
* whether it should be backed up;
* whether it requires explicit destructive confirmation.

---

# 2. Application

The application bundle lives at:

```text id="59a2rc"
/Applications/Vaelen.app
```

It contains:

* GUI application code;
* bundled resources;
* trusted built-in module definitions;
* application frameworks;
* other immutable release assets.

The application bundle is disposable.

Deleting or replacing it must not destroy:

* databases;
* project configuration;
* installed package state;
* project registry;
* user projects.

Mutable runtime or user data must not be stored inside the application bundle.

---

# 3. Application Support

Persistent Vaelen-managed state lives primarily under:

```text id="88xvr7"
~/Library/Application Support/Vaelen/
```

Conceptually:

```text id="dfwwca"
~/Library/Application Support/Vaelen/
│
├── packages/
├── instances/
├── config/
├── state/
├── projects/
├── runtime/
└── security/
```

The exact internal structure may evolve.

The semantic boundaries must remain.

---

# 4. Packages

Installed upstream software lives under:

```text id="ejup4s"
~/Library/Application Support/Vaelen/packages/
```

Example:

```text id="w5mpab"
packages/
├── php/
│   ├── 8.3.26/
│   ├── 8.4.13/
│   └── 8.5.0/
│
├── mysql/
│   └── 8.4.6/
│
├── redis/
│   └── 8.2.1/
│
└── mailpit/
    └── 1.27.7/
```

Package directories contain software, not user data.

They are Vaelen-owned.

Vaelen may delete a package when:

* it is not required by an active instance;
* the user explicitly requests removal;
* or a safe garbage-collection policy determines it is unused.

---

# 5. Package immutability

Installed package directories should be treated as immutable wherever practical.

Example:

```text id="ct5unh"
packages/php/8.4.13/
```

must not become the normal location for:

* `php.ini`;
* project configuration;
* logs;
* runtime sockets;
* user extensions;
* mutable databases.

Those belong elsewhere.

This makes package removal predictable.

Deleting:

```text id="j2zx7a"
packages/php/8.4.13/
```

should mean:

> Remove this software version.

It should not mean:

> Remove this software version plus unknown user state.

---

# 6. Package metadata

Each package contains or is associated with Vaelen metadata.

Conceptually:

```text id="s8j8hk"
packages/php/8.4.13/
├── package/
└── .vaelen-package.json
```

Metadata may include:

```text id="my0d6k"
module
version
architecture
source
checksum
installation timestamp
package schema version
Vaelen version that installed it
```

This allows package ownership and provenance to be verified.

---

# 7. Instances

Mutable service instances live under:

```text id="eyh0ug"
~/Library/Application Support/Vaelen/instances/
```

Example:

```text id="r0j5js"
instances/
├── mysql/
│   └── default/
│       ├── config/
│       ├── data/
│       └── metadata.json
│
└── redis/
    └── default/
        ├── config/
        ├── data/
        └── metadata.json
```

Instance directories are separate from package directories.

This is one of Vaelen's most important filesystem boundaries.

---

# 8. Instance configuration

Generated and user-controlled instance configuration belongs under:

```text id="x3zuhf"
instances/<module>/<instance>/config/
```

For example:

```text id="kt0pqp"
instances/mysql/default/config/my.cnf
```

or:

```text id="chp4jv"
instances/redis/default/config/redis.conf
```

Configuration must not modify the package installation itself.

---

# 9. Instance data

Persistent service data belongs under:

```text id="29q4h6"
instances/<module>/<instance>/data/
```

Examples:

```text id="kv0p98"
instances/mysql/default/data/
instances/postgresql/default/data/
instances/redis/default/data/
```

This category is classified as:

```text id="kxuhho"
USER_DATA
```

even though Vaelen created the directory.

This distinction is critical.

Vaelen owns the location structurally.

The contents are considered valuable developer data.

They must not be silently deleted.

---

# 10. Ownership is not identical to deletion permission

Vaelen may create and manage:

```text id="fm6gsw"
instances/mysql/default/data/
```

but that does not mean Vaelen may automatically destroy it.

Therefore Vaelen distinguishes:

```text id="kvwx7o"
managed by Vaelen
```

from:

```text id="igwwn6"
safe to delete automatically
```

A MySQL data directory is managed by Vaelen but not automatically disposable.

---

# 11. Project registry

Global project registration state belongs under:

```text id="j6g6rv"
~/Library/Application Support/Vaelen/projects/
```

This may eventually be represented by the Core state database rather than individual JSON files.

Conceptually it stores:

```text id="7uw44e"
linked projects
parked directories
custom domains
driver selections
project identifiers
```

It does not contain project source code.

---

# 12. Projects remain external

A project such as:

```text id="gkib4e"
~/Code/callthewaiter
```

remains outside Vaelen's ownership boundary.

Running:

```bash id="aytdhe"
val link
```

means:

> Register this project with Vaelen.

It does not mean:

> Transfer ownership of this directory to Vaelen.

Therefore:

```bash id="qg2v76"
val unlink
```

must remove registration and generated infrastructure.

It must never delete:

```text id="e2yuxh"
~/Code/callthewaiter
```

---

# 13. Project configuration

A project may intentionally contain:

```text id="ldajh9"
vaelen.yml
```

and eventually perhaps:

```text id="tb3q0k"
vaelen.lock
```

These files are user/project-owned configuration.

They are expected to be:

* human-readable;
* editable;
* potentially committed to version control.

Vaelen may modify them only through explicit user-facing operations intended to edit project configuration.

Unlinking or uninstalling Vaelen must not automatically delete them.

---

# 14. Global configuration

Human-readable global Vaelen preferences belong under:

```text id="5qrm8q"
~/Library/Application Support/Vaelen/config/
```

Examples may include:

```text id="r3umfc"
default PHP version
default TLD
default HTTPS behavior
module preferences
update preferences
```

The exact format is separate from this ADR.

Configuration is persistent.

---

# 15. Internal state

Internal Core state belongs under:

```text id="f3g5be"
~/Library/Application Support/Vaelen/state/
```

or a state database located within Application Support.

This state may include:

```text id="ur1md8"
installed package records
instance records
desired service state
process ownership metadata
module registry state
operation history
schema version
```

This state is machine-managed.

Users should not normally edit it manually.

---

# 16. State database

SQLite is the preferred implementation candidate for structured internal Core state.

Reasons include:

* transactional writes;
* atomicity;
* schema migrations;
* concurrency;
* indexed queries;
* corruption resistance;
* mature macOS support.

Conceptually:

```text id="pkmj0v"
~/Library/Application Support/Vaelen/state/vaelen.sqlite
```

However:

> SQLite stores metadata about reality. It does not become reality itself.

If the database says:

```text id="1vmuyh"
MySQL running
```

but no MySQL process exists, actual machine state wins.

Core reconciles the discrepancy.

---

# 17. Database recovery principle

Internal state loss should be inconvenient but must not make user service data meaningless.

For example, if:

```text id="qbdgx9"
vaelen.sqlite
```

is lost but:

```text id="4epif5"
instances/mysql/default/data/
```

still exists, Vaelen should eventually be capable of detecting recoverable orphaned instance data.

The internal state database must not be the sole location of information required to recognize valuable user data.

---

# 18. Instance metadata

For this reason, instance directories should contain minimal local metadata.

Example:

```text id="zmlw19"
instances/mysql/default/
├── metadata.json
├── config/
└── data/
```

Metadata might contain:

```text id="a9k91f"
module: mysql
instance: default
createdWithVersion: 8.4.6
dataFormatVersion: ...
createdAt: ...
```

The Core database remains authoritative during normal operation.

Local metadata provides recovery context.

---

# 19. Runtime state

Ephemeral runtime artifacts should live separately from persistent state.

Conceptually:

```text id="hhd4h5"
~/Library/Application Support/Vaelen/runtime/
```

containing:

```text id="tm7oc4"
runtime/
├── sockets/
├── locks/
├── pids/
└── operations/
```

These artifacts are disposable after Vaelen determines they are stale.

---

# 20. Why runtime is not user data

A socket such as:

```text id="27e6go"
runtime/sockets/php-8.4.sock
```

has no value after the owning process disappears.

Similarly:

```text id="jsb88x"
runtime/pids/mysql-default.pid
```

does not represent persistent service state.

It represents runtime coordination.

Vaelen may remove stale runtime artifacts automatically after verifying they are no longer active.

---

# 21. Runtime directory permissions

Runtime directories should be accessible only as broadly as required.

Sockets used for internal Vaelen communication should not be world-writable.

Permissions should reflect the per-user nature of Vaelen.

Where possible:

```text id="szns61"
user owns runtime
other users cannot control runtime
```

The exact UNIX modes will be defined during implementation.

---

# 22. Locks

Core may use filesystem or database-backed locks for operations requiring exclusivity.

Example:

```text id="1yogqj"
runtime/locks/
```

Locks must be recoverable after crashes.

A stale lock file must not permanently prevent Vaelen from operating.

Lock validity must therefore never be inferred from file existence alone.

---

# 23. Caches

Disposable cached content belongs under:

```text id="blsuzf"
~/Library/Caches/Vaelen/
```

Examples:

```text id="v9gs03"
Caches/Vaelen/
├── downloads/
├── manifests/
├── metadata/
└── temporary/
```

Cache contents must be safe to delete while Vaelen is stopped.

Removing the cache must not destroy:

* installed packages;
* databases;
* project configuration;
* secrets;
* trusted system configuration.

---

# 24. Download cache

Downloaded upstream artifacts may be cached under:

```text id="a0ic1g"
~/Library/Caches/Vaelen/downloads/
```

Example:

```text id="vbnw2v"
php-8.4.13-arm64.tar.gz
mailpit-1.27.7-arm64.tar.gz
```

Once an artifact has been installed successfully, the cached archive is not required for normal package execution.

It may therefore be garbage-collected.

---

# 25. Staging

Package installation requires temporary staging.

Preferred location:

```text id="khnsg6"
~/Library/Caches/Vaelen/staging/
```

Example:

```text id="kh0p3g"
staging/
└── php-8.4.13-<operation-id>/
```

Only after successful verification and validation does content move atomically into:

```text id="plczq1"
Application Support/Vaelen/packages/
```

Interrupted staging directories may be removed automatically after Core confirms no active operation owns them.

---

# 26. Logs

Vaelen logs should use:

```text id="by2sg7"
~/Library/Logs/Vaelen/
```

Conceptually:

```text id="qyp8zq"
~/Library/Logs/Vaelen/
├── core/
│   └── vaelend.log
│
├── router/
│   └── router.log
│
├── modules/
│   ├── php/
│   ├── mysql/
│   └── redis/
│
└── projects/
    └── <project-id>/
        ├── queue.log
        └── scheduler.log
```

This follows macOS conventions and separates diagnostic history from application state.

---

# 27. Logs are disposable but useful

Logs are not authoritative state.

Deleting logs must not alter runtime configuration or user data.

However, Vaelen should not delete recent diagnostic information aggressively because logs are essential for troubleshooting.

A retention policy may eventually control:

```text id="hzzvkn"
maximum age
maximum size
rotation
compression
```

---

# 28. Log rotation

Long-running services must not produce unbounded log growth.

Vaelen should provide or configure log rotation where upstream software does not already handle it adequately.

The retention system should be generic.

Modules may provide sensible defaults.

Example:

```text id="krw4yh"
mysql
    max file size
    retained files
```

should not require custom Core branches for MySQL.

---

# 29. Secrets

Secrets should not be stored in ordinary plaintext state when a more appropriate macOS facility exists.

Examples include:

```text id="j8i6hb"
API tokens
tunnel credentials
private authentication tokens
sensitive module credentials
```

macOS Keychain should be preferred.

Core state stores a reference or logical identifier rather than the secret itself where practical.

---

# 30. Database development credentials

Not every local development password requires Keychain storage.

For example, a deliberately insecure local-only MySQL development account may be part of explicit instance configuration.

The security model should distinguish:

```text id="yqmboy"
actual secret
```

from:

```text id="7g5ipj"
local development credential intentionally stored in config
```

Vaelen should not pretend every string called `password` has identical sensitivity.

Modules should identify secret semantics explicitly.

---

# 31. TLS private keys

Local certificate authority private keys are sensitive.

They must not be treated like ordinary generated configuration.

Storage must use restrictive permissions and appropriate macOS security mechanisms.

Vaelen must be able to identify:

* where the CA key exists;
* which certificates it created;
* which trust settings it installed;
* how to remove them.

The exact CA implementation belongs to the TLS/security ADR.

---

# 32. System modifications

Some Vaelen state exists outside Vaelen directories.

Examples may include:

```text id="vkpt7h"
/etc/resolver/test

Keychain trust entries

LaunchAgent registration

privileged helper registration

shell integration
```

These are classified as:

```text id="p2ypyx"
SYSTEM_MODIFICATION
```

Core must maintain an explicit record of modifications Vaelen caused.

---

# 33. System modification ledger

Vaelen should maintain enough state to answer:

```text id="m3iukz"
What did Vaelen change outside its own directories?
```

Conceptually:

```text id="lv8pms"
System modifications

✓ .test resolver
✓ local CA trust
✓ LaunchAgent
✓ privileged helper
✓ shell PATH integration
```

This ledger supports:

* diagnostics;
* repair;
* upgrades;
* complete uninstallation.

---

# 34. Never infer system ownership solely by pathname

Suppose:

```text id="etjdbw"
/etc/resolver/test
```

already existed before Vaelen.

Vaelen must not automatically assume it owns that file merely because it uses the same path.

Installation should:

1. inspect existing state;
2. determine whether it is compatible;
3. preserve or explicitly resolve conflicts;
4. record exactly what Vaelen created or changed.

This prevents destructive uninstall behavior.

---

# 35. External installations

Vaelen may discover software outside its managed package root.

Examples:

```text id="b1ogke"
/opt/homebrew/bin/php
/opt/homebrew/bin/mysql
/usr/local/bin/redis-server
```

These are:

```text id="tl3bpl"
EXTERNAL
```

Vaelen does not own them.

It may:

* detect them;
* report conflicts;
* display useful diagnostics.

It must not delete or mutate them unless the user explicitly invokes a future feature designed to manage external installations.

---

# 36. User project files

Anything beneath a linked project remains user-owned unless Vaelen explicitly created a known Vaelen metadata file.

Even then, deletion must remain conservative.

Example:

```text id="uwt3l5"
~/Code/foo/
├── app/
├── composer.json
├── .env
└── vaelen.yml
```

Vaelen must never recursively delete this project as part of:

```text id="0f0u9m"
unlink
module uninstall
Vaelen uninstall
clean
doctor --fix
```

---

# 37. Project-local generated files

If Vaelen eventually needs project-local generated files, they should live in an explicitly recognizable location.

For example:

```text id="4pxe7m"
.vaelen/
```

could contain generated project-local state if such a need arises.

This is not required initially.

The architecture should avoid scattering invisible Vaelen files throughout user projects.

---

# 38. File ownership metadata

Where Vaelen creates files outside clearly Vaelen-owned directories, it should retain enough metadata to identify them safely.

The guiding rule is:

> If Vaelen cannot establish that it created or owns an external artifact, Vaelen must not silently delete it.

---

# 39. Deletion classes

Artifacts fall into three deletion classes.

## Automatically disposable

Examples:

```text id="skwn7o"
cache
stale staging
stale sockets
temporary downloads
expired transient operation state
```

Vaelen may remove these automatically when safe.

## Vaelen-owned removable

Examples:

```text id="8wb3nu"
unused package versions
generated router configuration
Vaelen logs
```

Removal is allowed through explicit lifecycle operations or documented garbage collection.

## Valuable/destructive

Examples:

```text id="xvbrio"
MySQL databases
PostgreSQL databases
persistent Redis data
user projects
private keys
user-controlled project configuration
```

Deletion requires explicit destructive intent.

---

# 40. Destructive operation vocabulary

Core should distinguish ordinary removal from destructive deletion.

Conceptually:

```text id="pvsr5l"
remove
uninstall
clean
purge
```

Their meanings should remain consistent.

### Remove

Remove a registration or individual non-destructive object.

### Uninstall

Remove executable capability while preserving valuable data.

### Clean

Remove disposable or safely unused artifacts.

### Purge

Destroy software and associated persistent data.

The exact CLI surface may evolve.

The semantic distinction should not.

---

# 41. `val clean`

A future:

```bash id="4i7qde"
val clean
```

should inspect removable artifacts.

Example:

```text id="2h84o9"
Vaelen can reclaim 1.2 GB

Download cache             410 MB
Stale package staging       82 MB
Unused PHP 8.3.22           71 MB
Old logs                   240 MB
Unused MySQL package       397 MB

Persistent service data:
NOT INCLUDED
```

Valuable user data must never appear as ordinary cache cleanup.

---

# 42. Dry run

Potentially destructive cleanup operations should support inspection before execution.

Example:

```bash id="al90ab"
val clean --dry-run
```

or equivalent structured planning.

Core should produce the plan.

The CLI merely renders it.

---

# 43. Purge confirmation

A destructive purge should explain exactly what will be deleted.

Example:

```text id="0jghoz"
Purge mysql/default?

This will permanently delete:

MySQL packages
    8.4.6

Instance
    mysql/default

Database data
    3.7 GB

Configuration
    my.cnf

Logs
    84 MB

This operation cannot be undone.
```

Automation should require an explicit destructive flag rather than relying on an interactive confirmation.

---

# 44. Symlinks

Symlinks may be used internally where they provide clear value.

Example:

```text id="gblrrx"
packages/php/current -> 8.4.13
```

However, Vaelen's authoritative package selection should remain structured state rather than depending exclusively on symlink inspection.

Symlinks are implementation conveniences.

They are not the sole state database.

---

# 45. Atomic file writes

Critical configuration and metadata files should use atomic replacement where practical.

Conceptually:

```text id="c7z8n0"
write temporary file
       ↓
flush
       ↓
validate
       ↓
rename over destination
```

A crash during configuration generation should not leave half-written JSON/YAML/configuration where avoidable.

---

# 46. File permissions

Vaelen-created files should follow least privilege.

Examples:

```text id="yffwn0"
ordinary config
    user-readable/writable

runtime socket
    user-scoped

secret/private key
    restrictive user access

database data
    service/user access only as needed
```

World-writable files should not be created merely for convenience.

---

# 47. No root-owned user state

Ordinary Vaelen data under:

```text id="a8xwep"
~/Library/Application Support/Vaelen/
```

must not become root-owned because a privileged helper happened to participate in setup.

Privileged operations should avoid writing user-state files directly where possible.

The normal user daemon owns normal Vaelen state.

---

# 48. Backups

Vaelen should classify data according to backup relevance.

Conceptually:

```text id="kvlk2e"
Packages        reproducible
Cache           disposable
Logs            disposable
Runtime         disposable
Core state      reconstructable where possible
Instance data   valuable
Project files   user-owned
Secrets         sensitive
```

This classification should influence future backup/export functionality.

---

# 49. Vaelen does not automatically back up databases

Vaelen managing a database does not imply that Vaelen guarantees backups.

That would create a dangerous expectation.

Future backup functionality may exist.

Until then, persistent instance data should be described as:

> preserved by lifecycle operations, but not automatically backed up.

---

# 50. Export and migration

The filesystem model should make future machine migration straightforward.

A future operation might export:

```text id="fxrxr6"
Vaelen configuration
project registry
instance configuration
selected persistent data
```

Packages themselves generally need not be migrated because they can be downloaded again.

The architecture should favor reproducibility over copying opaque installations.

---

# 51. Machine-specific paths

Internal state may contain absolute paths such as:

```text id="2ml9mt"
/Users/bane/Code/project
```

Migration tooling must treat these as machine-specific.

Project configuration committed to repositories should avoid embedding machine-specific Vaelen paths wherever practical.

---

# 52. Filesystem reconciliation

Core should periodically or on startup validate important filesystem assumptions.

Examples:

```text id="ngmxgz"
package record exists
    but package directory missing

instance record exists
    but data directory missing

package directory exists
    but database record missing

runtime socket exists
    but process absent
```

These should produce explicit recoverable states.

---

# 53. Orphan detection

Vaelen should recognize orphaned managed artifacts.

Examples:

```text id="9x8tlk"
ORPHANED_PACKAGE

ORPHANED_INSTANCE

STALE_RUNTIME_ARTIFACT

UNKNOWN_VAELEN_DIRECTORY
```

Valuable orphaned instance data must not be deleted automatically.

Instead:

```text id="xt1nkm"
Found preserved MySQL instance data.

Instance:
mysql/default

Last known version:
8.4.6

[ Recover ]
[ Inspect ]
[ Delete ]
```

---

# 54. Corruption handling

If internal metadata is unreadable, Vaelen should fail conservatively.

Bad:

```text id="rvwmru"
metadata unreadable
    ↓
assume unused
    ↓
delete directory
```

Correct:

```text id="ukeywj"
metadata unreadable
    ↓
ownership uncertain
    ↓
preserve
    ↓
report diagnostic
```

Uncertainty must bias toward preserving user data.

---

# 55. State migrations

Internal state schemas will evolve.

Every persistent machine-managed format must have an explicit schema version.

This includes:

```text id="kyujy7"
SQLite schema
package metadata
instance metadata
system modification records
```

Migrations must be transactional where possible.

A failed Vaelen update should not leave state half-migrated.

---

# 56. Downgrade behavior

Older Vaelen versions may not understand newer state schemas.

Vaelen must detect this explicitly.

It should not attempt to interpret unknown newer formats optimistically.

Example:

```text id="10drkj"
This Vaelen version cannot read state schema 4.

Supported:
1–3
```

This is preferable to silent corruption.

---

# 57. Package downgrade vs data downgrade

Package versions are software.

Instance data may have its own compatibility requirements.

Therefore:

```text id="f0hw81"
install older MySQL binary
```

does not imply:

```text id="rzoucb"
old binary can safely open current database
```

Filesystem layout makes this distinction explicit.

Modules must provide compatibility knowledge where necessary.

---

# 58. Application uninstall

Removing:

```text id="y1vucm"
/Applications/Vaelen.app
```

alone does not constitute a complete Vaelen uninstall.

A complete uninstall may need to address:

```text id="jbs3fo"
Vaelen.app
vaelend registration
privileged helper
Application Support
Caches
Logs
resolver configuration
certificate trust
shell integration
```

Persistent service data requires special handling.

---

# 59. Safe uninstall

The default Vaelen uninstall experience should preserve valuable service data unless the user explicitly requests complete destruction.

Conceptually:

```text id="d6gy1f"
Remove Vaelen

Remove:
✓ Application
✓ Daemon
✓ Managed packages
✓ Cache
✓ Runtime state
✓ System integrations

Preserve:
✓ MySQL data
✓ PostgreSQL data
✓ project configuration

[ Remove Vaelen ]
```

A separate explicit option may offer:

```text id="4ns9fn"
Delete all Vaelen-managed data
```

with strong confirmation.

---

# 60. Uninstall ledger

Before uninstalling, Vaelen should build a removal plan from actual tracked ownership.

It should not rely on a hard-coded list alone.

Example:

```text id="f98pg8"
System modifications owned by this installation:

.test resolver
Vaelen Local CA trust
Vaelen LaunchAgent
Vaelen privileged helper
shell integration
```

Only modifications Vaelen can establish ownership of should be automatically reverted.

---

# 61. Multiple Vaelen versions

The filesystem architecture should avoid assumptions that the application bundle and data always update simultaneously.

An application update may temporarily involve:

```text id="3c1pph"
new Vaelen.app
old vaelend
existing state
running services
```

Protocol and state schema compatibility must therefore be explicit.

---

# 62. No hidden dot-directory as the entire architecture

Vaelen should not put its complete global runtime under:

```text id="3z31wk"
~/.vaelen
```

simply because many developer tools do so.

Vaelen is a native macOS application and should use native macOS filesystem conventions.

Project-local developer configuration may still use conventional project files where appropriate.

---

# 63. CLI path abstraction

Users should not need to know Vaelen's filesystem layout for ordinary operations.

Preferred:

```bash id="1k82e9"
val logs mysql
val module info php
val doctor
```

rather than instructions such as:

```text id="yubwrq"
open ~/Library/Application Support/Vaelen/...
```

The filesystem should nevertheless remain understandable to advanced users.

---

# 64. Human inspectability

Native conventions do not mean opaque storage.

A developer inspecting:

```text id="51y7rj"
~/Library/Application Support/Vaelen/
```

should be able to broadly understand:

```text id="okxlpe"
packages
instances
configuration
state
```

Vaelen should avoid deliberately obscure hashed directory structures where human-readable identifiers are safe.

---

# 65. Stable identifiers

Filesystem-friendly display names are not sufficient identity.

Projects, instances, and operations may require stable internal identifiers.

For example, two projects may both be named:

```text id="b5q9hm"
api
```

Stable IDs may therefore coexist with readable paths or metadata.

The exact identifier strategy belongs to implementation.

---

# 66. Path traversal safety

Module manifests, project names, and user-supplied identifiers must never be allowed to escape Vaelen-owned roots through path traversal.

Inputs such as:

```text id="pnj7l6"
../../something
```

must never influence managed paths without validation.

Core filesystem APIs should enforce root boundaries.

---

# 67. Symlink safety

Deletion routines must treat symlinks conservatively.

Recursive deletion must never follow a symlink out of a Vaelen-owned directory and delete external user files.

Before destructive operations, Core should distinguish:

```text id="v0hhdn"
regular file
directory
symlink
```

and apply safe semantics.

---

# 68. Canonical paths

Project registration and ownership checks should use canonicalized paths appropriately.

This avoids treating:

```text id="tt5w0h"
~/Code/foo
```

and:

```text id="7m0w17"
/Users/example/Code/foo
```

as unrelated projects merely because their textual representations differ.

Symlinked project paths require deliberate behavior.

---

# 69. Filesystem case behavior

Vaelen must not assume that every macOS filesystem is case-insensitive.

Identifiers and collision checks should account for the actual filesystem behavior where relevant.

The internal model should avoid relying on case-only distinctions.

---

# 70. Disk space awareness

Package installation and stateful services may consume substantial disk space.

Before large package operations, Core should be capable of checking available storage.

Failure due to insufficient space should be explicit.

Example:

```text id="ndx6zg"
Cannot install MySQL 8.4.

Required:
620 MB

Available:
184 MB
```

Database growth monitoring may later become part of resource observability.

---

# 71. Partial writes and disk exhaustion

Operations must account for disk exhaustion during:

* downloads;
* extraction;
* database initialization;
* configuration writes;
* log writes.

Critical state updates should not be committed before dependent filesystem operations succeed.

---

# 72. Filesystem event monitoring

Vaelen may use native filesystem events where useful.

However, the existence of a managed directory does not justify continuous watching.

Watchers should exist only when a running feature genuinely needs them.

This preserves:

> Off means off.

---

# 73. Time Machine and backup systems

Vaelen should avoid unnecessary churn in persistent directories.

Large reproducible package/cache artifacts should be clearly separable from valuable instance data so users or future documentation can make sensible backup decisions.

Vaelen should not assume Time Machine is enabled.

---

# 74. Proposed initial layout

The initial implementation should target approximately:

```text id="8oqslh"
/Applications/
└── Vaelen.app


~/Library/Application Support/Vaelen/
│
├── packages/
│   ├── caddy/
│   └── php/
│
├── instances/
│   └── ...
│
├── config/
│   └── ...
│
├── projects/
│   └── ...
│
├── state/
│   └── vaelen.sqlite
│
├── runtime/
│   ├── sockets/
│   ├── locks/
│   └── process-state/
│
└── security/
    └── non-secret security metadata


~/Library/Caches/Vaelen/
│
├── downloads/
└── staging/


~/Library/Logs/Vaelen/
│
├── core/
├── router/
├── modules/
└── projects/
```

Secrets live in Keychain where appropriate.

System modifications are tracked explicitly.

Projects remain wherever the developer keeps them.

---

# 75. Ownership matrix

| Artifact                   |             Managed by Vaelen |   Automatically disposable | User confirmation required for destructive deletion |
| -------------------------- | ----------------------------: | -------------------------: | --------------------------------------------------: |
| `Vaelen.app`               |                           Yes |                        Yes |                                                  No |
| Package binaries           |                           Yes |              Conditionally |                                         Normally no |
| Download cache             |                           Yes |                        Yes |                                                  No |
| Staging directories        |                           Yes |             Yes when stale |                                                  No |
| Runtime sockets            |                           Yes |             Yes when stale |                                                  No |
| Locks                      |                           Yes |             Yes when stale |                                                  No |
| Logs                       |                           Yes | Yes according to retention |                                                  No |
| Core state DB              |                           Yes |                         No |                                                 Yes |
| Generated instance config  |                           Yes |                         No |                                 With instance purge |
| MySQL/Postgres data        |                           Yes |                     **No** |                                             **Yes** |
| Persistent Redis data      |                           Yes |                     **No** |                                             **Yes** |
| Project source             |                            No |                  **Never** |                            Outside Vaelen ownership |
| `vaelen.yml`               |                  Project/user |                         No |                     Explicit project operation only |
| Keychain secrets           |   Yes where created by Vaelen |                         No |                                                 Yes |
| Vaelen CA private key      |                           Yes |                         No |                                Yes/system uninstall |
| Resolver entry             | Yes only if Vaelen created it |                         No |             Remove during explicit system uninstall |
| External Homebrew binaries |                            No |                  **Never** |                            Outside Vaelen ownership |

---

# 76. Consequences

## Positive

### Data safety

Valuable state is structurally separated from disposable software.

### Predictable uninstall

Vaelen can explain what it owns and what will remain.

### Native macOS behavior

Application Support, Caches, Logs, and Keychain are used according to their roles.

### Easier debugging

The filesystem remains understandable.

### Safer updates

Immutable packages and separate instance data reduce upgrade risk.

### Recovery

Instance metadata and explicit ownership allow recovery even when internal state is damaged.

### Future cleanup tools

`val clean` can safely distinguish cache from valuable data.

---

# 77. Costs

This structure creates more directories and metadata than placing everything under a single application folder.

Core must implement:

* ownership tracking;
* state migrations;
* safe deletion;
* orphan detection;
* path validation;
* atomic filesystem operations;
* system modification tracking.

That complexity is accepted because Vaelen will manage valuable developer infrastructure.

---

# 78. Alternatives Considered

## Store everything inside `/Applications/Vaelen`

Rejected.

Application bundles should remain replaceable, and mutable user/service state must survive application updates.

---

## Store everything under `~/.vaelen`

Rejected as the primary global layout.

Vaelen is a native macOS application and should follow macOS filesystem conventions.

---

## Store package and service data together

Rejected.

This makes safe updates, uninstall, rollback, and data preservation substantially harder.

---

## Treat everything Vaelen creates as disposable

Rejected.

Database contents and other service state may be valuable even when Vaelen originally created the directory.

---

## Treat nothing as disposable

Rejected.

Caches, stale sockets, staging directories, and reproducible packages require manageable cleanup.

---

# 79. Open Implementation Questions

1. Final SQLite schema.
2. Whether `runtime/` belongs under Application Support or another per-user runtime location.
3. Exact log rotation defaults.
4. Exact file permissions for each artifact class.
5. Instance metadata schema.
6. System modification ledger schema.
7. Project stable identifier strategy.
8. Exact handling of symlinked project roots.
9. Whether package metadata lives inside each package directory or exclusively in Core state plus recovery metadata.
10. Backup/export format.
11. Whether `vaelen.lock` is introduced with initial project configuration or later.
12. Exact Keychain service/account naming scheme.
13. Exact uninstall UX.
14. Garbage-collection retention defaults.

---

# 80. Invariants Established by This ADR

1. `/Applications/Vaelen.app` contains no valuable mutable service data.
2. Persistent Vaelen state uses native macOS Application Support conventions.
3. Disposable downloads and staging use the cache hierarchy.
4. Logs are separated from authoritative state.
5. Secrets use Keychain or appropriately protected storage where warranted.
6. Packages and instances are physically separate.
7. Package directories contain software, not service data.
8. Valuable instance data is never silently deleted.
9. Vaelen management does not imply automatic deletion permission.
10. User projects remain outside Vaelen ownership.
11. `val unlink` never deletes a user project.
12. Project configuration remains user/project-owned.
13. Runtime sockets, locks, and transient state are disposable after safe stale detection.
14. Internal state never overrides observed machine reality.
15. Loss of Core metadata should not automatically imply loss of instance data.
16. Instance directories retain enough metadata to aid recovery.
17. Cache deletion must never break installed packages or delete user data.
18. Vaelen tracks system modifications it causes.
19. Vaelen does not remove external system modifications it cannot establish ownership of.
20. External Homebrew/system binaries remain external.
21. Uninstall and purge are different operations.
22. Purge requires explicit destructive intent.
23. Filesystem uncertainty biases toward preservation.
24. Recursive deletion must not follow symlinks outside Vaelen-owned roots.
25. Critical metadata/configuration writes are atomic where practical.
26. Ordinary user state must not become root-owned.
27. Persistent schemas are explicitly versioned.
28. Unknown newer schemas must fail safely.
29. Package rollback and data-format rollback are separate concerns.
30. Vaelen must always be able to explain what it owns before deleting it.

---

# Summary

Vaelen manages software, infrastructure, and potentially valuable developer data.

Those things cannot share one lifecycle.

The filesystem therefore reflects their meaning:

```text id="1lj7jv"
Application
    disposable code

Packages
    reproducible software

Instances
    configuration + valuable service data

State
    Vaelen's model of the environment

Runtime
    ephemeral coordination

Caches
    disposable downloads

Logs
    disposable diagnostics

Keychain
    secrets

System
    explicitly tracked modifications

Projects
    owned by the developer
```

The central safety rule is:

> **Vaelen may automatically delete only what it can prove it owns and knows is disposable.**

When ownership is uncertain, preserve.

When data may be valuable, preserve.

When deletion is destructive, require explicit intent.

This gives Vaelen a filesystem model suitable not only for PHP binaries and temporary sockets, but eventually for databases and developer infrastructure that users must be able to trust.
