import XCTest
import Darwin
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

final class DispatcherTests: XCTestCase {
    func testDispatcherHandshakeRequiresMatchingSchemaBeforeNormalDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry)

        let old = await dispatcher.dispatch(IPCRequest(method: .handshake, params: .handshake(.init(client: .init(name: "old", version: "0.0.10-dev")))), handshaken: false)
        XCTAssertEqual(old.response.error?.code, .coreIncompatible)
        XCTAssertFalse(old.handshaken)

        let current = await dispatcher.dispatch(IPCRequest(method: .handshake, params: .handshake(.init(client: .init(name: "current", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))), handshaken: false)
        XCTAssertTrue(current.handshaken)
        guard case .handshake(let result) = current.response.result else { return XCTFail("handshake did not return compatibility identity") }
        XCTAssertEqual(result.schemaCompatibilityVersion, VaelenBuildInfo.schemaCompatibilityVersion)
        XCTAssertEqual(result.buildIdentity, VaelenBuildInfo.buildIdentity)
    }

    func testDispatcherRejectsNormalCommandBeforeHandshake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry)

        let result = await dispatcher.dispatch(IPCRequest(method: .status), handshaken: false)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
        XCTAssertEqual(result.response.error?.message, "Handshake is required before other requests.")
    }

    func testDispatcherRejectsUnknownMethodStructurally() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry)

        let result = await dispatcher.dispatch(IPCRequest(rawMethod: "project.future"), handshaken: true)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
    }

    func testRouteMutationPersistsThroughCoreAndSurvivesDispatcherRecreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "persisted.test", target: .staticFiles(documentRoot: "/tmp/persisted"), tls: .disabled)
        let intent = RouteIntent(route: route)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry, routeRepository: repository)

        let added = await dispatcher.dispatch(IPCRequest(method: .routeAdd, params: .route(intent)), handshaken: true)
        guard case .routeMutation(let addedIntent) = added.response.result else { return XCTFail("route add did not return the route") }
        XCTAssertEqual(addedIntent, intent)

        let recreated = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 2), registry: registry, routeRepository: repository)
        let listed = await recreated.dispatch(IPCRequest(method: .routeList), handshaken: true)
        guard case .routeList(let result) = listed.response.result else { return XCTFail("route list did not return routes") }
        XCTAssertEqual(result.routes, [intent])

        let removed = await recreated.dispatch(IPCRequest(method: .routeRemove, params: .routeRemove(.init(id: route.id))), handshaken: true)
        guard case .routeList(let afterRemoval) = removed.response.result else { return XCTFail("route remove did not return routes") }
        XCTAssertTrue(afterRemoval.routes.isEmpty)
    }

    func testExplicitRouteAssociationChangesOnlyMetadataAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("public"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("bootstrap"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("config"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: projectRoot.appendingPathComponent("artisan"))
        try Data("<?php".utf8).write(to: projectRoot.appendingPathComponent("public/index.php"))
        try Data("{\"require\":{\"laravel/framework\":\"^11.0\",\"php\":\"^8.3\"}}".utf8).write(to: projectRoot.appendingPathComponent("composer.json"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot)
        guard let projectID = project.id else { return XCTFail("linked project did not receive an ID") }
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "project.test", target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: projectRoot.appendingPathComponent("public").path), tls: .local)
        let intent = RouteIntent(route: route)
        try repository.upsert(intent)
        let router = InMemoryRouter()
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry, router: router, routeRepository: repository)

        let request = IPCRequest(method: .routeProjectAssociationAttach, params: .routeAssociation(.init(routeID: route.id, projectID: projectID)))
        let response = await dispatcher.dispatch(request, handshaken: true)
        guard case .routeAssociation(let association) = response.response.result else { return XCTFail("association did not return typed result") }
        XCTAssertEqual(association.state, .associated)
        XCTAssertEqual(association.route.route, route)
        XCTAssertEqual(try repository.all().first?.projectID, projectID.rawValue)
        XCTAssertEqual(try repository.all().first?.projectPath, projectRoot.path)
        let routerStatus = await router.status()
        XCTAssertEqual(routerStatus.routeCount, 0)

        let second = await dispatcher.dispatch(request, handshaken: true)
        guard case .routeAssociation(let repeated) = second.response.result else { return XCTFail("repeated association did not return typed result") }
        XCTAssertEqual(repeated.state, .satisfied)
        XCTAssertEqual(try repository.all().first?.route, route)
    }

    func testRouteAssociationRejectsExistingDifferentProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let first = try await registry.link(path: firstRoot)
        let second = try await registry.link(path: secondRoot)
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "owned.test", target: .staticFiles(documentRoot: firstRoot.path), tls: .disabled)
        try repository.upsert(RouteIntent(route: route, projectID: first.id?.rawValue, projectPath: firstRoot.path))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry, routeRepository: repository)

        let response = await dispatcher.dispatch(IPCRequest(method: .routeProjectAssociationAttach, params: .routeAssociation(.init(routeID: route.id, projectID: second.id!))), handshaken: true)
        XCTAssertEqual(response.response.error?.code, .invalidRequest)
        XCTAssertEqual(try repository.all().first?.projectID, first.id?.rawValue)
    }

    func testUnlinkPreservesDurableRouteAssociationAsOrphanedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await registry.link(path: projectRoot)
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "orphan.test", target: .staticFiles(documentRoot: projectRoot.path), tls: .disabled)
        try repository.upsert(RouteIntent(route: route, projectID: project.id?.rawValue, projectPath: projectRoot.path))

        try await registry.unlink(path: projectRoot)

        let persisted = try repository.all().first
        XCTAssertEqual(persisted?.projectID, project.id?.rawValue)
        XCTAssertEqual(persisted?.projectPath, projectRoot.path)
    }

    func testDispatcherDoesNotConvertRepositoryFailureIntoEmptyRoutes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        try store.execute("DROP TABLE route_intents")
        let registry = ProjectRegistry(store: store)
        let repository = RouteIntentRepository(store: store)

        XCTAssertThrowsError(try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, routeRepository: repository)) { error in
            XCTAssertNotNil(error as? SQLiteStateError)
        }
    }

    func testProjectReconciliationRejectsDiscoveredProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("discovered")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        _ = try await registry.park(path: root)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry)

        let result = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: "discovered", workingDirectory: root.path))), handshaken: true)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
        XCTAssertEqual(result.response.error?.message, "Project reconciliation requires a registered linked project.")
    }

    func testProjectActivationStartsAndThenReusesAnIsolatedMailpit() async throws {
        guard let package = MailpitModule().installedVersions().first else { throw XCTSkip("Mailpit package prerequisite unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { removeTestRoot(root) }
        let configuration = MailpitRuntimeConfiguration(smtpPort: try availablePort(), httpPort: try availablePort())
        try Data("version: 1\nservices:\n  mailpit: true\n".utf8).write(to: projectRoot.appendingPathComponent("vaelen.yml"))
        try Data("MAIL_MAILER=smtp\nMAIL_HOST=127.0.0.1\nMAIL_PORT=\(configuration.smtpPort)\nMAIL_PASSWORD=null\n".utf8).write(to: projectRoot.appendingPathComponent(".env"))

        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("vaelen"))
        let finalPackage = layout.mailpitPackagesDirectoryURL.appendingPathComponent(package.version, isDirectory: true)
        try FileManager.default.createDirectory(at: layout.mailpitPackagesDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: package.packagePath), to: finalPackage)
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod"); chmod.arguments = ["-R", "u+w", finalPackage.path]; try chmod.run(); chmod.waitUntilExit()
        let copiedPackage = MailpitPackage(version: package.version, architecture: package.architecture, packagePath: finalPackage.path, executablePath: finalPackage.appendingPathComponent("mailpit").path, source: package.source, artifactSHA256: package.artifactSHA256, license: package.license, installedAt: package.installedAt)
        try JSONEncoder().encode(copiedPackage).write(to: finalPackage.appendingPathComponent(".vaelen-package.json"), options: .atomic)
        let mailpit = MailpitModule(layout: layout, configuration: configuration)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: mailpit.instanceDatabasePath()).deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mailpit.instanceDatabasePath(), contents: Data())
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        _ = try await registry.link(path: projectRoot)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry, mailpit: mailpit, router: InMemoryRouter(), routeRepository: RouteIntentRepository(store: try SQLiteStateStore(databaseURL: layout.databaseURL.appendingPathExtension("routes"))))

        let planResponse = await dispatcher.dispatch(IPCRequest(method: .projectPlan, params: .projectEnvironment(.init(selector: projectRoot.path, workingDirectory: root.path))), handshaken: true)
        guard case .projectPlan(let planResult) = planResponse.response.result else { return XCTFail("project plan did not return a plan") }
        XCTAssertEqual(planResult.plan.state, .actionable)
        XCTAssertEqual(planResult.plan.operations.first?.id, "mailpit.start")

        let activationResponse = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: projectRoot.path, workingDirectory: root.path))), handshaken: true)
        guard case .projectActivation(let activationResult) = activationResponse.response.result else { return XCTFail("project activation did not return an execution result") }
        XCTAssertEqual(activationResult.execution.state, .succeeded)
        let firstPID = mailpit.status().pid
        XCTAssertEqual(mailpit.status().state, .running)

        let secondResponse = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: projectRoot.path, workingDirectory: root.path))), handshaken: true)
        guard case .projectActivation(let secondResult) = secondResponse.response.result else { return XCTFail("second activation did not return an execution result") }
        XCTAssertEqual(secondResult.execution.state, .succeeded)
        XCTAssertEqual(mailpit.status().pid, firstPID)
        _ = try mailpit.stop()
    }

    private func removeTestRoot(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod"); process.arguments = ["-R", "u+w", root.path]; try? process.run(); process.waitUntilExit(); try? FileManager.default.removeItem(at: root)
    }

    private func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MailpitModuleError.processFailed("socket") }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw MailpitModuleError.processFailed("bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard result == 0 else { throw MailpitModuleError.processFailed("getsockname") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
