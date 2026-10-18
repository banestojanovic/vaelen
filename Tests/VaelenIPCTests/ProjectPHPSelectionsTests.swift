import XCTest
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

final class ProjectPHPSelectionsTests: XCTestCase {
    func testBatchUsesClientWireAndKeepsHealthySelectionsWhenOtherProjectsAreBad() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("php-selections-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        guard let phpBinary = Self.findExecutable(named: "php") else {
            throw XCTSkip("No local PHP CLI is available for synthetic package validation.")
        }
        let version = try Self.phpVersion(executable: phpBinary)
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true))
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        let defaultPath = projectsRoot.appendingPathComponent("defaulted", isDirectory: true)
        let overridePath = projectsRoot.appendingPathComponent("pinned", isDirectory: true)
        let unavailablePath = projectsRoot.appendingPathComponent("unavailable", isDirectory: true)
        let malformedPath = projectsRoot.appendingPathComponent("malformed", isDirectory: true)
        let missingPath = projectsRoot.appendingPathComponent("gone", isDirectory: true)
        for path in [defaultPath, overridePath, unavailablePath, malformedPath, missingPath] {
            try fm.createDirectory(at: path, withIntermediateDirectories: true)
        }

        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let registry = ProjectRegistry(store: store)
        let defaultProject = try await registry.link(path: defaultPath, name: "defaulted")
        let overrideProject = try await registry.link(path: overridePath, name: "pinned")
        let unavailableProject = try await registry.link(path: unavailablePath, name: "unavailable")
        let malformedProject = try await registry.link(path: malformedPath, name: "malformed")
        let missingProject = try await registry.link(path: missingPath, name: "gone")
        guard let overrideID = overrideProject.id,
              let unavailableID = unavailableProject.id else {
            return XCTFail("linked projects must have IDs")
        }

        let packageDirectory = layout.phpPackagesDirectoryURL.appendingPathComponent(version, isDirectory: true)
        try fm.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let package = PHPPackage(
            version: version,
            architecture: "arm64",
            packagePath: packageDirectory.path,
            cliPath: phpBinary,
            fpmPath: phpBinary,
            source: "synthetic project.php.selections fixture",
            cliSHA256: "synthetic",
            fpmSHA256: "synthetic",
            installedAt: Date()
        )
        try JSONEncoder().encode(package).write(to: packageDirectory.appendingPathComponent(".vaelen-package.json"))
        try fm.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
        let defaultConfig = layout.configurationDirectoryURL.appendingPathComponent("php-default.json")
        let defaultBytes = Data(version.utf8)
        try defaultBytes.write(to: defaultConfig)
        try await registry.setPHPOverride(version, for: overrideID)
        try await registry.setPHPOverride("99.0.0", for: unavailableID)
        try Data("version: [invalid\n".utf8).write(to: malformedPath.appendingPathComponent("vaelen.yml"))
        try fm.removeItem(at: missingPath)

        let processDirectory = layout.phpInstancesDirectoryURL.appendingPathComponent(version, isDirectory: true)
        try fm.createDirectory(at: processDirectory, withIntermediateDirectories: true)
        let staleProcess = processDirectory.appendingPathComponent("process.json")
        let staleProcessBytes = try JSONSerialization.data(withJSONObject: [
            "pid": Int32.max, "version": version, "executable": phpBinary,
            "arguments": ["-F"], "configPath": processDirectory.appendingPathComponent("php-fpm.conf").path,
            "socketPath": processDirectory.appendingPathComponent("php.sock").path
        ])

        let router = SelectionsTestRouter()
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: root.appendingPathComponent("manifest.json")))
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test", pid: 1),
            registry: registry,
            php: module,
            router: router
        )
        let pair = InMemoryTransport.pair()
        let methods = RequestMethodLog()
        let server = Task {
            try await pair.server.connect()
            var decoder = FrameDecoder()
            var handshaken = false
            for _ in 0..<4 {
                let data = try await pair.server.read()
                for frame in try decoder.append(data) {
                    let request = try IPCCodec.decode(IPCRequest.self, from: frame)
                    await methods.append(request.knownMethod!)
                    let dispatched = await dispatcher.dispatch(request, handshaken: handshaken)
                    handshaken = dispatched.handshaken
                    try await pair.server.write(FrameEncoder().encode(IPCCodec.encode(dispatched.response)))
                }
            }
            await pair.server.disconnect()
        }

        defer { server.cancel() }
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "project-php-selections-test", version: VaelenBuildInfo.version))
        try await client.connect()
        let expectedDefault = try await client.projectPHP(selector: defaultProject.id?.rawValue.uuidString, workingDirectory: root.path)
        let expectedOverride = try await client.projectPHP(selector: overrideProject.id?.rawValue.uuidString, workingDirectory: root.path)
        try staleProcessBytes.write(to: staleProcess)
        let filesBeforeBatch = try Self.files(under: layout.rootURL)
        let routerCallsBeforeBatch = await router.callCount
        let selections = try await client.projectPHPSelections()
        await client.disconnect()
        try await server.value

        let receivedMethods = await methods.values
        XCTAssertEqual(receivedMethods, [.handshake, .projectPHP, .projectPHP, .projectPHPSelections])
        XCTAssertEqual(selections.count, 4)
        XCTAssertFalse(selections.contains(where: { $0.project.path == missingProject.rootPath.string }))
        XCTAssertTrue(selections.contains(where: { $0.project.path == malformedProject.rootPath.string }), "PHP selection enumeration must not parse unrelated vaelen.yml configuration")
        XCTAssertEqual(Self.selection(named: "defaulted", in: selections), expectedDefault)
        XCTAssertEqual(Self.selection(named: "pinned", in: selections), expectedOverride)
        let unavailable = try XCTUnwrap(Self.selection(named: "unavailable", in: selections))
        XCTAssertEqual(unavailable.overrideVersion, "99.0.0")
        XCTAssertEqual(unavailable.defaultVersion, version)
        XCTAssertNil(unavailable.effectiveVersion)
        XCTAssertFalse(unavailable.available)
        XCTAssertNil(expectedDefault.overrideVersion)
        XCTAssertEqual(expectedDefault.defaultVersion, version)
        XCTAssertEqual(expectedDefault.effectiveVersion, version)
        XCTAssertEqual(expectedOverride.overrideVersion, version)
        XCTAssertEqual(expectedOverride.effectiveVersion, version)
        XCTAssertEqual(try Self.files(under: layout.rootURL), filesBeforeBatch, "batch lookup must leave support files byte-identical")
        XCTAssertEqual(try Data(contentsOf: defaultConfig), defaultBytes)
        XCTAssertEqual(try Data(contentsOf: staleProcess), staleProcessBytes)
        let routerCallsAfterBatch = await router.callCount
        XCTAssertEqual(routerCallsAfterBatch, routerCallsBeforeBatch, "PHP batch selection must not inspect or mutate routes through the router")
        XCTAssertEqual(try module.status(requestedVersion: version).state, .stopped)
        XCTAssertFalse(fm.fileExists(atPath: staleProcess.path), "existing status API still maintains stale process records")
    }

    func testNilPHPModuleAndEmptyBatchReturnEmptySelectionList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-selections-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry)
        let response = await dispatcher.dispatch(IPCRequest(method: .projectPHPSelections), handshaken: true).response
        guard case .projectPHPSelections(let result)? = response.result else { return XCTFail("empty batch response required") }
        XCTAssertTrue(result.selections.isEmpty)
        XCTAssertNil(response.error)
    }

    func testUnavailableDefaultProducesUnavailableSelectionWithoutStartingRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-selections-default-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectPath = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
        try Data("99.0.0".utf8).write(to: layout.configurationDirectoryURL.appendingPathComponent("php-default.json"))
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        let project = try await registry.link(path: projectPath, name: "default-unavailable")
        let php = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: root.appendingPathComponent("manifest.json")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, php: php, router: SelectionsTestRouter())

        let response = await dispatcher.dispatch(IPCRequest(method: .projectPHPSelections), handshaken: true).response
        guard case .projectPHPSelections(let result)? = response.result,
              let selection = result.selections.first else { return XCTFail("one unavailable default selection required") }
        XCTAssertEqual(result.selections.count, 1)
        XCTAssertEqual(selection.project.path, project.rootPath.string)
        XCTAssertNil(selection.overrideVersion)
        XCTAssertNil(selection.defaultVersion, "unavailable defaults retain the existing validated-default behavior")
        XCTAssertNil(selection.effectiveVersion)
        XCTAssertFalse(selection.available)
        XCTAssertNil(response.error)
    }

    func testMissingSingleProjectErrorDoesNotPreventFollowingBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-selections-missing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry)
        let missing = await dispatcher.dispatch(
            IPCRequest(method: .projectPHP, params: .projectPHP(.init(selector: "00000000-0000-0000-0000-000000000000", workingDirectory: root.path))),
            handshaken: true
        ).response
        XCTAssertEqual(missing.error?.code, .projectNotFound)
        let batch = await dispatcher.dispatch(IPCRequest(method: .projectPHPSelections), handshaken: true).response
        guard case .projectPHPSelections(let result)? = batch.result else { return XCTFail("later batch should remain available") }
        XCTAssertTrue(result.selections.isEmpty)
        XCTAssertNil(batch.error)
    }

    func testPHPObservationPreservesDefaultFamiliesExactOverridesAndRunningState() {
        let versions = ["8.3.29", "8.3.30", "8.4.23", "8.4.24"]
        let packages = versions.map { version in
            PHPPackage(version: version, architecture: "arm64", packagePath: "/synthetic/\(version)", cliPath: "/synthetic/cli", fpmPath: "/synthetic/fpm", source: "pure resolution fixture", cliSHA256: "", fpmSHA256: "", installedAt: Date(timeIntervalSince1970: 0))
        }
        let statuses = [PHPStatus(version: "8.4.24", package: packages.last, state: .running, pid: 1, socket: "/synthetic/php.sock", health: "healthy", isDefault: true)]
        let inspector = ProjectEnvironmentInspector()
        let inherited = inspector.observePHP(phpPackages: packages, phpStatuses: statuses, phpDefault: "8.4")
        XCTAssertEqual(inherited.resolvedVersion, "8.4.24")
        XCTAssertEqual(inherited.resolvedState, "running")
        XCTAssertEqual(inherited.resolutionState, .resolved)
        let exact = inspector.observePHP(phpPackages: packages, phpStatuses: statuses, phpDefault: "8.4.24", phpOverride: "8.3.29")
        XCTAssertEqual(exact.resolvedVersion, "8.3.29", "explicit overrides never upgrade to a newer installed patch")
        XCTAssertEqual(exact.resolvedState, "not-running")
        let unavailable = inspector.observePHP(phpPackages: packages, phpStatuses: statuses, phpDefault: "8.4.24", phpOverride: "8.3.31")
        XCTAssertNil(unavailable.resolvedVersion, "unavailable overrides never fall back to the default")
        XCTAssertEqual(unavailable.resolutionState, .unavailable)
        let invalid = inspector.observePHP(phpPackages: [], phpStatuses: [], phpDefault: "8.4", invalidPHPVersions: ["8.4.24"])
        XCTAssertEqual(invalid.resolutionState, .invalid)
    }

    func testBatchRequiresHandshakeAndNilModuleKeepsEachProjectUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-selections-no-module-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectPath = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let project = try await registry.link(path: projectPath)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry)
        let rejected = await dispatcher.dispatch(IPCRequest(method: .projectPHPSelections), handshaken: false)
        XCTAssertFalse(rejected.handshaken)
        XCTAssertEqual(rejected.response.error?.code, .invalidRequest)
        let response = await dispatcher.dispatch(IPCRequest(method: .projectPHPSelections), handshaken: true).response
        guard case .projectPHPSelections(let result)? = response.result else { return XCTFail("batch response required") }
        let selection = try XCTUnwrap(result.selections.first)
        XCTAssertEqual(result.selections.count, 1)
        XCTAssertEqual(selection.project.path, project.rootPath.string)
        XCTAssertNil(selection.defaultVersion)
        XCTAssertNil(selection.effectiveVersion)
        XCTAssertNil(selection.observedVersion)
        XCTAssertFalse(selection.available)
    }

    private static func files(under root: URL) throws -> [String: Data] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
        return result
    }

    private static func selection(named name: String, in selections: [ProjectPHPSelection]) -> ProjectPHPSelection? {
        selections.first { $0.project.name == name }
    }

    private static func findExecutable(named name: String) -> String? {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func phpVersion(executable: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-v"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #"PHP (\d+\.\d+\.\d+)"#, options: .regularExpression) else {
            throw XCTSkip("The local PHP CLI did not report a parseable version.")
        }
        let match = text[range]
        return String(match.dropFirst("PHP ".count))
    }
}

private actor RequestMethodLog {
    private(set) var values: [CoreMethod] = []
    func append(_ method: CoreMethod) { values.append(method) }
}

private actor SelectionsTestRouter: Router {
    private(set) var callCount = 0
    func start() async throws { callCount += 1 }
    func stop() async throws { callCount += 1 }
    func status() async -> RouterStatus { callCount += 1; return .init(provider: "selections-test", state: .stopped, health: .unknown, routeCount: 0) }
    func health() async -> RouterHealth { callCount += 1; return .unhealthy }
    func reconcile(routes: [Route]) async throws { callCount += 1 }
    func addRoute(_ route: Route) async throws { callCount += 1 }
    func updateRoute(_ route: Route) async throws { callCount += 1 }
    func removeRoute(id: RouteID) async throws { callCount += 1 }
    func observedRoutes() async throws -> [Route] { callCount += 1; return [] }
}
