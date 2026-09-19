import XCTest
@testable import VaelenCore

final class RouteTargetTransitionTests: XCTestCase {
    private actor ControlledRouter: Router {
        private var routes: [RouteID: Route]
        private var failReconcile: Bool
        private var reconcileCount = 0

        init(initial: [Route], failReconcile: Bool = false) {
            routes = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })
            self.failReconcile = failReconcile
        }

        func start() async throws {}
        func stop() async throws {}
        func status() async -> RouterStatus { RouterStatus(provider: "isolated", state: .running, health: .healthy, routeCount: routes.count) }
        func health() async -> RouterHealth { .healthy }
        func setFailure(_ value: Bool) { failReconcile = value }
        func partiallyApply(_ route: Route) throws {
            routes[route.id] = route
            reconcileCount += 1
            throw RouterError.invalidRoute("injected partial provider failure")
        }
        func reconcile(routes desiredRoutes: [Route]) async throws {
            reconcileCount += 1
            if failReconcile { throw RouterError.invalidRoute("injected provider failure") }
            self.routes = Dictionary(uniqueKeysWithValues: desiredRoutes.map { ($0.id, $0) })
        }
        func addRoute(_ route: Route) async throws { try await reconcile(routes: Array(routes.values) + [route]) }
        func updateRoute(_ route: Route) async throws { try await reconcile(routes: routes.values.filter { $0.id != route.id } + [route]) }
        func removeRoute(id: RouteID) async throws { routes.removeValue(forKey: id) }
        func observedRoutes() async throws -> [Route] { Array(routes.values) }
        func applyCount() -> Int { reconcileCount }
    }

    private func fixture() throws -> (URL, SQLiteStateStore, RouteIntentRepository, UUID, Route, Route) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let repository = RouteIntentRepository(store: store)
        let projectID = UUID()
        let previous = Route(hostname: "provider.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/project/public"), tls: .local)
        let desired = Route(id: previous.id, hostname: previous.hostname, target: .fastCGI(socketPath: "/tmp/php-b.sock", documentRoot: "/tmp/project/public"), tls: .local)
        try repository.upsert(RouteIntent(route: previous, projectID: projectID, projectPath: "/tmp/project"))
        return (root, store, repository, projectID, previous, desired)
    }

    func testProviderFailureAfterAtomicPersistenceRetainsPendingTransition() async throws {
        let (root, _, repository, projectID, previous, desired) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let router = ControlledRouter(initial: [previous], failReconcile: true)
        let persisted = try repository.persistFastCGITargetTransition(id: previous.id, projectID: projectID, expectedSocket: previous.target.fastCGISocket!, desiredSocket: desired.target.fastCGISocket!)

        do {
            try await router.reconcile(routes: [persisted.intent.route])
            XCTFail("expected provider failure")
        } catch let error as RouterError {
            XCTAssertEqual(error, .invalidRoute("injected provider failure"))
        }
        XCTAssertEqual(try repository.all().first?.route, desired)
        XCTAssertEqual(try repository.pendingTransitions(), [persisted.transition])
        let observedRoutes = try await router.observedRoutes()
        let applyCount = await router.applyCount()
        XCTAssertEqual(observedRoutes, [previous])
        XCTAssertEqual(applyCount, 1)

        let reopened = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let reconstructed = RouteIntentRepository(store: reopened)
        XCTAssertEqual(try reconstructed.pendingTransitions(), [persisted.transition])
    }

    func testProviderSuccessThenCrashBeforeCompletionFinalizesWithoutSecondApply() async throws {
        let (root, _, repository, projectID, previous, desired) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let router = ControlledRouter(initial: [previous])
        let persisted = try repository.persistFastCGITargetTransition(id: previous.id, projectID: projectID, expectedSocket: previous.target.fastCGISocket!, desiredSocket: desired.target.fastCGISocket!)
        try await router.reconcile(routes: [persisted.intent.route])
        let appliedRoutes = try await router.observedRoutes()
        XCTAssertEqual(appliedRoutes, [desired])

        let reopened = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let reconstructed = RouteIntentRepository(store: reopened)
        XCTAssertEqual(try reconstructed.pendingTransitions(), [persisted.transition])
        try reconstructed.completeFastCGITargetTransition(id: desired.id, projectID: projectID, desiredRoute: desired)
        XCTAssertTrue(try reconstructed.pendingTransitions().isEmpty)
        let applyCount = await router.applyCount()
        let finalRoutes = try await router.observedRoutes()
        XCTAssertEqual(applyCount, 1)
        XCTAssertEqual(finalRoutes, [desired])
    }

    func testProviderFailureDoesNotCreateSecondTransitionOnRetry() async throws {
        let (root, _, repository, projectID, previous, desired) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let router = ControlledRouter(initial: [previous], failReconcile: true)
        let first = try repository.persistFastCGITargetTransition(id: previous.id, projectID: projectID, expectedSocket: previous.target.fastCGISocket!, desiredSocket: desired.target.fastCGISocket!)
        do {
            try await router.reconcile(routes: [first.intent.route])
            XCTFail("expected provider failure")
        } catch {
            // The durable transition is intentionally retained for retry.
        }
        XCTAssertThrowsError(try repository.persistFastCGITargetTransition(id: desired.id, projectID: projectID, expectedSocket: desired.target.fastCGISocket!, desiredSocket: "/tmp/php-c.sock")) { error in
            XCTAssertEqual(error as? RouteTargetMutationError, .transitionAlreadyExists)
        }
        XCTAssertEqual(try repository.pendingTransitions(), [first.transition])
    }

    func testProviderCannotApplyWhenDurableTransitionTransactionFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let projectID = UUID()
        let previous = Route(hostname: "transaction.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/project/public"))
        let desired = Route(id: previous.id, hostname: previous.hostname, target: .fastCGI(socketPath: "/tmp/php-b.sock", documentRoot: "/tmp/project/public"))
        let repository = RouteIntentRepository(store: store, targetMutationHook: { throw RouteTargetMutationError.persistenceFailed })
        try RouteIntentRepository(store: store).upsert(RouteIntent(route: previous, projectID: projectID, projectPath: "/tmp/project"))
        let router = ControlledRouter(initial: [previous])

        XCTAssertThrowsError(try repository.persistFastCGITargetTransition(id: previous.id, projectID: projectID, expectedSocket: previous.target.fastCGISocket!, desiredSocket: desired.target.fastCGISocket!))
        let applyCount = await router.applyCount()
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(try RouteIntentRepository(store: store).all().first?.route, previous)
        XCTAssertTrue(try RouteIntentRepository(store: store).pendingTransitions().isEmpty)
        let observed = try await router.observedRoutes()
        XCTAssertEqual(observed, [previous])
    }

    func testRetryAppliesAllRoutesAndPreservesUnrelatedRoute() async throws {
        let (root, _, repository, projectID, previous, desired) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = Route(hostname: "unrelated.test", target: .staticFiles(documentRoot: "/tmp/unrelated/public"))
        try repository.upsert(RouteIntent(route: unrelated))
        let router = ControlledRouter(initial: [previous, unrelated], failReconcile: true)
        let persisted = try repository.persistFastCGITargetTransition(id: previous.id, projectID: projectID, expectedSocket: previous.target.fastCGISocket!, desiredSocket: desired.target.fastCGISocket!)

        do {
            try await router.reconcile(routes: [persisted.intent.route, unrelated])
            XCTFail("expected provider failure")
        } catch {
            // The provider failed before changing its existing route set.
        }
        await router.setFailure(false)
        try await router.reconcile(routes: [persisted.intent.route, unrelated])

        let observed = try await router.observedRoutes()
        XCTAssertEqual(observed.sorted { $0.id.description < $1.id.description }, [desired, unrelated].sorted { $0.id.description < $1.id.description })
        try repository.completeFastCGITargetTransition(id: desired.id, projectID: projectID, desiredRoute: desired)
        XCTAssertTrue(try repository.pendingTransitions().isEmpty)
    }

    func testCompletionBindsExactProjectAndRouteIdentity() throws {
        let (root, _, repository, projectID, previous, desired) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transition = try repository.persistFastCGITargetTransition(id: previous.id, projectID: projectID, expectedSocket: previous.target.fastCGISocket!, desiredSocket: desired.target.fastCGISocket!).transition

        XCTAssertThrowsError(try repository.completeFastCGITargetTransition(id: transition.routeID, projectID: UUID(), desiredRoute: transition.desiredRoute))
        XCTAssertThrowsError(try repository.completeFastCGITargetTransition(id: RouteID(), projectID: projectID, desiredRoute: transition.desiredRoute))
        XCTAssertThrowsError(try repository.completeFastCGITargetTransition(id: transition.routeID, projectID: projectID, desiredRoute: Route(id: desired.id, hostname: desired.hostname, target: .fastCGI(socketPath: "/tmp/php-c.sock", documentRoot: "/tmp/project/public"), tls: desired.tls)))
        XCTAssertEqual(try repository.pendingTransitions(), [transition])
        try repository.completeFastCGITargetTransition(id: transition.routeID, projectID: projectID, desiredRoute: transition.desiredRoute)
        XCTAssertTrue(try repository.pendingTransitions().isEmpty)
    }

    func testSatisfiedRouteTargetIsStrictNoOp() async throws {
        let (root, _, repository, projectID, previous, desired) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try repository.upsert(RouteIntent(route: desired, projectID: projectID, projectPath: "/tmp/project"))
        let router = ControlledRouter(initial: [desired])
        let beforeIntent = try repository.all()
        let beforeTransitions = try repository.pendingTransitions()

        XCTAssertEqual(try repository.all().first?.route, desired)
        XCTAssertEqual(try repository.pendingTransitions(), beforeTransitions)
        XCTAssertEqual(try repository.all(), beforeIntent)
        let applyCount = await router.applyCount()
        let observed = try await router.observedRoutes()
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(observed, [desired])
        XCTAssertNotEqual(previous, desired)
    }

    func testPartialProviderSuccessRetainsOnlyFailedRouteTransition() async throws {
        let (root, _, repository, projectID, previous, desired) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let secondPrevious = Route(hostname: "second.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/project/public"))
        let secondDesired = Route(id: secondPrevious.id, hostname: secondPrevious.hostname, target: .fastCGI(socketPath: "/tmp/php-b.sock", documentRoot: "/tmp/project/public"))
        try repository.upsert(RouteIntent(route: secondPrevious, projectID: projectID, projectPath: "/tmp/project"))
        let firstTransition = try repository.persistFastCGITargetTransition(id: previous.id, projectID: projectID, expectedSocket: previous.target.fastCGISocket!, desiredSocket: desired.target.fastCGISocket!).transition
        let secondTransition = try repository.persistFastCGITargetTransition(id: secondPrevious.id, projectID: projectID, expectedSocket: secondPrevious.target.fastCGISocket!, desiredSocket: secondDesired.target.fastCGISocket!).transition
        let router = ControlledRouter(initial: [previous, secondPrevious])

        do {
            try await router.partiallyApply(desired)
            XCTFail("expected partial provider failure")
        } catch {}
        let partiallyObserved = try await router.observedRoutes()
        XCTAssertEqual(partiallyObserved.first { $0.id == desired.id }, desired)
        XCTAssertEqual(partiallyObserved.first { $0.id == secondPrevious.id }, secondPrevious)
        XCTAssertEqual(try repository.pendingTransitions(), [firstTransition, secondTransition].sorted { $0.routeID.description < $1.routeID.description })

        try repository.completeFastCGITargetTransition(id: firstTransition.routeID, projectID: projectID, desiredRoute: firstTransition.desiredRoute)
        XCTAssertEqual(try repository.pendingTransitions(), [secondTransition])
        await router.setFailure(false)
        try await router.reconcile(routes: [desired, secondDesired])
        try repository.completeFastCGITargetTransition(id: secondTransition.routeID, projectID: projectID, desiredRoute: secondTransition.desiredRoute)
        XCTAssertTrue(try repository.pendingTransitions().isEmpty)
    }
}
