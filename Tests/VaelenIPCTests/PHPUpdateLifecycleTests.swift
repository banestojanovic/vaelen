import CryptoKit
import Foundation
import XCTest
import VaelenTestSupport
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

/// Update results across the real IPC boundary, and operation stages through
/// the production transfer path.
///
/// A serialized update result once fell through `ResponseResult` decoding to
/// `.raw`, so the client rejected a successful update as `invalidResponse` and
/// the interface reported "operation failed" next to a healthy new default.
/// These tests pin the wire shape and exercise the framed Unix-socket path, the
/// observable operation stages, and genuine failure — all against isolated
/// state with the verified provider cache.
final class PHPUpdateLifecycleTests: XCTestCase {
    // MARK: - Wire shape (no I/O)

    /// A successful update result must survive the wire encoding and decode
    /// back to its own case — never to `.raw`.
    func testSuccessfulUpdateResultRoundTrip() throws {
        let original = PHPUpdateResult(
            version: "8.4.24", replacedVersion: "8.4.23",
            wasDefault: true, isDefault: true, isRunning: true,
            convergence: ["running", "default", "intents", "routes"], convergenceError: nil
        )
        let decoded = try IPCCodec.decode(ResponseResult.self, from: IPCCodec.encode(original))
        guard case .phpUpdateResult(let result) = decoded else {
            return XCTFail("A successful update result decoded as \(decoded) instead of .phpUpdateResult")
        }
        XCTAssertEqual(result, original)
    }

    /// Partial success — installed, but routing did not converge — must keep
    /// its shape, including absent optional fields.
    func testPartialUpdateResultWithAbsentOptionalsRoundTrip() throws {
        // Truly absent keys, not explicit nulls: this is what older writers and
        // hand-built payloads look like.
        let minimal = """
        {"version":"8.4.24","wasDefault":true,"isDefault":true,"isRunning":true,"convergence":["running","default","intents"]}
        """.data(using: .utf8)!
        let decoded = try IPCCodec.decode(ResponseResult.self, from: minimal)
        guard case .phpUpdateResult(let result) = decoded else {
            return XCTFail("A partial update result decoded as \(decoded) instead of .phpUpdateResult")
        }
        XCTAssertEqual(result.version, "8.4.24")
        XCTAssertNil(result.replacedVersion)
        XCTAssertNil(result.convergenceError)
        XCTAssertEqual(result.convergence, ["running", "default", "intents"])
    }

    /// A version list has no `convergence` key and must keep decoding as a
    /// version list — the new branch must not swallow neighbouring shapes.
    func testVersionsResultStillDecodesAsVersions() throws {
        let versions = PHPVersionsResult(available: ["8.4.24"], installed: [], default: "8.4.23")
        let decoded = try IPCCodec.decode(ResponseResult.self, from: IPCCodec.encode(versions))
        guard case .phpVersions(let result) = decoded else {
            return XCTFail("A version list decoded as \(decoded) instead of .phpVersions")
        }
        XCTAssertEqual(result, versions)
    }

    /// The full response envelope round-trips, so what the dispatcher sends is
    /// what the client reads.
    func testFullUpdateResponseEnvelopeRoundTrip() throws {
        let payload = PHPUpdateResult(
            version: "8.4.24", replacedVersion: "8.4.23",
            wasDefault: false, isDefault: false, isRunning: false,
            convergence: [], convergenceError: nil
        )
        let response = IPCResponse(id: UUID(), result: .phpUpdateResult(payload))
        let decoded = try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response))
        XCTAssertEqual(decoded.id, response.id)
        guard case .some(.phpUpdateResult(let result)) = decoded.result else {
            return XCTFail("The envelope lost the update result: \(String(describing: decoded.result))")
        }
        XCTAssertEqual(result, payload)
    }

    // MARK: - Production socket path (isolated state, verified cache)

    private let sourceVersion = "8.4.23"
    private let targetVersion = "8.4.24"

    private var root: URL!
    private var layout: VaelenFilesystemLayout!
    private var module: PHPModule!
    private var registry: ProjectRegistry!
    private var serviceIntents: ServiceIntentStore!
    private var dispatcher: CoreRequestDispatcher!
    private var serverTask: Task<Void, Error>?
    private var serverPaths: CoreEndpointPaths?
    private var clients: [VaelenCoreClient] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let cache = ProviderArtifactCache.shared
        guard (try? cache.artifacts(version: sourceVersion)) != nil, (try? cache.artifacts(version: targetVersion)) != nil else {
            throw XCTSkip("The verified provider cache needs PHP \(sourceVersion) and \(targetVersion). Run ./Scripts/refresh-php-catalog-from-provider.sh first.")
        }
        root = URL(fileURLWithPath: "/private/var/tmp/vaelen-lifecycle-\(UUID().uuidString.prefix(8))", isDirectory: true)
        layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true), logsDirectoryURL: root.appendingPathComponent("logs", isDirectory: true))
        try FileManager.default.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // The test server only exits after a shutdown request. Ask on a fresh
        // connection first so awaiting the server task cannot hang, then stop
        // any isolated FPM before removing its root.
        if serverTask != nil, let serverPaths {
            let killer = VaelenCoreClient(
                transport: UnixSocketTransport(path: serverPaths.socketPath),
                identity: ClientIdentity(name: "php-lifecycle-teardown", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)
            )
            try? await killer.connect()
            _ = try? await killer.shutdown()
            try? await killer.disconnect()
            _ = try? await serverTask?.value
            serverTask = nil
        }
        for client in clients { try? await client.disconnect() }
        clients = []
        var liveChildren: [String] = []
        if let module {
            for version in module.installedVersions()
            where FileManager.default.fileExists(atPath: layout.phpInstancesDirectoryURL.appendingPathComponent(version.version).appendingPathComponent("process.json").path) {
                _ = try? module.stop(requestedVersion: version.version)
                if FileManager.default.fileExists(atPath: layout.phpInstancesDirectoryURL.appendingPathComponent(version.version).appendingPathComponent("process.json").path) {
                    liveChildren.append(version.version)
                }
            }
        }
        module = nil
        if !liveChildren.isEmpty {
            XCTFail("Isolated PHP-FPM did not shut down for \(liveChildren.joined(separator: ", ")); preserving \(root.path).")
        } else if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    private func startServer(router: any Router = InMemoryRouter()) throws -> CoreEndpointPaths {
        let cache = ProviderArtifactCache.shared
        let manifests = try [cache.manifest(version: sourceVersion), cache.manifest(version: targetVersion)]
        let location = PHPProviderManifestLocation(
            box: .init(PHPManifestCatalog(manifests: manifests)),
            stateDirectory: layout.stateDirectoryURL,
            artifactBase: try cache.flatDirectory()
        )
        let module = PHPModule(layout: layout, location: location, includesBundledCatalog: false)
        self.module = module
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let registry = ProjectRegistry(store: store)
        self.registry = registry
        let intents = ServiceIntentStore(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json"))
        serviceIntents = intents
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test", pid: 1),
            registry: registry, php: module, router: router,
            routeRepository: RouteIntentRepository(store: store), serviceIntents: intents
        )
        self.dispatcher = dispatcher
        let paths = CoreEndpointPaths(layout: layout)
        let server = DaemonServer(paths: paths, dispatcher: dispatcher)
        serverPaths = paths
        serverTask = Task.detached { try await server.run() }
        return paths
    }

    private func connectClient(_ label: String, paths: CoreEndpointPaths) async throws -> VaelenCoreClient {
        let client = VaelenCoreClient(
            transport: UnixSocketTransport(path: paths.socketPath),
            identity: ClientIdentity(name: label, version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)
        )
        try await client.connect()
        clients.append(client)
        return client
    }

    private func waitForSocket(_ paths: CoreEndpointPaths) async throws {
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: paths.socketPath) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketPath), "The test Core server never bound its socket.")
    }

    /// The exact defect from the field: a successful update crossed the framed
    /// Unix-socket path and the client rejected it. The client must now decode
    /// the typed result instead of reporting failure.
    func testSocketUpdateReturnsDecodedResult() async throws {
        let paths = try startServer()
        try await waitForSocket(paths)
        let client = try await connectClient("php-update-lifecycle", paths: paths)
        // Both runtimes pre-installed so the update exercises production code
        // without re-downloading: the install short-circuits on valid packages.
        _ = try await client.phpInstall(sourceVersion)
        _ = try await client.phpInstall(targetVersion)

        let result = try await client.phpUpdate(targetVersion, sourceVersion: sourceVersion)
        XCTAssertEqual(result.version, targetVersion)
        XCTAssertEqual(result.replacedVersion, sourceVersion)
        XCTAssertFalse(result.wasDefault)
        XCTAssertFalse(result.isRunning, "A stopped non-default update must not start anything.")
        XCTAssertEqual(result.convergence, ["cleanup"], "Only replacement cleanup runs for a stopped non-default update.")
        XCTAssertNil(result.convergenceError)

        // The operation reaches one terminal state after convergence and cleanup.
        let terminal = try await client.phpOperation()
        XCTAssertEqual(terminal?.phase, .ready)
        XCTAssertEqual(terminal?.targetVersion, targetVersion)
        // The superseded package is gone from the inventory the socket serves.
        let catalog = try await client.phpCatalogSnapshot()
        XCTAssertFalse(catalog.installedVersions.map(\.version).contains(sourceVersion))
    }

    /// A genuine Core rejection still surfaces as the Core error — not as a
    /// decoding failure and not as silent success.
    func testSocketUpdateGenuineFailureSurfacesCoreError() async throws {
        let paths = try startServer()
        try await waitForSocket(paths)
        let client = try await connectClient("php-update-failure", paths: paths)
        do {
            _ = try await client.phpUpdate("9.9.9")
            XCTFail("An unsupported version must be rejected.")
        } catch let error as CoreClientError {
            guard case .remote(let payload) = error else {
                return XCTFail("A genuine Core failure must arrive as the Core error, not \(error).")
            }
            XCTAssertTrue(payload.message.contains("9.9.9"), "The error must name the rejected version: \(payload.message)")
        }
    }

    /// While routing converges, observers see a pending converging stage —
    /// never a frozen full bar and never a premature ready.
    func testConvergingStageIsObservableDuringRouting() async throws {
        let gate = GatedRouter()
        let paths = try startServer(router: gate)
        try await waitForSocket(paths)
        let client = try await connectClient("php-update-converging", paths: paths)
        let observer = try await connectClient("php-update-observer", paths: paths)
        try await gate.start()

        _ = try await client.phpInstall(sourceVersion)
        _ = try await client.phpInstall(targetVersion)
        _ = try await client.phpDefaultSet(sourceVersion)
        // An inherited project with a persisted route, so convergence has real
        // work: the route must move to the replacement's socket.
        let projectRoot = root.appendingPathComponent("projects/inherited-app")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try "<?php\n".write(to: projectRoot.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)
        let project = try await registry.link(path: projectRoot, name: "inherited-app")
        let id = try XCTUnwrap(project.id?.rawValue as UUID?)
        let repository = RouteIntentRepository(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        try repository.upsert(RouteIntent(
            route: Route(hostname: "inherited-app.test", target: .fastCGI(
                socketPath: layout.rootURL.appendingPathComponent("runtime/sockets/php/php-\(sourceVersion).sock").path,
                documentRoot: projectRoot.path)),
            projectID: id, projectPath: projectRoot.path))

        await gate.setArmed(true)
        // Copy to locals so the concurrent update does not capture the test.
        let updateTarget = targetVersion, updateSource = sourceVersion
        async let updating = client.phpUpdate(updateTarget, sourceVersion: updateSource)
        // Routing must become observably pending before it completes.
        var sawConverging = false
        for _ in 0..<300 {
            if let observed = try? await observer.phpOperation(),
               observed.targetVersion == targetVersion {
                if observed.phase == .converging { sawConverging = true; break }
                if observed.phase == .ready || observed.phase == .failed { break }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(sawConverging, "Routing convergence must be observable as a pending stage, not as a frozen bar or a premature ready.")
        await gate.release()
        let result = try await updating
        XCTAssertNil(result.convergenceError)
        XCTAssertTrue(result.convergence.contains("routes"))
        XCTAssertTrue(result.isDefault)
        XCTAssertTrue(result.isRunning)
        let terminal = try await observer.phpOperation()
        XCTAssertEqual(terminal?.phase, .ready)
    }

    /// An explicit project pin survives the socket update path unchanged.
    func testSocketUpdatePreservesExplicitPin() async throws {
        let paths = try startServer()
        try await waitForSocket(paths)
        let client = try await connectClient("php-update-pin", paths: paths)
        _ = try await client.phpInstall(sourceVersion)
        _ = try await client.phpInstall(targetVersion)

        let projectRoot = root.appendingPathComponent("projects/pinned-app")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try "<?php\n".write(to: projectRoot.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)
        let project = try await registry.link(path: projectRoot, name: "pinned-app")
        let id = try XCTUnwrap(project.id)
        try await registry.setPHPOverride(sourceVersion, for: id)

        // The pinned source refuses the update over the socket path too.
        do {
            _ = try await client.phpUpdate(targetVersion, sourceVersion: sourceVersion)
            XCTFail("An update whose source is pinned must be refused.")
        } catch let error as CoreClientError {
            guard case .remote(let payload) = error else {
                return XCTFail("The refusal must arrive as the Core error, not \(error).")
            }
            XCTAssertTrue(payload.message.contains("pinned-app"), "The refusal must name the project: \(payload.message)")
        }
        let survivingPin = try await registry.phpOverride(for: id)
        XCTAssertEqual(survivingPin, sourceVersion,
                       "An explicit pin must survive a refused update; the user chooses migration.")
        // The refused update changed nothing: the source is still installed and
        // no replacement relationship was recorded.
        let catalog = try await client.phpCatalogSnapshot()
        XCTAssertTrue(catalog.installedVersions.map(\.version).contains(sourceVersion))
    }

    /// A snapshot that outlived its lifetime is rejected instead of serving
    /// stale observations.
    func testStaleObservationSnapshotIsRejected() async throws {
        XCTAssertTrue(ProjectObservationSnapshotFreshness.isFresh(createdAt: Date(), now: Date()))
        XCTAssertFalse(ProjectObservationSnapshotFreshness.isFresh(
            createdAt: Date().addingTimeInterval(-31), now: Date()),
            "A snapshot older than its lifetime must not be treated as fresh.")
        XCTAssertFalse(ProjectObservationSnapshotFreshness.isFresh(
            createdAt: Date().addingTimeInterval(60), now: Date()),
            "A snapshot from the future must not be treated as fresh.")

        let paths = try startServer()
        try await waitForSocket(paths)
        let client = try await connectClient("php-update-snapshot", paths: paths)
        // A real project, so resolution succeeds and the stale snapshot itself
        // is what gets rejected.
        let projectRoot = root.appendingPathComponent("projects/snapshot-app")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try "<?php\n".write(to: projectRoot.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)
        _ = try await registry.link(path: projectRoot, name: "snapshot-app")

        // Server side: an unknown snapshot token is rejected with the snapshot
        // error, never served as if it were fresh.
        let direct = await dispatcher.dispatch(
            IPCRequest(method: .projectStatus, params: .projectEnvironment(ProjectEnvironmentRequest(selector: "snapshot-app", workingDirectory: projectRoot.path, snapshotID: UUID()))),
            handshaken: true
        )
        let rejection = try XCTUnwrap(direct.response.error)
        XCTAssertEqual(rejection.code, .projectObservationSnapshotExpired)
        XCTAssertTrue(rejection.message.lowercased().contains("snapshot"),
                      "The rejection must name the snapshot problem: \(rejection.message)")

        // Client side: the same expiry is recovered transparently with fresh
        // observations, so diagnostics never go stale — they just refresh.
        let report = try await client.projectStatus(selector: "snapshot-app", workingDirectory: projectRoot.path, snapshotID: UUID())
        XCTAssertEqual(report.identity.name, "snapshot-app")
    }
}

/// A router that passes everything through to memory until armed, then blocks
/// inside `reconcile` so routing convergence stays observably pending.
final class GatedRouter: Router, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private let gate = DispatchSemaphore(value: 0)
        func setArmed(_ value: Bool) { lock.lock(); armed = value; lock.unlock() }
        var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return armed }
        func awaitRelease() { gate.wait() }
        func release() { gate.signal() }
    }
    private let state = State()
    private let inner = InMemoryRouter()

    func setArmed(_ armed: Bool) async { state.setArmed(armed) }
    func release() async { state.release() }
    func start() async throws { try await inner.start() }
    func stop() async throws { try await inner.stop() }
    func status() async -> RouterStatus { await inner.status() }
    func health() async -> RouterHealth { await inner.health() }
    func reconcile(routes: [Route]) async throws {
        if state.isArmed { state.awaitRelease() }
        try await inner.reconcile(routes: routes)
    }
    func addRoute(_ route: Route) async throws { try await inner.addRoute(route) }
    func updateRoute(_ route: Route) async throws { try await inner.updateRoute(route) }
    func removeRoute(id: RouteID) async throws { try await inner.removeRoute(id: id) }
    func observedRoutes() async throws -> [Route] { try await inner.observedRoutes() }
}
