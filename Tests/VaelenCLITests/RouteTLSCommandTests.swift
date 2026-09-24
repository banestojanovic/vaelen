import XCTest
import VaelenCore
@testable import VaelenCLI

final class RouteTLSCommandTests: XCTestCase {
    private let projectID = UUID()

    private func route(_ host: String, tls: TLSMode = .local, path: String = "/tmp/site") -> RouteIntent {
        RouteIntent(route: Route(hostname: host, target: .staticFiles(documentRoot: path), tls: tls), projectID: projectID, projectPath: path)
    }

    func testCurrentDirectoryRequiresExactlyOneRouteAndExplicitHostDisambiguates() throws {
        let first = route("one.test")
        XCTAssertEqual(try selectSiteRoute([first], hostname: nil, workingDirectory: "/tmp/site"), first)
        let second = RouteIntent(route: Route(hostname: "two.test", target: .staticFiles(documentRoot: "/tmp/site")), projectID: projectID, projectPath: "/tmp/site")
        XCTAssertThrowsError(try selectSiteRoute([first, second], hostname: nil, workingDirectory: "/tmp/site")) { XCTAssertEqual($0 as? RouteSelectionError, .ambiguous(["one.test", "two.test"])) }
        XCTAssertEqual(try selectSiteRoute([first, second], hostname: "TWO.test", workingDirectory: "/tmp/site"), second)
    }

    func testNoRouteAndMissingHostnameFailWithoutInventingAnything() {
        XCTAssertThrowsError(try selectSiteRoute([], hostname: nil, workingDirectory: "/tmp/site")) { XCTAssertEqual($0 as? RouteSelectionError, .noRouteForDirectory) }
        XCTAssertThrowsError(try selectSiteRoute([], hostname: "missing.test", workingDirectory: "/tmp/site")) { XCTAssertEqual($0 as? RouteSelectionError, .notFound("missing.test")) }
    }

    func testCurrentDirectoryCanResolveLegacyRouteFromPublicDocumentRoot() throws {
        let legacy = RouteIntent(route: Route(hostname: "legacy.test", target: .staticFiles(documentRoot: "/tmp/legacy/public")))
        XCTAssertEqual(try selectSiteRoute([legacy], hostname: nil, workingDirectory: "/tmp/legacy"), legacy)
    }

    func testSecureCommandsParseOnlyOptionalExactHostname() throws {
        guard case .routeTLS(hostname: nil, secure: true) = try VaelenCLIMain.parse(["secure"]) else { return XCTFail("secure did not parse") }
        guard case .routeTLS(hostname: "site.test", secure: false) = try VaelenCLIMain.parse(["unsecure", "site.test"]) else { return XCTFail("unsecure did not parse") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["secure", "one.test", "two.test"]))
    }

    func testTLSChangePreservesIdentityAssociationAndTargetAndIsIdempotent() {
        let original = route("site.test", tls: .disabled)
        let secured = try! XCTUnwrap(routeTLSUpdate(original, secure: true))
        XCTAssertEqual(secured.route.id, original.route.id)
        XCTAssertEqual(secured.route.target, original.route.target)
        XCTAssertEqual(secured.projectID, original.projectID)
        XCTAssertEqual(secured.projectPath, original.projectPath)
        XCTAssertNotEqual(secured, original)
        XCTAssertNil(routeTLSUpdate(secured, secure: true))
        let otherRoute = route("other.test")
        let selected = try! selectSiteRoute([original, otherRoute], hostname: "site.test", workingDirectory: "/tmp/site")
        XCTAssertEqual(routeTLSUpdate(selected, secure: true), secured)
        XCTAssertEqual(otherRoute.route.tls, .local)
    }
}
