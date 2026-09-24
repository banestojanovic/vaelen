import XCTest
import VaelenCore
@testable import VaelenCLI

final class LinkServingCommandTests: XCTestCase {
    private enum SimulatedFailure: Error, Equatable { case routeCreation }

    func testLinkUsesCurrentDirectoryOnlyWhenPathIsOmitted() throws {
        guard case .link(path: nil) = try VaelenCLIMain.parse(["link"]) else { return XCTFail("no-argument link must use cwd") }
        guard case .link(path: "./sample-project") = try VaelenCLIMain.parse(["link", "./sample-project"]) else { return XCTFail("path argument must remain a path") }
        guard case .link(path: "sample.test") = try VaelenCLIMain.parse(["link", "sample.test"]) else { return XCTFail("a .test argument must remain a path, not a hostname") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["link", "one", "two"]))
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
