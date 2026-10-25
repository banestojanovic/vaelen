import XCTest
import CryptoKit
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

/// Real typed install/catalog/configuration/save requests against isolated Core
/// state. Only the already-installed executables are read to make local archives;
/// no live package, default, project, configuration, or service is changed.
@MainActor
final class PHPSettingsWorkflowTests: XCTestCase {
    func testMissingFeedCauseSurvivesCoreErrorMapping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-feed-map-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let module = PHPModule(layout: .init(rootURL: root), location: FilePHPManifestLocation(manifestURL: root.appendingPathComponent("manifest.json")))
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, php: module)
        let response = await dispatcher.dispatch(IPCRequest(method: .phpCatalogCheck), handshaken: true)
        XCTAssertEqual(response.response.error?.message, "No PHP update catalog is configured for this Vaelen distribution.")
        XCTAssertFalse(response.response.error?.message.contains("package metadata is invalid") ?? true)
    }

    func testLocalInventoryCompletionNeverChecksRemoteFeed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let location = CountingPHPManifestLocation()
        let module = PHPModule(layout: .init(rootURL: root), location: location)
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, php: module)
        let snapshot = await dispatcher.dispatch(IPCRequest(method: .phpCatalogSnapshot), handshaken: true)
        XCTAssertNil(snapshot.response.error)
        XCTAssertEqual(location.refreshCount, 0, "Install/remove completion must not depend on the update-feed request")
        _ = await dispatcher.dispatch(IPCRequest(method: .phpCatalog), handshaken: true)
        XCTAssertEqual(location.refreshCount, 1, "Automatic update discovery remains separate and supported")
    }

    func testOfficialReleaseChecksStayOutOfStartupAndSnapshotPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-official-boundary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let version = "8.4.26"
        let directory = layout.phpPackagesDirectoryURL.appendingPathComponent(version)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executableURL = directory.appendingPathComponent("php-fixture")
        let sourceURL = root.appendingPathComponent("php-fixture.c")
        try Data("#include <stdio.h>\nint main(void) { puts(\"PHP 8.4.26 (cli)\"); return 0; }\n".utf8).write(to: sourceURL)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-arch", "arm64", sourceURL.path, "-o", executableURL.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, "The isolated PHP executable fixture must compile")
        let package = PHPPackage(version: version, architecture: "arm64", packagePath: directory.path, cliPath: executableURL.path, fpmPath: executableURL.path, source: "fixture", cliSHA256: "fixture", fpmSHA256: "fixture", installedAt: Date())
        try JSONEncoder().encode(package).write(to: directory.appendingPathComponent(".vaelen-package.json"))
        let fetches = OfficialReleaseFetchCounter()
        let official = PHPReleaseAdvisoryStore(directory: layout.stateDirectoryURL, fetch: { _ in
            fetches.record()
            return Data(#"{"version":"8.4.27","date":"21 Oct 2026","tags":[]}"#.utf8)
        })
        let location = CountingPHPManifestLocation()
        let module = PHPModule(layout: layout, location: location, officialReleaseStore: official)
        XCTAssertEqual(module.eligibleInstalledVersions().count, 1)
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, php: module)
        await dispatcher.restoreServicesOnStartup()
        for _ in 0..<100 where location.refreshCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(location.refreshCount, 1)
        XCTAssertEqual(fetches.count, 0, "Service restoration must not check official releases")
        _ = await dispatcher.dispatch(IPCRequest(method: .status), handshaken: true)
        _ = await dispatcher.dispatch(IPCRequest(method: .phpCatalogSnapshot), handshaken: true)
        XCTAssertEqual(fetches.count, 0)
        _ = await dispatcher.dispatch(IPCRequest(method: .phpCatalog), handshaken: true)
        XCTAssertEqual(fetches.count, 1, "Automatic update checking must refresh official releases even when the provider fails")
        let explicit = await dispatcher.dispatch(IPCRequest(method: .phpCatalogCheck), handshaken: true)
        XCTAssertNotNil(explicit.response.error, "Provider failure must remain visible")
        XCTAssertEqual(fetches.count, 2, "Explicit update checking must force the independent official source")
        XCTAssertEqual(try module.runtimeCatalog().updateReports?.first?.upstreamRelease?.version, "8.4.27")
    }

    func testCachedInstallPublishesCacheVerificationInstallAndCompletionPhases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-cache-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let release = root.appendingPathComponent("release")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let manifest = try archiveInstalledExecutables(version: "8.3.29", release: release)
        let manifestURL = release.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support"), logsDirectoryURL: root.appendingPathComponent("logs"))
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: manifestURL, baseURL: release))
        _ = try module.install(requestedVersion: "8.3.29")
        let states = ProgressStateBox()
        _ = try module.remove(requestedVersion: "8.3.29")
        let poller = Task.detached {
            while !Task.isCancelled {
                if let state = module.operationState() { states.append(state) }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        _ = try module.install(requestedVersion: "8.3.29")
        poller.cancel()
        let observed = states.values
        XCTAssertTrue(observed.contains { $0.usingVerifiedCachedDownloads == true })
        XCTAssertTrue(observed.contains { $0.phase == .verifying })
        XCTAssertTrue(observed.contains { $0.phase == .installing })
        XCTAssertEqual(module.operationState()?.phase, .ready)
    }
    func testInstallLowerVersionAfterConfigurationLoadThenEditSaveResetAndReadBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-settings-workflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let release = root.appendingPathComponent("release")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let manifests = try ["8.4.23", "8.3.29"].map { try archiveInstalledExecutables(version: $0, release: release) }
        let manifestURL = release.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifests[0]).write(to: manifestURL)
        try JSONEncoder().encode(PHPManifestCatalog(manifests: manifests)).write(to: release.appendingPathComponent("php-catalog.json"))
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support"), logsDirectoryURL: root.appendingPathComponent("logs"))
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: manifestURL, baseURL: release))
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, php: module)
        let pair = InMemoryTransport.pair()
        let server = Task {
            try await pair.server.connect()
            var decoder = FrameDecoder()
            var handshaken = false
            while !Task.isCancelled {
                let data = try await pair.server.read()
                for frame in try decoder.append(data) {
                    let request = try IPCCodec.decode(IPCRequest.self, from: frame)
                    let dispatched = await dispatcher.dispatch(request, handshaken: handshaken)
                    handshaken = dispatched.handshaken
                    try await pair.server.write(FrameEncoder().encode(IPCCodec.encode(dispatched.response)))
                }
            }
        }
        defer { server.cancel() }
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "php-settings-workflow", version: VaelenBuildInfo.version))
        try await client.connect()
        let editor = PHPConfigurationEditor()

        _ = try await client.phpInstall("8.4.23")
        await editor.refresh { try await client.phpConfiguration() }
        let first = try XCTUnwrap(editor.snapshot)
        XCTAssertEqual(first.versions.map(\.version), ["8.4.23"])
        let shared = first.defaultSettings

        // The regression: an existing (non-nil) configuration snapshot predates
        // a second, numerically lower installed version. No client/model relaunch.
        editor.invalidateReads()
        let lowerPackage = try await client.phpInstall("8.3.29")
        XCTAssertEqual(lowerPackage.version, "8.3.29")
        let catalog = try await client.phpCatalog()
        XCTAssertEqual(catalog.installedVersions.map(\.version), ["8.4.23", "8.3.29"])
        await editor.refresh { try await client.phpConfiguration() }
        let lower = try XCTUnwrap(editor.snapshot?.versions.first { $0.version == "8.3.29" })
        XCTAssertEqual(lower.settings, shared)
        XCTAssertTrue(lower.inheritsDefault)
        XCTAssertTrue(lower.fpmIniPath.contains("8.3.29"))

        let higherContext = PHPSettingsContext.version("8.4.23")
        let lowerContext = PHPSettingsContext.version("8.3.29")
        editor.edit(higherContext, settings: shared) { $0.memory = "768" }
        XCTAssertEqual(editor.draft(for: lowerContext, settings: shared).memory, String(shared.memoryLimitMB))
        editor.edit(lowerContext, settings: shared) { $0.memory = "512"; $0.upload = "128" }
        let changed = try XCTUnwrap(editor.draft(for: lowerContext, settings: shared).values)
        await editor.save(context: lowerContext, settings: changed) {
            try await client.updatePHPConfiguration(version: "8.3.29", settings: changed)
        }
        XCTAssertNil(editor.saveErrors[lowerContext])
        let readBack = try await client.phpConfiguration()
        XCTAssertEqual(readBack.versions.first { $0.version == "8.3.29" }?.settings, changed)
        XCTAssertFalse(try XCTUnwrap(readBack.versions.first { $0.version == "8.3.29" }).inheritsDefault)
        XCTAssertEqual(readBack.versions.first { $0.version == "8.4.23" }?.settings, shared)
        XCTAssertEqual(editor.draft(for: higherContext, settings: shared).memory, "768")

        // Saving shared values changes only inherited versions, not this override.
        let changedShared = PHPSettingsValues(uploadLimitMB: 16, memoryLimitMB: 192, maxExecutionTimeSeconds: 45, maxInputVariables: 1500, postLimitMB: 17)
        await editor.save(context: .shared, settings: changedShared) { try await client.updatePHPConfiguration(version: nil, settings: changedShared) }
        let afterShared = try await client.phpConfiguration()
        XCTAssertEqual(afterShared.versions.first { $0.version == "8.3.29" }?.settings, changed)
        XCTAssertEqual(afterShared.versions.first { $0.version == "8.4.23" }?.settings, changedShared)

        // Exercise an actual Core save rejection and prove a successful read
        // cannot hide it. Reset failure is also returned by isolated Core.
        let invalid = PHPSettingsValues(uploadLimitMB: 0, memoryLimitMB: 512, maxExecutionTimeSeconds: 30, maxInputVariables: 2000, postLimitMB: 8)
        await editor.save(context: lowerContext, settings: invalid) { try await client.updatePHPConfiguration(version: "8.3.29", settings: invalid) }
        await editor.refresh { try await client.phpConfiguration() }
        XCTAssertNotNil(editor.saveErrors[lowerContext])
        XCTAssertEqual(editor.snapshot?.versions.first { $0.version == "8.3.29" }?.settings, changed)
        let settingsURL = layout.configurationDirectoryURL.appendingPathComponent("php/settings.json")
        let persisted = try Data(contentsOf: settingsURL)
        try Data("invalid isolated JSON".utf8).write(to: settingsURL)
        await editor.save(context: lowerContext, settings: nil) { try await client.updatePHPConfiguration(version: "8.3.29", settings: nil) }
        XCTAssertTrue(editor.saveErrors[lowerContext]?.hasPrefix("Reset failed:") == true)
        try persisted.write(to: settingsURL)
        await editor.refresh { try await client.phpConfiguration() }
        XCTAssertNotNil(editor.saveErrors[lowerContext])
        await editor.save(context: lowerContext, settings: nil) { try await client.updatePHPConfiguration(version: "8.3.29", settings: nil) }
        XCTAssertNil(editor.saveErrors[lowerContext])
        let reset = try await client.phpConfiguration()
        XCTAssertTrue(try XCTUnwrap(reset.versions.first { $0.version == "8.3.29" }).inheritsDefault)
        XCTAssertEqual(reset.versions.first { $0.version == "8.3.29" }?.settings, changedShared)
        let reloaded = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: manifestURL, baseURL: release))
        XCTAssertEqual(try reloaded.configuration().versions.first { $0.version == "8.3.29" }?.settings.memoryLimitMB, 192)

        _ = try await client.updatePHPConfiguration(version: "8.3.29", settings: changed)
        _ = try await client.phpRemove("8.3.29")
        await editor.refresh { try await client.phpConfiguration() }
        XCTAssertEqual(editor.snapshot?.versions.map(\.version), ["8.4.23"])
        XCTAssertNil(module.defaultVersion(), "The workflow must never change a default or start FPM")
        let removedDirectory = layout.phpPackagesDirectoryURL.appendingPathComponent("8.3.29")
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedDirectory.path))
        XCTAssertThrowsError(try module.resolveEligible("8.3.29"))
        for artifact in manifests[1].artifacts.values {
            let cached = layout.downloadsDirectoryURL.appendingPathComponent(artifact.file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path), "Verified download cache should survive uninstall")
            try FileManager.default.removeItem(at: release.appendingPathComponent(artifact.file))
        }
        let reinstalled = try await client.phpInstall("8.3.29")
        XCTAssertEqual(reinstalled.version, "8.3.29")
        XCTAssertTrue(FileManager.default.fileExists(atPath: removedDirectory.appendingPathComponent(".vaelen-package.json").path))
        XCTAssertTrue(module.eligibleInstalledVersions().contains { $0.version == "8.3.29" })
        let afterReinstall = try await client.phpConfiguration()
        XCTAssertEqual(afterReinstall.defaultSettings, changedShared)
        XCTAssertEqual(try XCTUnwrap(afterReinstall.versions.first { $0.version == "8.3.29" }).settings, changed, "Removal/reinstall preserves saved version overrides")
        XCTAssertFalse(try XCTUnwrap(afterReinstall.versions.first { $0.version == "8.3.29" }).inheritsDefault)
        XCTAssertNil(module.defaultVersion(), "Reinstall must not choose or change the default runtime")
        await client.disconnect()
    }

    private func archiveInstalledExecutables(version: String, release: URL) throws -> PHPManifest {
        let metadata = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vaelen/packages/php/\(version)/.vaelen-package.json")
        guard let package = try? JSONDecoder().decode(PHPPackage.self, from: Data(contentsOf: metadata)) else {
            throw XCTSkip("Read-only real PHP \(version) executables required for isolated install acceptance")
        }
        var artifacts = [String: PHPArtifact]()
        for (kind, path) in [("cli", package.cliPath), ("fpm", package.fpmPath)] {
            let source = URL(fileURLWithPath: path)
            let archive = release.appendingPathComponent("\(version)-\(kind).tar.gz")
            let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-czf", archive.path, "-C", source.deletingLastPathComponent().path, source.lastPathComponent]
            try tar.run(); tar.waitUntilExit()
            XCTAssertEqual(tar.terminationStatus, 0)
            let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
            artifacts[kind] = PHPArtifact(file: archive.lastPathComponent, url: "https://isolated.test/\(archive.lastPathComponent)", sha256: digest)
        }
        return PHPManifest(schemaVersion: 1, module: "php", phpVersion: version, platform: "macos", architecture: "arm64", artifacts: artifacts, verification: .init(algorithm: "sha256", authenticity: "isolated-installed-runtime"))
    }
}

private final class ProgressStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [PHPOperationState]()
    func append(_ state: PHPOperationState) { lock.lock(); storage.append(state); lock.unlock() }
    var values: [PHPOperationState] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class CountingPHPManifestLocation: PHPManifestLocation, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var refreshCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func artifactBaseURL() -> URL? { nil }
    func manifest() throws -> PHPManifest { throw PHPModuleError.manifestUnavailable }
    func refreshCatalogIfNeeded() throws {
        lock.lock(); count += 1; lock.unlock()
        throw PHPModuleError.manifestUnavailable
    }
}

private final class OfficialReleaseFetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
