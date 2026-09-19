import XCTest
@testable import VaelenCore

final class RoutingTests: XCTestCase {
    func testRouteIntentPersistsAndRemovesAcrossStoreReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = root.appendingPathComponent("state/vaelen.sqlite")
        let route = Route(hostname: "persisted.test", target: .staticFiles(documentRoot: "/tmp/persisted"), tls: .disabled)
        let intent = RouteIntent(route: route, projectID: UUID(), projectPath: "/tmp/persisted")
        do {
            let store = try SQLiteStateStore(databaseURL: database)
            let repository = RouteIntentRepository(store: store)
            try repository.upsert(intent)
        }
        let reopened = try SQLiteStateStore(databaseURL: database)
        let repository = RouteIntentRepository(store: reopened)
        XCTAssertEqual(try repository.all(), [intent])
        try repository.remove(id: route.id)
        XCTAssertTrue(try repository.all().isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    func testFastCGITargetUpdateUsesCompareAndSetAndPersists() throws {
        let (_, repository, root) = try repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let route = Route(hostname: "php.test", target: .fastCGI(socketPath: "/tmp/php-8.4.22.sock", documentRoot: "/tmp/php/public"), tls: .local)
        let intent = RouteIntent(route: route, projectID: UUID(), projectPath: "/tmp/php")
        try repository.upsert(intent)
        let updated = try repository.persistFastCGITargetTransition(id: route.id, projectID: intent.projectID!, expectedSocket: "/tmp/php-8.4.22.sock", desiredSocket: "/tmp/php-8.4.23.sock").intent
        XCTAssertEqual(updated.route.target.fastCGISocket, "/tmp/php-8.4.23.sock")
        XCTAssertEqual(try repository.all().first?.route.target.fastCGISocket, "/tmp/php-8.4.23.sock")
        XCTAssertThrowsError(try repository.persistFastCGITargetTransition(id: route.id, projectID: intent.projectID!, expectedSocket: "/tmp/php-8.4.22.sock", desiredSocket: "/tmp/php-8.4.24.sock")) { error in
            XCTAssertEqual(error as? RouteTargetMutationError, .expectedTargetMismatch)
        }
    }

    func testFastCGITransitionPersistsRouteAndProvenanceAtomically() throws {
        let (_, repository, root) = try repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID()
        let route = Route(hostname: "transition.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/project/public"), tls: .local)
        try repository.upsert(RouteIntent(route: route, projectID: projectID, projectPath: "/tmp/project"))

        let result = try repository.persistFastCGITargetTransition(id: route.id, projectID: projectID, expectedSocket: "/tmp/php-a.sock", desiredSocket: "/tmp/php-b.sock")
        let persisted = try XCTUnwrap(try repository.all().first)
        let transition = try XCTUnwrap(try repository.pendingTransitions().first)
        XCTAssertEqual(persisted.route.target.fastCGISocket, "/tmp/php-b.sock")
        XCTAssertEqual(persisted.route.id, route.id)
        XCTAssertEqual(persisted.projectID, projectID)
        XCTAssertEqual(persisted.projectPath, "/tmp/project")
        XCTAssertEqual(persisted.route.hostname, route.hostname)
        if case .fastCGI(_, let documentRoot) = persisted.route.target {
            XCTAssertEqual(documentRoot, "/tmp/project/public")
        } else {
            XCTFail("target kind changed")
        }
        XCTAssertEqual(persisted.route.tls, route.tls)
        XCTAssertEqual(result.transition, transition)
        XCTAssertEqual(transition.previousSocket, "/tmp/php-a.sock")
        XCTAssertEqual(transition.desiredSocket, "/tmp/php-b.sock")
        XCTAssertEqual(transition.state, .providerPending)
    }

    func testPendingTransitionSurvivesRepositoryReconstruction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = root.appendingPathComponent("state.sqlite")
        let projectID = UUID()
        let route = Route(hostname: "restart.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/project/public"))
        do {
            let store = try SQLiteStateStore(databaseURL: database)
            let repository = RouteIntentRepository(store: store)
            try repository.upsert(RouteIntent(route: route, projectID: projectID, projectPath: "/tmp/project"))
            _ = try repository.persistFastCGITargetTransition(id: route.id, projectID: projectID, expectedSocket: "/tmp/php-a.sock", desiredSocket: "/tmp/php-b.sock")
        }
        let reopened = try SQLiteStateStore(databaseURL: database)
        let repository = RouteIntentRepository(store: reopened)
        let transition = try XCTUnwrap(try repository.pendingTransitions().first)
        XCTAssertEqual(transition.projectID, projectID)
        XCTAssertEqual(transition.previousSocket, "/tmp/php-a.sock")
        XCTAssertEqual(try repository.all().first?.route.target.fastCGISocket, "/tmp/php-b.sock")
        try? FileManager.default.removeItem(at: root)
    }

    func testSchemaFourDatabaseMigratesTransitionTableWithoutLosingRoutes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = root.appendingPathComponent("state.sqlite")
        let route = Route(hostname: "migration.test", target: .staticFiles(documentRoot: "/tmp/migration"))
        do {
            let store = try SQLiteStateStore(databaseURL: database)
            try RouteIntentRepository(store: store).upsert(RouteIntent(route: route))
            try store.execute("DROP TABLE route_target_transitions")
            try store.execute("PRAGMA user_version = 4")
        }
        let reopened = try SQLiteStateStore(databaseURL: database)
        let repository = RouteIntentRepository(store: reopened)
        XCTAssertEqual(try repository.all().first?.route, route)
        XCTAssertTrue(try repository.pendingTransitions().isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    func testFastCGITransitionCASFailureLeavesRouteAndProvenanceUnchanged() throws {
        let (_, repository, root) = try repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID()
        let route = Route(hostname: "cas.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/project/public"))
        try repository.upsert(RouteIntent(route: route, projectID: projectID, projectPath: "/tmp/project"))
        try repository.upsert(RouteIntent(route: Route(id: route.id, hostname: route.hostname, target: .fastCGI(socketPath: "/tmp/php-c.sock", documentRoot: "/tmp/project/public"), tls: route.tls), projectID: projectID, projectPath: "/tmp/project"))

        XCTAssertThrowsError(try repository.persistFastCGITargetTransition(id: route.id, projectID: projectID, expectedSocket: "/tmp/php-a.sock", desiredSocket: "/tmp/php-b.sock")) { error in
            XCTAssertEqual(error as? RouteTargetMutationError, .expectedTargetMismatch)
        }
        XCTAssertEqual(try repository.all().first?.route.target.fastCGISocket, "/tmp/php-c.sock")
        XCTAssertTrue(try repository.pendingTransitions().isEmpty)
    }

    func testTransitionFailureLeavesCurrentRouteAndNoProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let repository = RouteIntentRepository(store: store, targetMutationHook: { throw RouteTargetMutationError.persistenceFailed })
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID()
        let route = Route(hostname: "failure.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/project/public"))
        try repository.upsert(RouteIntent(route: route, projectID: projectID, projectPath: "/tmp/project"))
        XCTAssertThrowsError(try repository.persistFastCGITargetTransition(id: route.id, projectID: projectID, expectedSocket: "/tmp/php-a.sock", desiredSocket: "/tmp/php-b.sock"))
        XCTAssertEqual(try repository.all().first?.route.target.fastCGISocket, "/tmp/php-a.sock")
        XCTAssertTrue(try repository.pendingTransitions().isEmpty)
    }

    func testActiveTransitionIsUniquePerRouteButNotAcrossRoutes() throws {
        let (_, repository, root) = try repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID()
        let first = Route(hostname: "one.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/project/public"))
        let second = Route(hostname: "two.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/project/public"))
        try repository.upsert(RouteIntent(route: first, projectID: projectID, projectPath: "/tmp/project"))
        try repository.upsert(RouteIntent(route: second, projectID: projectID, projectPath: "/tmp/project"))
        _ = try repository.persistFastCGITargetTransition(id: first.id, projectID: projectID, expectedSocket: "/tmp/php-a.sock", desiredSocket: "/tmp/php-b.sock")
        XCTAssertThrowsError(try repository.persistFastCGITargetTransition(id: first.id, projectID: projectID, expectedSocket: "/tmp/php-b.sock", desiredSocket: "/tmp/php-c.sock")) { error in
            XCTAssertEqual(error as? RouteTargetMutationError, .transitionAlreadyExists)
        }
        _ = try repository.persistFastCGITargetTransition(id: second.id, projectID: projectID, expectedSocket: "/tmp/php-a.sock", desiredSocket: "/tmp/php-c.sock")
        XCTAssertEqual(try repository.pendingTransitions().count, 2)
    }

    func testCompletedTransitionIsClearedOnlyForExactDesiredRoute() throws {
        let (_, repository, root) = try repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID()
        let route = Route(hostname: "complete.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/project/public"), tls: .local)
        try repository.upsert(RouteIntent(route: route, projectID: projectID, projectPath: "/tmp/project"))
        let transition = try repository.persistFastCGITargetTransition(id: route.id, projectID: projectID, expectedSocket: "/tmp/php-a.sock", desiredSocket: "/tmp/php-b.sock").transition
        XCTAssertThrowsError(try repository.completeFastCGITargetTransition(id: route.id, projectID: projectID, desiredRoute: transition.previousRoute))
        XCTAssertEqual(try repository.pendingTransitions(), [transition])
        try repository.completeFastCGITargetTransition(id: route.id, projectID: projectID, desiredRoute: transition.desiredRoute)
        XCTAssertTrue(try repository.pendingTransitions().isEmpty)
    }

    func testMalformedTransitionRepositoryFailsClosed() throws {
        let (store, repository, root) = try repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.execute("INSERT INTO route_target_transitions (route_id,project_id,previous_route_json,desired_route_json,previous_provider_json,desired_provider_json,previous_socket,desired_socket,state) VALUES ('bad','bad',X'00',X'00',X'00',X'00','a','b','providerPending')")
        XCTAssertThrowsError(try repository.pendingTransitions()) { error in
            XCTAssertEqual(error as? SQLiteStateError, .invalidRecord)
        }
    }

    func testReconcileIsAtomicWhenDesiredRoutesAreInvalid() async throws {
        let router = InMemoryRouter()
        try await router.start()
        let valid = Route(hostname: "app.test", target: .staticFiles(documentRoot: "/tmp/app"))
        try await router.reconcile(routes: [valid])

        let invalid = Route(hostname: "bad host", target: .staticFiles(documentRoot: "/tmp/bad"))
        do {
            try await router.reconcile(routes: [invalid])
            XCTFail("expected invalid route to fail")
        } catch {
            XCTAssertEqual(error as? RouterError, .invalidRoute("invalid hostname: bad host"))
        }
        let status = await router.status()
        XCTAssertEqual(status.routeCount, 1)
    }

    func testRouteLifecycleAndDuplicateHostnameProtection() async throws {
        let router = InMemoryRouter()
        try await router.start()
        let route = Route(hostname: "app.test", target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: "/tmp/app/public"))
        try await router.addRoute(route)
        do {
            try await router.addRoute(Route(hostname: "app.test", target: .staticFiles(documentRoot: "/tmp/other")))
            XCTFail("expected duplicate hostname to fail")
        } catch {
            XCTAssertEqual(error as? RouterError, .duplicateHostname("app.test"))
        }
        try await router.updateRoute(Route(id: route.id, hostname: "updated.test", target: route.target, tls: .disabled))
        var status = await router.status()
        XCTAssertEqual(status.routeCount, 1)
        try await router.removeRoute(id: route.id)
        status = await router.status()
        XCTAssertEqual(status.routeCount, 0)
    }

    func testRouterMustBeRunningForMutation() async {
        let router = InMemoryRouter()
        let route = Route(hostname: "app.test", target: .staticFiles(documentRoot: "/tmp/app"))
        do {
            try await router.addRoute(route)
            XCTFail("expected stopped router mutation to fail")
        } catch let error as RouterError {
            XCTAssertEqual(error, .notRunning)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMalformedRouteJSONFailsClosed() throws {
        let (store, repository, root) = try repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let rowID = UUID()
        try store.execute("INSERT INTO route_intents (id,route_json) VALUES ('\(rowID.uuidString)', X'7B6E6F7420726F7574657D')")

        XCTAssertThrowsError(try repository.all()) { error in
            XCTAssertEqual(error as? SQLiteStateError, .invalidRecord)
        }
    }

    func testInvalidRouteModelFailsClosed() throws {
        let (store, repository, root) = try repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let route = Route(hostname: "not valid", target: .staticFiles(documentRoot: "/tmp/root"), tls: .disabled)
        try insertRouteJSON(route, rowID: route.id.rawValue, into: store)

        XCTAssertThrowsError(try repository.all()) { error in
            XCTAssertEqual(error as? SQLiteStateError, .invalidRecord)
        }
    }

    func testDatabaseRowIDMustMatchEmbeddedRouteID() throws {
        let (store, repository, root) = try repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let route = Route(hostname: "mismatch.test", target: .staticFiles(documentRoot: "/tmp/root"), tls: .disabled)
        try insertRouteJSON(route, rowID: UUID(), into: store)

        XCTAssertThrowsError(try repository.all()) { error in
            XCTAssertEqual(error as? SQLiteStateError, .invalidRecord)
        }
    }

    func testInvalidNonNullProjectUUIDFailsClosed() throws {
        let (store, repository, root) = try repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let route = Route(hostname: "invalid-project.test", target: .staticFiles(documentRoot: "/tmp/root"), tls: .disabled)
        try insertRouteJSON(route, rowID: route.id.rawValue, projectID: "not-a-uuid", into: store)

        XCTAssertThrowsError(try repository.all()) { error in
            XCTAssertEqual(error as? SQLiteStateError, .invalidRecord)
        }
    }

    func testDuplicateEmbeddedRouteIDsFailClosedWithoutDictionaryTrap() throws {
        let (store, repository, root) = try repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let route = Route(hostname: "duplicate-a.test", target: .staticFiles(documentRoot: "/tmp/a"), tls: .disabled)
        try insertRouteJSON(route, rowID: route.id.rawValue, into: store)
        try insertRouteJSON(route, rowID: UUID(), into: store)

        XCTAssertThrowsError(try repository.all()) { error in
            XCTAssertEqual(error as? SQLiteStateError, .invalidRecord)
        }
    }

    private func repositoryFixture() throws -> (SQLiteStateStore, RouteIntentRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        return (store, RouteIntentRepository(store: store), root)
    }

    private func insertRouteJSON(_ route: Route, rowID: UUID, projectID: String? = nil, into store: SQLiteStateStore) throws {
        let data = try JSONEncoder().encode(route)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let sql: String
        if let projectID {
            sql = "INSERT INTO route_intents (id,route_json,project_id) VALUES ('\(rowID.uuidString)', X'\(hex)', '\(projectID)')"
        } else {
            sql = "INSERT INTO route_intents (id,route_json) VALUES ('\(rowID.uuidString)', X'\(hex)')"
        }
        try store.execute(sql)
    }
}
