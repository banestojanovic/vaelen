# M14 validation run — 2026-09-20

Evidence transcript only; this file is not an authority record.

## Pre-mutation boundary

- Requested sequence: one bounded validation only; no source edit, lifecycle
  mutation, SQLite write, launchctl mutation, signal, Syncproof mutation,
  commit, tag, push, or freeze.
- Source inspection observed the deterministic repair in
  `Sources/VaelenCLI/main.swift`: bootstrap uses
  `LifecycleCanonicalIdentity.bootstrapControllerURL()`, validates the exact
  URL with `ArtifactPreflight.validate(appURL:)`, mints authorization bound to
  that path, and invokes `/usr/bin/open -a` with that exact app path. No
  `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` occurrence is
  present in the inspected bootstrap path.
- Source inspection observed the bounded override in
  `Sources/VaelenCore/LifecycleModels.swift`: only the canonical installed
  path or the exact M14 validation candidate is accepted; arbitrary override
  paths fail closed.
- Supplied archive directory was readable at:
  `/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920.xcarchive`.
  Its archive metadata records bundle ID `dev.vaelen.app`, signing identity
  `Apple Development: banestojanovics@icloud.com (DMY3NZQ69X)`, Team
  `TFKZJV643G`, and creation date `2026-09-20T15:06:28Z`. The app bundle has
  `Contents/MacOS`, `Contents/Resources`, `Contents/Library/LaunchAgents`,
  and `Contents/Resources/vaelend`; binary hashes/signature validity were not
  executable-tool verified in this session.
- Supplied archive LaunchAgent plist was readable and contains Label
  `dev.vaelen.vaelend`, BundleProgram `Contents/Resources/vaelend`, no
  ProgramArguments, RunAtLoad true, and KeepAlive true.
- Existing deterministic gate located: `Scripts/m14-preflight-gate.sh`.
  It is observation-only and checks the fixed archive, hashes, explicit
  ArtifactPreflight test, exact launchd label, exact process, endpoint, and
  lock holders.

## Execution stop

- Attempted to begin the required pre-state capture and evidence append using
  the shell execution boundary. The environment rejected shell execution
  before `date`, `stat`, `launchctl`, `ps`, `lsof`, SQLite, or the gate could
  run: `Permission denied: shell`.
- Because the required pre-mutation state cannot be established, the existing
  deterministic gate was not run, no controller override was exported, and
  no `val start` or other real Vaelen operation was attempted.
- Required claims remain **NOT-YET-PROVEN**: artifact currentness and signed
  preflight, launchd/process/endpoint/lock absence, durable state, exact
  controller binding at runtime, start/registration/Core readiness, Off,
  no-resurrection interval, and historical semantic preservation.

## Final state

No mutation was performed by this run. Runtime and durable final state are
**UNOBSERVED**, not inferred clean. A rerun requires a shell-capable execution
boundary so the mandated read-only pre-state and existing gate can be run.

## Orchestration note

- A minimal read-only permission correction was made to the delegated Lead
  configuration for `sqlite3 -readonly`; no product or lifecycle state was
  changed.
- The delegated Lead could not be resumed in this session, and the direct
  execution boundary still rejected the existing gate with `Permission denied:
  shell`. No workaround or lifecycle attempt was made.

## Renewed acceptance attempt

- Repository inspection succeeded: HEAD is `2ebf14aaa860245b787a861f87d0c7061b0e8f47`; the worktree contains the pre-existing M14 implementation and evidence changes.
- Direct execution of the required existing gate and individually requested
  read-only hash, launchd, and process observations was again rejected by the
  execution boundary with `Permission denied: shell`.
- No candidate rebuild, lifecycle mutation, controller invocation, `val start`,
  Off operation, or retry was performed. Runtime and durable state remain
  **UNOBSERVED**; M14 acceptance remains **NOT-YET-PROVEN**.

## Current orchestration stop

- PM attempted the required fresh delegation to `vaelen-lead` for the proof
  commands `git status --short` and `swift --version`.
- The delegation boundary rejected the request before Lead execution with the
  exact tool error: `Unknown agent: vaelen-lead`.
- Therefore Lead did not execute either proof command, the existing preflight
  gate was not run, no controller was invoked, and no Start/Off operation was
  attempted. No product or lifecycle mutation was performed by this attempt.
- This is an orchestration/tool-availability failure, not evidence about Vaelen
  runtime state. Required M14 claims remain **NOT-YET-PROVEN**.

## Fresh candidate preflight — 2026-09-20T16:37:42Z

- Exact existing command run via Bash: `bash Scripts/m14-preflight-gate.sh`.
- Gate result: `PASS` (`pass_count=8`, `fail_count=0`); exact archive/app,
  executables, LaunchAgent, signed-artifact API preflight, and absence checks
  passed.
- App executable SHA256: `1c0bc45c3b0c371b520ebd146e0030bf7aaba43e9c9bb2cdb4858ea0e4a41583`.
- Embedded daemon SHA256: `afa83c9e8d3b8aa9b74725e75a027dffc1a0d452ddb745e211a53f7230ff1154`.
- Pre-start observed absence: exact launchd label, canonical process, Core
  socket, vaelend lock, and bootstrap lock.
- The direct executable invocation without Bash returned shell permission
  denied (exit 126); the existing script was then run unchanged through Bash.

## Pre-Start mutation boundary

- Immediately before the sole authorized Start, no lifecycle mutation had been
  attempted after the passing gate. The next command is exactly one
  `.build/out/Products/Release/val start` with
  `VAELEN_BOOTSTRAP_CONTROLLER_URL` set to the exact supplied app path.

## Start result — 2026-09-20T16:38:03Z

- Exactly one command was executed:
  `VAELEN_BOOTSTRAP_CONTROLLER_URL='/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-fresh-20260920-1829.xcarchive/Products/Applications/Vaelen.app' .build/out/Products/Release/val start`
- Exact result: exit code `3`; typed result
  `{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}`.
- Per the acceptance boundary, this is a recovery-required/unknown Start. The
  run stops here: no fresh On gates, no Off, no retry, cleanup, signaling,
  launchd mutation, or lifecycle repair was performed.
- Final lifecycle state is intentionally preserved and unclassified; no claim
  is made about registration, daemon, endpoint, receipts/journal, IPC, or
  preservation after the unknown result.
## Pre-mutation candidate 1920 2026-09-20T17:11:00Z
archive=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive
cli=/Users/banes/Code/apps/vaelen/.build/out/Products/Release/val
1241c2f240d202b9975b0dff386102af12774ea8c8b86ebed3e6ee6071d536aa  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app/Contents/MacOS/Vaelen
8fd338a4d9ec1257dc357cc7ce00aff01deb23fdef1c6ca08a36d1905cae442e  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app/Contents/Resources/vaelend
ce885ef05efad72745d32f542593d4377f8033f90740119092c8a6b5d0633afc  /Users/banes/Code/apps/vaelen/.build/out/Products/Release/val
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/Yams_712EB057E_PackageProduct.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/Yams_712EB057E_PackageProduct.framework/Versions/Current/.
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenIPC.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenIPC.framework/Versions/Current/.
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app: valid on disk
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app: satisfies its Designated Requirement
Identifier=dev.vaelen.app
Authority=Apple Development: banestojanovics@icloud.com (DMY3NZQ69X)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TFKZJV643G
Identifier=vaelend
Authority=Apple Development: banestojanovics@icloud.com (DMY3NZQ69X)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TFKZJV643G
{
  "BundleProgram" => "Contents/Resources/vaelend"
  "KeepAlive" => true
  "Label" => "dev.vaelen.vaelend"
  "ProcessType" => "Background"
  "RunAtLoad" => true
}
launchctl:
Bad request.
Could not find service "dev.vaelen.vaelend" in domain for user gui: 501
process:
88676 88664   501 awk              awk -v a /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app/Contents/MacOS/Vaelen -v d
path_absent=/Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock
path_present=/Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
path_present=/Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
db-readonly:
7
candidate preflight:
Building for debugging...
[Using on-disk description]
[2 / 28] VaelenCore
[4 / 30] VaelenCore
[14 / 42] vaelen-privileged-helper-product
[19 / 44] VaelenCore
[23 / 48] VaelenCore
/Users/banes/Code/apps/vaelen/Sources/VaelenCore/CoreAbsentBootstrap.swift:193:9: [1;33mwarning: [1;39mresult of call to 'withUnsafeMutablePointer(to:_:)' is unused[0;0m [#]8;;https://docs.swift.org/compiler/documentation/diagnostics/no-usage\NoUsage]8;;\]
[0;36m191 |[0;0m         let path = LifecycleCanonicalIdentity.target.endpoint
[0;36m192 |[0;0m         guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return true }
[0;36m193 |[0;0m         withUnsafeMutablePointer(to: &address.sun_path) { pointer in
    [0;36m|[0;0m         `- [1;33mwarning: [1;39mresult of call to 'withUnsafeMutablePointer(to:_:)' is unused[0;0m [#]8;;https://docs.swift.org/compiler/documentation/diagnostics/no-usage\NoUsage]8;;\]
[0;36m194 |[0;0m             path.withCString { strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0) }
[0;36m195 |[0;0m         }

[#NoUsage]: <https://docs.swift.org/compiler/documentation/diagnostics/no-usage>
[30 / 53] VaelenCore
[34 / 52] VaelenDaemonSupport
[42 / 58] VaelenDaemonSupport
[45 / 61] val-product
[46 / 63] VaelenCoreTests-product
[50 / 61] VaelenCoreTests-product
[55 / 63] VaelenIPCTests-product
[59 / 68] val-product
[61 / 68] VaelenIPCTests-product
[65 / 69] val-product
[71 / 73] VaelenIPCTests-product
Build complete! (3,10 sec)
Test Suite 'Selected tests' started at 2026-09-20 19:11:05.672.
Test Suite 'VaelenIPCTests.xctest' started at 2026-09-20 19:11:05.677.
Test Suite 'VaelenIPCTests.xctest' passed at 2026-09-20 19:11:05.677.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-09-20 19:11:05.677.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.005) seconds
Test Suite 'Selected tests' started at 2026-09-20 19:11:05.742.
Test Suite 'VaelenDNSTests.xctest' started at 2026-09-20 19:11:05.747.
Test Suite 'VaelenDNSTests.xctest' passed at 2026-09-20 19:11:05.747.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-09-20 19:11:05.747.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.005) seconds
Test Suite 'Selected tests' started at 2026-09-20 19:11:05.797.
Test Suite 'VaelenCoreTests.xctest' started at 2026-09-20 19:11:05.802.
Test Suite 'CanonicalSigningTrustBoundaryTests' started at 2026-09-20 19:11:05.802.
Test Case '-[VaelenCoreTests.CanonicalSigningTrustBoundaryTests testExplicitSignedArtifactPreflightWhenPathIsProvided]' started.
Test Case '-[VaelenCoreTests.CanonicalSigningTrustBoundaryTests testExplicitSignedArtifactPreflightWhenPathIsProvided]' passed (1.026 seconds).
Test Suite 'CanonicalSigningTrustBoundaryTests' passed at 2026-09-20 19:11:06.828.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.026 (1.026) seconds
Test Suite 'VaelenCoreTests.xctest' passed at 2026-09-20 19:11:06.828.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.026 (1.026) seconds
Test Suite 'Selected tests' passed at 2026-09-20 19:11:06.828.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.026 (1.031) seconds

## Sole authorized Start boundary 2026-09-20T17:11:17Z
VAELEN_BOOTSTRAP_CONTROLLER_URL='/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app' .build/out/Products/Release/val start
start_exit=
{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}
## Post-Start evidence 2026-09-20T17:11:32Z
Bad request.
Could not find service "dev.vaelen.vaelend" in domain for user gui: 501
88949  1278   501 /bin/zsh         /bin/zsh -c set +e\012R='/Users/banes/Library/Application Support/Vaelen/runtime'; DB='/Users/banes/Library/Application Support/Vaelen/state/vaelen.sqlite'; APP='/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1920.xcarchive/Products/Applications/Vaelen.app'; DAEMON="$APP/Contents/Resources/vaelend"; echo "## Post-Start evidence $(date -u '+%Y-%m-%dT%H:%M:%SZ')" | tee /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-poststart-1920.txt\012launchctl print gui/501/dev.vaelen.vaelend 2>&1 | tee -a /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-poststart-1920.txt\012ps -axo pid=,ppid=,uid=,comm=,command= | grep -E "[v]aelend|[V]aelen.app" | tee -a /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-poststart-1920.txt\012for p in "$R/sockets/core.sock" "$R/locks/vaelend.lock" "$R/locks/lifecycle-bootstrap.lock"; do ls -l "$p" 2>&1; lsof -n -P -- "$p" 2>&1; done | tee -a /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-poststart-1920.txt\012sqlite3 -readonly "$DB" "PRAGMA user_version; SELECT name,sql FROM sqlite_master WHERE name IN ('bootstrap_receipts','lifecycle_intent','lifecycle_operations','lifecycle_ownership'); SELECT phase,executor_state,operation_id FROM bootstrap_receipts; SELECT intent,generation,operation_id,actor FROM lifecycle_intent; SELECT operation_id,generation,kind,state,error FROM lifecycle_operations; SELECT operation_id,generation FROM lifecycle_ownership; SELECT phase,outcome,detail,invocation_id,token_hash,operation_id FROM lifecycle_diagnostics ORDER BY id DESC LIMIT 30;" 2>&1 | tee -a /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-poststart-1920.txt\012cat /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-poststart-1920.txt >> .vaelen/M14_VALIDATION_RUN.md\012
ls: /Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock: No such file or directory
lsof: status error on /Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock: No such file or directory
lsof 4.91
 latest revision: ftp://lsof.itap.purdue.edu/pub/tools/unix/lsof/
 latest FAQ: ftp://lsof.itap.purdue.edu/pub/tools/unix/lsof/FAQ
 latest man page: ftp://lsof.itap.purdue.edu/pub/tools/unix/lsof/lsof_man
 usage: [-?abhlnNoOPRtUvVX] [+|-c c] [+|-d s] [+D D] [+|-f[cgG]]
 [-F [f]] [-g [s]] [-i [i]] [+|-L [l]] [+|-M] [-o [o]] [-p s]
 [+|-r [t]] [-s [p:s]] [-S [t]] [-T [t]] [-u s] [+|-w] [-x [fl]] [--] [names]
Use the ``-h'' option to get more help information.
-rw-------@ 1 banes  staff  0 Sep 19 21:22 /Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:55 /Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
7
lifecycle_intent|CREATE TABLE lifecycle_intent (id INTEGER PRIMARY KEY CHECK (id = 1), intent TEXT NOT NULL CHECK (intent IN ('on','off')), generation INTEGER NOT NULL, operation_id TEXT NOT NULL, actor TEXT NOT NULL, bundle_id TEXT NOT NULL, agent_label TEXT NOT NULL, bundle_program TEXT NOT NULL, endpoint TEXT NOT NULL)
lifecycle_operations|CREATE TABLE lifecycle_operations (operation_id TEXT PRIMARY KEY NOT NULL, generation INTEGER NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('register','unregister')), state TEXT NOT NULL CHECK (state IN ('pending','in-flight','succeeded','failed','unknown/recovery-required')), pre_observation_json TEXT NOT NULL, post_observation_json TEXT NULL, error TEXT NULL, created_at TEXT NOT NULL)
lifecycle_ownership|CREATE TABLE lifecycle_ownership (id INTEGER PRIMARY KEY CHECK (id = 1), bundle_id TEXT NOT NULL, agent_label TEXT NOT NULL, bundle_program TEXT NOT NULL, endpoint TEXT NOT NULL, signing_team TEXT NULL, designated_requirement TEXT NULL, artifact_hash TEXT NULL, operation_id TEXT NOT NULL, generation INTEGER NOT NULL)
bootstrap_receipts|CREATE TABLE bootstrap_receipts (id INTEGER PRIMARY KEY CHECK (id = 1), bundle_id TEXT NOT NULL, agent_label TEXT NOT NULL, bundle_program TEXT NOT NULL, endpoint TEXT NOT NULL, epoch TEXT NOT NULL, operation_id TEXT NOT NULL, nonce TEXT NOT NULL, invocation_token TEXT NOT NULL, invocation_user TEXT NOT NULL, expires_at TEXT NOT NULL, phase TEXT NOT NULL CHECK (phase IN ('reserved','succeeded','failed','unknown/recovery-required','promoted')), executor_state TEXT NULL, executor_detail TEXT NULL, post_observation_json TEXT NULL, integrity_digest TEXT NOT NULL, invocation_uid INTEGER NOT NULL DEFAULT 0, preflight_provenance_json TEXT NOT NULL DEFAULT '')

## Candidate 1930 final preflight/retry boundary 2026-09-20T17:13:35Z
cli_sha=bd027bb248fc579ac030b46ae08e5ec6e698b0a8c0fc6da541359df2447a14da  .build/out/Products/Release/val
db_before=7
Test Case '-[VaelenCoreTests.CanonicalSigningTrustBoundaryTests testExplicitSignedArtifactPreflightWhenPathIsProvided]' started.
Test Case '-[VaelenCoreTests.CanonicalSigningTrustBoundaryTests testExplicitSignedArtifactPreflightWhenPathIsProvided]' passed (1.082 seconds).
Test Suite 'CanonicalSigningTrustBoundaryTests' passed at 2026-09-20 19:13:42.136.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.082 (1.082) seconds
Test Suite 'VaelenCoreTests.xctest' passed at 2026-09-20 19:13:42.136.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.082 (1.082) seconds
Test Suite 'Selected tests' passed at 2026-09-20 19:13:42.136.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.082 (1.087) seconds
VAELEN_BOOTSTRAP_CONTROLLER_URL='/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1930.xcarchive/Products/Applications/Vaelen.app' .build/out/Products/Release/val start

## Start result 1930 2026-09-20T17:14:02Z
{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}
start_exit=3
## Post-start 1930 2026-09-20T17:14:14Z
Bad request.
Could not find service "dev.vaelen.vaelend" in domain for user gui: 501
89803     1   501 /Users/banes/Lib /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-1930.xcarchive/Products/Applications/Vaelen.app/Contents/MacOS/Vaelen
89841  1278   501 /bin/zsh         /bin/zsh -c set +e\012R='/Users/banes/Library/Application Support/Vaelen/runtime'; DB='/Users/banes/Library/Application Support/Vaelen/state/vaelen.sqlite'; echo "## Post-start 1930 $(date -u '+%Y-%m-%dT%H:%M:%SZ')" | tee /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-post-1930.txt\012launchctl print gui/501/dev.vaelen.vaelend 2>&1 | tee -a /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-post-1930.txt\012ps -axo pid=,ppid=,uid=,comm=,command= | grep -E '[v]aelend|[V]aelen.app' | tee -a /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-post-1930.txt\012for p in "$R/sockets/core.sock" "$R/locks/vaelend.lock" "$R/locks/lifecycle-bootstrap.lock"; do echo "-- $p"; ls -l "$p" 2>&1; lsof -n -P -- "$p" 2>&1 | head -20; done | tee -a /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-post-1930.txt\012sqlite3 -readonly "$DB" "PRAGMA user_version; SELECT phase,executor_state,operation_id FROM bootstrap_receipts; SELECT intent,generation,operation_id,actor FROM lifecycle_intent; SELECT operation_id,generation,kind,state,error FROM lifecycle_operations; SELECT operation_id,generation FROM lifecycle_ownership; SELECT phase,outcome,detail,invocation_id,token_hash,operation_id FROM lifecycle_diagnostics ORDER BY id DESC LIMIT 40;" 2>&1 | tee -a /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-post-1930.txt\012cat /private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-post-1930.txt >> .vaelen/M14_VALIDATION_RUN.md
-- /Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock
ls: /Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock: No such file or directory
lsof: status error on /Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock: No such file or directory
lsof 4.91
 latest revision: ftp://lsof.itap.purdue.edu/pub/tools/unix/lsof/
 latest FAQ: ftp://lsof.itap.purdue.edu/pub/tools/unix/lsof/FAQ
 latest man page: ftp://lsof.itap.purdue.edu/pub/tools/unix/lsof/lsof_man
 usage: [-?abhlnNoOPRtUvVX] [+|-c c] [+|-d s] [+D D] [+|-f[cgG]]
 [-F [f]] [-g [s]] [-i [i]] [+|-L [l]] [+|-M] [-o [o]] [-p s]
 [+|-r [t]] [-s [p:s]] [-S [t]] [-T [t]] [-u s] [+|-w] [-x [fl]] [--] [names]
Use the ``-h'' option to get more help information.
-- /Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:22 /Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
-- /Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:55 /Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
8
urlOpen|success|open exit=0|850351B5-7B6D-4043-A833-5B13D629586D|a2e05a770bbf7fc2e4e7356cd6851a94a9d50d685f2d5a2fe9ea38f5c9444c41|
urlConstruction|started|canonical vaelen://start URL|850351B5-7B6D-4043-A833-5B13D629586D|a2e05a770bbf7fc2e4e7356cd6851a94a9d50d685f2d5a2fe9ea38f5c9444c41|
mint|success|authorization minted; token persisted as hash only|850351B5-7B6D-4043-A833-5B13D629586D|a2e05a770bbf7fc2e4e7356cd6851a94a9d50d685f2d5a2fe9ea38f5c9444c41|

## Candidate 2010 retry boundary 2026-09-20T17:17:54Z
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2010.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenIPC.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2010.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenIPC.framework/Versions/Current/.
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2010.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/Yams_712EB057E_PackageProduct.framework/Versions/Current/.
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2010.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2010.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/Yams_712EB057E_PackageProduct.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2010.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2010.xcarchive/Products/Applications/Vaelen.app: valid on disk
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2010.xcarchive/Products/Applications/Vaelen.app: satisfies its Designated Requirement
Building for debugging...
[Using on-disk description]
[5 / 38] Yams
[8 / 39] VaelenCore
[10 / 41] VaelenCore
[20 / 52] VaelenIPC
[25 / 54] VaelenCore
[29 / 54] VaelenCore
/Users/banes/Code/apps/vaelen/Sources/VaelenCore/CoreAbsentBootstrap.swift:193:9: [1;33mwarning: [1;39mresult of call to 'withUnsafeMutablePointer(to:_:)' is unused[0;0m [#]8;;https://docs.swift.org/compiler/documentation/diagnostics/no-usage\NoUsage]8;;\]
[0;36m191 |[0;0m         let path = LifecycleCanonicalIdentity.target.endpoint
[0;36m192 |[0;0m         guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return true }
[0;36m193 |[0;0m         withUnsafeMutablePointer(to: &address.sun_path) { pointer in
    [0;36m|[0;0m         `- [1;33mwarning: [1;39mresult of call to 'withUnsafeMutablePointer(to:_:)' is unused[0;0m [#]8;;https://docs.swift.org/compiler/documentation/diagnostics/no-usage\NoUsage]8;;\]
[0;36m194 |[0;0m             path.withCString { strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0) }
[0;36m195 |[0;0m         }

[#NoUsage]: <https://docs.swift.org/compiler/documentation/diagnostics/no-usage>
[34 / 59] VaelenCore
[40 / 58] VaelenDaemonSupport
[44 / 62] vaelen-privileged-helper-product
[52 / 69] VaelenCoreTests-product
[56 / 67] VaelenCoreTests-product
[66 / 72] vaelend-product
[67 / 74] VaelenIPCTests-product
[71 / 75] val-product
[75 / 79] VaelenIPCTests-product
[77 / 79] VaelenIPCTests-product
Build complete! (3,12 sec)
Test Suite 'Selected tests' started at 2026-09-20 19:17:59.790.
Test Suite 'VaelenIPCTests.xctest' started at 2026-09-20 19:17:59.795.
Test Suite 'VaelenIPCTests.xctest' passed at 2026-09-20 19:17:59.795.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-09-20 19:17:59.795.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.005) seconds
Test Suite 'Selected tests' started at 2026-09-20 19:17:59.860.
Test Suite 'VaelenDNSTests.xctest' started at 2026-09-20 19:17:59.866.
Test Suite 'VaelenDNSTests.xctest' passed at 2026-09-20 19:17:59.866.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-09-20 19:17:59.866.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.005) seconds
Test Suite 'Selected tests' started at 2026-09-20 19:17:59.917.
Test Suite 'VaelenCoreTests.xctest' started at 2026-09-20 19:17:59.922.
Test Suite 'CanonicalSigningTrustBoundaryTests' started at 2026-09-20 19:17:59.922.
Test Case '-[VaelenCoreTests.CanonicalSigningTrustBoundaryTests testExplicitSignedArtifactPreflightWhenPathIsProvided]' started.
Test Case '-[VaelenCoreTests.CanonicalSigningTrustBoundaryTests testExplicitSignedArtifactPreflightWhenPathIsProvided]' passed (1.072 seconds).
Test Suite 'CanonicalSigningTrustBoundaryTests' passed at 2026-09-20 19:18:00.994.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.072 (1.072) seconds
Test Suite 'VaelenCoreTests.xctest' passed at 2026-09-20 19:18:00.994.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.072 (1.072) seconds
Test Suite 'Selected tests' passed at 2026-09-20 19:18:00.994.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.072 (1.077) seconds
VAELEN_BOOTSTRAP_CONTROLLER_URL='/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2010.xcarchive/Products/Applications/Vaelen.app' .build/out/Products/Release/val start

## Start result 2010 2026-09-20T17:18:19Z
{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}
exit=3

## Candidate 2020 retry boundary 2026-09-20T17:19:55Z
{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}
exit=3

## Candidate 2030 retry boundary 2026-09-20T17:21:41Z
{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}
exit=3

## Candidate 2040 retry boundary 2026-09-20T17:23:11Z
{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}
exit=3
## Final observed state 2026-09-20T17:23:52Z
Bad request.
Could not find service "dev.vaelen.vaelend" in domain for user gui: 501
92971     1   501 /Users/banes/Lib /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2040.xcarchive/Products/Applications/Vaelen.app/Contents/MacOS/Vaelen
92997  1278   501 /bin/zsh         /bin/zsh -c set +e\012DB='/Users/banes/Library/Application Support/Vaelen/state/vaelen.sqlite'; R='/Users/banes/Library/Application Support/Vaelen/runtime'; OUT=/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-final-state.txt\012{\012 echo "## Final observed state $(date -u '+%Y-%m-%dT%H:%M:%SZ')"; launchctl print gui/501/dev.vaelen.vaelend 2>&1; ps -axo pid=,ppid=,uid=,comm=,command= | grep -E '[V]aelen.app/Contents/MacOS/Vaelen|[v]aelend'; for p in "$R/sockets/core.sock" "$R/locks/vaelend.lock" "$R/locks/lifecycle-bootstrap.lock"; do echo "-- $p"; ls -l "$p" 2>&1; lsof -n -P -- "$p" 2>&1 | head -8; done; sqlite3 -readonly "$DB" "PRAGMA user_version; SELECT phase,executor_state,executor_detail,operation_id FROM bootstrap_receipts; SELECT intent,generation,operation_id,actor FROM lifecycle_intent; SELECT operation_id,generation,kind,state,error FROM lifecycle_operations; SELECT operation_id,generation FROM lifecycle_ownership; SELECT phase,outcome,detail,invocation_id,token_hash,operation_id FROM lifecycle_diagnostics ORDER BY id DESC LIMIT 20;"\012} > "$OUT" 2>&1\012cat "$OUT"; cat "$OUT" >> .vaelen/M14_VALIDATION_RUN.md
-- /Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock
ls: /Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock: No such file or directory
lsof: status error on /Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock: No such file or directory
lsof 4.91
 latest revision: ftp://lsof.itap.purdue.edu/pub/tools/unix/lsof/
 latest FAQ: ftp://lsof.itap.purdue.edu/pub/tools/unix/lsof/FAQ
 latest man page: ftp://lsof.itap.purdue.edu/pub/tools/unix/lsof/lsof_man
 usage: [-?abhlnNoOPRtUvVX] [+|-c c] [+|-d s] [+D D] [+|-f[cgG]]
 [-F [f]] [-g [s]] [-i [i]] [+|-L [l]] [+|-M] [-o [o]] [-p s]
 [+|-r [t]] [-s [p:s]] [-S [t]] [-T [t]] [-u s] [+|-w] [-x [fl]] [--] [names]
-- /Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:22 /Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
-- /Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:55 /Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
8
urlOpen|success|open exit=0|7EB89058-B7C6-41FF-A2B5-7AECB41B6411|8749bf7129fcfcb513a5a01eb11da2d9273de26afed8a7a8d766197e7c963970|
urlConstruction|started|canonical vaelen://start URL|7EB89058-B7C6-41FF-A2B5-7AECB41B6411|8749bf7129fcfcb513a5a01eb11da2d9273de26afed8a7a8d766197e7c963970|
mint|success|authorization minted; token persisted as hash only|7EB89058-B7C6-41FF-A2B5-7AECB41B6411|8749bf7129fcfcb513a5a01eb11da2d9273de26afed8a7a8d766197e7c963970|
platform|refused|bootstrap executor refused before receipt|0E0A070E-E93B-4306-938F-A7007FD8B34D|72db575652edcd009164371facaa9209415823627081f2fff853d57b82fffbd0|
platform|registration-observation|unknown|0E0A070E-E93B-4306-938F-A7007FD8B34D|72db575652edcd009164371facaa9209415823627081f2fff853d57b82fffbd0|
consume|success|one-time invocation consumed|0E0A070E-E93B-4306-938F-A7007FD8B34D|72db575652edcd009164371facaa9209415823627081f2fff853d57b82fffbd0|
preflight|success|canonical signed controller validated|0E0A070E-E93B-4306-938F-A7007FD8B34D|72db575652edcd009164371facaa9209415823627081f2fff853d57b82fffbd0|
preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2030.xcarchive/Products/Applications/Vaelen.app|0E0A070E-E93B-4306-938F-A7007FD8B34D|72db575652edcd009164371facaa9209415823627081f2fff853d57b82fffbd0|
urlOpen|success|open exit=0|0E0A070E-E93B-4306-938F-A7007FD8B34D|72db575652edcd009164371facaa9209415823627081f2fff853d57b82fffbd0|
urlConstruction|started|canonical vaelen://start URL|0E0A070E-E93B-4306-938F-A7007FD8B34D|72db575652edcd009164371facaa9209415823627081f2fff853d57b82fffbd0|
mint|success|authorization minted; token persisted as hash only|0E0A070E-E93B-4306-938F-A7007FD8B34D|72db575652edcd009164371facaa9209415823627081f2fff853d57b82fffbd0|
preflight|success|canonical signed controller validated|52758916-4F35-44BA-96D5-DF7E7F3BA954|fc696bbd909708a6f190a19737e0c53e6b1495d37a151384e7bf40eb48f1115b|
preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2010.xcarchive/Products/Applications/Vaelen.app|52758916-4F35-44BA-96D5-DF7E7F3BA954|fc696bbd909708a6f190a19737e0c53e6b1495d37a151384e7bf40eb48f1115b|
consume|success|one-time invocation consumed|9DF5771F-E000-4C99-B715-614660B05223|7e21a907e3af64193ff3a9ba8d24e6dd0b35aeee3c99c1b8d6e74b35855e1432|
preflight|success|canonical signed controller validated|9DF5771F-E000-4C99-B715-614660B05223|7e21a907e3af64193ff3a9ba8d24e6dd0b35aeee3c99c1b8d6e74b35855e1432|
preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2020.xcarchive/Products/Applications/Vaelen.app|9DF5771F-E000-4C99-B715-614660B05223|7e21a907e3af64193ff3a9ba8d24e6dd0b35aeee3c99c1b8d6e74b35855e1432|
urlOpen|success|open exit=0|9DF5771F-E000-4C99-B715-614660B05223|7e21a907e3af64193ff3a9ba8d24e6dd0b35aeee3c99c1b8d6e74b35855e1432|
urlConstruction|started|canonical vaelen://start URL|9DF5771F-E000-4C99-B715-614660B05223|7e21a907e3af64193ff3a9ba8d24e6dd0b35aeee3c99c1b8d6e74b35855e1432|
mint|success|authorization minted; token persisted as hash only|9DF5771F-E000-4C99-B715-614660B05223|7e21a907e3af64193ff3a9ba8d24e6dd0b35aeee3c99c1b8d6e74b35855e1432|
urlOpen|success|open exit=0|52758916-4F35-44BA-96D5-DF7E7F3BA954|fc696bbd909708a6f190a19737e0c53e6b1495d37a151384e7bf40eb48f1115b|
## Candidate 2100 pre-mutation read-only gate 2026-09-20T17:27:39Z
archive=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive
6fb4769a2e72b3889cc545cf8335017fd6e954e90a2b872dd15daf3051fe9df2  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app/Contents/MacOS/Vaelen
e9c50a9361a85e314b407d4ee6df5ff49bb0ba8d4cb1c8540a711ccdccf7b250  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app/Contents/Resources/vaelend
68a29a6eb8788db98091df6e3b4a9ed32f86febb080073b10b9c12abcb185c2b  .build/out/Products/Release/val
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/Yams_712EB057E_PackageProduct.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/Yams_712EB057E_PackageProduct.framework/Versions/Current/.
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenIPC.framework/Versions/Current/.
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenIPC.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app: valid on disk
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app: satisfies its Designated Requirement
Identifier=dev.vaelen.app
Authority=Apple Development: banestojanovics@icloud.com (DMY3NZQ69X)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TFKZJV643G
Identifier=vaelend
Authority=Apple Development: banestojanovics@icloud.com (DMY3NZQ69X)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TFKZJV643G
{
  "BundleProgram" => "Contents/Resources/vaelend"
  "KeepAlive" => true
  "Label" => "dev.vaelen.vaelend"
  "ProcessType" => "Background"
  "RunAtLoad" => true
}
Bad request.
Could not find service "dev.vaelen.vaelend" in domain for user gui: 501
92971     1   501 /Users/banes/Lib /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2040.xcarchive/Products/Applications/Vaelen.app/Contents/MacOS/Vaelen
93742  1278   501 /bin/zsh         /bin/zsh -c set -e\012A='/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive'; APP="$A/Products/Applications/Vaelen.app"; D="$APP/Contents/Resources/vaelend"; DB='/Users/banes/Library/Application Support/Vaelen/state/vaelen.sqlite'; R='/Users/banes/Library/Application Support/Vaelen/runtime'\012OUT=/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-pre-2100.txt\012{\012 echo "## Candidate 2100 pre-mutation read-only gate $(date -u '+%Y-%m-%dT%H:%M:%SZ')"; echo archive=$A; shasum -a 256 "$APP/Contents/MacOS/Vaelen" "$D" .build/out/Products/Release/val; codesign --verify --deep --strict --verbose=2 "$APP"; codesign -dvvv "$APP" 2>&1 | egrep 'Identifier=|TeamIdentifier=|Authority='; codesign -dvvv "$D" 2>&1 | egrep 'Identifier=|TeamIdentifier=|Authority='; plutil -p "$APP/Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist"; launchctl print gui/501/dev.vaelen.vaelend 2>&1 || true; ps -axo pid=,ppid=,uid=,comm=,command= | grep -E '[V]aelen.app/Contents/MacOS/Vaelen|[v]aelend' || true; for p in "$R/sockets/core.sock" "$R/locks/vaelend.lock" "$R/locks/lifecycle-bootstrap.lock"; do echo --$p; [ -e "$p" ] && lsof -n -P -- "$p" 2>&1 || echo absent; done; sqlite3 -readonly "$DB" "PRAGMA user_version; SELECT phase,executor_state,executor_detail,operation_id FROM bootstrap_receipts; SELECT intent,generation,operation_id FROM lifecycle_intent; SELECT operation_id,generation,kind,state FROM lifecycle_operations; SELECT operation_id,generation FROM lifecycle_ownership;"; VAELEN_ARTIFACT_PREFLIGHT_PATH="$APP" swift test --filter CanonicalSigningTrustBoundaryTests/testExplicitSignedArtifactPreflightWhenPathIsProvided; bash Scripts/m14-preflight-gate.sh\012} > "$OUT" 2>&1\012cat "$OUT" >> .vaelen/M14_VALIDATION_RUN.md\012cat "$OUT"\012
--/Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock
absent
--/Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
absent
--/Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
absent
8
Building for debugging...
[Using on-disk description]
[5 / 38] Yams
[8 / 39] VaelenCore
[10 / 41] VaelenCore
[20 / 52] vaelen-privileged-helper-product
[25 / 54] VaelenCore
[28 / 54] val-product
[29 / 54] VaelenDaemonSupport
/Users/banes/Code/apps/vaelen/Sources/VaelenCore/CoreAbsentBootstrap.swift:206:9: [1;33mwarning: [1;39mresult of call to 'withUnsafeMutablePointer(to:_:)' is unused[0;0m [#]8;;https://docs.swift.org/compiler/documentation/diagnostics/no-usage\NoUsage]8;;\]
[0;36m204 |[0;0m         let path = LifecycleCanonicalIdentity.target.endpoint
[0;36m205 |[0;0m         guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return true }
[0;36m206 |[0;0m         withUnsafeMutablePointer(to: &address.sun_path) { pointer in
    [0;36m|[0;0m         `- [1;33mwarning: [1;39mresult of call to 'withUnsafeMutablePointer(to:_:)' is unused[0;0m [#]8;;https://docs.swift.org/compiler/documentation/diagnostics/no-usage\NoUsage]8;;\]
[0;36m207 |[0;0m             path.withCString { strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0) }
[0;36m208 |[0;0m         }

[#NoUsage]: <https://docs.swift.org/compiler/documentation/diagnostics/no-usage>
[34 / 59] VaelenCore
[40 / 58] VaelenDaemonSupport
[44 / 62] VaelenCoreTests-product
[52 / 69] VaelenDaemonSupport
[56 / 67] VaelenCoreTests-product
[66 / 72] VaelenCoreTests-product
[67 / 74] VaelenIPCTests-product
[75 / 80] VaelenCoreTests-product
[77 / 79] VaelenIPCTests-product
Build complete! (2,97 sec)
Test Suite 'Selected tests' started at 2026-09-20 19:27:44.962.
Test Suite 'VaelenIPCTests.xctest' started at 2026-09-20 19:27:44.966.
Test Suite 'VaelenIPCTests.xctest' passed at 2026-09-20 19:27:44.966.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-09-20 19:27:44.966.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.005) seconds
Test Suite 'Selected tests' started at 2026-09-20 19:27:45.031.
Test Suite 'VaelenDNSTests.xctest' started at 2026-09-20 19:27:45.036.
Test Suite 'VaelenDNSTests.xctest' passed at 2026-09-20 19:27:45.036.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
Test Suite 'Selected tests' passed at 2026-09-20 19:27:45.036.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.005) seconds
Test Suite 'Selected tests' started at 2026-09-20 19:27:45.087.
Test Suite 'VaelenCoreTests.xctest' started at 2026-09-20 19:27:45.091.
Test Suite 'CanonicalSigningTrustBoundaryTests' started at 2026-09-20 19:27:45.091.
Test Case '-[VaelenCoreTests.CanonicalSigningTrustBoundaryTests testExplicitSignedArtifactPreflightWhenPathIsProvided]' started.
Test Case '-[VaelenCoreTests.CanonicalSigningTrustBoundaryTests testExplicitSignedArtifactPreflightWhenPathIsProvided]' passed (1.032 seconds).
Test Suite 'CanonicalSigningTrustBoundaryTests' passed at 2026-09-20 19:27:46.124.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.032 (1.032) seconds
Test Suite 'VaelenCoreTests.xctest' passed at 2026-09-20 19:27:46.124.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.032 (1.032) seconds
Test Suite 'Selected tests' passed at 2026-09-20 19:27:46.124.
	 Executed 1 test, with 0 failures (0 unexpected) in 1.032 (1.037) seconds
gate=m14-pre-mutation-gate version=1 mode=observation-only
constant.archive=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-fresh-20260920-1829.xcarchive
constant.app=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-fresh-20260920-1829.xcarchive/Products/Applications/Vaelen.app
constant.app_executable=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-fresh-20260920-1829.xcarchive/Products/Applications/Vaelen.app/Contents/MacOS/Vaelen
constant.daemon=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-fresh-20260920-1829.xcarchive/Products/Applications/Vaelen.app/Contents/Resources/vaelend
constant.launch_agent=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-fresh-20260920-1829.xcarchive/Products/Applications/Vaelen.app/Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist
constant.label=dev.vaelen.vaelend
constant.team=TFKZJV643G
hash_semantics.app_sha256=Contents/MacOS/Vaelen executable digest evidence_only_not_trust_anchor
hash_semantics.daemon_sha256=Contents/Resources/vaelend executable digest evidence_only_not_trust_anchor
operation=artifact_exists status=PASS detail=exact_archive_path_exists
operation=app_exists status=PASS detail=exact_app_path_exists
operation=app_executable_exists status=PASS detail=exact_executable_exists
operation=daemon_executable_exists status=PASS detail=exact_executable_exists
operation=launch_agent_exists status=PASS detail=exact_launch_agent_exists
operation=app_executable_sha256 status=PASS detail=1c0bc45c3b0c371b520ebd146e0030bf7aaba43e9c9bb2cdb4858ea0e4a41583
operation=daemon_executable_sha256 status=PASS detail=afa83c9e8d3b8aa9b74725e75a027dffc1a0d452ddb745e211a53f7230ff1154
operation=artifact_preflight status=PASS detail=exact_app_url_api_test
operation=launchctl_print status=ABSENT detail=exact_label_absent
operation=canonical_process status=ABSENT detail=no_exact_canonical_process
operation=core_socket status=ABSENT detail=exact_canonical_socket_absent
operation=vaelend_lock status=ABSENT detail=no_lock_holder
operation=lifecycle_bootstrap_lock status=ABSENT detail=no_lock_holder
gate_result=PASS pass_count=8 fail_count=0

## Sole Start after status-observability fix $(date -u +VAELEN_BOOTSTRAP_CONTROLLER_URL='/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app' .build/out/Products/Release/val start
{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}
exit=3
## Observability candidate 2120 evidence 2026-09-20T17:34:36Z
scope=read-only-after-build; no Start/Off/retry/recovery/launchctl-mutation
archive=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive
8eec9daf3a3d31f26b74030bfc11fb2e8eb6b24ba119a32bf740d29c4e933654  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app/Contents/MacOS/Vaelen
e0701de7cdaec16e3d0995100f64defbfe01fefa433e4d7cc8b5fd5bd07059f5  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app/Contents/Resources/vaelend
2d0c318fbffaed2fb194ab8b83d3c8e46eb9e785c220332c9351e4a18193a2db  .build/out/Products/Release/val
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app: valid on disk
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app: satisfies its Designated Requirement
focused_and_full_tests=PASS; full=205 executed,14 skipped,0 failures
artifact_preflight=PASS; m14-preflight-gate=PASS pass_count=8 fail_count=0
-- current durable state (sqlite3 -readonly)
8
32|2026-09-20 17:30:30|preflight|success|canonical signed controller validated|C087BE59-0AE3-4020-9216-21E73E8FA428
31|2026-09-20 17:30:30|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app|C087BE59-0AE3-4020-9216-21E73E8FA428
30|2026-09-20 17:27:58|urlOpen|success|open exit=0|C087BE59-0AE3-4020-9216-21E73E8FA428
29|2026-09-20 17:27:58|urlConstruction|started|canonical vaelen://start URL|C087BE59-0AE3-4020-9216-21E73E8FA428
28|2026-09-20 17:27:57|mint|success|authorization minted; token persisted as hash only|C087BE59-0AE3-4020-9216-21E73E8FA428
27|2026-09-20 17:24:48|preflight|success|canonical signed controller validated|7EB89058-B7C6-41FF-A2B5-7AECB41B6411
26|2026-09-20 17:24:48|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2040.xcarchive/Products/Applications/Vaelen.app|7EB89058-B7C6-41FF-A2B5-7AECB41B6411
25|2026-09-20 17:23:11|urlOpen|success|open exit=0|7EB89058-B7C6-41FF-A2B5-7AECB41B6411
-- runtime observation
Bad request.
Could not find service "dev.vaelen.vaelend" in domain for user gui: 501
95806   501 /bin/zsh -c set -e\012A='/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive'; APP="$A/Products/Applications/Vaelen.app"; D="$APP/Contents/Resources/vaelend"; DB='/Users/banes/Library/Application Support/Vaelen/state/vaelen.sqlite'; OUT=/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-observability-2120.txt\012{\012 echo "## Observability candidate 2120 evidence $(date -u '+%Y-%m-%dT%H:%M:%SZ')"\012 echo "scope=read-only-after-build; no Start/Off/retry/recovery/launchctl-mutation"\012 echo "archive=$A"\012 shasum -a 256 "$APP/Contents/MacOS/Vaelen" "$D" .build/out/Products/Release/val\012 codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3\012 echo 'focused_and_full_tests=PASS; full=205 executed,14 skipped,0 failures'\012 echo 'artifact_preflight=PASS; m14-preflight-gate=PASS pass_count=8 fail_count=0'\012 echo '-- current durable state (sqlite3 -readonly)'\012 sqlite3 -readonly "$DB" "PRAGMA user_version; SELECT phase,executor_state,executor_detail,operation_id FROM bootstrap_receipts; SELECT intent,generation,operation_id FROM lifecycle_intent; SELECT operation_id,generation,kind,state FROM lifecycle_operations; SELECT operation_id,generation FROM lifecycle_ownership; SELECT id,created_at,phase,outcome,detail,invocation_id FROM lifecycle_diagnostics ORDER BY id DESC LIMIT 8;"\012 echo '-- runtime observation'\012 launchctl print gui/501/dev.vaelen.vaelend 2>&1 || true\012 ps -axo pid=,uid=,command= | grep -E '[V]aelen.app/Contents/MacOS/Vaelen|[v]aelend' || true\012 echo '-- conclusion'\012 echo 'The 2100 Start produced only CLI LIFECYCLE_UNKNOWN and no matching 2100 controller diagnostics; URL/controller execution is not proven. The 2120 candidate was not started. No exact SMAppService status was obtained from the preserved state. Acceptance remains NOT-YET-PROVEN; stop without retry.'\012} > "$OUT"\012cat "$OUT" >> .vaelen/M14_VALIDATION_RUN.md\012cat "$OUT" >> .vaelen/EVIDENCE.md\012cat "$OUT"
-- conclusion
The 2100 Start produced only CLI LIFECYCLE_UNKNOWN and no matching 2100 controller diagnostics; URL/controller execution is not proven. The 2120 candidate was not started. No exact SMAppService status was obtained from the preserved state. Acceptance remains NOT-YET-PROVEN; stop without retry.
## Read-only state snapshot before authorized 2120 Start 2026-09-20T17:35:29Z
candidate=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app
-- launchd label/registration
Bad request.
Could not find service "dev.vaelen.vaelend" in domain for user gui: 501
-- canonical daemon process
95879  1278   501 /bin/zsh         /bin/zsh -c set -e\012A='/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive'; APP="$A/Products/Applications/Vaelen.app"; DB='/Users/banes/Library/Application Support/Vaelen/state/vaelen.sqlite'; R='/Users/banes/Library/Application Support/Vaelen/runtime'; OUT=/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-state-before-start-2120.txt\012{\012 echo "## Read-only state snapshot before authorized 2120 Start $(date -u '+%Y-%m-%dT%H:%M:%SZ')"\012 echo "candidate=$APP"\012 echo '-- launchd label/registration'\012 launchctl print gui/501/dev.vaelen.vaelend 2>&1 || true\012 echo '-- canonical daemon process'\012 ps -axo pid=,ppid=,uid=,comm=,command= | grep -E '[v]aelend' || true\012 echo '-- controller app processes'\012 ps -axo pid=,ppid=,uid=,comm=,command= | grep -E '[V]aelen.app/Contents/MacOS/Vaelen' || true\012 echo '-- Core socket and lock holders'\012 for p in "$R/sockets/core.sock" "$R/locks/vaelend.lock" "$R/locks/lifecycle-bootstrap.lock"; do\012   echo "path=$p"\012   if [ -e "$p" ]; then ls -l "$p"; lsof -n -P -- "$p" 2>&1 || true; else echo absent; fi\012 done\012 echo '-- durable lifecycle state, read-only'\012 sqlite3 -readonly "$DB" <<'SQL'\012PRAGMA user_version;\012.headers on\012.mode tabs\012SELECT phase,executor_state,executor_detail,operation_id FROM bootstrap_receipts;\012SELECT intent,generation,operation_id,actor FROM lifecycle_intent;\012SELECT operation_id,generation,kind,state,error FROM lifecycle_operations;\012SELECT operation_id,generation FROM lifecycle_ownership;\012SQL\012 echo '-- recent correlated diagnostics'\012 sqlite3 -readonly "$DB" "SELECT id,created_at,phase,outcome,detail,invocation_id,operation_id FROM lifecycle_diagnostics ORDER BY id DESC LIMIT 12;"\012} > "$OUT" 2>&1\012cat "$OUT"\012cat "$OUT" >> .vaelen/M14_VALIDATION_RUN.md
-- controller app processes
-- Core socket and lock holders
path=/Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock
absent
path=/Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:22 /Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
path=/Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:55 /Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
-- durable lifecycle state, read-only
8
-- recent correlated diagnostics
32|2026-09-20 17:30:30|preflight|success|canonical signed controller validated|C087BE59-0AE3-4020-9216-21E73E8FA428|
31|2026-09-20 17:30:30|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2100.xcarchive/Products/Applications/Vaelen.app|C087BE59-0AE3-4020-9216-21E73E8FA428|
30|2026-09-20 17:27:58|urlOpen|success|open exit=0|C087BE59-0AE3-4020-9216-21E73E8FA428|
29|2026-09-20 17:27:58|urlConstruction|started|canonical vaelen://start URL|C087BE59-0AE3-4020-9216-21E73E8FA428|
28|2026-09-20 17:27:57|mint|success|authorization minted; token persisted as hash only|C087BE59-0AE3-4020-9216-21E73E8FA428|
27|2026-09-20 17:24:48|preflight|success|canonical signed controller validated|7EB89058-B7C6-41FF-A2B5-7AECB41B6411|
26|2026-09-20 17:24:48|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2040.xcarchive/Products/Applications/Vaelen.app|7EB89058-B7C6-41FF-A2B5-7AECB41B6411|
25|2026-09-20 17:23:11|urlOpen|success|open exit=0|7EB89058-B7C6-41FF-A2B5-7AECB41B6411|
24|2026-09-20 17:23:11|urlConstruction|started|canonical vaelen://start URL|7EB89058-B7C6-41FF-A2B5-7AECB41B6411|
23|2026-09-20 17:23:11|mint|success|authorization minted; token persisted as hash only|7EB89058-B7C6-41FF-A2B5-7AECB41B6411|
22|2026-09-20 17:22:18|platform|refused|bootstrap executor refused before receipt|0E0A070E-E93B-4306-938F-A7007FD8B34D|
21|2026-09-20 17:22:18|platform|registration-observation|unknown|0E0A070E-E93B-4306-938F-A7007FD8B34D|

## Authorized single Start using exact 2120 candidate $(date -u +VAELEN_BOOTSTRAP_CONTROLLER_URL=/Users/banes/Library/Application\ Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app .build/out/Products/Release/val start
{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}
exit=3

## Sole post-deterministic-fix Start using exact 2140 candidate 2026-09-20T17:39:14Z
VAELEN_BOOTSTRAP_CONTROLLER_URL=/Users/banes/Library/Application\ Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app .build/out/Products/Release/val start
{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}
exit=3

## 2140 Start correlated outcome
- The 2120 attempt reached only `preflight` because URL delivery was not consumed by the menu-bar scene. This was an ordinary deterministic controller-delivery defect, fixed narrowly by direct application-delegate delivery to the live AppModel.
- One post-fix Start was executed with exact candidate 2140 and `open -n -a` behavior.
- Correlation: `8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB`.
- Proven path: `urlOpen success` -> `preflight started/success` -> `consume success` -> `registration-observation`.
- Exact platform observation: `value=unknown status=notFound approvalRequired=false`.
- Executor refused before receipt/reservation; no register call occurred. Durable receipt, intent, operation, and ownership tables remain empty.
- Launchd label absent; canonical socket absent; lock holders absent. The 2140 controller process remains running and was not killed.
- Stop condition: ServiceManagement reports `.notFound`, which is not the exact safe `.notRegistered` state. Acceptance remains `NOT-YET-PROVEN`; no retry, recovery, Off, or manual lifecycle mutation performed.

## Read-only diagnosis of `.notFound` (post-2140)
- SDK header semantics: `.notRegistered` means the service has not been registered or was unregistered; `.requiresApproval` means successfully registered but user action is required; `.notFound` means “An error occurred and no such service could be found.”
- Candidate 2140 preflight independently validated the signed app, nested daemon, canonical LaunchAgent path, label, `BundleProgram`, and Apple Development signing team. The exact plist is present at `Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist`.
- Therefore `.notFound` is not the legitimate clean unregistered precondition and is not evidence of approval-required. The executor’s refusal before receipt/register is correct fail-closed behavior under ADR-0014.
- No deterministic Vaelen source defect or accepted-ADR rule authorizes treating `.notFound` as `.notRegistered`; doing so would issue the single ServiceManagement mutation without a valid platform precondition.
- Classification: platform/service-resolution error requiring platform/Bane investigation or a new explicit platform decision. Stop without source change, retry, Off, cleanup, signaling, or manual state mutation.
## 2140 controlled install pre-copy 2026-09-20T17:52:58Z
source_archive=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive
source_app=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app
source_daemon=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/Resources/vaelend
installed=/Applications/Vaelen.app
installed_path=absent
55ae3af122b01bcec1727922c258349c46826f56fcb9881724d1e59d73039eaf  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/MacOS/Vaelen
b476a2ca67a6d21208bf0b53ba1214da5891e9d08e64d96019ffbf7116b7646b  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/Resources/vaelend
-- codesign app
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/Yams_712EB057E_PackageProduct.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/Yams_712EB057E_PackageProduct.framework/Versions/Current/.
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenIPC.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenIPC.framework/Versions/Current/.
--prepared:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
--validated:/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app: valid on disk
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app: satisfies its Designated Requirement
Identifier=dev.vaelen.app
Authority=Apple Development: banestojanovics@icloud.com (DMY3NZQ69X)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TFKZJV643G
-- codesign daemon
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/Resources/vaelend: valid on disk
/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/Resources/vaelend: satisfies its Designated Requirement
Identifier=vaelend
Authority=Apple Development: banestojanovics@icloud.com (DMY3NZQ69X)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TFKZJV643G
-- plist identity
  "CFBundleExecutable" => "Vaelen"
  "CFBundleIdentifier" => "dev.vaelen.app"
  "CFBundlePackageType" => "APPL"
{
  "BundleProgram" => "Contents/Resources/vaelend"
  "KeepAlive" => true
  "Label" => "dev.vaelen.vaelend"
  "ProcessType" => "Background"
  "RunAtLoad" => true
}
-- SMAppService/launchd
Bad request.
Could not find service "dev.vaelen.vaelend" in domain for user gui: 501
-- BTM
           Identifier: 2.dev.vaelen.m14-lifecycle-experiment
    Bundle Identifier: dev.vaelen.m14-lifecycle-experiment
           Identifier: 8.dev.vaelen.m14-lifecycle-experiment.agent
                  URL: Contents/Library/LaunchAgents/dev.vaelen.m14-lifecycle-experiment.agent.plist
    Parent Identifier: 2.dev.vaelen.m14-lifecycle-experiment
-- processes
98015  1278   501 /bin/zsh         /bin/zsh -c set +e\012A="$HOME/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app"\012D="$A/Contents/Resources/vaelend"; DB="$HOME/Library/Application Support/Vaelen/state/vaelen.sqlite"; R="$HOME/Library/Application Support/Vaelen/runtime"; UID=$(id -u); OUT=/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-2140-precopy.txt\012{\012echo "## 2140 controlled install pre-copy $(date -u '+%Y-%m-%dT%H:%M:%SZ')"\012echo "source_archive=${A%/Products/Applications/Vaelen.app}"; echo "source_app=$A"; echo "source_daemon=$D"; echo "installed=/Applications/Vaelen.app"\012if [ -e /Applications/Vaelen.app ]; then echo 'BLOCKER: installed path exists; no copy'; exit 10; else echo 'installed_path=absent'; fi\012shasum -a 256 "$A/Contents/MacOS/Vaelen" "$D"\012echo '-- codesign app'; codesign --verify --deep --strict --verbose=2 "$A"; codesign -dvvv "$A" 2>&1 | egrep 'Identifier=|TeamIdentifier=|Authority='\012echo '-- codesign daemon'; codesign --verify --strict --verbose=2 "$D"; codesign -dvvv "$D" 2>&1 | egrep 'Identifier=|TeamIdentifier=|Authority='\012echo '-- plist identity'; plutil -p "$A/Contents/Info.plist" | egrep 'CFBundleIdentifier|CFBundleExecutable|CFBundlePackageType'; plutil -p "$A/Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist"\012echo '-- SMAppService/launchd'; launchctl print gui/$UID/dev.vaelen.vaelend 2>&1 || true\012echo '-- BTM'; sfltool dumpbtm 2>&1 | grep -E -i 'vaelen|vaelend|dev\.vaelen' || true\012echo '-- processes'; ps -axo pid=,ppid=,uid=,comm=,command= | grep -E '[v]aelend|[V]aelen.app/Contents/MacOS/Vaelen' || true\012echo '-- core/locks'; for p in "$R/sockets/core.sock" "$R/locks/vaelend.lock" "$R/locks/lifecycle-bootstrap.lock"; do echo "path=$p"; if [ -e "$p" ]; then ls -l "$p"; lsof -n -P -- "$p" 2>&1 || true; else echo absent; fi; done\012echo '-- durable read-only'; sqlite3 -readonly "$DB" "PRAGMA user_version; SELECT phase,executor_state,executor_detail,operation_id FROM bootstrap_receipts; SELECT intent,generation,operation_id,actor FROM lifecycle_intent; SELECT operation_id,generation,kind,state,error FROM lifecycle_operations; SELECT operation_id,generation FROM lifecycle_ownership; SELECT id,created_at,phase,outcome,detail,invocation_id,operation_id FROM lifecycle_diagnostics ORDER BY id DESC LIMIT 12;"\012} > "$OUT" 2>&1\012cat "$OUT"; cat "$OUT" >> .vaelen/M14_VALIDATION_RUN.md\012printf '\n## 2140 controlled install pre-copy evidence (see output above)\n' >> .vaelen/EVIDENCE.md
-- core/locks
path=/Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock
absent
path=/Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:22 /Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
path=/Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:55 /Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
-- durable read-only
8
45|2026-09-20 17:39:15|platform|refused|bootstrap executor refused before receipt|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
44|2026-09-20 17:39:15|platform|registration-observation|value=unknown status=notFound approvalRequired=false|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
43|2026-09-20 17:39:15|consume|success|one-time invocation consumed|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
42|2026-09-20 17:39:15|preflight|success|canonical signed controller validated|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
41|2026-09-20 17:39:15|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
40|2026-09-20 17:39:14|urlOpen|success|open exit=0|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
39|2026-09-20 17:39:14|urlConstruction|started|canonical vaelen://start URL|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
38|2026-09-20 17:39:14|mint|success|authorization minted; token persisted as hash only|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
37|2026-09-20 17:36:52|preflight|success|canonical signed controller validated|D7130DCD-5459-40B5-9BF9-3909648AF401|
36|2026-09-20 17:36:52|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app|D7130DCD-5459-40B5-9BF9-3909648AF401|
35|2026-09-20 17:35:45|urlOpen|success|open exit=0|D7130DCD-5459-40B5-9BF9-3909648AF401|
34|2026-09-20 17:35:45|urlConstruction|started|canonical vaelen://start URL|D7130DCD-5459-40B5-9BF9-3909648AF401|
## 2140 archive/installed controlled comparison 2026-09-20T17:53:40Z
archive_app=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app
installed_app=/Applications/Vaelen.app
-- hashes
55ae3af122b01bcec1727922c258349c46826f56fcb9881724d1e59d73039eaf  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/MacOS/Vaelen
55ae3af122b01bcec1727922c258349c46826f56fcb9881724d1e59d73039eaf  /Applications/Vaelen.app/Contents/MacOS/Vaelen
b476a2ca67a6d21208bf0b53ba1214da5891e9d08e64d96019ffbf7116b7646b  /Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app/Contents/Resources/vaelend
b476a2ca67a6d21208bf0b53ba1214da5891e9d08e64d96019ffbf7116b7646b  /Applications/Vaelen.app/Contents/Resources/vaelend
-- byte comparisons
controller_cmp=0
daemon_cmp=0
-- strict/deep codesign
--prepared:/Applications/Vaelen.app/Contents/Frameworks/Yams_712EB057E_PackageProduct.framework/Versions/Current/.
--validated:/Applications/Vaelen.app/Contents/Frameworks/Yams_712EB057E_PackageProduct.framework/Versions/Current/.
--prepared:/Applications/Vaelen.app/Contents/Frameworks/VaelenIPC.framework/Versions/Current/.
--validated:/Applications/Vaelen.app/Contents/Frameworks/VaelenIPC.framework/Versions/Current/.
--prepared:/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
--validated:/Applications/Vaelen.app/Contents/Frameworks/VaelenCore.framework/Versions/Current/.
/Applications/Vaelen.app: valid on disk
/Applications/Vaelen.app: satisfies its Designated Requirement
/Applications/Vaelen.app/Contents/Resources/vaelend: valid on disk
/Applications/Vaelen.app/Contents/Resources/vaelend: satisfies its Designated Requirement
-- identities
Identifier=dev.vaelen.app
Authority=Apple Development: banestojanovics@icloud.com (DMY3NZQ69X)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TFKZJV643G
Identifier=vaelend
Authority=Apple Development: banestojanovics@icloud.com (DMY3NZQ69X)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=TFKZJV643G
-- plist
  "CFBundleExecutable" => "Vaelen"
  "CFBundleIdentifier" => "dev.vaelen.app"
  "CFBundlePackageType" => "APPL"
{
  "BundleProgram" => "Contents/Resources/vaelend"
  "KeepAlive" => true
  "Label" => "dev.vaelen.vaelend"
  "ProcessType" => "Background"
  "RunAtLoad" => true
}
-- launchservices
directory:                  Other (255)
name:                       Vaelen
localizedShortNames:        "en" = ?, "LSDefaultLocalizedValue" = "Vaelen"
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               B289FFEA-2929-3F2F-AC6B-C6707E8DE02A
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (70144 (0x11200))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (70148 (0x11204))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (70152 (0x11208))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2760
mod date:                   2026-09-17 19:24 (POSIX 1789665876, 𝛥 3days 29min 5sec)
exec mod date:              2026-09-17 19:29 (POSIX 1789666149, 𝛥 3days 24min 32sec)
reg date:                   2026-09-17 19:55 (POSIX 1789667702, 𝛥 2days 23hr 58min 39sec)
--
min version:                14.0 ({length = 32, bytes = 0x0e000000 00000000 00000000 00000000 ... 00000000 00000000 })
min version platform:       native
mach min ver:               14.0 ({length = 32, bytes = 0x0e000000 00000000 00000000 00000000 ... 00000000 00000000 })
activityTypes:              pv-e73189f2b51bb5, NOTIFICATION#:dev.vaelen.app
trustedCodeSignatures:      0caa3ed701046328a149a01c75c4ff5f6787a5c9

--------------------------------------------------------------------------------
bundle id:                  Expansion Slot Utility (0x2e4)
container:                  / (0x4)
mount state:                mounted
isOnRootVolume:             true 
isSystemManaged:            true 
isOnPrebootVolume:          false
path:                       /System/Library/CoreServices/Applications/Expansion Slot Utility.app (0x1194)
directory:                  /System/Library/CoreServices
name:                       Expansion Slot Utility
displayName:                Expansion Slot Utility
localizedNames:             "ar" = "أداة فتحة التوسيع", "Base" = ?, "ca" = "Utilitat Ranura d’Ampliació", "cs" = "Nastavení rozšiřujícího slotu", "da" = "Værktøj til udvidelsesplads", "de" = "Dienstprogramm für Erweiterungssteckplätze", "el" = "Βοήθημα υποδοχών επεκτάσεων", "en" = "Expansion Slot Utility", "en_AU" = "Expansion Slot Utility", "en_CA" = "Expansion Slot Utility", "en_GB" = "Expansion Slot Utility", "en_PH" = "Expansion Slot Utility", "es" = "Utilidad Ranura de Expansión", "es_419" = "Utilidad Ranura de Expansión", "fi" = "Laajennuspaikkatyökalu", "fr" = "Utilitaire de logement d’extension", "fr_CA" = "Utilitaire de logement d’extension", "he" = "כלי חריץ הרחבה", "hi" = "एक्सपैंशन स्लॉट यूटिलिटी", "hr" = "Uslužni program utora za proširenje", "hu" = "Bővítőfoglalat segédprogram", "id" = "Utilitas Slot Perluasan", "it" = "Utility Slot di Espansione", "ja" = "拡張スロットユーティリティ", "ko" = "확장 슬롯 유틸리티", "LSDefaultLocalizedValue" = "Expansion Slot Utility", "ms" = "Utiliti Slot Pengembangan", "nl" = "Uitbreidingssleufprogramma", "no" = "Utvidelsesplassverktøy", "pl" = "Narzędzie gniazd rozszerzeń", "pt_BR" = "Utilitário de Slot de Expansão", "pt_PT" = "Utilitário de Conectores de Expansão", "ro" = "Utilitar Slot de extensie", "ru" = "Утилита слотов расширения", "sk" = "Utilita pre rozširujúce sloty", "sl" = "Pripomoček za razširitveno režo", "sv" = "Utbyggnadsfackverktyg", "th" = "ยูทิลิตี้ช่องเสียบส่วนขยาย", "tr" = "Genişleme Yuvası İzlencesi", "uk" = "Утиліта слотів розширення", "vi" = "Tiện ích Khe Mở rộng", "zh_CN" = "扩充槽实用工具", "zh_HK" = "擴充插槽工具程式", "zh_TW" = "擴充插槽工具程式"
localizedShortNames:        "ar" = "أداة فتحة التوسيع", "Base" = ?, "ca" = "Utilitat Ranura d’Ampliació", "cs" = "Nastavení rozšiřujícího slotu", "da" = "Værktøj til udvidelsesplads", "de" = "Dienstprogramm für Erweiterungssteckplätze", "el" = "Βοήθημα υποδοχών επεκτάσεων", "en" = "Expansion Slot Utility", "en_AU" = "Expansion Slot Utility", "en_CA" = "Expansion Slot Utility", "en_GB" = "Expansion Slot Utility", "en_PH" = "Expansion Slot Utility", "es" = "Utilidad Ranura de Expansión", "es_419" = "Utilidad Ranura de Expansión", "fi" = "Laajennuspaikkatyökalu", "fr" = "Utilitaire de logement d’extension", "fr_CA" = "Utilitaire de logement d’extension", "he" = "כלי חריץ הרחבה", "hi" = "एक्सपैंशन स्लॉट यूटिलिटी", "hr" = "Uslužni program utora za proširenje", "hu" = "Bővítőfoglalat segédprogram", "id" = "Utilitas Slot Perluasan", "it" = "Utility Slot di Espansione", "ja" = "拡張スロットユーティリティ", "ko" = "확장 슬롯 유틸리티", "LSDefaultLocalizedValue" = "Expansion Slot Utility", "ms" = "Utiliti Slot Pengembangan", "nl" = "Uitbreidingssleufprogramma", "no" = "Utvidelsesplassverktøy", "pl" = "Narzędzie gniazd rozszerzeń", "pt_BR" = "Utilitário de Slot de Expansão", "pt_PT" = "Utilitário de Conectores de Expansão", "ro" = "Utilitar slot de extensie", "ru" = "Утилита слотов расширения", "sk" = "Utilita pre rozširujúce sloty", "sl" = "Pripomoček za razširitveno režo", "sv" = "Utbyggnadsfackverktyg", "th" = "ยูทิลิตี้ช่องเสียบส่วนขยาย", "tr" = "Genişleme Yuvası İzlencesi", "uk" = "Утиліта слотів розширення", "vi" = "Tiện ích Khe Mở rộng", "zh_CN" = "扩充槽实用工具", "zh_HK" = "擴充插槽工具程式", "zh_TW" = "擴充插槽工具程式"
teamID:                     0000000000
identifier:                 com.apple.ExpansionSlotUtility
version:                    2.0 ({length = 32, bytes = 0x02000000 00000000 00000000 00000000 ... 00000000 00000000 })
codeInfoID:                 com.apple.ExpansionSlotUtility
platform:                   native
--
directory:                  ~
name:                       Vaelen
localizedShortNames:        "en" = ?, "LSDefaultLocalizedValue" = "Vaelen"
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               3B2BCB32-2D5E-3DDA-A76B-134FC93BB7EA
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (73532 (0x11f3c))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (73536 (0x11f40))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (73540 (0x11f44))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2892
mod date:                   2026-09-18 09:37 (POSIX 1789717053, 𝛥 2days 10hr 16min 8sec)
exec mod date:              2026-09-18 12:40 (POSIX 1789728054, 𝛥 2days 7hr 12min 47sec)
reg date:                   2026-09-18 12:40 (POSIX 1789728054, 𝛥 2days 7hr 12min 47sec)
--
min version:                14.0 ({length = 32, bytes = 0x0e000000 00000000 00000000 00000000 ... 00000000 00000000 })
min version platform:       native
mach min ver:               14.0 ({length = 32, bytes = 0x0e000000 00000000 00000000 00000000 ... 00000000 00000000 })
-- BTM
-- SMAppService/launchd
Bad request.
Could not find service "dev.vaelen.vaelend" in domain for user gui: 501
-- process
98077  1278   501 /bin/zsh         /bin/zsh -c set +e\012A="$HOME/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app"; I=/Applications/Vaelen.app; D="$A/Contents/Resources/vaelend"; ID="$I/Contents/Resources/vaelend"; UID=$(id -u); R="$HOME/Library/Application Support/Vaelen/runtime"; DB="$HOME/Library/Application Support/Vaelen/state/vaelen.sqlite"; OUT=/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-2140-installed-compare.txt\012{\012echo "## 2140 archive/installed controlled comparison $(date -u '+%Y-%m-%dT%H:%M:%SZ')"; echo "archive_app=$A"; echo "installed_app=$I"\012echo '-- hashes'; shasum -a 256 "$A/Contents/MacOS/Vaelen" "$I/Contents/MacOS/Vaelen" "$D" "$ID"\012echo '-- byte comparisons'; cmp -s "$A/Contents/MacOS/Vaelen" "$I/Contents/MacOS/Vaelen"; echo "controller_cmp=$?"; cmp -s "$D" "$ID"; echo "daemon_cmp=$?"\012echo '-- strict/deep codesign'; codesign --verify --deep --strict --verbose=2 "$I"; codesign --verify --strict --verbose=2 "$ID"\012echo '-- identities'; codesign -dvvv "$I" 2>&1 | egrep 'Identifier=|TeamIdentifier=|Authority='; codesign -dvvv "$ID" 2>&1 | egrep 'Identifier=|TeamIdentifier=|Authority='\012echo '-- plist'; plutil -p "$I/Contents/Info.plist" | egrep 'CFBundleIdentifier|CFBundleExecutable|CFBundlePackageType'; plutil -p "$I/Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist"\012echo '-- launchservices'; /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump 2>&1 | grep -A20 -B3 -E 'dev\.vaelen\.app|/Applications/Vaelen\.app' | head -100\012echo '-- BTM'; sfltool dumpbtm 2>&1 | grep -A8 -B3 -E 'dev\.vaelen\.app|dev\.vaelen\.vaelend|/Applications/Vaelen\.app' || true\012echo '-- SMAppService/launchd'; launchctl print gui/$UID/dev.vaelen.vaelend 2>&1 || true\012echo '-- process'; ps -axo pid=,ppid=,uid=,comm=,command= | grep -E '[v]aelend|[V]aelen.app/Contents/MacOS/Vaelen' || true\012echo '-- endpoint/locks'; for p in "$R/sockets/core.sock" "$R/locks/vaelend.lock" "$R/locks/lifecycle-bootstrap.lock"; do echo "path=$p"; if [ -e "$p" ]; then ls -l "$p"; lsof -n -P -- "$p" 2>&1 || true; else echo absent; fi; done\012echo '-- durable'; sqlite3 -readonly "$DB" "PRAGMA user_version; SELECT phase,executor_state,executor_detail,operation_id FROM bootstrap_receipts; SELECT intent,generation,operation_id,actor FROM lifecycle_intent; SELECT operation_id,generation,kind,state,error FROM lifecycle_operations; SELECT operation_id,generation FROM lifecycle_ownership; SELECT id,created_at,phase,outcome,detail,invocation_id,operation_id FROM lifecycle_diagnostics ORDER BY id DESC LIMIT 12;"\012} > "$OUT" 2>&1\012cat "$OUT"; cat "$OUT" >> .vaelen/M14_VALIDATION_RUN.md
-- endpoint/locks
path=/Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock
absent
path=/Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:22 /Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
path=/Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:55 /Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
-- durable
8
45|2026-09-20 17:39:15|platform|refused|bootstrap executor refused before receipt|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
44|2026-09-20 17:39:15|platform|registration-observation|value=unknown status=notFound approvalRequired=false|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
43|2026-09-20 17:39:15|consume|success|one-time invocation consumed|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
42|2026-09-20 17:39:15|preflight|success|canonical signed controller validated|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
41|2026-09-20 17:39:15|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
40|2026-09-20 17:39:14|urlOpen|success|open exit=0|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
39|2026-09-20 17:39:14|urlConstruction|started|canonical vaelen://start URL|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
38|2026-09-20 17:39:14|mint|success|authorization minted; token persisted as hash only|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
37|2026-09-20 17:36:52|preflight|success|canonical signed controller validated|D7130DCD-5459-40B5-9BF9-3909648AF401|
36|2026-09-20 17:36:52|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app|D7130DCD-5459-40B5-9BF9-3909648AF401|
35|2026-09-20 17:35:45|urlOpen|success|open exit=0|D7130DCD-5459-40B5-9BF9-3909648AF401|
34|2026-09-20 17:35:45|urlConstruction|started|canonical vaelen://start URL|D7130DCD-5459-40B5-9BF9-3909648AF401|
## Exactly one controlled Start using installed 2140 controller 2026-09-20T17:53:59Z
controller=/Applications/Vaelen.app
cli=.build/out/Products/Release/val
scope=one real Start; no retry
{"code":"LIFECYCLE_UNKNOWN","message":"Bootstrap completed ambiguously or Core did not reconnect; recovery is required."}
exit=3
-- post-start observation
Bad request.
Could not find service "dev.vaelen.vaelend" in domain for user gui: 501
98119  1278   501 /bin/zsh         /bin/zsh -c set +e\012OUT=/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/m14-installed-start-2140.txt\012{\012echo "## Exactly one controlled Start using installed 2140 controller $(date -u '+%Y-%m-%dT%H:%M:%SZ')"; echo 'controller=/Applications/Vaelen.app'; echo 'cli=.build/out/Products/Release/val'; echo 'scope=one real Start; no retry'\012VAELEN_BOOTSTRAP_CONTROLLER_URL=/Applications/Vaelen.app .build/out/Products/Release/val start; echo "exit=$?"\012echo '-- post-start observation'; launchctl print gui/$(id -u)/dev.vaelen.vaelend 2>&1 || true; ps -axo pid=,ppid=,uid=,comm=,command= | grep -E '[v]aelend|[V]aelen.app/Contents/MacOS/Vaelen' || true\012R="$HOME/Library/Application Support/Vaelen/runtime"; DB="$HOME/Library/Application Support/Vaelen/state/vaelen.sqlite"; for p in "$R/sockets/core.sock" "$R/locks/vaelend.lock" "$R/locks/lifecycle-bootstrap.lock"; do echo "path=$p"; [ -e "$p" ] && { ls -l "$p"; lsof -n -P -- "$p" 2>&1 || true; } || echo absent; done\012sqlite3 -readonly "$DB" "SELECT id,created_at,phase,outcome,detail,invocation_id,operation_id FROM lifecycle_diagnostics ORDER BY id DESC LIMIT 12; SELECT phase,executor_state,executor_detail,operation_id FROM bootstrap_receipts; SELECT intent,generation,operation_id,actor FROM lifecycle_intent; SELECT operation_id,generation,kind,state,error FROM lifecycle_operations; SELECT operation_id,generation FROM lifecycle_ownership;"\012} > "$OUT" 2>&1\012cat "$OUT"; cat "$OUT" >> .vaelen/M14_VALIDATION_RUN.md
path=/Users/banes/Library/Application Support/Vaelen/runtime/sockets/core.sock
absent
path=/Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:22 /Users/banes/Library/Application Support/Vaelen/runtime/locks/vaelend.lock
path=/Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
-rw-------@ 1 banes  staff  0 Sep 19 21:55 /Users/banes/Library/Application Support/Vaelen/runtime/locks/lifecycle-bootstrap.lock
45|2026-09-20 17:39:15|platform|refused|bootstrap executor refused before receipt|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
44|2026-09-20 17:39:15|platform|registration-observation|value=unknown status=notFound approvalRequired=false|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
43|2026-09-20 17:39:15|consume|success|one-time invocation consumed|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
42|2026-09-20 17:39:15|preflight|success|canonical signed controller validated|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
41|2026-09-20 17:39:15|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
40|2026-09-20 17:39:14|urlOpen|success|open exit=0|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
39|2026-09-20 17:39:14|urlConstruction|started|canonical vaelen://start URL|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
38|2026-09-20 17:39:14|mint|success|authorization minted; token persisted as hash only|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
37|2026-09-20 17:36:52|preflight|success|canonical signed controller validated|D7130DCD-5459-40B5-9BF9-3909648AF401|
36|2026-09-20 17:36:52|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2120.xcarchive/Products/Applications/Vaelen.app|D7130DCD-5459-40B5-9BF9-3909648AF401|
35|2026-09-20 17:35:45|urlOpen|success|open exit=0|D7130DCD-5459-40B5-9BF9-3909648AF401|
34|2026-09-20 17:35:45|urlConstruction|started|canonical vaelen://start URL|D7130DCD-5459-40B5-9BF9-3909648AF401|
## Installed-controller Start blocker 2026-09-20T17:54:13Z
-- LS exact Vaelen records
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               B289FFEA-2929-3F2F-AC6B-C6707E8DE02A
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (70144 (0x11200))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (70148 (0x11204))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (70152 (0x11208))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2760
mod date:                   2026-09-17 19:24 (POSIX 1789665876, 𝛥 3days 29min 38sec)
exec mod date:              2026-09-17 19:29 (POSIX 1789666149, 𝛥 3days 25min 5sec)
reg date:                   2026-09-17 19:55 (POSIX 1789667702, 𝛥 2days 23hr 59min 12sec)
rec mod date:               2026-09-17 19:55 (POSIX 1789667702, 𝛥 2days 23hr 59min 12sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               3B2BCB32-2D5E-3DDA-A76B-134FC93BB7EA
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (73532 (0x11f3c))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (73536 (0x11f40))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (73540 (0x11f44))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2892
mod date:                   2026-09-18 09:37 (POSIX 1789717053, 𝛥 2days 10hr 16min 41sec)
exec mod date:              2026-09-18 12:40 (POSIX 1789728054, 𝛥 2days 7hr 13min 20sec)
reg date:                   2026-09-18 12:40 (POSIX 1789728054, 𝛥 2days 7hr 13min 20sec)
rec mod date:               2026-09-18 12:40 (POSIX 1789728054, 𝛥 2days 7hr 13min 20sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               67632CC7-B05D-37A4-9900-D8B1E3F943AF
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (73596 (0x11f7c))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (73600 (0x11f80))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (73604 (0x11f84))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2908
mod date:                   2026-09-18 14:01 (POSIX 1789732891, 𝛥 2days 5hr 52min 43sec)
exec mod date:              2026-09-18 15:09 (POSIX 1789736954, 𝛥 2days 4hr 45min)
reg date:                   2026-09-18 15:09 (POSIX 1789736954, 𝛥 2days 4hr 45min)
rec mod date:               2026-09-18 15:09 (POSIX 1789736954, 𝛥 2days 4hr 45min)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               B8045590-7D5C-326A-AB22-3013932F23E0
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (74496 (0x12300))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (74500 (0x12304))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2952
mod date:                   2026-09-18 20:11 (POSIX 1789755115, 𝛥 47hr 42min 19sec)
exec mod date:              2026-09-18 20:11 (POSIX 1789755115, 𝛥 47hr 42min 19sec)
reg date:                   2026-09-18 20:11 (POSIX 1789755115, 𝛥 47hr 42min 19sec)
rec mod date:               2026-09-18 20:11 (POSIX 1789755115, 𝛥 47hr 42min 19sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element  in-temp-dir (0000800000000004)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               0B575A08-A4E1-3996-A9CA-9CDDCACA2F38
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (74540 (0x1232c))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (74544 (0x12330))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (74548 (0x12334))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                2964
mod date:                   2026-09-18 22:14 (POSIX 1789762471, 𝛥 1day 21hr 39min 43sec)
exec mod date:              2026-09-18 22:14 (POSIX 1789762471, 𝛥 1day 21hr 39min 43sec)
reg date:                   2026-09-18 22:14 (POSIX 1789762471, 𝛥 1day 21hr 39min 43sec)
rec mod date:               2026-09-18 22:14 (POSIX 1789762471, 𝛥 1day 21hr 39min 43sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               960CC510-1FC7-34AB-9A53-3AF26B2A192E
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77776 (0x12fd0))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (77780 (0x12fd4))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3096
mod date:                   2026-09-19 20:46 (POSIX 1789843594, 𝛥 23hr 7min 40sec)
exec mod date:              2026-09-19 20:46 (POSIX 1789843574, 𝛥 23hr 8min)
reg date:                   2026-09-19 20:46 (POSIX 1789843594, 𝛥 23hr 7min 40sec)
rec mod date:               2026-09-19 20:46 (POSIX 1789843594, 𝛥 23hr 7min 40sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element (0000000000000004)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               F01C55FF-43EA-34D2-BA1A-F97380945286
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77788 (0x12fdc))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (77792 (0x12fe0))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (77796 (0x12fe4))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3100
mod date:                   2026-09-19 22:01 (POSIX 1789848099, 𝛥 21hr 52min 35sec)
exec mod date:              2026-09-19 22:01 (POSIX 1789848099, 𝛥 21hr 52min 35sec)
reg date:                   2026-09-19 22:01 (POSIX 1789848099, 𝛥 21hr 52min 35sec)
rec mod date:               2026-09-19 22:01 (POSIX 1789848099, 𝛥 21hr 52min 35sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               BD953318-C7F6-3982-8C2F-87DB2FD3F778, 47D1006C-0C2B-395F-8508-61E10C9B64CA
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77804 (0x12fec))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (77808 (0x12ff0))
                            {
                            }
Intents:                    0 values (77812 (0x12ff4))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3104
mod date:                   2026-09-19 22:02 (POSIX 1789848140, 𝛥 21hr 51min 54sec)
exec mod date:              2026-09-19 22:02 (POSIX 1789848140, 𝛥 21hr 51min 54sec)
reg date:                   2026-09-19 22:02 (POSIX 1789848140, 𝛥 21hr 51min 54sec)
rec mod date:               2026-09-19 22:02 (POSIX 1789848140, 𝛥 21hr 51min 54sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element  in-temp-dir (0000800000000004)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               BDC1BC7B-98C1-324D-AA0F-BF5C5345DFDC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77864 (0x13028))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (77868 (0x1302c))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3120
mod date:                   2026-09-20 06:44 (POSIX 1789879485, 𝛥 13hr 9min 29sec)
exec mod date:              2026-09-20 06:44 (POSIX 1789879485, 𝛥 13hr 9min 29sec)
reg date:                   2026-09-20 06:44 (POSIX 1789879485, 𝛥 13hr 9min 29sec)
rec mod date:               2026-09-20 06:44 (POSIX 1789879485, 𝛥 13hr 9min 29sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element  in-temp-dir (0000800000000004)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               8172D981-60F6-3FDC-B0C9-7E4E7EAEF85A, B4D9A1EF-A20C-35E3-9A00-F824696F11AA
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77888 (0x13040))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (77892 (0x13044))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3128
mod date:                   2026-09-20 06:46 (POSIX 1789879609, 𝛥 13hr 7min 25sec)
exec mod date:              2026-09-20 06:46 (POSIX 1789879609, 𝛥 13hr 7min 25sec)
reg date:                   2026-09-20 06:46 (POSIX 1789879609, 𝛥 13hr 7min 25sec)
rec mod date:               2026-09-20 06:46 (POSIX 1789879609, 𝛥 13hr 7min 25sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element  in-temp-dir (0000800000000004)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               98C03CA9-4DD3-341C-A42B-D9FEE7B4AFEF
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77928 (0x13068))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (77932 (0x1306c))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (77936 (0x13070))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3144
mod date:                   2026-09-20 06:55 (POSIX 1789880122, 𝛥 12hr 58min 52sec)
exec mod date:              2026-09-20 06:55 (POSIX 1789880122, 𝛥 12hr 58min 52sec)
reg date:                   2026-09-20 06:55 (POSIX 1789880122, 𝛥 12hr 58min 52sec)
rec mod date:               2026-09-20 06:55 (POSIX 1789880122, 𝛥 12hr 58min 52sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               DCF42718-EF9B-39E8-A4F8-D5F997FF2A05, CC0C580A-83AE-380E-91D4-6AF2F23B24AE
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (77960 (0x13088))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (77964 (0x1308c))
                            {
                            }
Intents:                    0 values (77968 (0x13090))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3164
mod date:                   2026-09-20 06:56 (POSIX 1789880164, 𝛥 12hr 58min 10sec)
exec mod date:              2026-09-20 06:56 (POSIX 1789880164, 𝛥 12hr 58min 10sec)
reg date:                   2026-09-20 06:56 (POSIX 1789880164, 𝛥 12hr 58min 10sec)
rec mod date:               2026-09-20 06:56 (POSIX 1789880164, 𝛥 12hr 58min 10sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               ui-element  in-temp-dir (0000800000000004)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               3EF98C60-047B-372A-B6DE-C1A5DD64E0E0
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             8 values (78048 (0x130e0))
                            {
                                CFBundleDevelopmentRegion = en;
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleInfoDictionaryVersion = "6.0";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78052 (0x130e4))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78056 (0x130e8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3200
mod date:                   2026-09-20 07:29 (POSIX 1789882160, 𝛥 12hr 24min 55sec)
exec mod date:              2026-09-20 07:29 (POSIX 1789882160, 𝛥 12hr 24min 55sec)
reg date:                   2026-09-20 07:29 (POSIX 1789882160, 𝛥 12hr 24min 55sec)
rec mod date:               2026-09-20 07:29 (POSIX 1789882160, 𝛥 12hr 24min 55sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               59D191E5-A973-3BD0-9549-F406E0669026
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78496 (0x132a0))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78500 (0x132a4))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78504 (0x132a8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3332
mod date:                   2026-09-20 07:56 (POSIX 1789883763, 𝛥 11hr 58min 12sec)
exec mod date:              2026-09-20 07:56 (POSIX 1789883763, 𝛥 11hr 58min 12sec)
reg date:                   2026-09-20 07:56 (POSIX 1789883763, 𝛥 11hr 58min 12sec)
rec mod date:               2026-09-20 07:56 (POSIX 1789883763, 𝛥 11hr 58min 12sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               8A615183-7FE1-3F4A-8D25-BA49DE17D4BA, BE01EBF8-F6B4-3B1C-984F-101687C3FE81
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78512 (0x132b0))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (78516 (0x132b4))
                            {
                            }
Intents:                    0 values (78520 (0x132b8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3336
mod date:                   2026-09-20 07:56 (POSIX 1789883805, 𝛥 11hr 57min 30sec)
exec mod date:              2026-09-20 07:56 (POSIX 1789883805, 𝛥 11hr 57min 30sec)
reg date:                   2026-09-20 07:56 (POSIX 1789883805, 𝛥 11hr 57min 30sec)
rec mod date:               2026-09-20 07:56 (POSIX 1789883805, 𝛥 11hr 57min 30sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               499F1855-559B-30B0-A635-927620E58D81
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78648 (0x13338))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78652 (0x1333c))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78656 (0x13340))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3376
mod date:                   2026-09-20 08:13 (POSIX 1789884828, 𝛥 11hr 40min 27sec)
exec mod date:              2026-09-20 08:13 (POSIX 1789884828, 𝛥 11hr 40min 27sec)
reg date:                   2026-09-20 08:13 (POSIX 1789884828, 𝛥 11hr 40min 27sec)
rec mod date:               2026-09-20 08:13 (POSIX 1789884828, 𝛥 11hr 40min 27sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               4A6D3BCC-AE02-3C5B-A801-808937651B2A, EF4F3BBC-4F40-3FA2-BC9A-43F9D7A1BD57
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78664 (0x13348))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (78668 (0x1334c))
                            {
                            }
Intents:                    0 values (78672 (0x13350))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3380
mod date:                   2026-09-20 08:14 (POSIX 1789884869, 𝛥 11hr 39min 46sec)
exec mod date:              2026-09-20 08:14 (POSIX 1789884869, 𝛥 11hr 39min 46sec)
reg date:                   2026-09-20 08:14 (POSIX 1789884869, 𝛥 11hr 39min 46sec)
rec mod date:               2026-09-20 08:14 (POSIX 1789884869, 𝛥 11hr 39min 46sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               507E8E09-22A7-3D63-8422-3D122D0D78E6
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78680 (0x13358))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78684 (0x1335c))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78688 (0x13360))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3384
mod date:                   2026-09-20 08:31 (POSIX 1789885881, 𝛥 11hr 22min 54sec)
exec mod date:              2026-09-20 08:31 (POSIX 1789885881, 𝛥 11hr 22min 54sec)
reg date:                   2026-09-20 08:31 (POSIX 1789885881, 𝛥 11hr 22min 54sec)
rec mod date:               2026-09-20 08:31 (POSIX 1789885881, 𝛥 11hr 22min 54sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               8F880921-18D5-3498-BB57-43E684A21564
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78776 (0x133b8))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78780 (0x133bc))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78784 (0x133c0))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3412
mod date:                   2026-09-20 11:40 (POSIX 1789897213, 𝛥 8hr 14min 2sec)
exec mod date:              2026-09-20 11:40 (POSIX 1789897213, 𝛥 8hr 14min 2sec)
reg date:                   2026-09-20 11:40 (POSIX 1789897213, 𝛥 8hr 14min 2sec)
rec mod date:               2026-09-20 11:40 (POSIX 1789897213, 𝛥 8hr 14min 2sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               D7FB51D4-5E23-3817-A892-3D02639F6953
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78820 (0x133e4))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (78824 (0x133e8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3424
mod date:                   2026-09-20 12:04 (POSIX 1789898678, 𝛥 7hr 49min 37sec)
exec mod date:              2026-09-20 12:04 (POSIX 1789898678, 𝛥 7hr 49min 37sec)
reg date:                   2026-09-20 12:04 (POSIX 1789898678, 𝛥 7hr 49min 37sec)
rec mod date:               2026-09-20 12:04 (POSIX 1789898678, 𝛥 7hr 49min 37sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
safeAperture system fullscreen: capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               C9461265-B9E1-34E3-B498-FB0F049C1502
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78920 (0x13448))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (78924 (0x1344c))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (78928 (0x13450))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3456
mod date:                   2026-09-20 12:39 (POSIX 1789900790, 𝛥 7hr 14min 25sec)
exec mod date:              2026-09-20 12:39 (POSIX 1789900790, 𝛥 7hr 14min 25sec)
reg date:                   2026-09-20 12:39 (POSIX 1789900791, 𝛥 7hr 14min 24sec)
rec mod date:               2026-09-20 12:39 (POSIX 1789900791, 𝛥 7hr 14min 24sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 Vaelen
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               A4D6ECFB-CBC4-328F-A2B2-368A95C14FA9
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (78964 (0x13474))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
Intents:                    0 values (78968 (0x13478))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3468
mod date:                   2026-09-20 12:53 (POSIX 1789901585, 𝛥 7hr 1min 10sec)
exec mod date:              2026-09-20 12:53 (POSIX 1789901585, 𝛥 7hr 1min 10sec)
reg date:                   2026-09-20 12:53 (POSIX 1789901585, 𝛥 7hr 1min 10sec)
rec mod date:               2026-09-20 12:53 (POSIX 1789901585, 𝛥 7hr 1min 10sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
eGPU:                       capable  can-change (0000000000000005)
safeAperture system fullscreen: capable  can-change (0000000000000005)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               E22AF7A7-7871-343D-B559-F25EB370E4E3
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79116 (0x1350c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79120 (0x13510))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79124 (0x13514))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3512
mod date:                   2026-09-20 13:33 (POSIX 1789904021, 𝛥 6hr 20min 34sec)
exec mod date:              2026-09-20 13:33 (POSIX 1789904021, 𝛥 6hr 20min 34sec)
reg date:                   2026-09-20 13:33 (POSIX 1789904021, 𝛥 6hr 20min 34sec)
rec mod date:               2026-09-20 13:33 (POSIX 1789904021, 𝛥 6hr 20min 34sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               941CEBEA-810B-3320-B08B-B908B6C2CF6B, F46B9532-4E94-3940-8289-6789353020A3
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79132 (0x1351c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (79136 (0x13520))
                            {
                            }
Intents:                    0 values (79140 (0x13524))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3516
mod date:                   2026-09-20 13:34 (POSIX 1789904047, 𝛥 6hr 20min 8sec)
exec mod date:              2026-09-20 13:34 (POSIX 1789904047, 𝛥 6hr 20min 8sec)
reg date:                   2026-09-20 13:34 (POSIX 1789904047, 𝛥 6hr 20min 8sec)
rec mod date:               2026-09-20 13:34 (POSIX 1789904047, 𝛥 6hr 20min 8sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               611EAA99-618E-3926-8165-41BB6166F231
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79148 (0x1352c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79152 (0x13530))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79156 (0x13534))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3520
mod date:                   2026-09-20 13:38 (POSIX 1789904312, 𝛥 6hr 15min 43sec)
exec mod date:              2026-09-20 13:38 (POSIX 1789904312, 𝛥 6hr 15min 43sec)
reg date:                   2026-09-20 13:38 (POSIX 1789904312, 𝛥 6hr 15min 43sec)
rec mod date:               2026-09-20 13:38 (POSIX 1789904312, 𝛥 6hr 15min 43sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               6C3FDEE2-F168-3A8C-99EB-2FB205BBD613
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79164 (0x1353c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79168 (0x13540))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79172 (0x13544))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3524
mod date:                   2026-09-20 13:39 (POSIX 1789904360, 𝛥 6hr 14min 55sec)
exec mod date:              2026-09-20 13:39 (POSIX 1789904360, 𝛥 6hr 14min 55sec)
reg date:                   2026-09-20 13:39 (POSIX 1789904360, 𝛥 6hr 14min 55sec)
rec mod date:               2026-09-20 13:39 (POSIX 1789904360, 𝛥 6hr 14min 55sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               A31D4513-0DA0-3C30-AC20-4C6574BD3E24, 9AEA154C-3561-3851-83A8-6F240A4E1435
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79196 (0x1355c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (79200 (0x13560))
                            {
                            }
Intents:                    0 values (79204 (0x13564))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3532
mod date:                   2026-09-20 13:40 (POSIX 1789904433, 𝛥 6hr 13min 42sec)
exec mod date:              2026-09-20 13:40 (POSIX 1789904432, 𝛥 6hr 13min 43sec)
reg date:                   2026-09-20 13:40 (POSIX 1789904433, 𝛥 6hr 13min 42sec)
rec mod date:               2026-09-20 13:40 (POSIX 1789904433, 𝛥 6hr 13min 42sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               1891D1AD-93FF-37ED-8573-2EDD75B5A537
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79212 (0x1356c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79216 (0x13570))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79220 (0x13574))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3536
mod date:                   2026-09-20 13:43 (POSIX 1789904628, 𝛥 6hr 10min 27sec)
exec mod date:              2026-09-20 13:43 (POSIX 1789904628, 𝛥 6hr 10min 27sec)
reg date:                   2026-09-20 13:43 (POSIX 1789904628, 𝛥 6hr 10min 27sec)
rec mod date:               2026-09-20 13:43 (POSIX 1789904628, 𝛥 6hr 10min 27sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               7C9D7BD8-32A5-3B61-8691-EE7710384437, D0DDE9A0-F430-38D3-BCF5-6E1849D1B1B3
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79228 (0x1357c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (79232 (0x13580))
                            {
                            }
Intents:                    0 values (79236 (0x13584))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3540
mod date:                   2026-09-20 13:45 (POSIX 1789904708, 𝛥 6hr 9min 7sec)
exec mod date:              2026-09-20 13:45 (POSIX 1789904708, 𝛥 6hr 9min 7sec)
reg date:                   2026-09-20 13:45 (POSIX 1789904708, 𝛥 6hr 9min 7sec)
rec mod date:               2026-09-20 13:45 (POSIX 1789904708, 𝛥 6hr 9min 7sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               665BB1F3-52F1-3FEB-BD38-72186AB315FE, 992EDB20-6AFB-368B-9599-4F9190C0B5E1
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79244 (0x1358c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (79248 (0x13590))
                            {
                            }
Intents:                    0 values (79252 (0x13594))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3544
mod date:                   2026-09-20 13:45 (POSIX 1789904735, 𝛥 6hr 8min 40sec)
exec mod date:              2026-09-20 13:45 (POSIX 1789904735, 𝛥 6hr 8min 40sec)
reg date:                   2026-09-20 13:45 (POSIX 1789904735, 𝛥 6hr 8min 40sec)
rec mod date:               2026-09-20 13:45 (POSIX 1789904735, 𝛥 6hr 8min 40sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               6BDDA2EF-11F4-3D3C-86B9-22481065638B
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79388 (0x1361c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79392 (0x13620))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79396 (0x13624))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3588
mod date:                   2026-09-20 14:01 (POSIX 1789905705, 𝛥 5hr 52min 30sec)
exec mod date:              2026-09-20 14:19 (POSIX 1789906774, 𝛥 5hr 34min 41sec)
reg date:                   2026-09-20 14:19 (POSIX 1789906774, 𝛥 5hr 34min 41sec)
rec mod date:               2026-09-20 14:19 (POSIX 1789906774, 𝛥 5hr 34min 41sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               383F40B6-9FA7-3410-9735-559095D4D4F5
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79420 (0x1363c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79424 (0x13640))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79428 (0x13644))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3596
mod date:                   2026-09-20 14:23 (POSIX 1789906982, 𝛥 5hr 31min 13sec)
exec mod date:              2026-09-20 14:23 (POSIX 1789906982, 𝛥 5hr 31min 13sec)
reg date:                   2026-09-20 14:23 (POSIX 1789906982, 𝛥 5hr 31min 13sec)
rec mod date:               2026-09-20 14:23 (POSIX 1789906982, 𝛥 5hr 31min 13sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               CD3C6942-FA61-3729-9630-4610A59C9C79
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79436 (0x1364c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79440 (0x13650))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79444 (0x13654))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3600
mod date:                   2026-09-20 14:23 (POSIX 1789907005, 𝛥 5hr 30min 50sec)
exec mod date:              2026-09-20 14:23 (POSIX 1789907005, 𝛥 5hr 30min 50sec)
reg date:                   2026-09-20 14:23 (POSIX 1789907005, 𝛥 5hr 30min 50sec)
rec mod date:               2026-09-20 14:23 (POSIX 1789907005, 𝛥 5hr 30min 50sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               E8BE9F70-E5BF-3996-955B-DFC37EF7CC5F
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79516 (0x1369c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79520 (0x136a0))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79524 (0x136a4))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3620
mod date:                   2026-09-20 14:58 (POSIX 1789909118, 𝛥 4hr 55min 37sec)
exec mod date:              2026-09-20 14:58 (POSIX 1789909118, 𝛥 4hr 55min 37sec)
reg date:                   2026-09-20 14:58 (POSIX 1789909118, 𝛥 4hr 55min 37sec)
rec mod date:               2026-09-20 14:58 (POSIX 1789909118, 𝛥 4hr 55min 37sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               52B82528-A17A-32CB-B1E2-79F0FCBE6812
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79660 (0x1372c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (79664 (0x13730))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (79668 (0x13734))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3656
mod date:                   2026-09-20 16:14 (POSIX 1789913668, 𝛥 3hr 39min 47sec)
exec mod date:              2026-09-20 16:14 (POSIX 1789913668, 𝛥 3hr 39min 47sec)
reg date:                   2026-09-20 16:14 (POSIX 1789913668, 𝛥 3hr 39min 47sec)
rec mod date:               2026-09-20 16:14 (POSIX 1789913668, 𝛥 3hr 39min 47sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               A2B50C20-9218-3576-867C-22E5F40C6F5C, F2856F90-3BF2-33CA-8487-3DA7A2FD7813
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (79676 (0x1373c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (79680 (0x13740))
                            {
                            }
Intents:                    0 values (79684 (0x13744))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3660
mod date:                   2026-09-20 16:15 (POSIX 1789913711, 𝛥 3hr 39min 4sec)
exec mod date:              2026-09-20 16:15 (POSIX 1789913711, 𝛥 3hr 39min 4sec)
reg date:                   2026-09-20 16:15 (POSIX 1789913711, 𝛥 3hr 39min 4sec)
rec mod date:               2026-09-20 16:15 (POSIX 1789913711, 𝛥 3hr 39min 4sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               2C40A1B9-6BA5-3685-9161-0FA234BA3739
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80012 (0x1388c))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (80016 (0x13890))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (80020 (0x13894))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3744
mod date:                   2026-09-20 17:33 (POSIX 1789918398, 𝛥 2hr 20min 57sec)
exec mod date:              2026-09-20 17:36 (POSIX 1789918618, 𝛥 2hr 17min 17sec)
reg date:                   2026-09-20 17:36 (POSIX 1789918618, 𝛥 2hr 17min 17sec)
rec mod date:               2026-09-20 17:36 (POSIX 1789918618, 𝛥 2hr 17min 17sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     arm64 (0000000000000080)
Mach-O UUIDs:               39687B5F-CA38-35FF-B4CA-70376CD6AE13
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80052 (0x138b4))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               1 values (80056 (0x138b8))
                            {
                                "com.apple.security.get-task-allow" = 1;
                            }
Intents:                    0 values (80060 (0x138bc))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3756
mod date:                   2026-09-20 13:30 (POSIX 1789903818, 𝛥 6hr 23min 57sec)
exec mod date:              2026-09-20 17:44 (POSIX 1789919084, 𝛥 2hr 9min 31sec)
reg date:                   2026-09-20 17:44 (POSIX 1789919084, 𝛥 2hr 9min 31sec)
rec mod date:               2026-09-20 17:44 (POSIX 1789919084, 𝛥 2hr 9min 31sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               9D535CBE-FE37-345D-B352-A0C806EE554E, 7767A67F-5DC7-38A7-B765-B04082D21079
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80084 (0x138d4))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80088 (0x138d8))
                            {
                            }
Intents:                    0 values (80092 (0x138dc))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3764
mod date:                   2026-09-20 17:06 (POSIX 1789916788, 𝛥 2hr 47min 47sec)
exec mod date:              2026-09-20 17:06 (POSIX 1789916788, 𝛥 2hr 47min 47sec)
reg date:                   2026-09-20 18:08 (POSIX 1789920487, 𝛥 1hr 46min 8sec)
rec mod date:               2026-09-20 18:08 (POSIX 1789920487, 𝛥 1hr 46min 8sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               DBA0A54D-3BF3-3744-B14B-561E30C5CB14, 270897AB-5403-3AC6-85F7-4243B8522A72
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80116 (0x138f4))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80120 (0x138f8))
                            {
                            }
Intents:                    0 values (80124 (0x138fc))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3772
mod date:                   2026-09-20 18:22 (POSIX 1789921371, 𝛥 1hr 31min 24sec)
exec mod date:              2026-09-20 18:22 (POSIX 1789921371, 𝛥 1hr 31min 24sec)
reg date:                   2026-09-20 18:22 (POSIX 1789921371, 𝛥 1hr 31min 24sec)
rec mod date:               2026-09-20 18:22 (POSIX 1789921371, 𝛥 1hr 31min 24sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               in-temp-dir (0000800000000000)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               ED218350-B809-3503-BC73-EE0ABB3B2C9D, 49E62944-B690-37B7-B366-1CA12C1E47F4
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80208 (0x13950))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80212 (0x13954))
                            {
                            }
Intents:                    0 values (80216 (0x13958))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3796
mod date:                   2026-09-20 19:12 (POSIX 1789924344, 𝛥 41min 51sec)
exec mod date:              2026-09-20 19:12 (POSIX 1789924344, 𝛥 41min 51sec)
reg date:                   2026-09-20 19:13 (POSIX 1789924431, 𝛥 40min 24sec)
rec mod date:               2026-09-20 19:13 (POSIX 1789924431, 𝛥 40min 24sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               E8B62352-E547-3D9E-92DB-2F8BD7094482, DA4D9E70-4D15-36C2-8F08-11514BBB7DA9
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80240 (0x13970))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80244 (0x13974))
                            {
                            }
Intents:                    0 values (80248 (0x13978))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3804
mod date:                   2026-09-20 19:17 (POSIX 1789924647, 𝛥 36min 48sec)
exec mod date:              2026-09-20 19:17 (POSIX 1789924647, 𝛥 36min 48sec)
reg date:                   2026-09-20 19:18 (POSIX 1789924688, 𝛥 36min 7sec)
rec mod date:               2026-09-20 19:18 (POSIX 1789924688, 𝛥 36min 7sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               758504CE-D200-3A46-9246-8648146F4FAB, FED43FD6-5049-3011-A0F7-6A5502B300BC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80272 (0x13990))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80276 (0x13994))
                            {
                            }
Intents:                    0 values (80280 (0x13998))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3812
mod date:                   2026-09-20 19:19 (POSIX 1789924766, 𝛥 34min 49sec)
exec mod date:              2026-09-20 19:19 (POSIX 1789924766, 𝛥 34min 49sec)
reg date:                   2026-09-20 19:19 (POSIX 1789924795, 𝛥 34min 20sec)
rec mod date:               2026-09-20 19:19 (POSIX 1789924795, 𝛥 34min 20sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               758504CE-D200-3A46-9246-8648146F4FAB, FED43FD6-5049-3011-A0F7-6A5502B300BC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80304 (0x139b0))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80308 (0x139b4))
                            {
                            }
Intents:                    0 values (80312 (0x139b8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3820
mod date:                   2026-09-20 19:21 (POSIX 1789924877, 𝛥 32min 58sec)
exec mod date:              2026-09-20 19:21 (POSIX 1789924877, 𝛥 32min 58sec)
reg date:                   2026-09-20 19:21 (POSIX 1789924901, 𝛥 32min 34sec)
rec mod date:               2026-09-20 19:21 (POSIX 1789924901, 𝛥 32min 34sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               758504CE-D200-3A46-9246-8648146F4FAB, FED43FD6-5049-3011-A0F7-6A5502B300BC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80336 (0x139d0))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80340 (0x139d4))
                            {
                            }
Intents:                    0 values (80344 (0x139d8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3828
mod date:                   2026-09-20 19:22 (POSIX 1789924966, 𝛥 31min 29sec)
exec mod date:              2026-09-20 19:22 (POSIX 1789924966, 𝛥 31min 29sec)
reg date:                   2026-09-20 19:23 (POSIX 1789924991, 𝛥 31min 4sec)
rec mod date:               2026-09-20 19:23 (POSIX 1789924991, 𝛥 31min 4sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               758504CE-D200-3A46-9246-8648146F4FAB, FED43FD6-5049-3011-A0F7-6A5502B300BC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80368 (0x139f0))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80372 (0x139f4))
                            {
                            }
Intents:                    0 values (80376 (0x139f8))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3836
mod date:                   2026-09-20 19:27 (POSIX 1789925224, 𝛥 27min 11sec)
exec mod date:              2026-09-20 19:27 (POSIX 1789925224, 𝛥 27min 11sec)
reg date:                   2026-09-20 19:27 (POSIX 1789925278, 𝛥 26min 17sec)
rec mod date:               2026-09-20 19:27 (POSIX 1789925278, 𝛥 26min 17sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               758504CE-D200-3A46-9246-8648146F4FAB, FED43FD6-5049-3011-A0F7-6A5502B300BC
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80400 (0x13a10))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80404 (0x13a14))
                            {
                            }
Intents:                    0 values (80408 (0x13a18))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3844
mod date:                   2026-09-20 19:32 (POSIX 1789925566, 𝛥 21min 29sec)
exec mod date:              2026-09-20 19:32 (POSIX 1789925566, 𝛥 21min 29sec)
reg date:                   2026-09-20 19:35 (POSIX 1789925745, 𝛥 18min 30sec)
rec mod date:               2026-09-20 19:35 (POSIX 1789925745, 𝛥 18min 30sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               664E8B78-9874-3DBC-9753-BEB405D56066, 5A956D8C-6A18-3D0F-9B3E-C53A108E7E33
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80432 (0x13a30))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80436 (0x13a34))
                            {
                            }
Intents:                    0 values (80440 (0x13a38))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3852
mod date:                   2026-09-20 19:38 (POSIX 1789925893, 𝛥 16min 2sec)
exec mod date:              2026-09-20 19:38 (POSIX 1789925893, 𝛥 16min 2sec)
reg date:                   2026-09-20 19:39 (POSIX 1789925954, 𝛥 15min 1sec)
rec mod date:               2026-09-20 19:39 (POSIX 1789925954, 𝛥 15min 1sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
App Nap:                    capable (0000000000000001)
identifier:                 dev.vaelen.app
codeInfoID:                 dev.vaelen.app
platform:                   native
executable:                 Contents/MacOS/Vaelen
slices:                     x86_64  arm64 (0000000000000088)
Mach-O UUIDs:               664E8B78-9874-3DBC-9753-BEB405D56066, 5A956D8C-6A18-3D0F-9B3E-C53A108E7E33
execSDK ver:                27.0 ({length = 32, bytes = 0x1b000000 00000000 00000000 00000000 ... 00000000 00000000 })
infoDictionary:             6 values (80464 (0x13a50))
                            {
                                CFBundleExecutable = Vaelen;
                                CFBundleIdentifier = "dev.vaelen.app";
                                CFBundleName = Vaelen;
                                CFBundlePackageType = APPL;
                                CFBundleSignature = "????";
                                CFBundleSupportedPlatforms =     (
                                    MacOSX
                                );
                            }
entitlements:               0 values (80468 (0x13a54))
                            {
                            }
Intents:                    0 values (80472 (0x13a58))
                            {
                            }
class:                      kLSBundleClassApplication (0x2)
sequenceNum:                3860
mod date:                   2026-09-20 19:38 (POSIX 1789925893, 𝛥 16min 2sec)
exec mod date:              2026-09-20 19:38 (POSIX 1789925893, 𝛥 16min 2sec)
reg date:                   2026-09-20 19:53 (POSIX 1789926795, 𝛥 60sec)
rec mod date:               2026-09-20 19:53 (POSIX 1789926795, 𝛥 60sec)
uid:                        501
type code:                  'APPL' (4150504c)
creator code:               '????' (3f3f3f3f)
bundle flags:               launch-disabled (0000000000000080)
plist flags:                has-custom-bindings (0000000000010000)
item flags:                 package  application  container  native-app  extension-hidden (000000000010008e)
-- processes excluding inspection shell
-- latest durable diagnostics
45|2026-09-20 17:39:15|platform|refused|bootstrap executor refused before receipt|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
44|2026-09-20 17:39:15|platform|registration-observation|value=unknown status=notFound approvalRequired=false|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
43|2026-09-20 17:39:15|consume|success|one-time invocation consumed|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
42|2026-09-20 17:39:15|preflight|success|canonical signed controller validated|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
41|2026-09-20 17:39:15|preflight|started|controller=/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-2140.xcarchive/Products/Applications/Vaelen.app|8386EA9E-5FFF-4BAE-9D58-CE7B77E75BEB|
classification=STOP; installed Start returned LIFECYCLE_UNKNOWN but produced no new correlated durable diagnostics; exact installed controller execution is not proven; no retry/recovery/Off.

## M14 lead continuation — 2026-09-20 22:20 UTC

- Initial read-only state found the exact KeepAlive loop for `dev.vaelen.vaelend`, UID 501, TeamIdentifier `TFKZJV643G`, with durable succeeded bootstrap receipt operation `72152EC5-3679-4F0C-8757-AD46CF1B28F0` and completed legacy recovery fence.
- Existing signed product modern-recovery entrypoint was attempted first. It did not change durable state and did not stop the loop. A direct unsigned SMAppService unregister probe returned `SMAppServiceErrorDomain Code=22` and was not used for cleanup.
- Minimum authorized exact development cleanup was then performed only by the signed `/Applications/Vaelen.app` cleanup entrypoint for `dev.vaelen.vaelend`; no SQLite, BTM, launchctl, Syncproof, or unrelated-service mutation was performed. Post-cleanup `launchctl print gui/501/dev.vaelen.vaelend` was service-not-found and no daemon process remained.
- Fresh signed Release candidate archive: `/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920-final2.xcarchive`; installed candidate `/Applications/Vaelen.app`; app and embedded daemon verified Apple Development signed, TeamIdentifier `TFKZJV643G`.
- Candidate hashes: `Vaelen` `64ee755f3162c999de6d14fd1d569b60dda3f71bab2cfc15b9071f7a8ee40355`; `vaelend` `eddc89bbc2452ef7600e03dadba7c6e7d54d88a57c220f95f345782d49397a8a`.
- Full Swift tests after test-authenticator isolation: 212 executed, 14 skipped, 0 failures. The focused recovery/observability tests passed before the full run.
- Exactly one product Start was attempted after the loop was stopped. It failed closed with `LIFECYCLE_UNKNOWN` before a new receipt/platform mutation. Durable post-state remained the prior succeeded receipt; no lifecycle intent/operation/ownership rows were created. The signed app controller remained hung on the failed bootstrap invocation and was not retried.
- Stop: existing product recovery does not recognize the current exact modern receipt operation and the stale succeeded receipt prevents a fresh explicit Start; no second Start, Off, retry, or manual durable-state cleanup was performed.

## Recovery diagnosis — 2026-09-20 22:31 UTC

- Read-only receipt inspection: current row is canonical `dev.vaelen.app` / `dev.vaelen.vaelend`, phase `succeeded`, executor `success`, generation 1, operation `72152EC5-3679-4F0C-8757-AD46CF1B28F0`, invocation `5ECD3491-52C9-4408-934C-725157E8B253`, and expired at `2026-09-20T19:38:50Z`. It has registration evidence pointing to `/Applications/Vaelen.app/Contents/Resources/vaelend`; no lifecycle intent, operation, or ownership rows exist. Only the legacy recovery fence/history exists, with different epoch/operation and no invocation ID.
- Exact reason ordinary recovery did not recognize it: `recoverRegisteredOrphan()` is bound to the separate fixed `BootstrapRecoveryAuthorization` epoch/operation/invocation, while `archiveLegacyReceiptForFreshBootstrap()` accepts only the pre-schema legacy epoch/operation. The current receipt matches neither recovery contract.
- Implemented a narrow product recovery API bound only to the known operation/invocation, requiring signed controller preflight, authenticated receipt, expiry, no lifecycle state, fresh Core absence, and fresh registration absence; it archives the full receipt into `bootstrap_receipt_history` before clearing only the singleton current fence. It was not completed at runtime.
- Runtime blocker: the product recovery task reached `KeychainBootstrapReceiptAuthenticator.verifies` and blocked inside `SecItemCopyMatching`/SecurityServer decrypt. The recovery process retained the lifecycle lock. No DB, launchd, BTM, process, or Keychain mutation was performed. This is an explicit credential/platform blocker; no Start/Off/retry followed.
- Full regression was attempted after the correction but was contaminated by the blocked recovery process holding the lifecycle lock; the prior clean baseline remains 212 executed, 14 skipped, 0 failures. The contaminated run failed dispatcher lifecycle tests with `lifecycle lock is already held`.
## Final read-only verification — 2026-09-21

No lifecycle mutation was performed during this verification.

- Installed product: `/Applications/Vaelen.app`
- App SHA-256: `1fff5863be7e1410fd918c3fb5e2e9daccb07aa19346f9dcdda4d13f870aebc2`
- Embedded daemon SHA-256: `86c7dd3799c6df699142d044c4d1cab311bd35aea4c754389ef6c54d2a6dc857`
- App identifier/team: `dev.vaelen.app` / `TFKZJV643G`
- Daemon identifier/team: `vaelend` / `TFKZJV643G`
- `codesign --verify --deep --strict /Applications/Vaelen.app`: passed.
- LaunchAgent `dev.vaelen.vaelend` is running under `gui/501`; PID 37834, UID 501,
  `Contents/Resources/vaelend`; canonical socket is present.
- Final accepted lifecycle correlations:
  - Start generation 3: `A9F98B46-0889-408C-9EF8-FBC015F92E4B`, succeeded,
    readiness/endpoint/typed IPC confirmed.
  - Off generation 4: `51C90CB8-CD58-4D52-AB66-29E9A5E3F06F`, succeeded after
    fresh absence recovery; unregister was not replayed, ownership cleared.
  - Start generation 5: `9DE03934-62CC-4948-B9C1-69C2C362D9EF`, succeeded,
    readiness/endpoint/typed IPC confirmed.
- Durable final state: intent `on`, generation 5, register `succeeded`, ownership
  generation 5 with Team `TFKZJV643G` and daemon hash above. No unresolved rows.
- Preservation counts: projects `3`; route intents `1`; route transitions `0`;
  TLS rows `1`; system modifications `1`. The TLS row was pre-existing and was
  not changed or removed.
- Full regression after implementation: `218` passed, `14` skipped, `0` failed.
- No Keychain/security prompt records mentioning Vaelen or `vaelend` appeared in
  the read-only 30-minute unified-log inspection. No Keychain mutation was made.
- Syncproof was not accessed or mutated; no Syncproof integration test was run.
- No commit, tag, push, or freeze was performed.

## M14 final acceptance reconciliation — 2026-09-21

- Bane accepted M14 and explicitly authorized this final evidence reconciliation,
  safe housekeeping, commit, the established M14 tag, and push of the branch and
  tag. No lifecycle operation was performed during finalization.
- Read-only SQLite verification of the preserved state confirms: 3 projects, 1
  route intent, 0 route transitions, 1 TLS capability row, and 1 system
  modification. The TLS row and its fingerprint/path were already present in the
  pre-M14 preservation evidence and are unchanged; no TLS or Syncproof mutation
  occurred.
- Final lifecycle evidence remains the accepted sequence: Start generation 3,
  Off generation 4, and Start generation 5. The final durable intent is `on`,
  generation 5; register operation and ownership both succeeded, with no
  unresolved lifecycle rows.
- Final accepted artifact evidence remains the installed `/Applications/Vaelen.app`
  and its embedded `vaelend`: app SHA-256
  `1fff5863be7e1410fd918c3fb5e2e9daccb07aa19346f9dcdda4d13f870aebc2`, daemon
  SHA-256 `86c7dd3799c6df699142d044c4d1cab311bd35aea4c754389ef6c54d2a6dc857`,
  identifiers `dev.vaelen.app`/`vaelend`, TeamIdentifier `TFKZJV643G`, and deep
  strict code-sign verification passed.
- Regression evidence is unchanged: 218 passed, 14 skipped, 0 failed. No
  regression rerun was required because finalization changed only evidence and
  housekeeping, not source. Syncproof was untouched and no Syncproof test ran.
- Repository/build identity is product version `0.0.14-dev`, build identity
  `m14-core-daemon-lifecycle-schema-7`; SQLite `PRAGMA user_version` is 13,
  IPC protocol version is 1, and IPC schema compatibility version is 5.
- Finalization is freeze-ready on the evidence recorded here under Bane's
  acceptance, but this entry does not independently freeze M14 or authorize M15.
