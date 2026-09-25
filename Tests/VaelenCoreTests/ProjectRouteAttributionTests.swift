import XCTest
@testable import VaelenCore

final class ProjectRouteAttributionTests: XCTestCase {
    func testUnassociatedRouteDoesNotMatchAnUnrelatedProject() {
        let unrelated = RouteIntent(route: Route(
            hostname: "syncproof.test",
            target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: "/Users/example/syncproof/public")
        ))

        XCTAssertTrue(ProjectRouteAttribution.routes(
            for: UUID(), verifiedDocumentRoot: "/Users/example/from-barbell/public", from: [unrelated]
        ).isEmpty)
    }

    func testUnlinkedDiscoveredProjectDoesNotMatchUnassociatedRouteEvenAtItsPath() {
        let legacy = RouteIntent(
            route: Route(hostname: "legacy.test", target: .staticFiles(documentRoot: "/tmp/discovered/public")),
            projectPath: "/tmp/discovered"
        )

        XCTAssertTrue(ProjectRouteAttribution.routes(
            for: nil, verifiedDocumentRoot: "/tmp/discovered/public", from: [legacy]
        ).isEmpty)
    }

    func testLegacySyncproofRouteMatchesOnlyItsExactVerifiedDocumentRoot() {
        let syncproofID = UUID()
        let legacy = RouteIntent(route: Route(
            hostname: "syncproof.test",
            target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: "/Users/banes/Code/syncproof/public")
        ))
        let unrelated = RouteIntent(route: Route(
            hostname: "from-barbell.test",
            target: .staticFiles(documentRoot: "/Users/banes/Code/from-barbell/public")
        ))

        XCTAssertEqual(ProjectRouteAttribution.routes(
            for: syncproofID, verifiedDocumentRoot: "/Users/banes/Code/syncproof/public/", from: [legacy, unrelated]
        ), [legacy])
        XCTAssertTrue(ProjectRouteAttribution.routes(
            for: syncproofID, verifiedDocumentRoot: "/Users/banes/Code/other/public", from: [legacy]
        ).isEmpty)
    }

    func testAssociatedProjectShowsAllOfItsHostsWithoutUnassociatedRoutes() {
        let projectID = UUID()
        let first = RouteIntent(route: Route(
            hostname: "app.test",
            target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: "/tmp/app/public"),
            tls: .disabled
        ), projectID: projectID, projectPath: "/tmp/app")
        let second = RouteIntent(route: Route(
            hostname: "secure.app.test",
            target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: "/tmp/app/public"),
            tls: .local
        ), projectID: projectID, projectPath: "/tmp/app")
        let unassociated = RouteIntent(route: Route(
            hostname: "stray.test",
            target: .http(host: "127.0.0.1", port: 3000)
        ))

        XCTAssertEqual(ProjectRouteAttribution.routes(
            for: projectID, verifiedDocumentRoot: "/tmp/app/public", from: [first, second, unassociated]
        ), [first, second])
    }
}
