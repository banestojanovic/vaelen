import XCTest
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

private actor AdoptionStatusPausingRouter: Router {
    private let pauseAt: Int
    private var statusCalls = 0
    private var reachedSecondStatus = false
    private var reachedContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(pauseAt: Int = 2) { self.pauseAt = pauseAt }

    func start() async throws {}
    func stop() async throws {}
    func status() async -> RouterStatus {
        statusCalls += 1
        if statusCalls == pauseAt {
            reachedSecondStatus = true
            reachedContinuation?.resume()
            await withCheckedContinuation { resumeContinuation = $0 }
        }
        return RouterStatus(provider: "adoption-test", state: .stopped, health: .unknown, routeCount: 0)
    }
    func health() async -> RouterHealth { .unknown }
    func reconcile(routes: [Route]) async throws {}
    func addRoute(_ route: Route) async throws {}
    func updateRoute(_ route: Route) async throws {}
    func removeRoute(id: RouteID) async throws {}
    func observedRoutes() async throws -> [Route] { [] }

    func waitUntilPausedStatus() async {
        if reachedSecondStatus { return }
        await withCheckedContinuation { reachedContinuation = $0 }
    }

    func resumeSecondStatus() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

final class ProjectAdoptionApplyTests: XCTestCase {
    func testRouteCreationChoiceRejectsExistingHostWithoutMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-create-conflict-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "create-conflict-app")
        let routes = RouteIntentRepository(store: store)
        let existing = Route(hostname: "shop.test", target: .staticFiles(documentRoot: projectRoot.path), tls: .disabled)
        try routes.upsert(RouteIntent(route: existing))
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, routeRepository: routes, serviceInstances: ServiceInstanceRepository(store: store))
        let preview = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionPreview, params: .projectAdoptionPreview(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path))), handshaken: true).response
        guard case .projectAdoptionPreview(let review) = preview.result else { return XCTFail("expected adoption review") }
        let spec = try ProjectEnvironmentSpec(version: 2, web: ProjectWebRequirement(host: "shop.test", documentRoot: "public", secure: false, createRoute: true))
        let request = ProjectAdoptionApplyRequest(confirmation: review.confirmation, selector: project.id?.rawValue.uuidString, workingDirectory: root.path, spec: spec, createRoute: true, webChoiceConfirmed: true)
        let response = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response
        XCTAssertNil(response.result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("vaelen.yml").path))
        XCTAssertEqual(try routes.all(), [RouteIntent(route: existing)])
    }

    func testRouteCreationChoiceWritesOnlyReviewedManifestIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-create-route-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "create-route-app")
        let routes = RouteIntentRepository(store: store)
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, routeRepository: routes, serviceInstances: ServiceInstanceRepository(store: store))
        let preview = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionPreview, params: .projectAdoptionPreview(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path))), handshaken: true).response
        guard case .projectAdoptionPreview(let review) = preview.result else { return XCTFail("expected adoption review") }
        XCTAssertTrue(review.preview.unresolvedDecisions.contains { $0.contains("--create-route") })
        let spec = try ProjectEnvironmentSpec(version: 2, web: ProjectWebRequirement(host: "shop.test", documentRoot: "public", secure: false, createRoute: true))
        let request = ProjectAdoptionApplyRequest(confirmation: review.confirmation, selector: project.id?.rawValue.uuidString, workingDirectory: root.path, spec: spec, createRoute: true, webChoiceConfirmed: true)
        let response = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response
        guard case .projectAdoptionApply = response.result else { return XCTFail("expected route intent adoption, got \(String(describing: response.error))") }
        XCTAssertTrue(try routes.all().isEmpty)
        XCTAssertTrue(String(decoding: try Data(contentsOf: projectRoot.appendingPathComponent("vaelen.yml")), as: UTF8.self).contains("shop.test"))
    }

    func testProjectDownIsIdempotentWhenNoClaimsExist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-down-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "down-app")
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, serviceInstances: ServiceInstanceRepository(store: store))
        let request = IPCRequest(method: .projectDown, params: .projectEnvironment(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path)))

        for _ in 0..<2 {
            let response = await dispatcher.dispatch(request, handshaken: true).response
            guard case .projectActivation(let result) = response.result else { return XCTFail("expected idempotent project down result") }
            XCTAssertEqual(result.execution.state, .succeeded)
            XCTAssertEqual(result.execution.operations.first?.state, .satisfied)
        }
    }

    func testProjectDownRetainsManualOwnerAndReleasesOnlyProjectClaim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-down-owner-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "down-owner-app")
        let repository = ServiceInstanceRepository(store: store)
        let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("database"), kind: .mysql, instance: ProjectInstanceName("shared"))
        let record = try ServiceInstanceRecord(id: .init(kind: .mysql, name: binding.instance), packageIdentifier: "vendor/mysql@8.4.1", endpoint: .mysql(port: 13307), dataDirectory: root.appendingPathComponent("mysql-data").path)
        try repository.saveManuallyClaimedInstance(record)
        try repository.addProjectClaim(binding, for: try XCTUnwrap(project.id))
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, serviceInstances: repository)
        let request = IPCRequest(method: .projectDown, params: .projectEnvironment(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path)))

        let response = await dispatcher.dispatch(request, handshaken: true).response
        guard case .projectActivation(let result) = response.result else { return XCTFail("expected project down result") }
        XCTAssertEqual(result.execution.state, .succeeded)
        XCTAssertEqual(try repository.claims(for: record.id), [.manual(instance: record.id)])
        XCTAssertTrue(result.execution.operations.first?.message.contains("left running") == true)
    }

    func testPreviewApplyCreatesManifestPreservesEnvAndRejectsRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = projectRoot.appendingPathComponent(".env")
        let envBytes = Data("DB_PASSWORD=private-value\n".utf8)
        try envBytes.write(to: env)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "adoption-app")
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, serviceInstances: ServiceInstanceRepository(store: store))
        let preview = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionPreview, params: .projectAdoptionPreview(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path))), handshaken: true).response
        guard case .projectAdoptionPreview(let review) = preview.result else { return XCTFail("expected adoption review") }
        let spec = try ProjectEnvironmentSpec(version: 2, php: try PHPRequirement(value: "8.3"))
        let request = ProjectAdoptionApplyRequest(confirmation: review.confirmation, selector: project.id?.rawValue.uuidString, workingDirectory: root.path, spec: spec, webChoiceConfirmed: true)
        let applied = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response
        guard case .projectAdoptionApply(let result) = applied.result else { return XCTFail("expected adoption apply, got \(String(describing: applied.error))") }
        XCTAssertTrue(result.manifestCreated)
        XCTAssertEqual(try Data(contentsOf: env), envBytes)
        let manifestBytes = try Data(contentsOf: projectRoot.appendingPathComponent("vaelen.yml"))
        XCTAssertTrue(String(decoding: manifestBytes, as: UTF8.self).contains("8.3"))
        let retried = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response
        XCTAssertNil(retried.result)
        XCTAssertEqual(try Data(contentsOf: projectRoot.appendingPathComponent("vaelen.yml")), manifestBytes)
    }

    func testStaleEvidenceAndUnsupportedRouteChoiceAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-stale-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "stale-app")
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, serviceInstances: ServiceInstanceRepository(store: store))
        let preview = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionPreview, params: .projectAdoptionPreview(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path))), handshaken: true).response
        guard case .projectAdoptionPreview(let review) = preview.result else { return XCTFail("expected adoption review") }
        try Data("{}".utf8).write(to: projectRoot.appendingPathComponent("package.json"))
        let appearedManifest = Data("version: 2\nnode: 22\n".utf8)
        try appearedManifest.write(to: projectRoot.appendingPathComponent("vaelen.yml"))
        let spec = try ProjectEnvironmentSpec(version: 2)
        let request = ProjectAdoptionApplyRequest(confirmation: review.confirmation, selector: project.id?.rawValue.uuidString, workingDirectory: root.path, spec: spec, selectedRouteIDs: [RouteID()], webChoiceConfirmed: true)
        let response = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response
        XCTAssertNil(response.result)
        XCTAssertEqual(try Data(contentsOf: projectRoot.appendingPathComponent("vaelen.yml")), appearedManifest)
    }

    func testExistingManifestIsNeverOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-existing-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = projectRoot.appendingPathComponent("vaelen.yml")
        let original = Data("version: 2\nphp: 8.2\n".utf8)
        try original.write(to: manifest)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "existing-app")
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, serviceInstances: ServiceInstanceRepository(store: store))
        let preview = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionPreview, params: .projectAdoptionPreview(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path))), handshaken: true).response
        guard case .projectAdoptionPreview(let review) = preview.result else { return XCTFail("expected adoption review") }
        let spec = try ProjectEnvironmentSpec(version: 2)
        let request = ProjectAdoptionApplyRequest(confirmation: review.confirmation, selector: project.id?.rawValue.uuidString, workingDirectory: root.path, spec: spec, webChoiceConfirmed: true)
        let response = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response
        XCTAssertNil(response.result)
        XCTAssertEqual(try Data(contentsOf: manifest), original)
    }

    func testServiceBindingMustMatchExactCatalogInstanceAndPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-catalog-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "catalog-app")
        let repository = ServiceInstanceRepository(store: store)
        let name = try ProjectInstanceName("primary")
        let record = try ServiceInstanceRecord(id: .init(kind: .mysql, name: name), packageIdentifier: "vendor/mysql@8.4.1", endpoint: .mysql(port: 3307), dataDirectory: root.appendingPathComponent("mysql-data").path)
        try repository.saveInstance(record)
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, serviceInstances: repository)
        let preview = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionPreview, params: .projectAdoptionPreview(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path))), handshaken: true).response
        guard case .projectAdoptionPreview(let review) = preview.result else { return XCTFail("expected adoption review") }
        let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("database"), kind: .mysql, instance: name, version: "8.0.0")
        let spec = try ProjectEnvironmentSpec(version: 2, services: [binding])
        let request = ProjectAdoptionApplyRequest(confirmation: review.confirmation, selector: project.id?.rawValue.uuidString, workingDirectory: root.path, spec: spec, webChoiceConfirmed: true)
        let response = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response
        XCTAssertNil(response.result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("vaelen.yml").path))
    }

    func testRouteOwnedByAnotherProjectCannotBeClaimed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-route-owner-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "route-owner-app")
        let routeRepository = RouteIntentRepository(store: store)
        let route = Route(hostname: "app.test", target: .staticFiles(documentRoot: "public"), tls: .local)
        let otherOwner = UUID()
        try routeRepository.upsert(RouteIntent(route: route, projectID: otherOwner, projectPath: projectRoot.path))
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, routeRepository: routeRepository, serviceInstances: ServiceInstanceRepository(store: store))
        let preview = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionPreview, params: .projectAdoptionPreview(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path))), handshaken: true).response
        guard case .projectAdoptionPreview(let review) = preview.result else { return XCTFail("expected adoption review") }
        XCTAssertTrue(review.preview.hasRouteOwnershipConflicts)
        let spec = try ProjectEnvironmentSpec(version: 2)
        let request = ProjectAdoptionApplyRequest(confirmation: review.confirmation, selector: project.id?.rawValue.uuidString, workingDirectory: root.path, spec: spec, selectedRouteIDs: [route.id], webChoiceConfirmed: true)
        let response = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response
        XCTAssertNil(response.result)
        XCTAssertEqual(try routeRepository.all().first?.projectID, otherOwner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("vaelen.yml").path))
    }

    func testAbsoluteRouteDocumentRootIsReviewedRelativeToProjectAndOwnershipStaysPending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-absolute-root-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("public"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "absolute-root-app")
        let routeRepository = RouteIntentRepository(store: store)
        let route = Route(hostname: "app.test", target: .staticFiles(documentRoot: projectRoot.appendingPathComponent("public").path), tls: .local)
        try routeRepository.upsert(RouteIntent(route: route, projectID: project.id?.rawValue, projectPath: projectRoot.path))
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, routeRepository: routeRepository, serviceInstances: ServiceInstanceRepository(store: store))
        let preview = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionPreview, params: .projectAdoptionPreview(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path))), handshaken: true).response
        guard case .projectAdoptionPreview(let review) = preview.result else { return XCTFail("expected adoption review") }
        let spec = try ProjectEnvironmentSpec(version: 2, web: ProjectWebRequirement(host: "app.test", documentRoot: "public", secure: true))
        let request = ProjectAdoptionApplyRequest(confirmation: review.confirmation, selector: project.id?.rawValue.uuidString, workingDirectory: root.path, spec: spec, selectedRouteIDs: [route.id], webChoiceConfirmed: true)
        let response = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response
        guard case .projectAdoptionApply(let result) = response.result else { return XCTFail("expected apply success, got \(String(describing: response.error))") }
        XCTAssertEqual(result.selectedRoutes, [route.id])
        XCTAssertEqual(try routeRepository.all().first?.projectID, project.id?.rawValue)
        XCTAssertEqual(try routeRepository.all().first?.projectPath, projectRoot.path)
    }

    func testRouteDocumentRootOutsideProjectIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-outside-root-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "outside-root-app")
        let routeRepository = RouteIntentRepository(store: store)
        let route = Route(hostname: "app.test", target: .staticFiles(documentRoot: outside.path), tls: .local)
        try routeRepository.upsert(RouteIntent(route: route, projectID: project.id?.rawValue, projectPath: projectRoot.path))
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, routeRepository: routeRepository, serviceInstances: ServiceInstanceRepository(store: store))
        let preview = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionPreview, params: .projectAdoptionPreview(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path))), handshaken: true).response
        guard case .projectAdoptionPreview(let review) = preview.result else { return XCTFail("expected adoption review") }
        let spec = try ProjectEnvironmentSpec(version: 2, web: ProjectWebRequirement(host: "app.test", documentRoot: "public", secure: true))
        let request = ProjectAdoptionApplyRequest(confirmation: review.confirmation, selector: project.id?.rawValue.uuidString, workingDirectory: root.path, spec: spec, selectedRouteIDs: [route.id], webChoiceConfirmed: true)
        let response = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response
        XCTAssertNil(response.result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("vaelen.yml").path))
    }

    func testRouteEvidenceChangedWhileApplyAwaitsReportIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-route-race-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "route-race-app")
        let routeRepository = RouteIntentRepository(store: store)
        let route = Route(hostname: "app.test", target: .staticFiles(documentRoot: "public"), tls: .local)
        try routeRepository.upsert(RouteIntent(route: route, projectID: project.id?.rawValue, projectPath: projectRoot.path))
        let router = AdoptionStatusPausingRouter()
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, router: router, routeRepository: routeRepository, serviceInstances: ServiceInstanceRepository(store: store))
        let preview = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionPreview, params: .projectAdoptionPreview(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path))), handshaken: true).response
        guard case .projectAdoptionPreview(let review) = preview.result else { return XCTFail("expected adoption review") }
        let spec = try ProjectEnvironmentSpec(version: 2)
        let request = ProjectAdoptionApplyRequest(confirmation: review.confirmation, selector: project.id?.rawValue.uuidString, workingDirectory: root.path, spec: spec, webChoiceConfirmed: true)
        let applying = Task { await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response }
        await router.waitUntilPausedStatus()
        let changed = Route(id: route.id, hostname: "changed.test", target: route.target, tls: route.tls)
        try routeRepository.upsert(RouteIntent(route: changed, projectID: project.id?.rawValue, projectPath: projectRoot.path))
        await router.resumeSecondStatus()
        let response = await applying.value
        XCTAssertNil(response.result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("vaelen.yml").path))
    }

    func testRouteTargetChangedAfterPlanPreservesUnownedRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-route-target-race-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("public"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("bootstrap"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("config"), withIntermediateDirectories: true)
        try Data("<?php echo 'ok';".utf8).write(to: projectRoot.appendingPathComponent("public/index.php"))
        try Data("{\"require\":{\"laravel/framework\":\"^11.0\"}}".utf8).write(to: projectRoot.appendingPathComponent("composer.json"))
        try Data("<?php // artisan".utf8).write(to: projectRoot.appendingPathComponent("artisan"))
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot, name: "route-target-race-app")
        let routeRepository = RouteIntentRepository(store: store)
        let route = Route(hostname: "app.test", target: .staticFiles(documentRoot: projectRoot.appendingPathComponent("public").path), tls: .local)
        try routeRepository.upsert(RouteIntent(route: route))
        let router = AdoptionStatusPausingRouter(pauseAt: 3)
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, router: router, routeRepository: routeRepository, serviceInstances: ServiceInstanceRepository(store: store))
        let applying = Task { await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: project.id?.rawValue.uuidString, workingDirectory: root.path))), handshaken: true).response }
        await router.waitUntilPausedStatus()
        let changed = Route(id: route.id, hostname: route.hostname, target: .staticFiles(documentRoot: "elsewhere"), tls: .disabled)
        try routeRepository.upsert(RouteIntent(route: changed))
        await router.resumeSecondStatus()
        let response = await applying.value
        guard case .projectActivation(let result) = response.result else { return XCTFail("expected project activation result") }
        XCTAssertNotEqual(result.execution.state, .succeeded)
        let persisted = try XCTUnwrap(routeRepository.all().first)
        XCTAssertEqual(persisted.route, changed)
        XCTAssertNil(persisted.projectID)
    }

    func testExactCatalogPackageIdentifiersAreAcceptedForPostgreSQLAndValkey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-exact-packages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let repository = ServiceInstanceRepository(store: store)
        let packages: [(ProjectServiceKind, String, ServiceInstanceEndpoint)] = [
            (.postgresql, "postgresql-18.6", try .postgresql(port: 15432)),
            (.valkey, "valkey-9.1.2", try .valkey(port: 16379))
        ]

        for (kind, packageIdentifier, endpoint) in packages {
            let projectRoot = root.appendingPathComponent("\(kind.rawValue)-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let project = try await registry.link(path: projectRoot, name: "\(kind.rawValue)-adoption")
            let name = try ProjectInstanceName("primary")
            let record = try ServiceInstanceRecord(id: .init(kind: kind, name: name), packageIdentifier: packageIdentifier, endpoint: endpoint, dataDirectory: root.appendingPathComponent("\(kind.rawValue)-data").path)
            try repository.saveInstance(record)
            let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, serviceInstances: repository)
            let preview = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionPreview, params: .projectAdoptionPreview(.init(selector: project.id?.rawValue.uuidString, workingDirectory: projectRoot.path))), handshaken: true).response
            guard case .projectAdoptionPreview(let review) = preview.result else { return XCTFail("expected \(kind.rawValue) adoption review") }
            let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("primary"), kind: kind, instance: name, version: packageIdentifier)
            let spec = try ProjectEnvironmentSpec(version: 2, services: [binding])
            let request = ProjectAdoptionApplyRequest(confirmation: review.confirmation, selector: project.id?.rawValue.uuidString, workingDirectory: projectRoot.path, spec: spec, webChoiceConfirmed: true)
            let response = await dispatcher.dispatch(IPCRequest(method: .projectAdoptionApply, params: .projectAdoptionApply(request)), handshaken: true).response
            guard case .projectAdoptionApply = response.result else { return XCTFail("expected exact \(kind.rawValue) package binding to apply, got \(String(describing: response.error))") }
        }
    }
}
