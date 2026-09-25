import XCTest
import VaelenCore
@testable import VaelenCLI

final class LinkServingCommandTests: XCTestCase {
    private enum SimulatedFailure: Error, Equatable { case routeCreation }

    func testLinkUsesCurrentDirectoryOnlyWhenPathIsOmitted() throws {
        guard case .link(path: nil, hostname: nil) = try VaelenCLIMain.parse(["link"]) else { return XCTFail("no-argument link must use cwd") }
        guard case .link(path: "./sample-project", hostname: nil) = try VaelenCLIMain.parse(["link", "./sample-project"]) else { return XCTFail("path argument must remain a path") }
        guard case .link(path: "sample.test", hostname: nil) = try VaelenCLIMain.parse(["link", "sample.test"]) else { return XCTFail("a .test argument must remain a path, not a hostname") }
        guard case .link(path: "./sample-project", hostname: "api.sample.test") = try VaelenCLIMain.parse(["link", "./sample-project", "--host", "api.sample.test"]) else { return XCTFail("custom hostname did not parse") }
        guard case .link(path: nil, hostname: "custom.test") = try VaelenCLIMain.parse(["link", "--host", "custom.test"]) else { return XCTFail("cwd custom hostname did not parse") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["link", "one", "two"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["link", "--host", "one.test", "--host", "two.test"]))
    }

    func testAdditionalHostPreservesExistingRouteAndCollisionIsCaseInsensitive() {
        let projectID = UUID()
        let existing = RouteIntent(route: Route(hostname: "app.test", target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: "/tmp/site/public"), tls: .local), projectID: projectID, projectPath: "/tmp/site")
        let addition = RouteIntent(route: Route(hostname: "api.app.test", target: existing.route.target, tls: existing.route.tls), projectID: projectID, projectPath: "/tmp/site")
        XCTAssertNotEqual(existing.route.id, addition.route.id)
        XCTAssertEqual(existing.route.target, .fastCGI(socketPath: "/tmp/php.sock", documentRoot: "/tmp/site/public"))
        XCTAssertEqual(existing.route.tls, .local)
        XCTAssertNil(hostnameCollision("API.APP.TEST", candidateProjectRoutes: [existing, addition], allRoutes: [existing, addition]))

        let other = RouteIntent(route: Route(hostname: "occupied.test", target: .staticFiles(documentRoot: "/tmp/other/public")), projectID: UUID(), projectPath: "/tmp/other")
        XCTAssertEqual(hostnameCollision("OCCUPIED.TEST", candidateProjectRoutes: [existing, addition], allRoutes: [existing, addition, other]), other)
    }

    func testNewHostConfigurationFailsClosedWhenExistingTargetsOrTLSModesDiffer() throws {
        let projectID = UUID()
        let first = RouteIntent(route: Route(hostname: "one.test", target: .staticFiles(documentRoot: "/tmp/app/public"), tls: .local), projectID: projectID, projectPath: "/tmp/app")
        let same = RouteIntent(route: Route(hostname: "two.test", target: first.route.target, tls: .local), projectID: projectID, projectPath: "/tmp/app")
        let inherited = try XCTUnwrap(additionalHostConfiguration(from: [first, same]))
        XCTAssertEqual(inherited.target, first.route.target)
        XCTAssertEqual(inherited.tls, .local)

        let otherTarget = RouteIntent(route: Route(hostname: "three.test", target: .http(host: "127.0.0.1", port: 3000), tls: .local), projectID: projectID, projectPath: "/tmp/app")
        XCTAssertThrowsError(try additionalHostConfiguration(from: [first, otherTarget])) { XCTAssertEqual($0 as? AdditionalHostConfigurationError, .differingTargets) }

        let otherTLS = RouteIntent(route: Route(hostname: "four.test", target: first.route.target, tls: .disabled), projectID: projectID, projectPath: "/tmp/app")
        XCTAssertThrowsError(try additionalHostConfiguration(from: [first, otherTLS])) { XCTAssertEqual($0 as? AdditionalHostConfigurationError, .differingTLSModes) }
    }

    func testExistingProjectRouteIsSelectedAndHostCollisionIsIsolated() {
        let projectID = UUID()
        let otherID = UUID()
        let current = RouteIntent(route: Route(hostname: "custom.test", target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: "/tmp/site/web"), tls: .local), projectID: projectID, projectPath: "/tmp/site")
        let other = RouteIntent(route: Route(hostname: "site.test", target: .staticFiles(documentRoot: "/tmp/other/public")), projectID: otherID, projectPath: "/tmp/other")

        XCTAssertEqual(routesForProject([current, other], projectID: projectID, projectPath: "/tmp/site"), [current])
        XCTAssertNil(hostnameCollision("custom.test", candidateProjectRoutes: [current], allRoutes: [current, other]))
        XCTAssertEqual(hostnameCollision("site.test", candidateProjectRoutes: [current], allRoutes: [current, other]), other)
    }

    func testLegacyProjectRouteMatchesByCanonicalProjectPath() {
        let legacy = RouteIntent(route: Route(hostname: "legacy.test", target: .staticFiles(documentRoot: "/tmp/legacy/public")))
        XCTAssertEqual(routesForProject([legacy], projectID: UUID(), projectPath: "/tmp/legacy"), [legacy])
    }

    func testFreshProjectHostnameCollisionIsDetectedBeforeLink() {
        let occupied = RouteIntent(route: Route(hostname: "fresh.test", target: .staticFiles(documentRoot: "/tmp/other/public")), projectID: UUID(), projectPath: "/tmp/other")
        XCTAssertEqual(preflightLinkCollision(hostname: "fresh.test", projectPath: "/tmp/fresh", routes: [occupied]), occupied)
        XCTAssertNil(preflightLinkCollision(hostname: "fresh.test", projectPath: "/tmp/other", routes: [occupied]))
    }

    func testPrelinkedProjectWithoutRouteDoesNotConflictWithItsExpectedHostname() {
        let projectID = UUID()
        let routes: [RouteIntent] = []
        XCTAssertTrue(routesForProject(routes, projectID: projectID, projectPath: "/tmp/prelinked").isEmpty)
        XCTAssertNil(preflightLinkCollision(hostname: "prelinked.test", projectPath: "/tmp/prelinked", routes: routes))
    }

    func testRouteCreationFailureRollsBackOnlyLinkCreatedByThisInvocation() async {
        var freshLinkRolledBack = false
        do {
            let _: Void = try await withNewLinkRollback(linkCreatedByInvocation: true, rollback: { freshLinkRolledBack = true }, operation: {
                throw SimulatedFailure.routeCreation
            })
            XCTFail("simulated route creation should fail")
        } catch {
            XCTAssertEqual(error as? SimulatedFailure, .routeCreation)
        }
        XCTAssertTrue(freshLinkRolledBack)

        var existingLinkRolledBack = false
        do {
            let _: Void = try await withNewLinkRollback(linkCreatedByInvocation: false, rollback: { existingLinkRolledBack = true }, operation: {
                throw SimulatedFailure.routeCreation
            })
            XCTFail("simulated route creation should fail")
        } catch {
            XCTAssertEqual(error as? SimulatedFailure, .routeCreation)
        }
        XCTAssertFalse(existingLinkRolledBack)
    }
}
