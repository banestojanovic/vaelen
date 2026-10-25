# Clean-checkout test suite reliability

## Phase A: Frame

- [x] Read the Principles section of the poteto-mode skill.
- [x] State a falsifiable definition of done.
- [x] Quantify the work and record blockers.

Definition of done: `Scripts/test.sh` passes from a clean isolated worktree with no PHP provider artifacts and no catalog refresh. Default test paths cannot fetch Vaelen package artifacts or install into user Vaelen support directories. Tests requiring real provider bytes or system services use explicit acceptance flags or skip before side effects. SwiftPM dependencies must already be available: the wrapper disables automatic version resolution, but that flag alone is not proof that a missing dependency checkout cannot be fetched. Test source paths are audited for non-loopback network access; this environment does not provide an OS-level egress block, so the audit does not claim a network-denied run. The run identifies all skips and checks shared app, project, and provider-cache state before and after.

Scope: five units, several bounded test and harness changes, then one clean-checkout full-suite run and one independent review. The first baseline blocker was a discovery test reading ignored bundled PHP executables from a SwiftPM test resource bundle where those binaries are absent. Audit also found Caddy helpers that implicitly installed into shared app support and MySQL lifecycle tests that assumed installed packages. `sandbox-exec` is unavailable here, so source review can establish that default test network paths are local or mocked, but this run cannot prove OS-level egress denial. The wrapper disables automatic SwiftPM version resolution; required dependency checkouts must already be available for a fully network-independent build.

## Phase B: Design the workflow

- [x] Capture the failing baseline before changes.
- [x] Use a clean task worktree at current `dev` and preserve canonical checkout dirt.
- [x] Make the PHP discovery behavior test use local, controlled artifacts.
- [x] Move provider-byte acceptance tests behind explicit artifacts and opt-in execution.
- [x] Audit tests for shared package, app, project, cache, network, and service state; move real PHP, Caddy, and MySQL acceptance slices behind opt-in flags or use local fixtures.
- [x] Run the standard test command from the isolated worktree without provider caches or refresh (first run found one remaining installed-PHP assumption; replaced it with a local executable fixture and reran successfully).
- [x] Record counts, skips, commands, and evidence. The focused PHP update verification map now describes the acceptance gates.
- [x] Obtain one independent read-only review and resolve findings.

## Phase C: Run the loop

- [x] Unit 1. Capture the baseline with the provider cache absent.
- [x] Unit 2. Replace the hidden prerequisite in the PHP discovery test and rerun it.
- [x] Unit 3. Separate genuine provider artifact acceptance from normal local tests.
- [x] Unit 4. Verify test state is confined to each worktree and private fixture root.
- [x] Unit 5. Run the full standard suite from a clean checkout with no provider cache or refresh.

## Phase D: Keep the audit trail

- [x] Append decisions and evidence to `.audit/hermetic-test-suite.tsv`.

## Phase E: Verify and hand back

- [x] Audit the run against the definition of done and report verified limits. One fresh read-only Sol review found and closed the last Caddy package prerequisite; review also corrected the SwiftPM/network scope statement.
