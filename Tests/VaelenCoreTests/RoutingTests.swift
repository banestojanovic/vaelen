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
