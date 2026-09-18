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
}
