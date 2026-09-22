import XCTest
import Darwin
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

private final class DispatcherTrustFake: @unchecked Sendable, TLSTrustBoundary {
    var trusted = false
    func observe(certificateData: Data) throws -> LocalCATrustService.Observation {
        trusted ? .init(trusted: true, canonical: "trust:empty-array", fingerprint: "empty-fingerprint") : .init(trusted: false, canonical: "trust:nil", fingerprint: nil)
    }
    func trust(certificateData: Data) throws { trusted = true }
    func removeTrust(certificateData: Data) throws { trusted = false }
}

final class DispatcherTests: XCTestCase {
    func testProjectRelationshipsTraverseCoreAndRemainIndependentlyDurable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let project = workspace.appendingPathComponent("project", isDirectory: true)
        for path in ["bootstrap", "config", "public"] {
            try FileManager.default.createDirectory(at: project.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("marker".utf8).write(to: project.appendingPathComponent("artisan"))
        try Data("<?php".utf8).write(to: project.appendingPathComponent("public/index.php"))
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state/state.sqlite")
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1),
            registry: ProjectRegistry(store: try SQLiteStateStore(databaseURL: database))
        )

        let emptyParks = await dispatcher.dispatch(IPCRequest(method: .pathList, params: .listProjects(.init())), handshaken: true)
        guard case .parkedPathList(let emptyParkList) = emptyParks.response.result else { return XCTFail("missing parked-root list") }
        XCTAssertTrue(emptyParkList.paths.isEmpty)
        let emptyLinks = await dispatcher.dispatch(IPCRequest(method: .projectLinks, params: .listProjects(.init())), handshaken: true)
        guard case .projectList(let emptyLinkList) = emptyLinks.response.result else { return XCTFail("missing explicit-link list") }
        XCTAssertTrue(emptyLinkList.projects.isEmpty)

        let parked = await dispatcher.dispatch(IPCRequest(method: .pathPark, params: .park(.init(path: workspace.path, workingDirectory: root.path))), handshaken: true)
        guard case .parkedPathMutation(let parkedResult) = parked.response.result else { return XCTFail("park did not return a typed result") }
        XCTAssertTrue(parkedResult.created)
        let repeatedPark = await dispatcher.dispatch(IPCRequest(method: .pathPark, params: .park(.init(path: workspace.appendingPathComponent(".").path, workingDirectory: root.path))), handshaken: true)
        guard case .parkedPathMutation(let repeatedParkResult) = repeatedPark.response.result else { return XCTFail("repeated park did not return a typed result") }
        XCTAssertFalse(repeatedParkResult.created)
        XCTAssertEqual(repeatedParkResult.path?.id, parkedResult.path?.id)

        let linked = await dispatcher.dispatch(IPCRequest(method: .projectLink, params: .link(.init(path: project.path, workingDirectory: root.path))), handshaken: true)
        guard case .projectMutation(let linkedResult) = linked.response.result else { return XCTFail("link did not return a typed result") }
        XCTAssertTrue(linkedResult.created)
        let repeatedLink = await dispatcher.dispatch(IPCRequest(method: .projectLink, params: .link(.init(path: project.appendingPathComponent(".").path, workingDirectory: root.path))), handshaken: true)
        guard case .projectMutation(let repeatedLinkResult) = repeatedLink.response.result else { return XCTFail("repeated link did not return a typed result") }
        XCTAssertFalse(repeatedLinkResult.created)
        XCTAssertEqual(repeatedLinkResult.project?.id, linkedResult.project?.id)

        let recreated = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 2),
            registry: ProjectRegistry(store: try SQLiteStateStore(databaseURL: database))
        )
        let persistedParks = await recreated.dispatch(IPCRequest(method: .pathList, params: .listProjects(.init())), handshaken: true)
        guard case .parkedPathList(let persistedParkList) = persistedParks.response.result else { return XCTFail("recreated Core lost parked roots") }
        XCTAssertEqual(persistedParkList.paths.map(\.path), [workspace.standardizedFileURL.path])
        let persistedLinks = await recreated.dispatch(IPCRequest(method: .projectLinks, params: .listProjects(.init())), handshaken: true)
        guard case .projectList(let persistedLinkList) = persistedLinks.response.result else { return XCTFail("recreated Core lost explicit links") }
        XCTAssertEqual(persistedLinkList.projects.map(\.path), [project.standardizedFileURL.path])
        let presented = await recreated.dispatch(IPCRequest(method: .projectList, params: .listProjects(.init())), handshaken: true)
        guard case .projectList(let presentedList) = presented.response.result else { return XCTFail("combined project list unavailable") }
        XCTAssertEqual(presentedList.projects.count, 1)
        XCTAssertEqual(presentedList.projects.first?.detectedFramework, "Laravel")
        XCTAssertEqual(presentedList.projects.first?.sources, ["explicitLink", "parkedFolder"])

        _ = await recreated.dispatch(IPCRequest(method: .pathUnpark, params: .unpark(.init(path: workspace.path, workingDirectory: root.path))), handshaken: true)
        let linksAfterUnpark = await recreated.dispatch(IPCRequest(method: .projectLinks, params: .listProjects(.init())), handshaken: true)
        guard case .projectList(let linksAfterUnparkResult) = linksAfterUnpark.response.result else { return XCTFail("explicit links unavailable after unpark") }
        XCTAssertEqual(linksAfterUnparkResult.projects.map(\.path), [project.standardizedFileURL.path])

        _ = await recreated.dispatch(IPCRequest(method: .pathPark, params: .park(.init(path: workspace.path, workingDirectory: root.path))), handshaken: true)
        _ = await recreated.dispatch(IPCRequest(method: .projectUnlink, params: .unlink(.init(path: project.path, workingDirectory: root.path))), handshaken: true)
        let parksAfterUnlink = await recreated.dispatch(IPCRequest(method: .pathList, params: .listProjects(.init())), handshaken: true)
        guard case .parkedPathList(let parksAfterUnlinkResult) = parksAfterUnlink.response.result else { return XCTFail("parked roots unavailable after unlink") }
        XCTAssertEqual(parksAfterUnlinkResult.paths.map(\.path), [workspace.standardizedFileURL.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
    }

    func testM13TrustAndUntrustTraverseDispatcherWithParameterlessRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let fake = DispatcherTrustFake()
        let keychain = LocalCAKeychain(tag: "dev.vaelen.ipc.\(UUID().uuidString)")
        defer { try? keychain.removeCAKey() }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let tls = TLSCapability(layout: layout, store: store, keychain: keychain, trustBoundary: fake)
        _ = try await tls.install()
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry, tls: tls)
        let handshake = await dispatcher.dispatch(IPCRequest(method: .handshake, params: .handshake(.init(client: .init(name: "test", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))), handshaken: false)
        XCTAssertTrue(handshake.handshaken)

        let trusted = await dispatcher.dispatch(IPCRequest(method: .tlsTrustLocalCA), handshaken: true)
        guard case .tlsTrust(let trust)? = trusted.response.result else { return XCTFail("missing typed trust response") }
        XCTAssertEqual(trust.result.operation, .confirmed)
        XCTAssertNil(IPCRequest(method: .tlsTrustLocalCA).params)

        let untrusted = await dispatcher.dispatch(IPCRequest(method: .tlsRemoveLocalCATrust), handshaken: true)
        guard case .tlsTrust(let remove)? = untrusted.response.result else { return XCTFail("missing typed untrust response") }
        XCTAssertEqual(remove.result.operation, .removed)
        XCTAssertNil(IPCRequest(method: .tlsRemoveLocalCATrust).params)
    }

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

    func testDispatcherRejectsMalformedTransitionProvenanceAtStartup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        try store.execute("INSERT INTO route_target_transitions (route_id,project_id,previous_route_json,desired_route_json,previous_provider_json,desired_provider_json,previous_socket,desired_socket,state) VALUES ('bad','bad',X'00',X'00',X'00',X'00','a','b','providerPending')")
        let registry = ProjectRegistry(store: store)
        XCTAssertThrowsError(try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, routeRepository: RouteIntentRepository(store: store))) { error in
            XCTAssertEqual(error as? SQLiteStateError, .invalidRecord)
        }
    }

    func testProjectReconciliationRejectsDiscoveredProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("discovered")
        for path in ["bootstrap", "config", "public"] {
            try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("marker".utf8).write(to: projectRoot.appendingPathComponent("artisan"))
        try Data("<?php".utf8).write(to: projectRoot.appendingPathComponent("public/index.php"))
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        _ = try await registry.park(path: root)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry)

        // Precondition: Slice 4 discovery recognizes the parked folder as a discovered (unlinked) project.
        let listed = await dispatcher.dispatch(IPCRequest(method: .projectList, params: .listProjects(.init())), handshaken: true)
        guard case .projectList(let listedResult) = listed.response.result else { return XCTFail("combined project list unavailable") }
        XCTAssertEqual(listedResult.projects.first(where: { $0.name == "discovered" })?.registration, "discovered")

        // Read-only environment remains observable for discovered projects.
        let status = await dispatcher.dispatch(IPCRequest(method: .projectStatus, params: .projectEnvironment(.init(selector: "discovered", workingDirectory: root.path))), handshaken: true)
        XCTAssertNil(status.response.error)

        // Reconciliation stays gated to explicitly linked projects.
        let result = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: "discovered", workingDirectory: root.path))), handshaken: true)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
        XCTAssertEqual(result.response.error?.message, "Project reconciliation requires a registered linked project.")

        let plan = await dispatcher.dispatch(IPCRequest(method: .projectPlan, params: .projectEnvironment(.init(selector: "discovered", workingDirectory: root.path))), handshaken: true)
        XCTAssertEqual(plan.response.error?.code, .invalidRequest)
        XCTAssertEqual(plan.response.error?.message, "Project reconciliation requires a registered linked project.")
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
