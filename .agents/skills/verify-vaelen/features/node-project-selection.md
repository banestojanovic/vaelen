# Choose project Node

The first Node slice stores exact pins by linked `ProjectID`, installs reviewed official arm64 packages, and applies pins through explicit `val node exec -- COMMAND...`.

## Run focused checks

Build the current worktree CLI and run the focused suites through `Scripts/test.sh`.

```bash
swift build --product val --skip-update --disable-automatic-resolution
VAELEN_VAL_EXECUTABLE="$PWD/.build/debug/val" Scripts/test.sh --filter 'NodeSelectionTests|NodePackagesTests|NodeIPCTests|NodeCommandTests|DispatcherTests.testNodeInstallShutdownWaitsForStagingCleanup'
```

`NodeCommandTests` launches the real CLI with controlled PATH Node stand-ins. The child has no Core socket. It verifies exact arguments, empty arguments, cwd, stdin, stdout, stderr, and exit status. Missing selected packages and a colon-containing managed support path fail safely without invoking the invocation PATH stand-in. Clearing a pin restores the original PATH choice. The colon-path check installs the official archive before exercising the actual CLI.

`DispatcherTests.testNodeInstallShutdownWaitsForStagingCleanup` pauses archive acquisition and confirms shutdown stays pending until the install returns and its temporary stage is removed.

`NodeSelectionTests` verifies exact stable versions, schema 7 migration preservation, independent pins, missing projects, symlink aliases, path component boundaries, nested unpinned linked roots, and strictly read-only state errors. `NodePackagesTests` uses explicit internal fixtures to test the contained ustar extractor and owned package publication. `NodeIPCTests` exercises distinct Node envelopes alongside PHP and Core listing and clearing of unavailable projects.

## Check real official archives

Obtain the two arm64 archives listed in [Node release provenance](../../../../docs/node-release-provenance.md). Cache them in a disposable directory. The test verifies the pinned signed-manifest digests before extraction, installs only under a temporary root, probes the real binaries, and removes that root.

```bash
VAELEN_NODE_ARCHIVE_DIRECTORY=/absolute/path/to/disposable/archive-cache VAELEN_VAL_EXECUTABLE="$PWD/.build/debug/val" Scripts/test.sh --filter 'NodeSelectionTests|NodePackagesTests|NodeIPCTests|NodeCommandTests|DispatcherTests.testNodeInstallShutdownWaitsForStagingCleanup'
```

Record the selected and passed counts. The official archive test skips when the cache variable is absent. The real CLI child test skips when the CLI variable is absent. Report skips explicitly.

## Check the Core CLI flow

Use a private Core socket and a temporary support root. Link two temporary projects and a nested linked project. Install an exact reviewed release without selecting it. Select that release for one project. Run `val node exec -- node --version` and `val node exec -- npm --version` in each project. Verify that the second and nested unpinned project keep their invocation PATH choice. Remove the selected package temporarily and require an error without fallback. Clear the pin by project ID after removing the project directory, then confirm the missing project remains listed with no pin.

Keep the support root, socket, package downloads, and projects separate from the user's default support directory and existing projects. Record process cleanup and retained evidence.

## Check ordinary shell `node` and `npm`

Cache the reviewed Node 24.22.1 macOS arm64 archive in a disposable directory, build `val`, then run the integration and shell suites:

```bash
swift build --product val --skip-update --disable-automatic-resolution
VAELEN_NODE_ARCHIVE_DIRECTORY=/absolute/path/to/disposable/archive-cache \
  VAELEN_VAL_EXECUTABLE="$PWD/.build/debug/val" \
  Scripts/test.sh --filter 'NodeCLIIntegrationTests|PHPShellIntegrationTests'
```

`NodeCLIIntegrationTests` starts a private Core and links temporary projects. It installs the reviewed archive only under its temporary support root, invokes the production zsh shell block with a copied `val` helper and isolated `HOME`, then checks `node --version` and `npm --version` in a pinned project and an unpinned project. The pinned project must report Node 24.22.1 and npm 11.19.1; the unpinned project must report the controlled invocation-PATH stand-ins. The real user's `.zshrc`, support directory, and projects are not used.

## Native Projects Settings UI

The Projects page has a per-linked-project Node selector. It shows an exact pin, inherited invocation PATH, or an unavailable pinned package. Its choices come only from the reviewed releases returned by Core. An uninstalled choice must finish installing before Core applies the project pin. Clearing the pin uses the Node `useDefault` action. The selector identifies projects by UUID, with the project path used only when the legacy project record has no ID. Package install and pin changes share the app's relationship mutation lock.

Build and launch an isolated visible-state fixture on macOS with the same harness used for the PHP Settings UI. Use one of `node-settings-selected`, `node-settings-unpinned`, or `node-settings-unavailable` and select **Projects**. For example:

```bash
EVIDENCE="artifacts/verification/vaelen-node-settings-$(date -u +%Y%m%dT%H%M%SZ)"
VAELEN_SETTINGS_FIXTURE=node-settings-unavailable VAELEN_SETTINGS_PAGE=projects \
  .agents/skills/verify-vaelen-app/scripts/launch-fixture.sh "$EVIDENCE"
.agents/skills/verify-vaelen-app/scripts/doctor-fixture.sh "$EVIDENCE"
```

Use CUA to verify the visible **Project Node** state and fixture marker. Do not invoke a fixture mutation. The fixture proves presentation only. It does not exercise Core IPC, package installation, or persistence. Record a separate live Core run for those behaviors.

## Coverage limits

Ordinary shell `node` and `npm` are routed through the selected project's Node runtime after the user opts into `val shell install`. The shell integration tests verify argument, output, and exit-status forwarding through a controlled helper; pair them with `NodeCommandTests` for the real CLI resolver path. x64 installation is unsupported by this catalog. UI acceptance and the full Core CLI selection flow require separate recorded runs. Tests of in-memory dispatcher calls do not prove those interactions.
