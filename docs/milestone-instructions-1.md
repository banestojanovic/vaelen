
You are continuing development of Vaelen.

Milestone 0 has been completed successfully and manually verified.

The existing implementation currently proves:

- `vaelend` is the authoritative per-user Core process.
- `val` communicates with Core over structured UNIX-domain-socket IPC.
- Vaelen.app communicates with the same Core.
- IPC protocol versioning works.
- structured JSON CLI output works.
- the single-daemon invariant works.
- Core availability/unavailability is reflected correctly by clients.
- automated tests pass.

Do not redesign or replace working Milestone 0 architecture unless implementation evidence demonstrates a real problem.

Your task is now to implement:

# MILESTONE 1 — PROJECT REGISTRY & DISCOVERY

The goal is to introduce Vaelen's first persistent developer-facing domain model:

    Project

and support:

    val link
    val unlink
    val links
    val park
    val unpark
    val paths

without implementing PHP, routing, DNS, TLS, modules, services, project runtime reconciliation, or framework-specific behavior.

This milestone should prove that Vaelen can safely discover, identify, persist, query, and remove references to developer-owned projects while respecting the filesystem and ownership rules established by the architecture.

--------------------------------------------------
1. READ THE ARCHITECTURE FIRST
--------------------------------------------------

Before modifying code, read these files completely:

    docs/PHILOSOPHY.md
    docs/ARCHITECTURE.md

    docs/adr/0001-core-runtime-model.md
    docs/adr/0004-filesystem-state-and-ownership.md
    docs/adr/0005-ipc-and-client-protocol.md
    docs/adr/0008-project-model-and-desired-state-reconciliation.md

Also consult the other ADRs if a decision touches their domain.

For this milestone, ADR-0004 and ADR-0008 are especially important.

Treat the documentation as the architectural source of truth.

If implementation details in this prompt conflict with an ADR, the ADR wins.

If implementation evidence reveals that an ADR assumption is materially wrong, do not silently work around it. Explain the issue before introducing a contradictory architecture.

--------------------------------------------------
2. INSPECT MILESTONE 0
--------------------------------------------------

Before editing:

1. Inspect the repository tree.
2. Inspect Package.swift and Xcode configuration.
3. Inspect VaelenCore.
4. Inspect VaelenIPC.
5. Inspect VaelenDaemon.
6. Inspect VaelenCLI.
7. Inspect the menu-bar app.
8. Inspect the current test suite.
9. Understand how filesystem paths are centralized.
10. Understand how Core state is isolated and exposed through IPC.

Preserve the existing architecture.

Do not create parallel implementations of functionality already present.

Before coding, briefly state:

- what currently exists;
- what you intend to add;
- which existing types will be extended;
- any implementation decision not explicitly resolved by the ADRs.

Then implement.

--------------------------------------------------
3. MILESTONE GOAL
--------------------------------------------------

At completion, this should work:

    cd ~/Code/my-project
    val link

and Vaelen should register that directory as a project.

Then:

    val links

should show the registered project.

Then:

    val unlink

should remove the registration WITHOUT modifying the project directory.

Additionally:

    cd ~/Code
    val park

should register that directory as a discovery root.

Immediate child directories should become discoverable as projects without eagerly starting, installing, configuring, or modifying anything.

Conceptually:

    ~/Code
      ├── callthewaiter/
      ├── syncproof/
      └── wordpress-site/

             │
             ▼

        Parked Path
             │
             ▼

      Project Discovery
             │
             ▼

       Project Registry
             │
             ▼

           Core
          /    \
       val    Vaelen.app

The registry is authoritative Core state.

Clients do not maintain their own project registries.

--------------------------------------------------
4. IMPORTANT SCOPE BOUNDARY
--------------------------------------------------

M1 implements project registration and discovery only.

DO NOT implement:

- PHP
- PHP version detection
- PHP-FPM
- Composer integration
- Caddy
- nginx
- routing
- DNS
- `.test` resolver configuration
- TLS
- certificates
- HTTPS
- modules
- package management
- MySQL
- PostgreSQL
- Redis
- Mailpit
- queues
- scheduler
- `val up`
- `val down`
- desired-state reconciliation
- framework runtime behavior
- privileged helper
- launchd changes unrelated to M1
- filesystem watchers unless genuinely required
- project configuration mutation
- `.env` mutation
- `vaelen.yml` generation

Do not create placeholder implementations for these.

M1 should remain small.

--------------------------------------------------
5. PROJECT DOMAIN MODEL
--------------------------------------------------

Introduce a typed Project model in the appropriate Core/domain layer.

A project should conceptually contain at least:

    id
    name
    rootPath
    registrationKind

Potential registration kinds:

    linked
    discovered

Do not blindly copy those exact names if the existing codebase suggests better Swift naming.

Project identity must NOT simply be its display name.

Project identity must NOT rely exclusively on its current path.

ADR-0008 explicitly separates stable project identity from filesystem path.

Choose a small robust stable ID representation.

A UUID is acceptable for explicitly registered projects unless existing architecture suggests something better.

Do not invent a complicated global identity scheme.

--------------------------------------------------
6. PROJECT SOURCE OWNERSHIP
--------------------------------------------------

This is a critical invariant.

Vaelen DOES NOT own project source directories.

If a developer links:

    ~/Code/callthewaiter

Vaelen owns only its registration metadata.

Vaelen must never:

- delete the directory;
- move the directory;
- rename the directory;
- modify arbitrary source files;
- chmod the directory;
- recursively clean the directory.

`val unlink` means:

    remove Vaelen's reference to this project

NOT:

    remove the project

This distinction should be visible in implementation and tests.

--------------------------------------------------
7. CANONICAL PATHS
--------------------------------------------------

Filesystem identity must be handled carefully.

Before storing project paths:

- expand relevant user path representations if needed;
- convert relative paths to absolute paths;
- normalize path representation;
- resolve filesystem semantics carefully;
- account for symlinks according to ADR-0008;
- avoid duplicate registrations of the same physical project.

For example, these should not accidentally become separate logical registrations when they refer to the same canonical directory:

    ~/Code/foo
    /Users/bane/Code/foo
    ~/Code/../Code/foo

Be conservative with symlinks.

Do not perform destructive symlink resolution or mutate symlink targets.

Centralize canonicalization behavior.

Add tests.

--------------------------------------------------
8. LINK
--------------------------------------------------

Implement:

    val link

When executed inside a project directory, it should register the current working directory.

Example:

    cd ~/Code/callthewaiter
    val link

Expected output approximately:

    Linked callthewaiter
    /Users/.../Code/callthewaiter

Also support an explicit path if it fits the CLI architecture cleanly:

    val link ~/Code/callthewaiter

Do not require explicit path support if doing so would distort the CLI design, but it is desirable.

Linking should be idempotent.

Running:

    val link
    val link

must NOT create two projects.

The second invocation should report that the project is already linked or otherwise return a successful no-op.

--------------------------------------------------
9. NAMED LINKS
--------------------------------------------------

ADR-0008 allows named links conceptually.

Support:

    val link my-api

for the current directory if this can be expressed unambiguously within the CLI parser.

The name acts as a Vaelen-facing project/link name.

However:

- project identity must remain separate from name;
- renaming/alias behavior should not become a large subsystem;
- names should be validated;
- duplicate/conflicting names should produce clear errors.

If CLI ambiguity between a path and a name becomes problematic, prefer an explicit option such as:

    val link --name my-api

Choose the cleanest API and document the decision.

Do not introduce magical guessing if explicit syntax is safer.

--------------------------------------------------
10. UNLINK
--------------------------------------------------

Implement:

    val unlink

from inside a registered project.

Also support unlinking by registered name if clean:

    val unlink my-api

The command removes only the explicit registration.

It MUST NOT:

- delete source files;
- remove the directory;
- remove project configuration;
- uninstall anything;
- stop unrelated resources;
- modify `.env`;
- modify `vaelen.yml`.

For M1 there are no runtime resources to stop anyway.

The implementation should nevertheless preserve this semantic boundary.

--------------------------------------------------
11. LINKS
--------------------------------------------------

Implement:

    val links

This should list explicitly linked projects.

Human-readable output should be compact.

For example:

    Linked Projects

    callthewaiter    ~/Code/callthewaiter
    syncproof        ~/Code/syncproof

Exact formatting may differ.

Also support:

    val links --json

using structured Core data.

Do not parse human output to generate JSON.

--------------------------------------------------
12. PARK
--------------------------------------------------

Implement the Valet-inspired concept:

    cd ~/Code
    val park

This registers the current directory as a parked discovery root.

It does NOT eagerly register every child as a permanent explicit link.

It establishes:

    "Projects directly beneath this path may be discovered by Vaelen."

Initial M1 discovery depth:

    immediate child directories only

Do NOT recursively scan arbitrary directory trees.

For:

    ~/Code/
        app-one/
        app-two/
        archive/
            old/
                app-three/

M1 may discover:

    app-one
    app-two
    archive

but should NOT recursively discover:

    archive/old/app-three

unless architecture explicitly requires otherwise.

Keep the rule deterministic.

--------------------------------------------------
13. PARKED PATH MODEL
--------------------------------------------------

Introduce a typed ParkedPath or equivalent domain model.

It should contain enough information to provide:

- stable registration;
- canonical root path;
- date/metadata only if actually useful;
- deterministic persistence.

Do not add timestamps everywhere merely because they might be useful someday.

--------------------------------------------------
14. PARK IDEMPOTENCY
--------------------------------------------------

Running:

    val park
    val park

in the same canonical directory must not create duplicate parked paths.

Return a successful no-op or clear already-parked result.

--------------------------------------------------
15. UNPARK
--------------------------------------------------

Implement:

    val unpark

for the current directory.

Optionally allow:

    val unpark ~/Code

if consistent with CLI design.

Unparking removes the discovery root.

It MUST NOT:

- delete directories;
- remove explicit links inside that directory;
- modify project source;
- uninstall anything.

After unpark, projects that exist ONLY because of discovery should disappear from the effective discovered project list.

Explicitly linked projects remain.

--------------------------------------------------
16. PATHS
--------------------------------------------------

Implement:

    val paths

to list parked discovery roots.

Example:

    Parked Paths

    ~/Code
    ~/Sites

Also:

    val paths --json

Return structured data.

--------------------------------------------------
17. DISCOVERY
--------------------------------------------------

Implement deterministic project discovery from parked roots.

For each parked path:

1. validate the root exists;
2. inspect immediate children;
3. consider directories only;
4. canonicalize candidates;
5. produce discovered project representations;
6. merge them with explicit registrations.

Do not recursively traverse.

Do not install filesystem watchers yet.

Discovery may occur on demand when Core queries projects.

That is preferable to a permanent background watcher for M1.

Remember the philosophy:

    unused functionality should not create unnecessary background work.

--------------------------------------------------
18. WHAT COUNTS AS A PROJECT?
--------------------------------------------------

For M1, be deliberately permissive.

An immediate child directory of a parked path may be treated as a discoverable project directory.

Do NOT require:

- composer.json
- package.json
- artisan
- wp-config.php
- .git
- vaelen.yml

yet.

Framework/project interpretation belongs to drivers later.

M1 is filesystem discovery, not framework detection.

However, ignore obvious filesystem entries that are not directories.

Do not invent a large exclusion heuristic system yet.

--------------------------------------------------
19. EXPLICIT LINK VS DISCOVERED PROJECT
--------------------------------------------------

ADR-0008 states:

    Explicit link wins over parked defaults but one logical project.

Implement this now.

Example:

    ~/Code is parked

and therefore:

    ~/Code/foo

is discovered.

Then:

    cd ~/Code/foo
    val link

must NOT result in:

    foo [discovered]
    foo [linked]

as two projects.

There should be one logical project.

Its explicit registration takes precedence.

The same canonical physical directory should resolve to one effective project.

Test this carefully.

--------------------------------------------------
20. PROJECT NAME
--------------------------------------------------

Default project name should initially derive from the directory name.

For:

    /Users/bane/Code/callthewaiter

default:

    callthewaiter

If explicitly linked with a custom name, that name wins.

Do not implement framework-derived names yet.

--------------------------------------------------
21. DEFAULT DOMAIN
--------------------------------------------------

ADR-0008 describes default:

    <name>.test

It is acceptable for the Project representation to expose a derived default domain in M1 if this remains pure metadata.

For example:

    callthewaiter.test

But DO NOT:

- configure DNS;
- create routes;
- create certificates;
- claim the domain works.

If including domain would encourage premature routing logic, defer it to the routing milestone.

Prefer architectural cleanliness over showing a fake domain.

--------------------------------------------------
22. PERSISTENCE
--------------------------------------------------

Project registration and parked paths must survive daemon restart.

Use the persistence model established by ADR-0004.

ADR-0004 prefers:

    ~/Library/Application Support/Vaelen/state/vaelen.sqlite

for Core metadata.

If M0 already established an appropriate state store, extend it.

If not, M1 is the first milestone where durable Core state genuinely matters.

Use SQLite unless implementation evidence provides a compelling reason not to.

Do NOT introduce:

- Core Data;
- SwiftData;
- Realm;
- external database dependencies;
- JSON files as an ad-hoc database if SQLite is practical.

The architecture intentionally selected SQLite for Core metadata.

--------------------------------------------------
23. SQLITE IMPLEMENTATION
--------------------------------------------------

Keep the persistence layer small.

We need approximately:

    projects
    parked_paths

Do not create 20 future tables.

Use schema versioning/migrations from the beginning, but keep it lightweight.

For example, conceptual schema:

    schema_version

    projects
        id
        name
        canonical_path
        registration_kind

    parked_paths
        id
        canonical_path

Exact schema is an implementation decision.

Do not store derived/discovered projects permanently unless there is a concrete reason.

A strong M1 design is:

    persist explicit links
    persist parked roots
    derive discovered projects from current filesystem reality

because discovery is reality, not ownership.

Use your engineering judgment, but preserve that distinction.

--------------------------------------------------
24. SQLITE OWNERSHIP PRINCIPLE
--------------------------------------------------

Remember ADR-0004:

    SQLite stores metadata about reality.
    It does not become reality itself.

If the database says a project exists but the directory has disappeared, Vaelen must not pretend the filesystem exists.

If a parked root disappears, retain its registration unless explicitly removed, but report it appropriately as unavailable/missing.

Do not silently delete metadata merely because a disk, volume, or directory is temporarily unavailable.

--------------------------------------------------
25. MISSING PROJECT DIRECTORIES
--------------------------------------------------

If an explicitly linked project's source directory disappears:

    val links

should still be able to represent the registration.

Its state may be something like:

    missing

or:

    unavailable

Choose a small typed representation.

Do NOT automatically remove it.

The user may have:

- renamed a directory;
- disconnected an external disk;
- temporarily moved something.

Preservation wins over guessing.

--------------------------------------------------
26. MISSING PARKED PATHS
--------------------------------------------------

Likewise, a parked path that becomes unavailable should remain registered.

Expose that state.

Do not automatically unpark it.

--------------------------------------------------
27. CORE AUTHORITY
--------------------------------------------------

All mutations go through `vaelend`.

CLI commands must NOT directly edit SQLite.

Vaelen.app must NOT directly edit SQLite.

Correct:

    val
      │
      ▼
    IPC
      │
      ▼
    vaelend
      │
      ▼
    Project Registry
      │
      ▼
    persistence

Incorrect:

    val ──► SQLite

The same applies to parked paths.

--------------------------------------------------
28. CORE SERVICES
--------------------------------------------------

Introduce only the abstractions actually required.

Likely concepts include something equivalent to:

    ProjectRegistry
    ProjectRepository
    ProjectDiscovery

but do not force these names.

A reasonable separation is:

    ProjectRegistry
        domain behavior / merging / identity

    ProjectRepository
        durable explicit registrations

    ProjectDiscovery
        current filesystem discovery

Do not create a generic Repository Framework.

Do not create a generic Reconciliation Engine.

Build what M1 needs.

--------------------------------------------------
29. ACTOR / CONCURRENCY SAFETY
--------------------------------------------------

Project registry mutations are authoritative Core mutations.

Ensure concurrent clients cannot corrupt state or create duplicates.

Examples:

two clients simultaneously run:

    val link ~/Code/foo

Result:

    exactly one logical explicit registration

Two clients simultaneously run:

    val park ~/Code

Result:

    exactly one parked root

Use SQLite constraints and appropriate Core isolation rather than relying solely on optimistic application checks.

--------------------------------------------------
30. IPC EXTENSION
--------------------------------------------------

Extend protocol version 1 only as appropriate.

Add structured methods conceptually equivalent to:

    project.link
    project.unlink
    project.list

    path.park
    path.unpark
    path.list

Do not use those exact names if the established IPC naming convention suggests something cleaner.

Keep requests/responses typed.

Do not send arbitrary dictionaries around the Core.

Do not create future IPC endpoints.

--------------------------------------------------
31. PROTOCOL VERSIONING
--------------------------------------------------

Adding backwards-compatible methods does not necessarily require changing the protocol version.

Follow the compatibility semantics established in M0.

Do not increment the protocol version merely because new methods exist unless the protocol compatibility contract requires it.

Document the decision.

--------------------------------------------------
32. CLI PATH DISPLAY
--------------------------------------------------

Internally store canonical absolute paths.

For human output, it is desirable to render paths under the current user's home directory as:

    ~/Code/foo

rather than:

    /Users/bane/Code/foo

where appropriate.

This is presentation only.

JSON output should preferably return canonical absolute paths.

Do not store `~` in persistent state.

--------------------------------------------------
33. JSON OUTPUT
--------------------------------------------------

Support machine-readable output for list/query commands:

    val links --json
    val paths --json

If appropriate, mutation commands may also support JSON, but do not overbuild this if the CLI architecture does not yet provide a generic output mode.

Structured output should contain stable typed fields.

Example conceptual project JSON:

    {
      "id": "...",
      "name": "callthewaiter",
      "path": "/Users/.../Code/callthewaiter",
      "registration": "linked",
      "availability": "available"
    }

Do not treat this exact schema as immutable public API yet.

--------------------------------------------------
34. OPTIONAL `val status` EXTENSION
--------------------------------------------------

If clean, extend:

    val status

when executed inside a known project to include small contextual information.

For example:

    Vaelen

    Core       Running
    Version    0.0.1-dev
    PID        12345
    Protocol   1

    Project    callthewaiter
    Path       ~/Code/callthewaiter
    Source     linked

However:

this is optional for M1.

Do not complicate the existing status command if project-context resolution does not fit cleanly yet.

The dedicated project commands matter more.

--------------------------------------------------
35. GUI SCOPE
--------------------------------------------------

The menu-bar app should remain minimal.

Do NOT build the final project UI.

However, M1 should prove that Vaelen.app can query the same Project Registry through the shared Core client.

A minimal addition is sufficient.

For example:

    Vaelen
    ● Core Running

    Projects
    callthewaiter
    syncproof
    wordpress-site

or even:

    Projects: 3

with a simple disclosure/list if easy.

The purpose is architectural verification:

    CLI project data == GUI project data == Core project data

Do not build project cards/settings/detail screens yet.

--------------------------------------------------
36. GUI MUST NOT SCAN DIRECTORIES
--------------------------------------------------

This is important.

Vaelen.app must NOT independently inspect parked directories.

It asks Core for projects.

Correct:

    Vaelen.app
        │
        ▼
    Core client
        │
        ▼
      IPC
        │
        ▼
    vaelend
        │
        ▼
    Project Registry / Discovery

Incorrect:

    Vaelen.app ──► FileManager ──► ~/Code

The Core owns discovery semantics.

--------------------------------------------------
37. NO WATCHERS YET
--------------------------------------------------

Do not introduce FSEvents or permanent directory watchers in M1.

Discovery can be refreshed:

- when requested;
- when the GUI refreshes;
- after link/park/unlink/unpark mutations.

We can introduce event-driven filesystem observation later if actual UX requires it.

Avoid idle resource cost now.

--------------------------------------------------
38. EVENTS
--------------------------------------------------

M0 established IPC event capability if implemented.

If project mutations naturally fit the existing event mechanism, emit small structured events such as:

    projectRegistryChanged
    parkedPathsChanged

so the GUI can refresh.

If events were not fully implemented in M0, do not create an elaborate event system solely for M1.

A lightweight refresh strategy is acceptable.

Do not poll aggressively.

--------------------------------------------------
39. ERROR HANDLING
--------------------------------------------------

Add only errors M1 actually requires.

Examples:

    PROJECT_NOT_FOUND
    PROJECT_PATH_NOT_FOUND
    PROJECT_PATH_NOT_DIRECTORY
    PROJECT_NAME_CONFLICT
    PARKED_PATH_NOT_FOUND
    INVALID_PROJECT_NAME

Do not build the entire future error taxonomy.

Human CLI errors should be understandable.

Example:

    $ val link /does/not/exist
    Project path does not exist:
    /does/not/exist

Expected user mistakes should not produce Swift stack traces.

--------------------------------------------------
40. NAME VALIDATION
--------------------------------------------------

If custom project names are supported, keep validation predictable.

Names should be safe for future use in domains and CLI references.

Avoid silently transforming surprising input.

If normalization is required, make it explicit.

Do not yet couple project name validation tightly to DNS rules unless ADR-0008 requires it.

--------------------------------------------------
41. PROJECT LOOKUP
--------------------------------------------------

Implement deterministic lookup by:

- canonical path;
- explicit registered name where applicable;
- current working directory context.

Do not introduce fuzzy matching.

If a name is ambiguous, fail clearly rather than guessing.

--------------------------------------------------
42. CURRENT DIRECTORY RESOLUTION
--------------------------------------------------

Commands such as:

    val unlink

need to determine whether the current directory corresponds to a known project.

Support at least exact project-root execution.

It would be useful if running from a descendant directory also resolves the containing project:

    ~/Code/foo/resources/views
        ↓
    project ~/Code/foo

But only implement this if it can be done deterministically and safely.

Prefer the nearest containing registered/discovered project root.

Add tests if implemented.

Do not create expensive recursive scanning.

--------------------------------------------------
43. DISCOVERY PRECEDENCE
--------------------------------------------------

Effective project list should conceptually be:

    explicit links
        +
    discovered immediate children of parked roots
        -
    canonical duplicates

Explicit registration wins when both refer to the same canonical directory.

This merge logic belongs in Core.

Test it thoroughly.

--------------------------------------------------
44. OVERLAPPING PARKED PATHS
--------------------------------------------------

Handle this deterministically.

Example:

    ~/Code
    ~/Code/client

both parked.

Do not produce duplicate logical projects when canonical paths collide.

Do not attempt to forbid all overlapping parked paths unless necessary.

Canonical identity should make merging safe.

Add at least one test.

--------------------------------------------------
45. HIDDEN DIRECTORIES
--------------------------------------------------

For M1, do not treat obvious hidden metadata directories as projects.

An immediate child beginning with `.` should normally be ignored during parked discovery.

Keep the rule simple.

Do not create a configurable ignore engine yet.

--------------------------------------------------
46. PERMISSIONS / UNREADABLE DIRECTORIES
--------------------------------------------------

Discovery must not crash because one directory cannot be read.

Represent or skip unreadable candidates safely and log enough information for diagnostics.

Do not request elevated privileges.

M1 remains entirely user-level.

--------------------------------------------------
47. TESTING — DOMAIN
--------------------------------------------------

Add tests for at least:

- explicit project registration;
- idempotent linking;
- unlink;
- unlink never deletes source directory;
- custom name if implemented;
- name conflict;
- canonical path deduplication;
- missing linked directory preservation;
- explicit link overriding discovered representation.

--------------------------------------------------
48. TESTING — PARKED PATHS
--------------------------------------------------

Add tests for:

- park;
- idempotent park;
- unpark;
- parked root persistence;
- missing parked root preservation;
- immediate child discovery;
- no recursive discovery;
- hidden child directories ignored;
- files ignored;
- overlapping parked paths do not create duplicate projects.

Use temporary directories.

Do not write tests against the developer's actual `~/Code`.

--------------------------------------------------
49. TESTING — PERSISTENCE
--------------------------------------------------

Add integration tests proving:

    register project
    destroy/recreate registry/Core using same temporary DB
    project remains registered

and:

    park path
    restart state layer
    parked path remains

Also test uniqueness constraints where appropriate.

Tests must use isolated temporary databases.

Never use the developer's real Vaelen database.

--------------------------------------------------
50. TESTING — CONCURRENCY
--------------------------------------------------

Where practical, test concurrent duplicate registration attempts.

The persistence/domain layer should guarantee uniqueness.

We want correctness from constraints + isolation, not luck.

--------------------------------------------------
51. TESTING — IPC
--------------------------------------------------

Extend IPC tests for the new project/path operations.

Test:

    client
      ↓
    IPC
      ↓
    Core
      ↓
    registry

Do not only unit-test repository functions.

At least one end-to-end or integration-level test should prove a project mutation can travel through the real Core client/server path.

--------------------------------------------------
52. TESTING — FILESYSTEM SAFETY
--------------------------------------------------

Create a temporary fake project with a sentinel file:

    project/
        DO_NOT_DELETE.txt

Link it.

Unlink it.

Assert:

    project directory still exists
    DO_NOT_DELETE.txt still exists
    file contents unchanged

Do the equivalent for park/unpark.

This explicitly protects one of Vaelen's most important ownership invariants.

--------------------------------------------------
53. DATABASE INSPECTION
--------------------------------------------------

The implementation should make the SQLite database inspectable during development.

Do not encrypt ordinary non-secret project metadata.

Do not put secrets into this database.

Do not expose persistence details as part of the normal CLI API.

--------------------------------------------------
54. MIGRATIONS
--------------------------------------------------

Introduce the smallest sane migration mechanism.

M1 starts with schema version 1.

Do not introduce a third-party migration framework unless absolutely necessary.

We need enough structure so future Vaelen versions can evolve the DB safely.

Test initialization from an empty database.

--------------------------------------------------
55. LOGGING
--------------------------------------------------

Add useful Core logs for:

- project linked;
- project unlinked;
- path parked;
- path unparked;
- discovery errors;
- persistence errors.

Do not spam logs every time a directory is successfully enumerated.

Do not log unnecessary user source information beyond what is useful for local diagnostics.

--------------------------------------------------
56. `val doctor`
--------------------------------------------------

Do NOT implement the full future `val doctor` system.

If `val doctor` already exists from M0, it may optionally report whether the state database can be opened.

Otherwise defer it.

Do not expand M1 into diagnostics architecture.

--------------------------------------------------
57. DO NOT CREATE `vaelen.yml`
--------------------------------------------------

This deserves explicit emphasis.

M1 does NOT write:

    vaelen.yml

to linked or discovered projects.

The project declaration format exists architecturally, but project registration must not mutate source trees.

Later milestones will determine explicit configuration UX.

--------------------------------------------------
58. DO NOT AUTO-LINK DISCOVERED PROJECTS
--------------------------------------------------

A project discovered under a parked root is not automatically converted into a persistent explicit project registration.

Discovery remains discovery.

This distinction is important.

--------------------------------------------------
59. DO NOT CREATE PROJECT-SPECIFIC STATE INSIDE PROJECTS
--------------------------------------------------

No:

    .vaelen/
    .vaelen-id
    .vaelen-state
    .vaelen-cache

inside user projects for M1.

Vaelen's registry belongs in Vaelen-owned Application Support state.

--------------------------------------------------
60. PERFORMANCE
--------------------------------------------------

M1 does not require complex optimization.

But:

    val links

and GUI project listing should feel immediate for normal development directories.

Do not recursively scan enormous trees.

Do not hash entire project directories.

Do not inspect project file contents.

Immediate-child discovery should be cheap.

--------------------------------------------------
61. BUILD INCREMENTALLY
--------------------------------------------------

Suggested implementation sequence:

Step 1:
Inspect M0 and identify extension points.

Step 2:
Implement canonical filesystem path abstraction + tests.

Step 3:
Implement Project and ParkedPath domain models.

Step 4:
Implement SQLite state store + schema migration.

Step 5:
Implement explicit ProjectRepository persistence.

Step 6:
Implement ParkedPath persistence.

Step 7:
Implement ProjectDiscovery for immediate child directories.

Step 8:
Implement ProjectRegistry merge/precedence behavior.

Step 9:
Add Core operations.

Step 10:
Extend IPC request/response models.

Step 11:
Extend shared Core client.

Step 12:
Implement:

    val link
    val unlink
    val links

Step 13:
Implement:

    val park
    val unpark
    val paths

Step 14:
Add JSON output.

Step 15:
Expose minimal project information to Vaelen.app.

Step 16:
Run complete automated tests.

Step 17:
Perform manual acceptance tests.

Do not proceed while intermediate code does not compile.

--------------------------------------------------
62. MANUAL ACCEPTANCE TEST — LINK
--------------------------------------------------

Use real disposable directories for manual testing.

For example:

    mkdir -p /tmp/vaelen-m1/foo
    echo "keep me" > /tmp/vaelen-m1/foo/DO_NOT_DELETE.txt

Then:

    cd /tmp/vaelen-m1/foo
    val link

Verify:

    val links

contains foo.

Restart `vaelend`.

Verify:

    val links

still contains foo.

Then:

    cd /tmp/vaelen-m1/foo
    val unlink

Verify it disappears from explicit links.

Then:

    cat /tmp/vaelen-m1/foo/DO_NOT_DELETE.txt

must still return:

    keep me

--------------------------------------------------
63. MANUAL ACCEPTANCE TEST — PARK
--------------------------------------------------

Create:

    /tmp/vaelen-m1/code/
        alpha/
        beta/
        .hidden/
        file.txt
        nested/
            child/

Then:

    cd /tmp/vaelen-m1/code
    val park

Query the effective projects using the implemented project-list mechanism.

Expected immediate discovered directories:

    alpha
    beta
    nested

Not:

    .hidden
    file.txt
    nested/child

Then:

    val paths

must show the parked root.

Restart Core.

The parked path must remain registered.

--------------------------------------------------
64. MANUAL ACCEPTANCE TEST — PRECEDENCE
--------------------------------------------------

With `/tmp/vaelen-m1/code` parked:

    cd /tmp/vaelen-m1/code/alpha
    val link

The effective project list must contain exactly ONE alpha project.

It should be represented as explicitly linked rather than duplicated as discovered + linked.

Then:

    val unlink

The explicitly linked representation disappears.

Because its parent remains parked, alpha should again appear as discovered.

This is a critical M1 test.

--------------------------------------------------
65. MANUAL ACCEPTANCE TEST — MISSING PATH
--------------------------------------------------

Explicitly link:

    /tmp/vaelen-m1/movable

Then rename it outside Vaelen:

    mv /tmp/vaelen-m1/movable /tmp/vaelen-m1/moved

Query links.

Vaelen should retain the original registration but mark it unavailable/missing.

It must NOT silently delete the registration.

--------------------------------------------------
66. MANUAL ACCEPTANCE TEST — GUI
--------------------------------------------------

With Core running and several projects discoverable:

Launch Vaelen.app.

Verify the app obtains project information through Core.

Then link/unlink or park/unpark using the CLI.

Refresh/reconnect the GUI as supported.

Verify CLI and GUI ultimately show the same Core-owned project state.

The GUI must not independently scan directories.

--------------------------------------------------
67. MANUAL ACCEPTANCE TEST — CORE AUTHORITY
--------------------------------------------------

Stop `vaelend`.

Run:

    val link

It should fail because Core is unavailable.

The CLI must NOT silently modify SQLite directly as a fallback.

Restart Core.

The operation should work again.

This proves Core remains authoritative.

--------------------------------------------------
68. MANUAL ACCEPTANCE TEST — IDEMPOTENCY
--------------------------------------------------

Run repeatedly:

    val link
    val link
    val link

Result:

    one explicit project

Run repeatedly:

    val park
    val park
    val park

Result:

    one parked path

No duplicate rows.

--------------------------------------------------
69. MANUAL DATABASE CHECK
--------------------------------------------------

During development, inspect the SQLite database manually.

Verify:

- paths are canonical absolute paths;
- duplicate project paths do not exist;
- duplicate parked paths do not exist;
- discovered projects are not unnecessarily persisted;
- no project source contents are stored;
- no secrets are stored.

Do not build application behavior around manual SQLite access.

This is only verification.

--------------------------------------------------
70. RESOURCE CHECK
--------------------------------------------------

After M1, Vaelen should still have essentially the same idle process model as M0:

    Vaelen.app
    vaelend

and short-lived:

    val

M1 must NOT result in:

- one process per project;
- directory watcher daemons;
- PHP;
- Caddy;
- databases;
- Docker;
- helper processes.

Project discovery is metadata work.

--------------------------------------------------
71. COMPLETION REPORT
--------------------------------------------------

When finished, provide a concise engineering report with:

## Implemented

What actually works.

## Domain model

Final Project and ParkedPath representation.

## Persistence

SQLite location, schema, uniqueness constraints, migration mechanism.

## Discovery

Exact discovery and precedence rules.

## IPC

Methods added and whether protocol version changed.

## CLI

Commands implemented and examples.

## GUI

Minimal M1 project functionality added.

## Tests

Tests added and final results.

## Manual verification

Commands actually executed and observed behavior.

## Files

Important files created/changed.

## Decisions

Implementation choices where ADRs intentionally left details open.

## ADR concerns

Any implementation evidence suggesting an ADR should be reconsidered.

## Deferred

Everything deliberately left for future milestones.

Do not claim completion unless the code builds and tests pass.

--------------------------------------------------
72. DEFINITION OF DONE
--------------------------------------------------

M1 is complete only when:

[ ] Project is a typed Core domain model
[ ] ParkedPath is a typed Core domain model
[ ] canonical path handling exists and is tested
[ ] explicit links persist across daemon restart
[ ] parked paths persist across daemon restart
[ ] SQLite state store exists
[ ] schema initialization/migration exists
[ ] project paths have uniqueness protection
[ ] parked paths have uniqueness protection
[ ] `val link` works
[ ] linking is idempotent
[ ] `val unlink` works
[ ] unlink never deletes source
[ ] `val links` works
[ ] `val links --json` works
[ ] `val park` works
[ ] parking is idempotent
[ ] `val unpark` works
[ ] unpark never deletes source
[ ] `val paths` works
[ ] `val paths --json` works
[ ] parked discovery inspects immediate child directories only
[ ] hidden directories are ignored
[ ] ordinary files are ignored
[ ] discovery does not recursively scan
[ ] discovered projects are not unnecessarily persisted
[ ] explicit link overrides discovered representation
[ ] unlinking explicit project under parked root reveals discovered representation again
[ ] missing linked paths are preserved as metadata
[ ] missing parked roots are preserved as metadata
[ ] overlapping parked paths do not create duplicate logical projects
[ ] all mutations go through Core
[ ] CLI does not access SQLite directly
[ ] GUI does not access SQLite directly
[ ] GUI does not independently scan projects
[ ] GUI can display minimal Core-owned project information
[ ] Core-unavailable mutations fail safely
[ ] concurrent duplicate registrations cannot corrupt state
[ ] persistence tests pass
[ ] filesystem safety tests pass
[ ] IPC integration tests pass
[ ] full existing M0 test suite still passes
[ ] no PHP implementation added
[ ] no Caddy implementation added
[ ] no DNS/TLS implementation added
[ ] no module system implementation added
[ ] no project drivers implemented
[ ] no `val up` reconciliation implemented
[ ] no privileged helper added
[ ] no filesystem watcher added
[ ] no source project files are modified
[ ] idle runtime footprint remains essentially M0
[ ] repository builds cleanly
[ ] complete test suite passes

Stop there.

Do NOT automatically begin Milestone 2.

--------------------------------------------------
FINAL ENGINEERING PRINCIPLE

Milestone 0 proved:

    clients → Core

Milestone 1 must prove:

    developer filesystem
            │
            ▼
    discovery + registration
            │
            ▼
        Core-owned state
          /       \
        CLI       GUI

while maintaining the rule:

    Vaelen knows about projects.
    Vaelen does not own projects.

Keep the implementation small, explicit, native, inspectable, and boring.

We are building the foundation that PHP, routing, services, and `val up` will later depend upon.

Do not optimize for how many Vaelen features can be added in this milestone.

Optimize for whether we can trust the Project Registry when everything else is eventually built on top of it.
