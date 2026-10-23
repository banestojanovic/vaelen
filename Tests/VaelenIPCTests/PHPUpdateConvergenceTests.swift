import CryptoKit
import Foundation
import XCTest
import VaelenTestSupport
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

private struct FPMIdentity {
    let version: String
    let pid: Int32
    let startedAt: String
}

/// Update convergence through the real dispatcher/IPC path.
///
/// These use a genuine same-family update pair (a real older patch and a real
/// newer patch from the provider's verified cache), so update behaviour is
/// exercised against real PHP rather than a stand-in. All state is isolated
/// beneath a unique temporary root; no live package, default, project,
/// configuration or service is touched.
@MainActor
final class PHPUpdateConvergenceTests: XCTestCase {
    /// An older patch and its real successor in the same minor line.
    private var sourceVersion = "8.4.23"
    private var targetVersion = "8.4.24"
    private var acceptanceArtifactDirectory: URL?
    private var fpmVersionsToCheck = Set<String>()
    private var fpmIdentitiesToCheck = [FPMIdentity]()

    private var root: URL!
    private var layout: VaelenFilesystemLayout!
    private var dispatcher: CoreRequestDispatcher!
    private var serviceIntents: ServiceIntentStore!
    private var module: PHPModule!
    private var registry: ProjectRegistry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let isRealAcceptance = (name ?? "").contains("testRealPHP8424To8427Acceptance")
        let cache = ProviderArtifactCache.shared
        guard isRealAcceptance || ((try? cache.artifacts(version: sourceVersion)) != nil && (try? cache.artifacts(version: targetVersion)) != nil) else {
            throw XCTSkip("The verified provider cache needs PHP \(sourceVersion) and \(targetVersion). Run ./Scripts/refresh-php-catalog-from-provider.sh first.")
        }
        if isRealAcceptance {
            guard let path = ProcessInfo.processInfo.environment["VAELEN_PHP_ACCEPTANCE_ARTIFACT_DIR"], !path.isEmpty else {
                throw XCTSkip("Set VAELEN_PHP_ACCEPTANCE_ARTIFACT_DIR to a private directory containing the four exact PHP 8.4.24 and 8.4.27 provider archives.")
            }
            acceptanceArtifactDirectory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        root = URL(fileURLWithPath: "/private/var/tmp/vaelen-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true), logsDirectoryURL: root.appendingPathComponent("logs", isDirectory: true))
        try FileManager.default.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Never remove a temporary root that still has a live PHP-FPM under it.
        var liveChildren: [String] = []
        if let module {
            let installed = Set(module.installedVersions().map(\.version))
            for version in fpmVersionsToCheck.union(installed) {
                let record = layout.phpInstancesDirectoryURL.appendingPathComponent(version).appendingPathComponent("process.json")
                guard FileManager.default.fileExists(atPath: record.path) else { continue }
                if installed.contains(version) { _ = try? module.stop(requestedVersion: version) }
                if FileManager.default.fileExists(atPath: record.path) { liveChildren.append(version) }
            }
        }
        for identity in fpmIdentitiesToCheck where Self.processIdentityIsLive(identity) {
            liveChildren.append("\(identity.version) (PID \(identity.pid))")
        }
        module = nil
        dispatcher = nil
        registry = nil
        if !liveChildren.isEmpty {
            XCTFail("Isolated PHP-FPM did not shut down for \(liveChildren.joined(separator: ", ")); preserving \(root.path).")
        } else if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Update reports a real outcome

    func testRealPHP8424To8427Acceptance() async throws {
        sourceVersion = "8.4.24"
        targetVersion = "8.4.27"
        let artifactDirectory = try XCTUnwrap(acceptanceArtifactDirectory)
        let manifests = try [sourceVersion, targetVersion].map { version -> PHPManifest in
            let digests = try Self.acceptanceDigests(version: version, directory: artifactDirectory)
            return PHPManifest(
                schemaVersion: 1, module: "php", phpVersion: version, platform: "macos", architecture: "arm64",
                build: .init(requiredExtensions: PHPPackageProvider.requiredExtensions, optionalExtensions: PHPPackageProvider.optionalExtensions, notices: []),
                artifacts: Dictionary(uniqueKeysWithValues: ["cli", "fpm"].map { kind in
                    (kind, PHPArtifact(file: PHPPackageProvider.artifactFile(version: version, kind: kind), url: PHPPackageProvider.artifactURL(version: version, kind: kind), sha256: digests[kind]!))
                }),
                verification: .init(algorithm: "sha256", authenticity: PHPPackageProvider.authenticity, digestPinnedByReview: true),
                release: .init(tag: PHPPackageProvider.channel, url: PHPPackageProvider.baseURL)
            )
        }
        _ = try makeModule(manifests: manifests, artifactBase: artifactDirectory)
        let module = self.module!
        _ = try await install(sourceVersion)
        XCTAssertEqual(try module.exec(requestedVersion: sourceVersion, workingDirectory: root.path, arguments: ["-r", "echo PHP_VERSION;"]).output.trimmingCharacters(in: .whitespacesAndNewlines), sourceVersion)
        _ = try await selectDefault(sourceVersion)
        let settings = PHPManagedSettings(uploadLimitMB: 24, memoryLimitMB: 640, maxExecutionTimeSeconds: 120, maxInputVariables: 4_000, postLimitMB: 32)
        _ = try module.updateConfiguration(version: sourceVersion, settings: settings)
        let project = try await linkProject(named: "pinned-acceptance", phpOverride: sourceVersion)

        let refusal = await dispatcher.dispatch(IPCRequest(method: .phpUpdate, params: .phpVersion(PHPVersionRequest(version: targetVersion, sourceVersion: sourceVersion))), handshaken: true)
        let refusalMessage = try XCTUnwrap(refusal.response.error?.message)
        XCTAssertTrue(refusalMessage.contains("pinned-acceptance"), refusalMessage)
        XCTAssertTrue(refusalMessage.contains(sourceVersion), refusalMessage)
        XCTAssertFalse(module.installedVersions().map(\.version).contains(targetVersion))
        XCTAssertEqual(module.defaultVersion(), sourceVersion)
        XCTAssertEqual(try module.status(requestedVersion: sourceVersion).state, .running)
        let pinnedVersion = try await registry.phpOverride(for: project)
        XCTAssertEqual(pinnedVersion, sourceVersion)

        try await registry.setPHPOverride(nil, for: project)
        let sourceRecord = try Self.fpmIdentity(version: sourceVersion, layout: layout)
        fpmIdentitiesToCheck.append(sourceRecord)
        let result = try await update(version: targetVersion, sourceVersion: sourceVersion)
        XCTAssertEqual(result.replacedVersion, sourceVersion)
        XCTAssertNil(result.convergenceError)
        XCTAssertTrue(result.wasDefault)
        XCTAssertTrue(result.isDefault)
        XCTAssertTrue(result.isRunning)
        XCTAssertTrue(result.convergence.contains("cleanup"))
        XCTAssertEqual(module.defaultVersion(), targetVersion)
        XCTAssertFalse(module.installedVersions().map(\.version).contains(sourceVersion))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpPackagesDirectoryURL.appendingPathComponent(sourceVersion).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpInstancesDirectoryURL.appendingPathComponent(sourceVersion).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpInstancesDirectoryURL.appendingPathComponent(sourceVersion).appendingPathComponent("process.json").path))
        XCTAssertFalse(Self.processIdentityIsLive(sourceRecord), "The exact source FPM master captured before update must have exited.")
        XCTAssertEqual(try module.status(requestedVersion: targetVersion).state, .running)
        XCTAssertEqual(try module.exec(requestedVersion: targetVersion, workingDirectory: root.path, arguments: ["-r", "echo PHP_VERSION;"]).output.trimmingCharacters(in: .whitespacesAndNewlines), targetVersion)
        XCTAssertEqual(try module.configuration().versions.first { $0.version == targetVersion }?.settings, settings)
        XCTAssertTrue(try serviceIntents.enabledServices().contains("php:\(targetVersion)"))
        XCTAssertFalse(try serviceIntents.enabledServices().contains("php:\(sourceVersion)"))
    }

    /// Updating a running default must leave the replacement healthy, running and
    /// default, with the replacement owning the saved start intent.
    func testUpdatingRunningDefaultLeavesReplacementHealthyAndDefault() async throws {
        _ = try makeModule()
        let module = self.module!
        _ = try await install(sourceVersion)
        _ = try await selectDefault(sourceVersion)
        XCTAssertEqual(try module.status(requestedVersion: sourceVersion).state, PHPFPMState.running)

        let result = try await update(version: targetVersion, sourceVersion: sourceVersion)
        XCTAssertEqual(result.replacedVersion, sourceVersion)
        XCTAssertTrue(result.wasDefault, "The replaced runtime was the default.")
        XCTAssertTrue(result.isRunning, "Updating the running default must leave the replacement running.")
        XCTAssertTrue(result.isDefault, "Updating the running default must leave the replacement as default.")
        XCTAssertNil(result.convergenceError)
        XCTAssertTrue(result.convergence.contains("running"))
        XCTAssertTrue(result.convergence.contains("default"))
        XCTAssertTrue(result.convergence.contains("cleanup"), "A fully successful update removes the superseded package.")
        XCTAssertEqual(module.defaultVersion(), targetVersion)
        XCTAssertEqual(try module.status(requestedVersion: targetVersion).state, PHPFPMState.running)
        // The replacement owns the saved start intent; the removed runtime does not.
        let enabled = try serviceIntents.enabledServices()
        XCTAssertTrue(enabled.contains("php:\(targetVersion)"))
        XCTAssertFalse(enabled.contains("php:\(sourceVersion)"), "The removed superseded runtime must not keep a start intent.")
        // Nothing is kept solely for rollback: the package, its generated
        // instance artifacts, and its socket are gone.
        XCTAssertFalse(module.installedVersions().map(\.version).contains(sourceVersion))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpPackagesDirectoryURL.appendingPathComponent(sourceVersion).path),
                       "The superseded package directory must be removed.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpInstancesDirectoryURL.appendingPathComponent(sourceVersion).path),
                       "The superseded runtime's generated instance artifacts must be removed.")
        // The interface stays serviceable.
        let status = await dispatcher.dispatch(IPCRequest(method: .phpStatus, params: .phpVersion(PHPVersionRequest(version: targetVersion))), handshaken: true)
        XCTAssertNil(status.response.error)
    }

    /// Updating a stopped, non-default runtime must not start it and must not
    /// change the global default.
    func testUpdatingStoppedNonDefaultRuntimeStartsNothingAndKeepsDefault() async throws {
        _ = try makeModule()
        let module = self.module!
        _ = try await install(sourceVersion)
        // A different runtime owns the default role.
        let otherManifest = try ProviderArtifactCache.shared.manifest(version: "8.3.33")
        try seedPackage(manifest: otherManifest)
        _ = try await selectDefault("8.3.33")
        XCTAssertEqual(module.defaultVersion(), "8.3.33")
        XCTAssertEqual(try module.status(requestedVersion: sourceVersion).state, PHPFPMState.stopped)

        let result = try await update(version: targetVersion, sourceVersion: sourceVersion)
        XCTAssertEqual(result.replacedVersion, sourceVersion)
        XCTAssertFalse(result.wasDefault)
        XCTAssertFalse(result.isRunning, "Updating a stopped non-default runtime must not start it.")
        XCTAssertEqual(module.defaultVersion(), "8.3.33", "The global default must not change.")
        XCTAssertEqual(result.convergence, ["cleanup"], "Only replacement cleanup runs for a stopped non-default update.")
        XCTAssertNil(result.convergenceError)
        // The superseded runtime is removed even though it never ran here.
        XCTAssertFalse(module.installedVersions().map(\.version).contains(sourceVersion))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpPackagesDirectoryURL.appendingPathComponent(sourceVersion).path))
    }

    /// The replaced runtime's saved settings follow the replacement.
    func testUpdateCarriesSavedSettingsToTheReplacement() async throws {
        _ = try makeModule()
        let module = self.module!
        _ = try await install(sourceVersion)
        let settings = PHPManagedSettings(uploadLimitMB: 24, memoryLimitMB: 640, maxExecutionTimeSeconds: 120, maxInputVariables: 4_000, postLimitMB: 32)
        _ = try module.updateConfiguration(version: sourceVersion, settings: settings)
        XCTAssertEqual(try module.configuration().versions.first { $0.version == sourceVersion }?.settings, settings)

        let result = try await update(version: targetVersion, sourceVersion: sourceVersion)
        XCTAssertNil(result.convergenceError)
        let carried = try XCTUnwrap(module.configuration().versions.first { $0.version == targetVersion })
        XCTAssertEqual(carried.settings, settings, "Saved settings must survive the update and follow the replacement.")
        XCTAssertEqual(carried.inheritsDefault, false, "The carried settings remain a per-version override.")
        // Replacement happened, so the source is gone — while the replacement's
        // saved settings are intact.
        XCTAssertFalse(module.installedVersions().map(\.version).contains(sourceVersion))
        XCTAssertTrue(result.convergence.contains("cleanup"))
    }

    /// When several patches of a line coexist, an update names the runtime being
    /// replaced, and only that runtime's settings are carried over.
    func testNamedSourceRuntimeDecidesWhichSettingsAreCarriedOver() async throws {
        _ = try makeModule()
        let module = self.module!
        _ = try await install(sourceVersion)
        // Another installed patch in the same line with its own saved settings.
        let otherManifest = try ProviderArtifactCache.shared.manifest(version: "8.4.23")
        try seedPackage(manifest: otherManifest)
        let sourceSettings = PHPManagedSettings(uploadLimitMB: 6, memoryLimitMB: 192, maxExecutionTimeSeconds: 30, maxInputVariables: 300, postLimitMB: 10)
        let otherSettings = PHPManagedSettings(uploadLimitMB: 48, memoryLimitMB: 1024, maxExecutionTimeSeconds: 200, maxInputVariables: 8_000, postLimitMB: 64)
        _ = try module.updateConfiguration(version: sourceVersion, settings: sourceSettings)
        _ = try module.updateConfiguration(version: "8.4.23", settings: otherSettings)

        // Update 8.4.22 -> 8.4.23, naming 8.4.22 as the source.
        let result = try await update(version: targetVersion, sourceVersion: sourceVersion)
        XCTAssertEqual(result.replacedVersion, sourceVersion, "The named source runtime must be the one reported as replaced.")
        // The target already had its own override, so the other patch's settings
        // must not have overwritten it.
        XCTAssertEqual(try module.configuration().versions.first { $0.version == targetVersion }?.settings, otherSettings,
                       "Settings must come from the named source, never from another installed patch.")
        XCTAssertFalse(module.installedVersions().map(\.version).contains(sourceVersion),
                       "The named source is removed once replaced.")
    }

    /// An update whose source is still required by an explicit project pin is
    /// refused before anything mutates, naming the affected projects. Pins are
    /// never silently migrated and the pinned runtime is never removed.
    func testPinnedSourceRefusesUpdateAndNamesProjects() async throws {
        _ = try makeModule()
        _ = try await install(sourceVersion)
        _ = try await selectDefault(sourceVersion)

        _ = try await linkProject(named: "inherited-app", phpOverride: nil)
        let pinned = try await linkProject(named: "pinned-app", phpOverride: sourceVersion)

        let response = await dispatcher.dispatch(IPCRequest(method: .phpUpdate, params: .phpVersion(PHPVersionRequest(version: targetVersion, sourceVersion: sourceVersion))), handshaken: true)
        let payload = try XCTUnwrap(response.response.error)
        XCTAssertTrue(payload.message.contains("pinned-app"), "The refusal must name the affected project: \(payload.message)")
        XCTAssertTrue(payload.message.contains(sourceVersion), "The refusal must name the required runtime: \(payload.message)")
        // Nothing mutated: no target installed, the source still default and
        // running, the pin intact.
        XCTAssertFalse(module.installedVersions().map(\.version).contains(targetVersion))
        XCTAssertEqual(module.defaultVersion(), sourceVersion)
        XCTAssertEqual(try module.status(requestedVersion: sourceVersion).state, PHPFPMState.running)
        let pinnedAfter = try await registry.phpOverride(for: pinned)
        XCTAssertEqual(pinnedAfter, sourceVersion)
    }

    /// An inherited project stays inherited across an update that removes the
    /// source it used to resolve to.
    func testInheritedProjectStaysInheritedAcrossReplacement() async throws {
        _ = try makeModule()
        _ = try await install(sourceVersion)
        _ = try await selectDefault(sourceVersion)

        let inherited = try await linkProject(named: "inherited-app", phpOverride: nil)

        let result = try await update(version: targetVersion, sourceVersion: sourceVersion)
        XCTAssertNil(result.convergenceError)
        let inheritedAfter = try await registry.phpOverride(for: inherited)
        XCTAssertNil(inheritedAfter, "An inherited project must stay inherited.")
        XCTAssertEqual(module.defaultVersion(), targetVersion)
        XCTAssertFalse(module.installedVersions().map(\.version).contains(sourceVersion))
    }

    /// When route convergence cannot complete after a successful install, the
    /// result is reported as partial success rather than a bare completion.
    func testPartialSuccessIsReportedWhenRouteConvergenceFails() async throws {
        // The router accepts an apply but never reports a route back, so any
        // inherited FastCGI target cannot be verified as converged.
        _ = try makeModule(router: UnverifiableRouter(), loadRoutes: false)
        let module = self.module!
        _ = try await install(sourceVersion)
        _ = try await selectDefault(sourceVersion)
        // An inherited project with a real route, so convergence has work to do.
        let project = try await linkProject(named: "inherited-app", phpOverride: nil)
        try persistRouteIntent(for: project, hostname: "inherited-app.test", version: sourceVersion)
        // Reload Core so it holds the pending route before the update runs.
        _ = try makeModule(router: UnverifiableRouter())

        let result = try await update(version: targetVersion, sourceVersion: sourceVersion)
        // Installation succeeded...
        XCTAssertTrue(module.installedVersions().map(\.version).contains(targetVersion))
        XCTAssertTrue(result.isDefault)
        // ...and the incomplete convergence is reported rather than hidden.
        XCTAssertNotNil(result.convergenceError, "A convergence failure must be reported, not presented as a finished update.")
        XCTAssertFalse(result.convergence.contains("routes"), "Routes must not be reported as converged when they were not.")
        // Cleanup never runs while convergence is incomplete: the working
        // source is preserved for recovery, not half-removed. The default
        // handover already happened, so the default names the replacement.
        XCTAssertFalse(result.convergence.contains("cleanup"))
        XCTAssertTrue(module.installedVersions().map(\.version).contains(sourceVersion),
                      "A failed convergence must preserve the working source.")
        XCTAssertEqual(module.defaultVersion(), targetVersion)
        // The interface remains responsive and the state inspectable.
        let catalog = await dispatcher.dispatch(IPCRequest(method: .phpCatalogSnapshot), handshaken: true)
        XCTAssertNil(catalog.response.error)
    }

    /// Long work must stay off the dispatcher executor: status, operation state
    /// and Quit remain serviceable while an update runs.
    func testDispatcherStaysResponsiveDuringAnUpdate() async throws {
        // Capture everything the assertions need before starting any concurrency,
        // so no test state crosses into the concurrent region.
        let dispatcher = try makeModule()
        _ = try await install(sourceVersion)
        _ = try await selectDefault(sourceVersion)

        let updateTask = Task { @MainActor in
            await Self.performUpdate(dispatcher: dispatcher, version: targetVersion, source: sourceVersion)
        }
        defer { updateTask.cancel() }
        for _ in 0..<5 {
            let operation = await dispatcher.dispatch(IPCRequest(method: .phpOperation), handshaken: true)
            XCTAssertNil(operation.response.error, "Operation state must stay serviceable during an update.")
            let status = await dispatcher.dispatch(IPCRequest(method: .phpStatus, params: .phpVersion(PHPVersionRequest(version: sourceVersion))), handshaken: true)
            XCTAssertNil(status.response.error, "Status must stay serviceable during an update.")
            // Navigation-relevant reads stay answerable too.
            let catalog = await dispatcher.dispatch(IPCRequest(method: .phpCatalogSnapshot), handshaken: true)
            XCTAssertNil(catalog.response.error, "Navigation must stay serviceable during an update.")
        }
        _ = await updateTask.value
    }

    /// After a successful update nothing requires the superseded runtime, so its
    /// start intent is retired and its package is removed.
    func testSupersededRuntimeIsFullyRetired() async throws {
        _ = try makeModule()
        _ = try await install(sourceVersion)
        _ = try await selectDefault(sourceVersion)

        let result = try await update(version: targetVersion, sourceVersion: sourceVersion)
        XCTAssertEqual(result.replacedVersion, sourceVersion)
        XCTAssertNil(result.convergenceError)
        let enabled = try serviceIntents.enabledServices()
        XCTAssertFalse(enabled.contains("php:\(sourceVersion)"),
                       "Nothing requires the superseded runtime, so its start intent is cleared.")
        XCTAssertTrue(enabled.contains("php:\(targetVersion)"))
        XCTAssertFalse(module.installedVersions().map(\.version).contains(sourceVersion))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpPackagesDirectoryURL.appendingPathComponent(sourceVersion).path))
        // Simulate a restart: the retired intent stays off.
        let persisted = try String(contentsOf: layout.stateDirectoryURL.appendingPathComponent("service-intents.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("\"php:\(sourceVersion)\":true"), "The retired start intent must persist as off.")
    }

    /// An orphaned route still dialling the source blocks the update, naming
    /// the hostname. Convergence cannot move a route no project owns, so
    /// removing the runtime would strand it.
    func testOrphanRouteRefusesUpdateAndNamesHostname() async throws {
        _ = try makeModule(router: InMemoryRouter(), loadRoutes: false)
        _ = try await install(sourceVersion)
        _ = try await selectDefault(sourceVersion)
        // An orphaned intent: no owning project, dialling the source socket.
        let repository = RouteIntentRepository(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        let orphan = Route(hostname: "orphan.test", target: .fastCGI(
            socketPath: layout.rootURL.appendingPathComponent("runtime/sockets/php/php-\(sourceVersion).sock").path,
            documentRoot: root.appendingPathComponent("projects/orphan").path))
        try repository.upsert(RouteIntent(route: orphan))
        // Reload Core so it holds the orphan intent before the update runs.
        _ = try makeModule(router: InMemoryRouter())

        let response = await dispatcher.dispatch(IPCRequest(method: .phpUpdate, params: .phpVersion(PHPVersionRequest(version: targetVersion, sourceVersion: sourceVersion))), handshaken: true)
        let payload = try XCTUnwrap(response.response.error)
        XCTAssertTrue(payload.message.contains("orphan.test"), "The refusal must name the stranded hostname: \(payload.message)")
        XCTAssertTrue(payload.message.contains(sourceVersion), "The refusal must name the required runtime: \(payload.message)")
        // Nothing mutated.
        XCTAssertFalse(module.installedVersions().map(\.version).contains(targetVersion))
        XCTAssertEqual(module.defaultVersion(), sourceVersion)
        XCTAssertTrue(module.installedVersions().map(\.version).contains(sourceVersion))
    }

    /// When cleanup itself fails, the working source is preserved and the
    /// specific cleanup failure is reported — never complete success.
    func testCleanupFailurePreservesSourceAndReportsSpecifically() async throws {
        _ = try makeModule()
        _ = try await install(sourceVersion)
        // Make the package directory undeletable so removal fails deterministically.
        let packageDir = layout.phpPackagesDirectoryURL.appendingPathComponent(sourceVersion)
        let lock = packageDir.appendingPathComponent("php")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: lock.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: lock.path) }

        let result = try await update(version: targetVersion, sourceVersion: sourceVersion)
        // The target installed fine...
        XCTAssertTrue(module.installedVersions().map(\.version).contains(targetVersion))
        // ...but cleanup failed, so the outcome is partial and specific.
        guard let failure = result.convergenceError else {
            return XCTFail("A failed cleanup must be reported, not presented as a finished update.")
        }
        XCTAssertTrue(failure.contains("cleanup"), "The failure must name cleanup as the incomplete step: \(failure)")
        XCTAssertFalse(result.convergence.contains("cleanup"))
        // The working source is preserved, not half-removed.
        XCTAssertTrue(module.installedVersions().map(\.version).contains(sourceVersion))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageDir.path))
    }

    /// An explicitly named source that cannot serve as an update source is rejected
    /// with a specific reason, and no other runtime is touched.
    func testInvalidUpdateSourceIsRejectedWithoutTouchingAnotherRuntime() async throws {
        _ = try makeModule()
        _ = try await install(sourceVersion)
        let other = try ProviderArtifactCache.shared.manifest(version: "8.3.33")
        try seedPackage(manifest: other)

        let response = await dispatcher.dispatch(IPCRequest(method: .phpUpdate, params: .phpVersion(PHPVersionRequest(version: targetVersion, sourceVersion: other.phpVersion))), handshaken: true)
        let payload = try XCTUnwrap(response.response.error)
        XCTAssertTrue(payload.message.contains("not an earlier patch"),
                      "The rejection must name the actual problem: \(payload.message)")
        // Nothing was installed for the target, and the wrong runtime is untouched.
        XCTAssertFalse(module.installedVersions().map(\.version).contains(targetVersion))
        XCTAssertTrue(module.installedVersions().map(\.version).contains(sourceVersion))
        XCTAssertTrue(module.installedVersions().map(\.version).contains(other.phpVersion))
    }

    // MARK: - Support

    @discardableResult
    private func makeModule(router: any Router = InMemoryRouter(), loadRoutes: Bool = true, manifests suppliedManifests: [PHPManifest]? = nil, artifactBase suppliedArtifactBase: URL? = nil) throws -> CoreRequestDispatcher {
        let cache = ProviderArtifactCache.shared
        let manifests = try (suppliedManifests ?? [cache.manifest(version: sourceVersion), cache.manifest(version: targetVersion)])
        let location = PHPProviderManifestLocation(
            box: .init(PHPManifestCatalog(manifests: manifests)),
            stateDirectory: layout.stateDirectoryURL,
            artifactBase: try (suppliedArtifactBase ?? cache.flatDirectory())
        )
        let module = PHPModule(layout: layout, location: location, includesBundledCatalog: false)
        self.module = module
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let registry = ProjectRegistry(store: store)
        self.registry = registry
        let intents = ServiceIntentStore(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json"))
        serviceIntents = intents
        let repository = loadRoutes ? RouteIntentRepository(store: store) : nil
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test", pid: 1),
            registry: registry, php: module, router: router,
            routeRepository: repository, serviceIntents: intents
        )
        self.dispatcher = dispatcher
        return dispatcher
    }

    private static func acceptanceDigests(version: String, directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for kind in ["cli", "fpm"] {
            let filename = PHPPackageProvider.artifactFile(version: version, kind: kind)
            let archive = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: archive.path) else {
                throw XCTSkip("Missing required provider artifact \(filename) in VAELEN_PHP_ACCEPTANCE_ARTIFACT_DIR.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
            process.arguments = ["-a", "256", archive.path]
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let digest = String(data: bytes, encoding: .utf8)?.split(separator: " ").first else {
                throw PHPModuleError.verificationFailed(filename)
            }
            result[kind] = String(digest)
        }
        return result
    }

    private static func fpmIdentity(version: String, layout: VaelenFilesystemLayout) throws -> FPMIdentity {
        let record = layout.phpInstancesDirectoryURL.appendingPathComponent(version).appendingPathComponent("process.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        XCTAssertEqual(object["version"] as? String, version)
        return FPMIdentity(
            version: version,
            pid: try XCTUnwrap((object["pid"] as? NSNumber)?.int32Value),
            startedAt: try XCTUnwrap(object["startedAt"] as? String, "The running FPM process record must include its start identity.")
        )
    }

    private static func processIdentityIsLive(_ identity: FPMIdentity) -> Bool {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(identity.pid)", "-o", "lstart="]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == identity.startedAt
    }

    private func install(_ version: String) async throws -> PHPPackage {
        let response = await dispatcher.dispatch(IPCRequest(method: .phpInstall, params: .phpVersion(PHPVersionRequest(version: version))), handshaken: true)
        if let error = response.response.error { throw NSError(domain: "Vaelen", code: 1, userInfo: [NSLocalizedDescriptionKey: error.message]) }
        return try module.resolveEligible(version)
    }

    @discardableResult
    private func selectDefault(_ version: String) async throws -> PHPRuntimeCatalog {
        let response = await dispatcher.dispatch(IPCRequest(method: .phpDefaultSet, params: .phpVersion(PHPVersionRequest(version: version))), handshaken: true)
        if let error = response.response.error { throw NSError(domain: "Vaelen", code: 1, userInfo: [NSLocalizedDescriptionKey: error.message]) }
        fpmVersionsToCheck.insert(version)
        return try module.runtimeCatalog()
    }

    /// Update and return Core's report of what actually happened.
    private func update(version: String, sourceVersion: String?) async throws -> PHPUpdateResult {
        let result = try await Self.performUpdate(dispatcher: dispatcher, version: version, source: sourceVersion)
        if let error = result.convergenceError, result.replacedVersion == nil {
            throw NSError(domain: "Vaelen", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        return result
    }

    /// Issue the update request and decode Core's outcome.
    ///
    /// The dispatcher's in-memory response is deliberately round-tripped through
    /// the real wire encoding first, exactly as the framed Unix-socket path
    /// would carry it. Reading the in-memory value directly would bypass
    /// `ResponseResult` decoding and miss serialization defects.
    static func performUpdate(dispatcher: CoreRequestDispatcher, version: String, source: String?) async -> PHPUpdateResult {
        let response = await dispatcher.dispatch(IPCRequest(method: .phpUpdate, params: .phpVersion(PHPVersionRequest(version: version, sourceVersion: source))), handshaken: true)
        if let error = response.response.error {
            return PHPUpdateResult(version: version, replacedVersion: nil, wasDefault: false, isDefault: false, isRunning: false, convergence: [], convergenceError: error.message)
        }
        guard let wireData = try? IPCCodec.encode(response.response),
              let wireResponse = try? IPCCodec.decode(IPCResponse.self, from: wireData),
              case .some(.phpUpdateResult(let result)) = wireResponse.result else {
            return PHPUpdateResult(version: version, replacedVersion: nil, wasDefault: false, isDefault: false, isRunning: false, convergence: [], convergenceError: "Core did not report an update outcome.")
        }
        return result
    }

    /// Persist a real FastCGI route intent for a project, so post-update convergence
    /// has an inherited target to converge.
    private func persistRouteIntent(for project: ProjectID, hostname: String, version: String) throws {
        let id = try XCTUnwrap(project.rawValue as UUID?)
        let repository = RouteIntentRepository(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        let route = Route(hostname: hostname, target: .fastCGI(socketPath: layout.rootURL.appendingPathComponent("runtime/sockets/php/php-\(version).sock").path, documentRoot: root.appendingPathComponent("projects/inherited-app").path))
        try repository.upsert(RouteIntent(route: route, projectID: id, projectPath: root.appendingPathComponent("projects/inherited-app").path))
    }

    /// Place an already-installed package from the cache's real binaries.
    private func seedPackage(manifest: PHPManifest) throws {
        let cache = ProviderArtifactCache.shared
        let staged = try cache.stagedExecutables(version: manifest.phpVersion)
        let directory = layout.phpPackagesDirectoryURL.appendingPathComponent(manifest.phpVersion, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["php", "php-fpm"] {
            let destination = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: staged.appendingPathComponent(name), to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
        let digests = try cache.artifacts(version: manifest.phpVersion)
        let package = PHPPackage(version: manifest.phpVersion, architecture: "arm64", packagePath: directory.path,
                                 cliPath: directory.appendingPathComponent("php").path,
                                 fpmPath: directory.appendingPathComponent("php-fpm").path,
                                 source: manifest.artifacts["cli"]!.url, cliSHA256: digests["cli"]!, fpmSHA256: digests["fpm"]!, installedAt: Date())
        try JSONEncoder().encode(package).write(to: directory.appendingPathComponent(".vaelen-package.json"))
    }

    @discardableResult
    private func linkProject(named name: String, phpOverride: String?) async throws -> ProjectID {
        let projectRoot = root.appendingPathComponent("projects/\(name)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try "<?php\n".write(to: projectRoot.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)
        let project = try await registry.link(path: projectRoot, name: name)
        let id = try XCTUnwrap(project.id)
        if let phpOverride { try await registry.setPHPOverride(phpOverride, for: id) }
        return id
    }
}

/// A router that accepts a route apply but never reports it back, so
/// post-update convergence cannot be verified in a controlled way.
final class UnverifiableRouter: Router, @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var running = false
        func setRunning(_ value: Bool) { lock.lock(); running = value; lock.unlock() }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    }
    private let box = Box()

    func start() async throws { box.setRunning(true) }
    func stop() async throws { box.setRunning(false) }
    func status() async -> RouterStatus {
        RouterStatus(provider: "unverifiable", state: box.isRunning ? .running : .stopped, health: box.isRunning ? .healthy : .unknown, routeCount: 0)
    }
    func health() async -> RouterHealth { box.isRunning ? .healthy : .unknown }
    // The apply is accepted, but no route is ever observed afterwards.
    func reconcile(routes: [Route]) async throws {
        guard box.isRunning else { throw RouterError.notRunning }
        for route in routes { _ = try route.validated() }
    }
    func addRoute(_ route: Route) async throws { _ = try route.validated() }
    func updateRoute(_ route: Route) async throws { _ = try route.validated() }
    func removeRoute(id: RouteID) async throws {}
    func observedRoutes() async throws -> [Route] { [] }
}
